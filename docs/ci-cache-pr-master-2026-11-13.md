# PR/master cache lifecycle experiment — 2026-11-13

This follow-up tests the gap left by PR 1 and the original PR 2 proposal. Repairing restores and warming master's current dependencies does not address a PR that introduces a new dependency. Allowing PR saves helps repeated PR runs, but does not make those entries readable by master.

The fork-only experiment used real `pull_request` events, repeated attempts, two actual fork merges, and `workflow_dispatch` runs whose workflow ref was `master`. It tested Linux/Ubuntu 24.04, GHC 9.10.2, Stack 3.3.1, and Agda 2.8.0. This was a dependency-cache lifecycle test, not a repeat of the earlier full platform/WASM matrix or ALS application tests.

The result is a verified manual procedure: a trusted workflow dispatched on master can build a reviewed PR dependency revision and save the resulting cache in master's scope. The PR and post-merge master then use that one shared entry. This does not promote a PR-created cache or bypass GitHub's scope restriction. The dependency build must run in master scope before the consumers that should reuse it.

The experiment's files are `.github/workflows/cache-pr-master-experiment.yaml` and `.github/cache-lifecycle/package.yaml` on the fork. The workflow checks out the previously tested application source at `818ec174c7a2ded86137089b39ae28521a7af6a9`, then copies the dependency manifest from the specified immutable fork revision. It actually runs Stack's snapshot, application-dependency, and test-dependency builds. It does not build ALS itself, run ALS tests, publish packages, or upload application artifacts. Dependency fingerprints are computed from the manifest, and keys do not include the event, branch name, or merge SHA. Platform/compiler/ICU/resolver guards remain in the keys.

The use of frozen source plus a revision-specific manifest isolates dependency changes. It does not establish that every arbitrary source change, build hook, resolver change, or WASM dependency change can be handled by this harness. A production implementation needs the relevant reviewed build inputs and compatible cache paths/versions; it must not automatically execute untrusted PR code with a privileged workflow.

First, [fork PR 5](https://github.com/banacorn/agda-language-server/pull/5) added only `Only` to the dependency manifest. A semantic comparison confirmed that this was the sole manifest change despite YAML formatting differences. The first run was allowed to save a PR-scoped cache. A master-scope negative control used exactly the same manifest and primary key, after the PR cache existed.

| Test | Evidence | Exact hit | Dependency compilation |
|---|---|---|---|
| PR 5 initial run; save enabled | [43326629129, attempt 1](https://github.com/banacorn/agda-language-server/actions/runs/43326629129/attempts/1) | false; restored compatible baseline | `Only` compiled and registered |
| Unchanged PR 5 rerun | [43326629129, attempt 2](https://github.com/banacorn/agda-language-server/actions/runs/43326629129/attempts/2) | true | No packages compiled |
| Master negative control, same PR revision, saving disabled | [43326810775](https://github.com/banacorn/agda-language-server/actions/runs/43326810775) | false; restored compatible baseline | `Only` compiled again |
| Master producer, same PR revision, saving enabled | [43327048218](https://github.com/banacorn/agda-language-server/actions/runs/43327048218) | false | `Only` compiled; shared entry saved |
| PR 5 rerun after deleting its private entry | [43326629129, attempt 3](https://github.com/banacorn/agda-language-server/actions/runs/43326629129/attempts/3) | true, with only master entry available | No packages compiled |
| Master after merging PR 5 | [43327490059](https://github.com/banacorn/agda-language-server/actions/runs/43327490059) | true, asserted by the workflow | No packages compiled |

The original PR entry was cache ID `10445410577`, scoped to `refs/pull/5/merge`, with size 153,235,917 bytes. The master producer created ID `10445527096`, scoped to `refs/heads/master`, with the exact same primary key and cache version, and size 152,740,777 bytes. Only the experimental PR entry was deliberately deleted to make the third PR attempt unambiguous. This was not a test of automatic closed-PR cleanup.

PR 5 merged only into the playground fork, with merge commit `ef8383eb2de2389a9f064c3cf446fea9cd83658c`. The negative control establishes that enabling PR saves alone leaves the master rebuild. The master producer was a separate build; it did not reuse or promote the PR archive. Therefore this first sequence alone does not demonstrate avoiding the initial duplicate compilation.

The second sequence tested warming before the first PR run. The harness was changed so only a manually dispatched run on `refs/heads/master`, with saving explicitly enabled, could save dependencies. PRs were strictly restore-only. A new branch added `Boolean`, whose version 0.2.4 was verified in the actual LTS 24.1 snapshot. Its revision was `b6994ff79079454d038f1cb7db324895714fcf47`.

The master producer was dispatched against that immutable revision and completed before [fork PR 6](https://github.com/banacorn/agda-language-server/pull/6) was opened. Thus the first PR run had access to an existing shared cache rather than needing a PR-scoped copy.

| Test | Evidence | Exact hit | Dependency compilation |
|---|---|---|---|
| Master producer before PR 6 existed | [43327600055](https://github.com/banacorn/agda-language-server/actions/runs/43327600055) | false | `Boolean` compiled once; shared entry saved |
| PR 6 first run, saving disabled | [43327965080, attempt 1](https://github.com/banacorn/agda-language-server/actions/runs/43327965080/attempts/1) | true | No packages compiled |
| Unchanged PR 6 rerun, saving disabled | [43327965080, attempt 2](https://github.com/banacorn/agda-language-server/actions/runs/43327965080/attempts/2) | true | No packages compiled |
| Master after merging PR 6 | [43330650786](https://github.com/banacorn/agda-language-server/actions/runs/43330650786) | true, asserted by the workflow | No packages compiled |

All ten job attempts completed successfully. Log checks found no cache restore/save errors. Every exact-hit consumer completed the dependency commands without compiling packages.

The second shared cache is ID `10445696307`, scoped to `refs/heads/master`, with size 153,137,139 bytes. PR 6 merged into the fork at `1522b8494bce4fd4e0ce531bbf67e159e5b9a5f2`. No upstream PR was opened or merged, and the prepared production PR 1 branch was not changed.

Storage was measured through the fork API, rather than estimated from runner directories. The fork settings were rechecked: maximum cache size 10 GB, maximum retention 7 days.

| Stage | Entries | Bytes |
|---|---:|---:|
| Before this experiment | 36 | 8,784,438,216 |
| After the first PR saved its private entry | 37 | 8,937,674,133 |
| After removing that private entry, retaining the first master entry | 37 | 8,937,178,993 |
| After producing the second shared dependency generation | 38 | 9,090,316,132 |
| Final post-merge inventory | 38 | 9,090,316,132 |

Both scopes briefly held a copy of the first dependency generation: the two measured archives added 305,976,694 bytes to the original baseline. The final intended arrangement retains two master generations, adding 305,877,916 bytes to the baseline, with no PR-scoped entries. Every original cache ID/key/version/size tuple was retained unchanged. This verifies capacity for these two Linux changes only; it does not establish capacity for many PR caches, full-matrix generations, or arbitrary dependency changes.

The operational procedure tested was: select a reviewed immutable dependency revision; dispatch the warming workflow with workflow ref `master` and that revision as an input; wait for successful dependency builds and a shared cache save; run the PR using the same compatible key inputs; then merge and let master restore the same entry. Merely dispatching the workflow on the feature branch would not establish master scope. In this harness, checking out a different dependency revision did not change the run's cache scope.

This remains a manual procedure. Opening PR 6 only after warming was deliberate sequencing, not an implemented automatic wait/dispatch mechanism. There is no automatic maintainer approval, default-branch producer orchestration, or safe handling of arbitrary fork PR build code in the production workflow. If a PR starts before warming finishes, its first run can still rebuild. The scope of this result must not be expanded into a claim that PR 1 or the original PR 2 proposal already solves the full lifecycle automatically.

Cleanup completed in fork commit `aed430a`. The fork's original publishing-capable CI was temporarily disabled while experimental PRs were opened and merged, then restored to active; its workflow file was not edited. The lifecycle harness's automatic PR trigger was removed, leaving a manual experiment that saves only when explicitly requested on master. The two shared experimental caches can remain as reproducible evidence within the measured quota. No schedule was added.

Local evidence includes `/tmp/als-pr-lifecycle-state.json`, `/tmp/als-pr-lifecycle-summary.json`, `/tmp/als-lifecycle-*.log`, `/tmp/als-pr-lifecycle-initial-cache.json`, and `/tmp/als-lifecycle-final-cache.json`. Temporary files may disappear; linked GitHub runs and this report preserve the principal findings.
