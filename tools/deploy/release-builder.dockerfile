# Keep the Erlang and Elixir versions aligned with the root Dockerfile, but
# compile the bare-host artifact in the same Ubuntu userspace as its target.
FROM docker.io/hexpm/elixir:1.19.5-erlang-28.5-debian-trixie-20260505-slim@sha256:133fa7e54ceb2d812e9f79e33e827019c3df2c1f8e89b6ae37d605d78d4d17cb AS toolchain

FROM docker.io/ubuntu:26.04@sha256:2260313b31c8c011cd2eebe728008efac1b3982be73eb71348ea2648d2c0e09b AS builder

# The pinned HexPM image supplies only the build toolchain. Dependencies and
# NIFs are compiled after the toolchain is copied into Ubuntu 26.04.
COPY --from=toolchain /usr/local/ /usr/local/

RUN apt-get update \
  && apt-get install -y --no-install-recommends \
    build-essential \
    git \
    libncurses6 \
    libssl3t64 \
    libstdc++6 \
    nodejs=22.22.1+dfsg+~cs22.19.15-1ubuntu1 \
    npm=9.2.0~ds3-1 \
  && rm -rf /var/lib/apt/lists/*

WORKDIR /app
ENV MIX_ENV=prod
ENV ERL_COMPILER_OPTIONS=deterministic
ENV LANG=C.UTF-8
# Keep build-on-host releases viable on the supported 1.5 GB VPS floor. These
# limits apply only to the disposable builder, not to the running release.
ENV ERL_FLAGS="+S 1:1 +SDcpu 1 +SDio 1 +A 1 +Mea min"
ENV MAKEFLAGS=-j1

RUN mix local.hex --force && mix local.rebar --force

COPY mix.exs mix.lock ./
COPY apps/topics_club_core/mix.exs apps/topics_club_core/mix.exs
COPY apps/topics_club_engine/mix.exs apps/topics_club_engine/mix.exs
COPY apps/topics_club_gateway/mix.exs apps/topics_club_gateway/mix.exs
RUN mix deps.get --only prod --check-locked

COPY config/config.exs config/prod.exs config/
RUN mix deps.compile

COPY apps/topics_club_gateway/assets/package.json apps/topics_club_gateway/assets/package-lock.json apps/topics_club_gateway/assets/
ARG RELEASE_NAME
RUN if [ "$RELEASE_NAME" = topics_club_gateway ]; then \
      npm ci --prefix apps/topics_club_gateway/assets --omit=dev; \
    fi

COPY . .

ARG SOURCE_REVISION
ARG BUILD_TAG

RUN mix compile \
  && if [ "$RELEASE_NAME" = topics_club_gateway ]; then mix assets.setup && mix assets.deploy; fi \
  && TOPICS_CLUB_SOURCE_REVISION="$SOURCE_REVISION" \
    mix release "$RELEASE_NAME" --path /output --overwrite \
  && release_version=$(awk '{print $2}' /output/releases/start_erl.data) \
  && erlang_version=$(erl -noshell -eval 'io:format("~s", [erlang:system_info(otp_release)]), halt().') \
  && elixir_version=$(elixir --version | awk '/^Elixir / {print $2}') \
  && { \
    printf 'tag=%s\n' "$BUILD_TAG"; \
    printf 'commit=%s\n' "$SOURCE_REVISION"; \
    printf 'release=%s\n' "$RELEASE_NAME"; \
    printf 'release_version=%s\n' "$release_version"; \
    printf 'erlang=%s\n' "$erlang_version"; \
    printf 'elixir=%s\n' "$elixir_version"; \
    printf 'node=%s\n' "$(node --version)"; \
    printf 'npm=%s\n' "$(npm --version)"; \
    printf 'builder_os=%s\n' 'ubuntu:26.04'; \
    printf 'toolchain_image=%s\n' 'hexpm/elixir:1.19.5-erlang-28.5'; \
    printf 'built_at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"; \
  } > /output/deploy-manifest

FROM scratch AS artifact
COPY --from=builder /output /
