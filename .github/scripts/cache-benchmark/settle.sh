#!/usr/bin/env bash
# settle.sh REPO PREFIX OUT_JSON
#
# Runs after every warm run (or grouped warm phase) for one ownership
# group: takes a stable paginated inventory of that group's
# ci-cache-benchmark-<pair_id>- prefixed entries, records their compressed
# actions-cache sizes to OUT_JSON, then deletes them by ID so the next
# repetition starts from a clean slate. Never touches anything outside
# its own prefix, so unrelated concurrently-running groups are untouched.
set -euo pipefail
REPO="$1" PREFIX="$2" OUT="$3"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"

inventory="$(cache_stable_inventory "$REPO" "$PREFIX")"
echo "$inventory" | jq -c '[.[] | {id, key, ref, size_in_bytes}]' > "$OUT"

n="$(jq 'length' <<<"$inventory")"
echo "settle: prefix=${PREFIX} entries=${n}"

if [[ "$n" -gt 0 ]]; then
  ids="$(jq -r '.[].id' <<<"$inventory")"
  cache_delete_ids "$REPO" $ids

  remaining="$(cache_list_all "$REPO" "$PREFIX" | jq 'length')"
  if [[ "$remaining" -ne 0 ]]; then
    echo "::error::settle: ${remaining} cache entries under prefix '${PREFIX}' survived deletion" >&2
    exit 1
  fi
fi
