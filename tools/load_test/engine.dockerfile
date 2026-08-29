ARG BUILDER_IMAGE=topics-club-load-builder:local
FROM ${BUILDER_IMAGE} AS builder

ARG SOURCE_REVISION

RUN TOPICS_CLUB_SOURCE_REVISION="${SOURCE_REVISION}" \
    mix release topics_club_engine --path /engine-release --overwrite

FROM docker.io/debian:trixie-20260505-slim

RUN apt-get update \
  && apt-get install -y --no-install-recommends ca-certificates libncurses6 libssl3t64 libstdc++6 \
  && rm -rf /var/lib/apt/lists/*

WORKDIR /app
RUN chown nobody:root /app

COPY --from=builder --chown=nobody:root /engine-release/ /app/

ENV ERL_CRASH_DUMP=/tmp/topics-club-engine.dump
ENV LANG=C.UTF-8
ENV LC_ALL=C.UTF-8
ENV ELIXIR_ERL_OPTIONS=+fnu
ENV MIX_ENV=prod

USER nobody

CMD ["/app/bin/topics_club_engine", "start"]
