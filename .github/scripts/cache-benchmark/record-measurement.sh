#!/usr/bin/env bash
# record-measurement.sh OUTPUT_JSON_PATH
#
# Appends a row to the job summary and writes the full measurement as JSON
# to OUTPUT_JSON_PATH, from env vars set by the calling job:
#   ENTRY_ID BENCH_STRATEGY BENCH_REP BENCH_PHASE PAIR_ID BENCH_PREFIX
#   PRIMARY_KEY PRIMARY_CACHE_HIT PRIMARY_CACHE_MATCHED_KEY PRIMARY_RESTORE_MS PRIMARY_SIZE_BYTES
#   SECONDARY_ACTIVE SECONDARY_KEY SECONDARY_CACHE_HIT SECONDARY_CACHE_MATCHED_KEY SECONDARY_RESTORE_MS SECONDARY_SIZE_BYTES
#   BUILD_MS SAVE_MS
set -euo pipefail
OUT="$1"

classify() {
  local hit="$1" matched="$2"
  if [[ "$hit" == "true" ]]; then
    echo "exact"
  elif [[ -n "$matched" ]]; then
    echo "prefix"
  else
    echo "miss"
  fi
}

primary_status="$(classify "${PRIMARY_CACHE_HIT:-}" "${PRIMARY_CACHE_MATCHED_KEY:-}")"
secondary_status="skipped"
if [[ "${SECONDARY_ACTIVE:-false}" == "true" ]]; then
  secondary_status="$(classify "${SECONDARY_CACHE_HIT:-}" "${SECONDARY_CACHE_MATCHED_KEY:-}")"
fi

jq -n \
  --arg entry_id "$ENTRY_ID" \
  --arg strategy "$BENCH_STRATEGY" \
  --argjson rep "$BENCH_REP" \
  --arg phase "$BENCH_PHASE" \
  --arg pair_id "$PAIR_ID" \
  --arg prefix "$BENCH_PREFIX" \
  --arg primary_key "${PRIMARY_KEY:-}" \
  --arg primary_matched_key "${PRIMARY_CACHE_MATCHED_KEY:-}" \
  --arg primary_status "$primary_status" \
  --argjson primary_restore_ms "${PRIMARY_RESTORE_MS:-0}" \
  --argjson primary_size_bytes "${PRIMARY_SIZE_BYTES:-0}" \
  --arg secondary_active "${SECONDARY_ACTIVE:-false}" \
  --arg secondary_key "${SECONDARY_KEY:-}" \
  --arg secondary_matched_key "${SECONDARY_CACHE_MATCHED_KEY:-}" \
  --arg secondary_status "$secondary_status" \
  --argjson secondary_restore_ms "${SECONDARY_RESTORE_MS:-0}" \
  --argjson secondary_size_bytes "${SECONDARY_SIZE_BYTES:-0}" \
  --argjson build_ms "${BUILD_MS:-0}" \
  --argjson save_ms "${SAVE_MS:-0}" \
  '{
    entry_id: $entry_id, strategy: $strategy, rep: $rep, phase: $phase,
    pair_id: $pair_id, prefix: $prefix,
    primary: {
      key: $primary_key, matched_key: $primary_matched_key,
      status: $primary_status, restore_ms: $primary_restore_ms,
      uncompressed_size_bytes: $primary_size_bytes
    },
    secondary: {
      active: ($secondary_active == "true"),
      key: $secondary_key, matched_key: $secondary_matched_key,
      status: $secondary_status, restore_ms: $secondary_restore_ms,
      uncompressed_size_bytes: $secondary_size_bytes
    },
    build_ms: $build_ms, save_ms: $save_ms
  }' > "$OUT"

{
  echo "| ${ENTRY_ID} | ${BENCH_STRATEGY} | ${BENCH_REP} | ${BENCH_PHASE} | primary:${primary_status} | secondary:${secondary_status} | restore ${PRIMARY_RESTORE_MS:-0}ms | build ${BUILD_MS:-0}ms | save ${SAVE_MS:-0}ms |"
} >> "$GITHUB_STEP_SUMMARY"
