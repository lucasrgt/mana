# Mana's pinned Elixir toolchain (framework/ash/toolchain) plus Lean 4.35.0 for Lynx: the laws are
# checked on the same compiler and OTP that run the code they describe.
FROM elixir@sha256:09b37446f1b24a280890c4b294eec6a53ba2501a2289959b483d849035e1053c
RUN apt-get update && apt-get install -y --no-install-recommends build-essential git ca-certificates curl \
    && rm -rf /var/lib/apt/lists/*
ENV ELAN_HOME=/opt/elan MIX_HOME=/opt/mix HEX_HOME=/opt/hex
ENV PATH="/opt/elan/bin:${PATH}"
RUN curl -sSf https://raw.githubusercontent.com/leanprover/elan/master/elan-init.sh | sh -s -- -y --no-modify-path --default-toolchain leanprover/lean4:v4.35.0 \
 && lean --version \
 && mix local.hex --force && mix local.rebar --force \
 && mkdir -p /opt/hex && chmod -R a+rwX /opt/elan /opt/mix /opt/hex
ENV HOME=/tmp
WORKDIR /app
