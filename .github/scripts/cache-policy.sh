#!/usr/bin/env bash
# Cache path/key definitions for the two policies compared by the cache
# benchmark harness (.github/workflows/cache-benchmark.yaml):
#
#   legacy      - the unchanged policy currently implemented inline in
#                 test.yaml / wasm.yaml (whole Stack root, broad WASM
#                 restore-key prefixes, no single-writer discipline).
#   redesigned  - the policy specified by PR 1 commits 2 and 3 in ci.md
#                 (partitioned native cache boundaries, exact-only WASM
#                 toolchain/native-utilities caches, single-writer keys).
#
# This file is the single source of truth for both, so the production
# workflows (once commits 2 and 3 land) and the benchmark harness never
# describe the redesigned policy differently. All functions print the
# requested value on stdout; callers capture it into an env var.
set -euo pipefail

# ---- native: Haskell toolchain (macOS only in both policies) --------------

legacy_toolchain_paths() {
  printf '%s\n' "$HOME/.ghcup" "$HOME/.stack/programs" "$HOME/.stack/pantry"
}

legacy_toolchain_key() {
  local os="$1" arch="$2" ghc="$3"
  echo "${os}-${arch}-haskell-${ghc}-stack-latest"
}

legacy_toolchain_restore_keys() {
  local os="$1" arch="$2" ghc="$3"
  printf '%s\n' "${os}-${arch}-haskell-${ghc}-" "${os}-${arch}-haskell-"
}

redesigned_toolchain_paths() {
  printf '%s\n' "$HOME/.ghcup"
}

redesigned_toolchain_key() {
  local os="$1" arch="$2" stack_version="$3" ghc="$4"
  echo "ghcup-v1-${os}-${arch}-${stack_version}-${ghc}"
}
# Exact-only: no restore-keys. A prefix hit could select a toolchain built
# for a different GHC/Stack pairing than the one this job requested.

# ---- native: compiled dependencies -----------------------------------------

legacy_deps_paths() {
  # The entire Stack root, including Pantry, Stack-managed compilers and
  # embedded MSYS2 -- exactly what ci.md commit 2 says to stop doing.
  local stack_root="$1"
  printf '%s\n' "$stack_root"
}

legacy_deps_key() {
  local os="$1" resolver="$2" hash="$3" agda="$4"
  echo "${os}-stack-resolver-${resolver}-global-${hash}-${agda}"
}

legacy_deps_restore_keys() {
  local os="$1" resolver="$2" agda="$3"
  echo "${os}-stack-resolver-${resolver}-global-${agda}"
}

redesigned_deps_paths() {
  local stack_root="$1"
  printf '%s\n' "${stack_root}/snapshots" "${stack_root}/setup-exe-cache"
}

# CONFIG_HASH: hash of exactly the files that affect the compiled-dependency
# set for the selected stack-*.yaml, never every YAML file in the repo.
redesigned_config_hash() {
  local stack_yaml="$1" stack_lock="$2"
  sha256sum "$stack_yaml" "$stack_lock" package.yaml agda-language-server.cabal \
    | sha256sum | cut -d' ' -f1
}

redesigned_deps_key() {
  local os="$1" arch="$2" stack_version="$3" ghc="$4" icu="$5" resolver="$6" agda="$7" config_hash="$8"
  echo "stack-snapshot-v3-${os}-${arch}-${stack_version}-${ghc}-${icu}-${resolver}-${agda}-${config_hash}"
}

# The sole compiled-cache restore prefix: everything except CONFIG_HASH.
# A restored entry under this prefix is only a valid hit if OS, arch,
# Stack, GHC, ICU ABI, resolver and Agda target are all unchanged; the
# caller must independently confirm that (see redesigned_deps_key above)
# before treating a prefix match as reusable and must always re-run both
# dependency-producing commands after a prefix (non-exact) restore.
redesigned_deps_restore_prefix() {
  local os="$1" arch="$2" stack_version="$3" ghc="$4" icu="$5" resolver="$6" agda="$7"
  echo "stack-snapshot-v3-${os}-${arch}-${stack_version}-${ghc}-${icu}-${resolver}-${agda}-"
}

# ---- WASM: toolchain (ghc-wasm-meta) ---------------------------------------

legacy_wasm_toolchain_paths() { printf '%s\n' "$HOME/.ghc-wasm"; }

legacy_wasm_toolchain_key() {
  local os="$1" arch="$2" commit="$3" flavour="$4"
  echo "ghc-wasm-${os}-${arch}-${commit}-flavor-${flavour}"
}

legacy_wasm_toolchain_restore_keys() {
  local os="$1" arch="$2"
  echo "ghc-wasm-${os}-${arch}-"
}

redesigned_wasm_toolchain_paths() { printf '%s\n' "$HOME/.ghc-wasm"; }

# WASM_TOOLCHAIN_PRODUCER_HASH covers the toolchain cache schema, the
# ghc-wasm-meta commit, the flavour, and immutable setup behavior. Bump
# SCHEMA whenever the producer steps below change in a way that makes an
# older cache payload incompatible.
wasm_toolchain_producer_hash() {
  local schema="v1" commit="$1" flavour="$2"
  printf '%s' "${schema}-${commit}-${flavour}" | sha256sum | cut -d' ' -f1
}

redesigned_wasm_toolchain_key() {
  local os="$1" arch="$2" producer_hash="$3"
  echo "ghc-wasm-v3-${os}-${arch}-${producer_hash}"
}
# Exact-only: no restore-keys, and callers must gate on cache-hit == 'true'
# (not merely a non-empty cache-matched-key).

# ---- WASM: native utilities (alex/happy) -----------------------------------

redesigned_native_utils_paths() {
  # alex/happy are installed with `cabal install --installdir=... \
  # --install-method=copy`, into a dedicated directory this cache owns
  # exclusively -- but `--install-method=copy` is NOT relocatable: the
  # copied binary still has an absolute path to its own cabal *store*
  # entry baked in (e.g. alex looks up its AlexTemplate.hs via
  # Paths_alex, resolved against the store path fixed at build time).
  # Without the store entry, the binary crashes at runtime on a fresh
  # restore ("openFile: does not exist"). So the payload must include
  # both the installdir copies AND the cabal store, unlike a genuinely
  # relocatable/static binary. The mutable Cabal *index*
  # (~/.config/cabal, ~/.cache/cabal) is still deliberately excluded: it
  # is not part of producer identity, and `cabal update` runs fresh on
  # every use regardless of cache state. The store, by contrast, is
  # content-addressed by package+flags+compiler and safe to cache.
  printf '%s\n' "$HOME/.ghc-wasm/native-utils" "$HOME/.local/state/cabal/store" "$HOME/.cabal/store"
}

# NATIVE_UTILITIES_PRODUCER_HASH covers its cache schema, host
# Cabal/compiler identity, producer behavior, and the pinned Alex/Happy
# versions.
native_utils_producer_hash() {
  local schema="v1" cabal_version="$1" alex_version="$2" happy_version="$3"
  printf '%s' "${schema}-${cabal_version}-${alex_version}-${happy_version}" | sha256sum | cut -d' ' -f1
}

redesigned_native_utils_key() {
  local os="$1" arch="$2" producer_hash="$3"
  echo "native-tools-v3-${os}-${arch}-${producer_hash}"
}
# Exact-only, same rationale as the toolchain key.
