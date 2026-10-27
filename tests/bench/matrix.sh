#!/usr/bin/env bash
# Runs run.lua (core, open, each command) and overlay.lua on every shape, each in
# its own process, into .bench/results/. Generate the files first with gen.lua.
#   bash tests/bench/matrix.sh [shape ...]     (default: all rows x columns below)
cd "$(dirname "$0")/../.." || exit 1
mkdir -p .bench/results
shapes=("$@")
if [ ${#shapes[@]} -eq 0 ]; then
  for n in 10000 100000 1000000; do for c in 5 10 25 50 100; do shapes+=("${n}x${c}"); done; done
fi
# a runaway allocation fails instead of swapping the machine to a halt
ulimit -v 8000000
run() { # name, then the command
  local out=".bench/results/$1.txt"; shift
  timeout 1800 "$@" > "$out" 2>&1
  echo "exit $?" >> "$out"
}
for s in "${shapes[@]}"; do
  echo "== $s $(date +%T)"
  run "$s.core" nvim --headless --clean -l tests/bench/run.lua "$s" core
  run "$s.open" nvim --headless --clean -l tests/bench/run.lua "$s" open
  run "$s.row_add" nvim --headless --clean -l tests/bench/run.lua "$s" "row add"
  run "$s.sort_price" nvim --headless --clean -l tests/bench/run.lua "$s" "sort price"
  run "$s.sort_name" nvim --headless --clean -l tests/bench/run.lua "$s" "sort name desc"
  run "$s.addcol" nvim --headless --clean -l tests/bench/run.lua "$s" "addcol total formula price * qty + 1"
  run "$s.overlay" nvim --headless --clean -l tests/bench/overlay.lua "$s"
done
echo finished
