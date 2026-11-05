FROM elixir:1.20.5-otp-29
RUN apt-get update && apt-get install -y --no-install-recommends curl git ca-certificates build-essential && rm -rf /var/lib/apt/lists/*
ENV ELAN_HOME=/opt/elan MIX_HOME=/opt/mix HEX_HOME=/opt/hex
ENV PATH="/opt/elan/bin:${PATH}"
RUN curl -sSf https://raw.githubusercontent.com/leanprover/elan/master/elan-init.sh | sh -s -- -y --no-modify-path --default-toolchain leanprover/lean4:v4.35.0 \
 && lean --version \
 && mix local.hex --force && mix local.rebar --force \
 && mkdir -p /opt/hex && chmod -R a+rwX /opt/elan /opt/mix /opt/hex
ENV HOME=/tmp
WORKDIR /app
