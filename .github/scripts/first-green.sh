#!/usr/bin/env bash
# usage: first-green.sh <empty work folder> [budget seconds, default 300]
# Runs `mana new demo` from this checkout, then the starter's headless suite,
# printing how long each stage took. Fails when either fails or the whole
# run exceeds the budget.
set -euo pipefail
shopt -s lastpipe

work=$1
budget=${2:-300}
repo=$(cd "$(dirname "$0")/../.." && pwd)
mkdir -p "$work"
cd "$work"

now() { date +%s%3N; }
seconds() { printf '%d.%d' $(($1 / 1000)) $(($1 % 1000 / 100)); }

stages=()
start=$(now)
last=$start
label="start"
close() {
  local at
  at=$(now)
  stages+=("$(printf '%8ss  %s' "$(seconds $((at - last)))" "$label")")
  label=$1
  last=$at
}

status=0
{
  "$repo/framework/cli/mana" new demo --mana-url "$repo"
  cd demo
  mana/framework/moments/moments suite --headless --project app
} 2>&1 | while IFS= read -r line; do
  printf '%s\n' "$line"
  # Each progress line of `mana new` ("· stage") or of the suite ("Suite: ...")
  # closes the stage before it.
  case "$line" in "· "* | "Suite: "*) close "${line#· }" ;; esac
done || status=$?
close ""
total=$(($(now) - start))

echo
echo "Stage durations:"
printf '%s\n' "${stages[@]}"
printf '%8ss  total (budget %ss)\n' "$(seconds "$total")" "$budget"
if [ "$status" -ne 0 ]; then
  echo "FAILED: exit status $status"
  exit "$status"
fi
if [ "$total" -gt $((budget * 1000)) ]; then
  echo "FAILED: over the ${budget}s budget"
  exit 1
fi
