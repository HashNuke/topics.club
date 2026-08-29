# Find eligible builder and runner images on Docker Hub. We use Ubuntu/Debian
# instead of Alpine to avoid DNS resolution issues in production.
#
# https://hub.docker.com/r/hexpm/elixir/tags?name=ubuntu
# https://hub.docker.com/_/ubuntu/tags
#
# This file is based on these images:
#
#   - https://hub.docker.com/r/hexpm/elixir/tags - for the build image
#   - https://hub.docker.com/_/debian/tags?name=trixie-20260505-slim - for the release image
#   - https://pkgs.org/ - resource for finding needed packages
#   - Ex: docker.io/hexpm/elixir:1.19.5-erlang-28.5-debian-trixie-20260505-slim
#
ARG ELIXIR_VERSION=1.19.5
ARG OTP_VERSION=28.5
ARG DEBIAN_VERSION=trixie-20260505-slim

ARG BUILDER_IMAGE="docker.io/hexpm/elixir:${ELIXIR_VERSION}-erlang-${OTP_VERSION}-debian-${DEBIAN_VERSION}"
ARG RUNNER_IMAGE="docker.io/debian:${DEBIAN_VERSION}"

FROM ${BUILDER_IMAGE} AS builder

# install build dependencies
RUN apt-get update \
  && apt-get install -y --no-install-recommends build-essential git npm \
  && rm -rf /var/lib/apt/lists/*

# prepare build dir
WORKDIR /app

# install hex + rebar
RUN mix local.hex --force \
  && mix local.rebar --force

# set build ENV
ENV MIX_ENV="prod"

# install mix dependencies
COPY mix.exs mix.lock ./
COPY apps/topics_club_core/mix.exs apps/topics_club_core/mix.exs
COPY apps/topics_club_engine/mix.exs apps/topics_club_engine/mix.exs
COPY apps/topics_club_gateway/mix.exs apps/topics_club_gateway/mix.exs
RUN mix deps.get --only $MIX_ENV
RUN mkdir config

# copy compile-time config files before we compile dependencies
# to ensure any relevant config change will trigger the dependencies
# to be re-compiled.
COPY config/config.exs config/${MIX_ENV}.exs config/
RUN mix deps.compile

RUN mix assets.setup

COPY apps/topics_club_gateway/assets/package.json apps/topics_club_gateway/assets/package-lock.json apps/topics_club_gateway/assets/
RUN npm ci --prefix apps/topics_club_gateway/assets --omit=dev

COPY priv priv

COPY apps/topics_club_core apps/topics_club_core
COPY apps/topics_club_engine apps/topics_club_engine
COPY apps/topics_club_gateway/lib apps/topics_club_gateway/lib
COPY apps/topics_club_gateway/priv/gettext apps/topics_club_gateway/priv/gettext

COPY lib lib

# Compile the release
RUN mix compile

COPY apps/topics_club_gateway/assets apps/topics_club_gateway/assets
COPY apps/topics_club_gateway/priv/static apps/topics_club_gateway/priv/static

# compile assets
RUN mix assets.deploy

# Changes to config/runtime.exs don't require recompiling the code
COPY config/runtime.exs config/

COPY rel rel
ARG RAILWAY_GIT_COMMIT_SHA
RUN source_revision="${RAILWAY_GIT_COMMIT_SHA:-}" \
  && if [ -z "$source_revision" ]; then \
    source_revision="$(find apps config lib priv rel mix.exs mix.lock -type f -print0 \
      | sort -z \
      | xargs -0 sha256sum \
      | sha256sum \
      | cut -c1-40)"; \
  fi \
  && TOPICS_CLUB_SOURCE_REVISION="$source_revision" mix release topics_club

# start a new build stage so that the final image will only contain
# the compiled release and other runtime necessities
FROM ${RUNNER_IMAGE} AS final

RUN apt-get update \
  && apt-get install -y --no-install-recommends libstdc++6 openssl libncurses6 locales ca-certificates curl \
  && rm -rf /var/lib/apt/lists/*

# Set the locale
RUN sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen \
  && locale-gen

ENV LANG=en_US.UTF-8
ENV LANGUAGE=en_US:en
ENV LC_ALL=en_US.UTF-8

WORKDIR "/app"
RUN chown nobody /app

# set runner ENV
ENV MIX_ENV="prod"

# Only copy the final release from the build stage
COPY --from=builder --chown=nobody:root /app/_build/${MIX_ENV}/rel/topics_club ./

USER nobody

HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=3 \
  CMD curl --fail --silent "http://127.0.0.1:${PORT:-4000}/health" >/dev/null || exit 1

# If using an environment that doesn't automatically reap zombie processes, it is
# advised to add an init process such as tini via `apt-get install`
# above and adding an entrypoint. See https://github.com/krallin/tini for details
# ENTRYPOINT ["/tini", "--"]

CMD ["/app/bin/server"]
