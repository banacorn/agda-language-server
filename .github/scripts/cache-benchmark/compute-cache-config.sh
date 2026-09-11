#!/usr/bin/env bash
# compute-cache-config.sh SLOT
#
# Fills in PRIMARY_* or SECONDARY_* (SLOT is "primary" or "secondary") env
# vars for the next actions/cache/restore+save steps, based on the matrix
# entry's kind/strategy and the build facts already resolved into the
# environment by earlier steps. Sourced values come from cache-policy.sh
# (the single source of truth for both compared policies).
#
# Slot assignment (see cache-benchmark.yaml header comment for rationale):
#   native  primary   = compiled-dependency cache (Stack root / snapshots)
#           secondary = macOS-only Haskell toolchain cache
#   wasm    primary   = ghc-wasm-meta toolchain cache
#           secondary = native-utilities (alex/happy) cache, or the
#                       legacy native-cabal cache under the legacy policy
set -euo pipefail
SLOT="$1"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../cache-policy.sh
source "${SCRIPT_DIR}/../cache-policy.sh"

emit() {
  local name="$1" value="$2"
  {
    echo "${name}<<__CACHE_CFG_EOF__"
    echo "${value}"
    echo "__CACHE_CFG_EOF__"
  } >> "$GITHUB_ENV"
}

join_lines() { printf '%s\n' "$@"; }

if [[ "$ENTRY_KIND" == "native" ]]; then
  if [[ "$SLOT" == "primary" ]]; then
    if [[ "$BENCH_STRATEGY" == "legacy" ]]; then
      paths="$(legacy_deps_paths "$STACK_ROOT")"
      key="$(legacy_deps_key "$RUNNER_OS" "$RESOLVER" "$(sha256sum "$STACK_YAML" | cut -d' ' -f1)" "$AGDA_LABEL")"
      restore_keys="$(legacy_deps_restore_keys "$RUNNER_OS" "$RESOLVER" "$AGDA_LABEL")"
      exact_only="false"
    else
      config_hash="$(redesigned_config_hash "$STACK_YAML" "${STACK_YAML}.lock")"
      echo "CONFIG_HASH=${config_hash}" >> "$GITHUB_ENV"
      paths="$(redesigned_deps_paths "$STACK_ROOT")"
      key="$(redesigned_deps_key "$RUNNER_OS" "$RUNNER_ARCH" "$STACK_VERSION" "$GHC_VERSION" "$ICU_VERSION" "$RESOLVER" "$AGDA_LABEL" "$config_hash")"
      restore_keys="$(redesigned_deps_restore_prefix "$RUNNER_OS" "$RUNNER_ARCH" "$STACK_VERSION" "$GHC_VERSION" "$ICU_VERSION" "$RESOLVER" "$AGDA_LABEL")"
      exact_only="false"
    fi
    emit PRIMARY_ACTIVE "true"
    emit PRIMARY_PATHS "$paths"
    emit PRIMARY_KEY "${BENCH_PREFIX}${key}"
    emit PRIMARY_RESTORE_KEYS "${restore_keys:+${BENCH_PREFIX}${restore_keys}}"
    emit PRIMARY_EXACT_ONLY "$exact_only"
  else
    # Toolchain cache: only active on macOS in both policies.
    if [[ "$RUNNER_OS" != "macOS" ]]; then
      emit SECONDARY_ACTIVE "false"
      emit SECONDARY_PATHS ""
      emit SECONDARY_KEY ""
      emit SECONDARY_RESTORE_KEYS ""
      emit SECONDARY_EXACT_ONLY "false"
    elif [[ "$BENCH_STRATEGY" == "legacy" ]]; then
      paths="$(legacy_toolchain_paths)"
      key="$(legacy_toolchain_key "$RUNNER_OS" "$RUNNER_ARCH" "$GHC_VERSION")"
      restore_keys="$(legacy_toolchain_restore_keys "$RUNNER_OS" "$RUNNER_ARCH" "$GHC_VERSION" | paste -sd'\n' -)"
      emit SECONDARY_ACTIVE "true"
      emit SECONDARY_PATHS "$paths"
      emit SECONDARY_KEY "${BENCH_PREFIX}${key}"
      emit SECONDARY_RESTORE_KEYS "$(printf '%s\n' "$restore_keys" | sed "s/^/${BENCH_PREFIX}/")"
      emit SECONDARY_EXACT_ONLY "false"
    else
      paths="$(redesigned_toolchain_paths)"
      key="$(redesigned_toolchain_key "$RUNNER_OS" "$RUNNER_ARCH" "$STACK_VERSION" "$GHC_VERSION")"
      emit SECONDARY_ACTIVE "true"
      emit SECONDARY_PATHS "$paths"
      emit SECONDARY_KEY "${BENCH_PREFIX}${key}"
      emit SECONDARY_RESTORE_KEYS ""
      emit SECONDARY_EXACT_ONLY "true"
    fi
  fi
else # wasm
  if [[ "$SLOT" == "primary" ]]; then
    if [[ "$BENCH_STRATEGY" == "legacy" ]]; then
      paths="$(legacy_wasm_toolchain_paths)"
      key="$(legacy_wasm_toolchain_key "$RUNNER_OS" "$RUNNER_ARCH" "$GHC_WASM_META_COMMIT_HASH" "$GHC_WASM_META_FLAVOUR")"
      restore_keys="$(legacy_wasm_toolchain_restore_keys "$RUNNER_OS" "$RUNNER_ARCH")"
      emit PRIMARY_ACTIVE "true"
      emit PRIMARY_PATHS "$paths"
      emit PRIMARY_KEY "${BENCH_PREFIX}${key}"
      emit PRIMARY_RESTORE_KEYS "${BENCH_PREFIX}${restore_keys}"
      emit PRIMARY_EXACT_ONLY "false"
    else
      producer_hash="$(wasm_toolchain_producer_hash "$GHC_WASM_META_COMMIT_HASH" "$GHC_WASM_META_FLAVOUR")"
      echo "WASM_TOOLCHAIN_PRODUCER_HASH=${producer_hash}" >> "$GITHUB_ENV"
      paths="$(redesigned_wasm_toolchain_paths)"
      key="$(redesigned_wasm_toolchain_key "$RUNNER_OS" "$RUNNER_ARCH" "$producer_hash")"
      emit PRIMARY_ACTIVE "true"
      emit PRIMARY_PATHS "$paths"
      emit PRIMARY_KEY "${BENCH_PREFIX}${key}"
      emit PRIMARY_RESTORE_KEYS ""
      emit PRIMARY_EXACT_ONLY "true"
    fi
  else
    if [[ "$BENCH_STRATEGY" == "legacy" ]]; then
      paths="$(join_lines "$HOME/.config/cabal" "$HOME/.cache/cabal")"
      key="native-cabal-${RUNNER_OS}-${RUNNER_ARCH}-${GHC_WASM_META_COMMIT_HASH}-flavor-${GHC_WASM_META_FLAVOUR}"
      restore_keys="native-cabal-${RUNNER_OS}-${RUNNER_ARCH}-"
      emit SECONDARY_ACTIVE "true"
      emit SECONDARY_PATHS "$paths"
      emit SECONDARY_KEY "${BENCH_PREFIX}${key}"
      emit SECONDARY_RESTORE_KEYS "${BENCH_PREFIX}${restore_keys}"
      emit SECONDARY_EXACT_ONLY "false"
    else
      producer_hash="$(native_utils_producer_hash "$CABAL_VERSION" "$ALEX_VERSION" "$HAPPY_VERSION")"
      echo "NATIVE_UTILITIES_PRODUCER_HASH=${producer_hash}" >> "$GITHUB_ENV"
      paths="$(redesigned_native_utils_paths)"
      key="$(redesigned_native_utils_key "$RUNNER_OS" "$RUNNER_ARCH" "$producer_hash")"
      emit SECONDARY_ACTIVE "true"
      emit SECONDARY_PATHS "$paths"
      emit SECONDARY_KEY "${BENCH_PREFIX}${key}"
      emit SECONDARY_RESTORE_KEYS ""
      emit SECONDARY_EXACT_ONLY "true"
    fi
  fi
fi
