#!/usr/bin/env bash
# Manual fallback for removing leftover cache-benchmark entries after a
# cancelled run or a failure that prevented the automated cleanup job
# (cache-benchmark.yaml: job `cleanup`) from running.
#
# Usage:
#   GH_TOKEN=... .github/scripts/cache-benchmark/manual-cleanup.sh \
#     <BENCHMARK_REPOSITORY> <pair-prefix, e.g. ci-cache-benchmark-legacy-macos-arm64-rep2->
#
# Requires `gh` authenticated with repo-scoped access to BENCHMARK_REPOSITORY
# and the `actions: write` permission (a classic/fine-grained PAT, or
# GH_TOKEN from `gh auth login`). Never accepts UPSTREAM_REPOSITORY as the
# target, lists the matching cache IDs before deleting, deletes only from
# the given fork, and verifies the prefix is empty afterward via a stable
# paginated read.
set -euo pipefail
UPSTREAM_REPOSITORY="agda/agda-language-server"

REPO="${1:?usage: manual-cleanup.sh <BENCHMARK_REPOSITORY> <pair-prefix>}"
PREFIX="${2:?usage: manual-cleanup.sh <BENCHMARK_REPOSITORY> <pair-prefix>}"

if [[ "$REPO" == "$UPSTREAM_REPOSITORY" ]]; then
  echo "::error::refusing to run manual cleanup against UPSTREAM_REPOSITORY (${UPSTREAM_REPOSITORY})" >&2
  exit 1
fi

case "$PREFIX" in
  ci-cache-benchmark-*) ;;
  *)
    echo "::error::prefix must start with 'ci-cache-benchmark-' (got '${PREFIX}')" >&2
    exit 1
    ;;
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"

echo "Repository: ${REPO}"
echo "Prefix:     ${PREFIX}"
echo

inventory="$(cache_stable_inventory "$REPO" "$PREFIX")"
echo "Matching cache entries:"
jq -r '.[] | "  id=\(.id)  key=\(.key)  size_in_bytes=\(.size_in_bytes)"' <<<"$inventory"
echo

ids="$(jq -r '.[].id' <<<"$inventory")"
if [[ -z "$ids" ]]; then
  echo "Nothing to delete."
  exit 0
fi

id_count="$(wc -l <<<"$ids")"
read -r -p "Delete the ${id_count} entries above from ${REPO}? [y/N] " confirm
if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
  echo "Aborted."
  exit 1
fi

cache_delete_ids "$REPO" $ids

remaining="$(cache_list_all "$REPO" "$PREFIX" | jq 'length')"
if [[ "$remaining" -ne 0 ]]; then
  echo "::error::${remaining} entries under prefix '${PREFIX}' remain after deletion" >&2
  exit 1
fi
echo "Prefix '${PREFIX}' is now empty in ${REPO}."
