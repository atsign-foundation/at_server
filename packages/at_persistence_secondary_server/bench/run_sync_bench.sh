#!/usr/bin/env bash
# Sweeps the sync commit-log scan bench across log sizes and writes the full
# output to a file. See bench/sync_commit_log_bench.dart for what is measured.
#
#   ./bench/run_sync_bench.sh                 # 100k, 500k, 1M
#   SIZES="100000" ./bench/run_sync_bench.sh  # override the sweep
#
# Output: bench/results/sync_bench_<host>.txt (full log, never piped through
# tail — a truncated failure means re-running a multi-minute seed).
set -euo pipefail

cd "$(dirname "$0")/.."

SIZES=${SIZES:-"100000 500000 1000000"}
REPEAT=${REPEAT:-3}
# Per-size wall-clock bound. Seeding 1e6 entries into Hive dominates; 2x the
# observed worst case. macOS has no coreutils `timeout`.
TIMEOUT=${TIMEOUT:-1800}

OUT_DIR="bench/results"
mkdir -p "$OUT_DIR"
OUT="$OUT_DIR/sync_bench_$(hostname -s).txt"
: > "$OUT"

{
  echo "host:   $(hostname -s)"
  echo "uname:  $(uname -a)"
  echo "dart:   $(dart --version 2>&1)"
  echo "date:   $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "commit: $(git rev-parse --short HEAD)"
  echo "sizes:  $SIZES"
  echo
} >> "$OUT"

# AOT-compile once: the secondary runs from an AOT snapshot, and JIT vs AOT
# materially changes a tight per-entry loop. Benchmarking `dart run` would
# measure the wrong runtime.
BIN="$(mktemp -d)/sync_bench"
echo ">>> compiling (AOT)" | tee -a "$OUT"
dart compile exe bench/sync_commit_log_bench.dart -o "$BIN" >> "$OUT" 2>&1
trap 'rm -rf "$(dirname "$BIN")"' EXIT

status=0
for n in $SIZES; do
  echo ">>> entries=$n" | tee -a "$OUT"
  set +e
  perl -e 'alarm shift; exec @ARGV' "$TIMEOUT" \
    "$BIN" --entries "$n" --repeat "$REPEAT" \
    >> "$OUT" 2>&1
  rc=$?
  set -e
  if [[ $rc -ne 0 ]]; then
    echo "!!! entries=$n FAILED (exit $rc)" | tee -a "$OUT"
    status=$rc
  fi
  echo >> "$OUT"
done

echo
echo "full results: $OUT"
tail -n 40 "$OUT"
exit $status
