#!/usr/bin/env bash
# aggregate-report.sh MEASUREMENTS_DIR SETTLE_DIR
#
# Reads every cold/warm measurement JSON (from record-measurement.sh) and
# every settle inventory JSON (from settle.sh), and writes a per-strategy
# summary to $GITHUB_STEP_SUMMARY:
#   - per-entry median cold/warm restore+build+save duration
#   - aggregate runner-minutes actually consumed (measured)
#   - a MODELED full-workflow critical-path wall-clock estimate
#   - compressed cache bytes for the final repetition, benchmark entries
#     excluded from the redesigned steady-state figure
set -euo pipefail
MEAS_DIR="$1" SETTLE_DIR="$2"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"

all_measurements="$(find "$MEAS_DIR" -name '*.json' -print0 | xargs -0 jq -s '.' 2>/dev/null || echo '[]')"
all_settles="$(find "$SETTLE_DIR" -name '*.json' -print0 | xargs -0 cat 2>/dev/null | jq -s 'add // []')"

echo "## Cache benchmark report" >> "$GITHUB_STEP_SUMMARY"
echo "HARNESS_SHA=${HARNESS_SHA:-unknown}  BASE_SHA=${BASE_SHA:-unknown}  REDESIGN_SHA=${REDESIGN_SHA:-unknown}" >> "$GITHUB_STEP_SUMMARY"
echo "" >> "$GITHUB_STEP_SUMMARY"

for strategy in legacy redesigned; do
  echo "### ${strategy}" >> "$GITHUB_STEP_SUMMARY"
  echo "" >> "$GITHUB_STEP_SUMMARY"
  echo "| entry | median cold total ms | median warm total ms |" >> "$GITHUB_STEP_SUMMARY"
  echo "|---|---|---|" >> "$GITHUB_STEP_SUMMARY"

  entries="$(jq -r --arg s "$strategy" '[.[] | select(.strategy == $s) | .entry_id] | unique | .[]' <<<"$all_measurements")"
  total_runner_ms=0
  while IFS= read -r entry_id; do
    [[ -z "$entry_id" ]] && continue
    cold_durs="$(jq -r --arg s "$strategy" --arg e "$entry_id" \
      '[.[] | select(.strategy==$s and .entry_id==$e and .phase=="cold") | (.primary.restore_ms + .build_ms + .save_ms)] | .[]' <<<"$all_measurements")"
    warm_durs="$(jq -r --arg s "$strategy" --arg e "$entry_id" \
      '[.[] | select(.strategy==$s and .entry_id==$e and .phase=="warm") | (.primary.restore_ms + .build_ms + .save_ms)] | .[]' <<<"$all_measurements")"
    cold_median="$(median $cold_durs)"
    warm_median="$(median $warm_durs)"
    echo "| ${entry_id} | ${cold_median} | ${warm_median} |" >> "$GITHUB_STEP_SUMMARY"

    sum_ms="$(jq -r --arg s "$strategy" --arg e "$entry_id" \
      '[.[] | select(.strategy==$s and .entry_id==$e) | (.primary.restore_ms + .build_ms + .save_ms)] | add // 0' <<<"$all_measurements")"
    total_runner_ms=$((total_runner_ms + sum_ms))
  done <<<"$entries"

  runner_minutes="$(awk -v ms="$total_runner_ms" 'BEGIN { printf "%.1f", ms/60000 }')"
  echo "" >> "$GITHUB_STEP_SUMMARY"
  echo "Aggregate measured runner-minutes across all cold+warm executions: **${runner_minutes}**" >> "$GITHUB_STEP_SUMMARY"

  modeled_ms="$(jq -r --arg s "$strategy" \
    '([.[] | select(.strategy==$s and .phase=="cold") | (.primary.restore_ms + .build_ms + .save_ms)] | max // 0)
     + ([.[] | select(.strategy==$s and .phase=="warm") | (.primary.restore_ms + .build_ms + .save_ms)] | max // 0)' <<<"$all_measurements")"
  echo "MODELED full-workflow critical-path wall-clock (max single-entry cold + max single-entry warm, not observed end-to-end): ${modeled_ms} ms" >> "$GITHUB_STEP_SUMMARY"

  final_rep_bytes="$(jq -r --arg s "$strategy" \
    '[.[] | select((.key | startswith("ci-cache-benchmark-" + $s)) and (.key | test("-rep3-")))] | [.[].size_in_bytes] | add // 0' <<<"$all_settles")"
  echo "Compressed cache bytes recorded at final repetition (rep 3) settle inventory: ${final_rep_bytes} bytes" >> "$GITHUB_STEP_SUMMARY"
  if [[ "$strategy" == "redesigned" ]]; then
    echo "_Benchmark-prefixed entries are excluded from the redesigned steady-state calculation by construction: this number is the benchmark measurement itself, not steady-state repository usage._" >> "$GITHUB_STEP_SUMMARY"
  fi
  echo "" >> "$GITHUB_STEP_SUMMARY"
done
