#!/usr/bin/env bash
# usage: boundary.sh
# Keeps the two halves of Mana apart in code: the Flutter packages
# (framework/flutter) never reach into the Elixir ones (framework/ash,
# framework/mop), and the Elixir packages never reach into the Dart side
# (framework/flutter, framework/cli, framework/moments). They meet only in the
# shared artifacts: the JSON:API contract, catalog.toml and the Moments
# protocol. Prose (*.md) may name the other side; code may not. The CLI and the
# Moments launcher are tooling over both halves and stay out of this rule.
set -euo pipefail

cd "$(dirname "$0")/../../framework"
code=(-rnE --exclude='*.md' --exclude='*.lock' --exclude-dir=build --exclude-dir=.dart_tool
  --exclude-dir=deps --exclude-dir=_build)
failed=0

if grep "${code[@]}" '(framework/|\.\./)+(ash|mop)/' flutter; then
  echo "A Flutter package reaches into the Elixir side (above)." >&2
  failed=1
fi

if grep "${code[@]}" '(framework/|\.\./)+(flutter|cli|moments)/' ash mop; then
  echo "An Elixir package reaches into the Dart side (above)." >&2
  failed=1
fi

[ "$failed" = 0 ] && echo "boundary: Flutter and Elixir packages meet only in the shared artifacts"
exit "$failed"
