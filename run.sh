#!/bin/sh
# Runs a command for one package inside the Elixir + Lean image, as the current user.
# Usage: MOP_PROJECT=mop_access ./run.sh mix test
cd "$(dirname "$0")"
exec docker run --rm -i --user "$(id -u):$(id -g)" -v "$PWD":/app -w "/app/${MOP_PROJECT:-mop_br}" mop-lean "$@"
