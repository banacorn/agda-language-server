#!/usr/bin/env bash
# resolve-native-env.sh
#
# Run with cwd = the checked-out source tree ("src"), BEFORE the
# haskell-actions/setup step: it resolves GHC_VERSION, which that step
# takes as an input. Only pure config resolution (yq against the
# checked-out stack-*.yaml) -- no real toolchain calls -- since no GHC
# exists yet at this point in the job. The platform-specific real
# toolchain dependency installs (Windows ICU/pkgconf via `stack exec`,
# which needs a real GHC already on PATH) live in
# resolve-native-platform-deps.sh instead, run after setup, mirroring
# production test.yaml's already-correct step order.
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
