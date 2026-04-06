# Find eligible builder and runner images on Docker Hub. We use Ubuntu/Debian
# instead of Alpine to avoid DNS resolution issues in production.
#
# https://hub.docker.com/r/hexpm/elixir/tags?name=debian
# https://hub.docker.com/_/debian/tags?name=bookworm-slim
#
# Build context is the parent dust/ directory (set via Kamal builder.context)
# so that the dust_protocol path dependency can be copied into the image.
#
ARG ELIXIR_VERSION=1.18.4
ARG OTP_VERSION=27.3.4.1
ARG DEBIAN_VERSION=bookworm-20250630

ARG BUILDER_IMAGE="hexpm/elixir:${ELIXIR_VERSION}-erlang-${OTP_VERSION}-debian-${DEBIAN_VERSION}"
ARG RUNNER_IMAGE="debian:${DEBIAN_VERSION}"

FROM ${BUILDER_IMAGE} AS builder

# install build dependencies
RUN apt-get update -y && \
  apt-get install -y --no-install-recommends \
  build-essential \
  git \
  curl \
  ca-certificates \
  unzip \
  && rm -rf /var/lib/apt/lists/*

# Install Bun for asset building
RUN curl -fsSL https://bun.sh/install | bash
ENV PATH="/root/.bun/bin:${PATH}"

# prepare build dir
WORKDIR /app

# install hex + rebar
RUN mix local.hex --force \
  && mix local.rebar --force

# set build ENV
ENV MIX_ENV="prod"
ENV ERL_FLAGS="+JPperf true"

# Copy the protocol dependency (path: "../protocol/elixir" in mix.exs)
COPY protocol/elixir /protocol/elixir

# install mix dependencies
COPY server/mix.exs server/mix.lock ./
RUN mix deps.get --only $MIX_ENV
RUN mkdir config

# copy compile-time config files before we compile dependencies
# to ensure any relevant config change will trigger the dependencies
# to be re-compiled.
COPY server/config/config.exs server/config/${MIX_ENV}.exs config/
RUN mix deps.compile

COPY server/priv priv

COPY server/lib lib

COPY server/assets assets

# compile assets
RUN mix assets.setup
RUN mix assets.deploy

# Compile the release
RUN mix compile

# Changes to config/runtime.exs don't require recompiling the code
COPY server/config/runtime.exs config/

COPY server/rel rel
RUN mix release

# start a new build stage so that the final image will only contain
# the compiled release and other runtime necessities
FROM ${RUNNER_IMAGE} AS final

RUN apt-get update -y && \
  apt-get install -y --no-install-recommends \
  libstdc++6 \
  openssl \
  libncurses5 \
  locales \
  ca-certificates \
  tini \
  && rm -rf /var/lib/apt/lists/*

# Set the locale
RUN sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen \
  && locale-gen

ENV LANG=en_US.UTF-8
ENV LANGUAGE=en_US:en
ENV LC_ALL=en_US.UTF-8

WORKDIR "/app"

# Create persistent store data directory (mounted as volume in production)
RUN mkdir -p /app/data/stores && chown -R nobody:nogroup /app/data

RUN chown nobody /app

# set runner ENV
ENV MIX_ENV="prod"
ENV ERL_FLAGS="+JPperf true"

# Only copy the final release from the build stage
COPY --from=builder --chown=nobody:root /app/_build/${MIX_ENV}/rel/dust ./

# Make the release binaries executable
RUN chmod +x /app/bin/*

USER nobody

# Use Tini as init system to properly handle signals and reap zombie processes
ENTRYPOINT ["/usr/bin/tini", "--"]

CMD ["sh", "-c", "/app/bin/migrate && /app/bin/server"]
