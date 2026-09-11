#!/usr/bin/env bash
# Shared helpers for querying and mutating the GitHub Actions cache API
# (repos/{owner}/{repo}/actions/caches). Sourced by cache-benchmark.yaml
# steps; requires `gh`, `jq`, and GH_TOKEN in the environment.
set -euo pipefail

# cache_list_page REPO PAGE
# Prints one unfiltered page (100 entries) of the cache list JSON payload.
#
# Deliberately does NOT use the API's server-side "key" prefix filter
# (`-f key=...`): on Windows runners specifically, a key-filtered query
# was observed to reliably return 0 matches for over 5 minutes after a
# confirmed-successful save, while an unfiltered listing from the exact
# same job/runner/token found the entry immediately, and ubuntu/macOS
# runners never showed the problem with the filter at all. That points
# at a bug/inconsistency in the server-side key-filter's index
# specifically, not general propagation lag or an HTTP cache -- so this
# always fetches the full unfiltered list and filters client-side
# instead (see cache_list_all).
cache_list_page() {
  local repo="$1" page="$2"
  gh api "repos/${repo}/actions/caches" \
    --method GET \
    -F "per_page=100" \
    -F "page=${page}"
}

# cache_list_all REPO KEY_PREFIX
# Fully paginates the unfiltered cache list until every entry has been
# seen, then filters client-side by key prefix. Prints a JSON array of
# matching cache objects (id, key, ref, size_in_bytes, ...).
cache_list_all() {
  local repo="$1" prefix="$2"
  local page=1 total=-1 seen=0 collected="[]"
  while :; do
    local resp
    resp="$(cache_list_page "$repo" "$page")"
    total="$(jq -r '.total_count' <<<"$resp")"
    local batch_all batch_n matched
    batch_all="$(jq -c '.actions_caches' <<<"$resp")"
    batch_n="$(jq 'length' <<<"$batch_all")"
    seen=$((seen + batch_n))
    matched="$(jq -c --arg p "$prefix" '[.[] | select(.key | startswith($p))]' <<<"$batch_all")"
    collected="$(jq -c -s '.[0] + .[1]' <(echo "$collected") <(echo "$matched"))"
    if [[ "$seen" -ge "$total" ]] || [[ "$batch_n" -eq 0 ]]; then
      break
    fi
    page=$((page + 1))
  done
  echo "$collected"
}

# cache_stable_inventory REPO KEY_PREFIX [MAX_ATTEMPTS]
# Repeats the complete paginated read until two consecutive reads report
# the same total_count and identical sorted cache-ID sets. Prints the
# final stable JSON array. Fails (non-zero) if it never stabilizes.
cache_stable_inventory() {
  local repo="$1" prefix="$2" max="${3:-10}"
  local prev="" cur="" attempt=1
  prev="$(cache_list_all "$repo" "$prefix" | jq -c 'sort_by(.id)')"
  while [[ "$attempt" -lt "$max" ]]; do
    sleep 2
    cur="$(cache_list_all "$repo" "$prefix" | jq -c 'sort_by(.id)')"
    if [[ "$(jq -c '[.[].id]' <<<"$prev")" == "$(jq -c '[.[].id]' <<<"$cur")" ]]; then
      echo "$cur"
      return 0
    fi
    prev="$cur"
    attempt=$((attempt + 1))
  done
  echo "::error::cache inventory for prefix '${prefix}' in ${repo} did not stabilize after ${max} attempts" >&2
  return 1
}

# cache_delete_ids REPO ID...
# Deletes caches by numeric ID. Best-effort: reports failures but does not
# abort the whole batch on one failed delete.
cache_delete_ids() {
  local repo="$1"; shift
  local failed=0
  for id in "$@"; do
    if ! gh api "repos/${repo}/actions/caches/${id}" --method DELETE >/dev/null 2>&1; then
      echo "::warning::failed to delete cache id ${id} in ${repo}" >&2
      failed=1
    fi
  done
  return "$failed"
}

# cache_verify_ids_exist REPO ID...
# Exits 0 if every given cache ID is present in a fresh listing, otherwise
# prints the missing IDs and exits 1.
cache_verify_ids_exist() {
  local repo="$1"; shift
  local present missing=()
  present="$(gh api "repos/${repo}/actions/caches" -F per_page=100 --paginate --jq '.actions_caches[].id' 2>/dev/null || true)"
  for id in "$@"; do
    if ! grep -qx "$id" <<<"$present"; then
      missing+=("$id")
    fi
  done
  if [[ "${#missing[@]}" -gt 0 ]]; then
    echo "::warning::missing cache ids: ${missing[*]}" >&2
    return 1
  fi
  return 0
}

# median NUM...
# Prints the median of the given numbers (integers or floats).
median() {
  printf '%s\n' "$@" | sort -n | awk '
    { a[NR] = $1 }
    END {
      if (NR == 0) { print 0; exit }
      if (NR % 2 == 1) { print a[(NR + 1) / 2] }
      else { print (a[NR / 2] + a[NR / 2 + 1]) / 2 }
    }'
}

# dir_size_bytes PATH...
# Prints the total apparent size, in bytes, of the given paths (0 for
# paths that do not exist).
dir_size_bytes() {
  local total=0
  for p in "$@"; do
    if [[ -e "$p" ]]; then
      local size
      size="$(du -sk "$p" 2>/dev/null | awk '{print $1 * 1024}')"
      total=$((total + size))
    fi
  done
  echo "$total"
}
