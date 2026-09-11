#!/usr/bin/env bash
# resolve-native-platform-deps.sh
#
# Run with cwd = the checked-out source tree ("src"), AFTER
# haskell-actions/setup has installed a real GHC (this script's Windows
# branch runs `stack exec`, which needs one on PATH already -- installing
# it here previously ran before setup and silently relied on Stack's own
# install-ghc fallback to paper over the ordering bug, which install-ghc:
# false (see stack-*.yaml) no longer permits). Installs the ICU/pkgconf
# MSYS2 packages the ICU-linked build needs on Windows, or sets
# PKG_CONFIG_PATH on macOS. Expects STACK_YAML_FILE and RUNNER_OS already
# in the environment (from resolve-native-env.sh).
set -euo pipefail

if [[ "${BENCH_FAKE:-false}" == "true" ]]; then
  : # fake mode: no real toolchain, nothing to install
elif [[ "$RUNNER_OS" == "Windows" ]]; then
  stack exec --stack-yaml "$STACK_YAML_FILE" -- pacman -S --noconfirm mingw-w64-clang-x86_64-icu mingw-w64-clang-x86_64-pkgconf
  stack path --stack-yaml "$STACK_YAML_FILE" --extra-library-dirs | tr ',' '\n' | grep -i 'bin$' | sed 's/^ *//' >> "$GITHUB_PATH"
elif [[ "$RUNNER_OS" == "macOS" ]]; then
  echo "PKG_CONFIG_PATH=$(brew --prefix)/opt/icu4c/lib/pkgconfig" >> "$GITHUB_ENV"
fi
