#!/bin/sh
# Elaborates the translated Lean files of a law group and prints Lean's messages.
# Usage (inside the container, from mop_br): ../leancheck.sh tmp/<Module>/<group>
set -e
dir="$1"
out=/tmp/olean
mkdir -p "$out"
export LEAN_PATH="/app/${MOP_PROJECT:-mop_br}/deps/lynx/Lean/.lake/build/lib/lean:$out"
cd "$dir"
for f in $(find . -name '*.lean' | sort | awk '{print length($0) " " $0}' | sort -n | cut -d' ' -f2); do
  mod=$(echo "$f" | sed 's#^\./##; s#\.lean$##; s#/#.#g')
  mkdir -p "$out/$(dirname "$f")"
  lean -R . -o "$out/${f%.lean}.olean" -i "$out/${f%.lean}.ilean" "$f" || true
done
