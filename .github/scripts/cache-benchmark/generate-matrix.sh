#!/usr/bin/env bash
# Emits the 15-entry x {legacy,redesigned} x {rep 1..3} = 90 job matrix
# consumed by both the cold and warm phases of cache-benchmark.yaml, as a
# single compact JSON array on stdout.
#
# Entry shape:
#   strategy   "legacy" | "redesigned"
#   rep        1 | 2 | 3
#   id         unique entry id, e.g. "ubuntu-Agda-2.8.0"
#   kind       "native" | "wasm"
#   os         GitHub-hosted runner label
#   arch       "x64" | "arm64" (native only)
#   agda_name  e.g. "2.8.0"
#   agda_label e.g. "Agda-2.8.0"
#   agda_flag  e.g. "2-8-0" (wasm only)
#   agda_commit  Agda submodule/package-set commit (wasm only)
#   group      cache-ownership group: equals `id` for ungrouped entries,
#              or a shared name ("macos-arm64", "wasm") for entries that
#              share a toolchain cache key.
#   is_writer  whether this entry is allowed to save the group's shared
#              cache under the given strategy (see cache-policy.sh notes
#              in ci.md commits 2/3: redesigned groups have a single
#              designated writer -- Agda 2.8.0 -- legacy groups race).
#   pair_id    "<strategy>-<group>-rep<rep>", shared by every member of a
#              group so they use one ci-cache-benchmark-<pair_id>- prefix.
set -euo pipefail

AGDA_NATIVE='[
  {"name":"2.8.0",   "label":"Agda-2.8.0"},
  {"name":"2.7.0.1", "label":"Agda-2.7.0.1"},
  {"name":"2.6.4.3", "label":"Agda-2.6.4.3"}
]'

AGDA_WASM='[
  {"name":"2.8.0",   "label":"Agda-2.8.0",   "flag":"2-8-0", "commit":"e2f8c69414fa115328280ecc4de1d2b7a23be7fa"},
  {"name":"2.7.0.1", "label":"Agda-2.7.0.1", "flag":"2-7-0", "commit":"702c924fdab93aa8992adca84e72a91c490f7b1b"},
  {"name":"2.6.4.3", "label":"Agda-2.6.4.3", "flag":"2-6-4", "commit":"8f35851954c39dc3849095bfd018bed9bd1b32ad"}
]'

jq -n \
  --argjson agda_native "$AGDA_NATIVE" \
  --argjson agda_wasm "$AGDA_WASM" \
  '
  def strategies: ["legacy", "redesigned"];
  def reps: [1, 2, 3];

  def ungrouped_native:
    [
      {os: "ubuntu-latest",  arch: "x64"},
      {os: "windows-latest", arch: "x64"}
    ] as $platforms
    | $platforms[] as $p
    | $agda_native[] as $a
    | {
        kind: "native",
        os: $p.os, arch: $p.arch,
        agda_name: $a.name, agda_label: $a.label,
        id: ($p.os + "-" + $a.label),
        group: null
      };

  def grouped_macos:
    [
      {os: "macos-latest",    arch: "arm64"},
      {os: "macos-15-intel",  arch: "x64"}
    ] as $platforms
    | $platforms[] as $p
    | $agda_native[] as $a
    | {
        kind: "native",
        os: $p.os, arch: $p.arch,
        agda_name: $a.name, agda_label: $a.label,
        id: ($p.os + "-" + $a.label),
        group: ("macos-" + $p.arch)
      };

  def grouped_wasm:
    $agda_wasm[] as $a
    | {
        kind: "wasm",
        os: "ubuntu-22.04", arch: "x64",
        agda_name: $a.name, agda_label: $a.label,
        agda_flag: $a.flag, agda_commit: $a.commit,
        id: ("wasm-" + $a.label),
        group: "wasm"
      };

  [ungrouped_native, grouped_macos, grouped_wasm] as $bases
  | ($bases | flatten) as $entries
  | ($entries | length) as $n
  | if $n != 15 then error("expected 15 base entries, got \($n)") else . end
  | [
      strategies[] as $strategy
      | reps[] as $rep
      | $entries[] as $e
      | ($e.group // $e.id) as $group
      | (
          if $e.group == null then true
          elif $strategy == "legacy" then true
          else $e.agda_name == "2.8.0"
          end
        ) as $is_writer
      | ($strategy + "-" + $group + "-rep" + ($rep | tostring)) as $pair_id
      | $e + {
          strategy: $strategy,
          rep: $rep,
          group: $group,
          is_writer: $is_writer,
          pair_id: $pair_id,
          prefix: ("ci-cache-benchmark-" + $pair_id + "-")
        }
    ]
  | if length != 90 then error("expected 90 matrix entries, got \(length)") else . end
  '
