#!/usr/bin/env bash
# usage: local-ci.sh [base]   (default: the upstream of the current branch)
# CI's checks, on this machine, for the packages changed since base: each
# Elixir package (deps, hex.audit, format, Credo strict with ManaLint,
# compile and test with warnings as errors, in the pinned toolchain), each MOP
# package with its laws proved (the pinned toolchain plus Lean), cli and
# moments (format, analyze, test), each Flutter package (format, analyze,
# test), the agent skill, and mana new to green when the starter changed.
# Postgres-tagged tests run when MANA_TEST_POSTGRES names a database.
set -euo pipefail

repo=$(cd "$(dirname "$0")/../.." && pwd)
cd "$repo"
base=${1:-$(git rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null || echo origin/main)}
changed=$(git diff --name-only "$base"...HEAD; git diff --name-only HEAD)
mana=framework/cli/mana
ran=0

touched() { grep -q "^$1" <<<"$changed"; }
step() { echo "· $*"; ran=1; }

for dir in framework/ash/*/; do
  dir=${dir%/}
  [ -f "$dir/mix.exs" ] || continue
  touched "$dir/" || touched framework/ash/.credo.exs || touched framework/ash/lint/ ||
    { [ "$dir" = framework/ash/web ] && touched framework/catalog.toml; } || continue
  step "Elixir $(basename "$dir")"
  "$mana" mix "$dir" do deps.get + hex.audit + format --check-formatted + compile --warnings-as-errors + credo --strict
  MIX_ENV=test "$mana" mix "$dir" test --warnings-as-errors
done

for dir in framework/mop/*/; do
  dir=${dir%/}
  [ -f "$dir/mix.exs" ] || continue
  touched "$dir/" || touched framework/mop/Dockerfile || continue
  step "Laws $(basename "$dir")"
  docker build -q -t mop-laws framework/mop >/dev/null
  MOP_PROJECT=$(basename "$dir") framework/mop/run.sh sh -c \
    'mix deps.get >/dev/null && mix format --check-formatted && mix compile --warnings-as-errors && mix test'
done

for pkg in cli moments; do
  touched "framework/$pkg/" || continue
  step "Dart $pkg"
  (cd "framework/$pkg" && dart pub get --enforce-lockfile >/dev/null &&
    dart format --output=none --set-exit-if-changed bin lib test && dart analyze && dart test)
done

for dir in framework/flutter/*/; do
  dir=${dir%/}
  touched "$dir/" || continue
  step "Flutter $(basename "$dir")"
  (cd "$dir" && flutter pub get >/dev/null && dart format --output=none --set-exit-if-changed . &&
    flutter analyze && if [ -d test ]; then flutter test; fi)
done

if touched framework/catalog.toml || touched framework/agents/; then
  step "agent skill"
  "$mana" capabilities skill --check
fi

if touched framework/cli/templates/ || touched framework/cli/lib/src/new_project.dart || touched framework/contracts/; then
  step "mana new to green"
  work=$(mktemp -d)
  .github/scripts/first-green.sh "$work" 300
  rm -rf "$work"
fi

[ "$ran" = 1 ] || echo "· nothing CI covers changed since $base"
