#!/usr/bin/env bash
# resolve-native-env.sh
#
# Run with cwd = the checked-out source tree ("src"). Resolves the
# per-Agda-target Stack config and, for Windows, installs the ICU/pkgconf
# MSYS2 packages the ICU-linked build needs. Writes STACK_YAML_FILE,
# STACK_YAML_ARG, RESOLVER, GHC_VERSION to $GITHUB_ENV. Expects AGDA_LABEL
# and RUNNER_OS already in the environment.
set -euo pipefail

STACK_YAML_FILE="stack-9.10.2-${AGDA_LABEL}.yaml"
RESOLVER="$(yq .resolver "$STACK_YAML_FILE")"
GHC_VERSION="$(yq .compiler "$STACK_YAML_FILE" | cut -c 5-)"

{
  echo "STACK_YAML_FILE=${STACK_YAML_FILE}"
  echo "STACK_YAML_ARG=--stack-yaml ${STACK_YAML_FILE}"
  echo "RESOLVER=${RESOLVER}"
  echo "GHC_VERSION=${GHC_VERSION}"
} >> "$GITHUB_ENV"

if [[ "${BENCH_FAKE:-false}" == "true" ]]; then
  : # fake mode: no real toolchain, nothing to install
elif [[ "$RUNNER_OS" == "Windows" ]]; then
  stack exec --stack-yaml "$STACK_YAML_FILE" -- pacman -S --noconfirm mingw-w64-clang-x86_64-icu mingw-w64-clang-x86_64-pkgconf
  stack path --stack-yaml "$STACK_YAML_FILE" --extra-library-dirs | tr ',' '\n' | grep -i 'bin$' | sed 's/^ *//' >> "$GITHUB_PATH"
elif [[ "$RUNNER_OS" == "macOS" ]]; then
  echo "PKG_CONFIG_PATH=$(brew --prefix)/opt/icu4c/lib/pkgconfig" >> "$GITHUB_ENV"
fi
