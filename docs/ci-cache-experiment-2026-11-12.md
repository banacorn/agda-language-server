# CI cache experiments — 2026-11-12

Tested source: [`818ec174c7a2ded86137089b39ae28521a7af6a9`](https://github.com/banacorn/agda-language-server/commit/818ec174c7a2ded86137089b39ae28521a7af6a9), branch `fix/ci-cache-reuse`.

The fork-only harness checks out that exact revision. It omits publishing jobs and uses an experiment-specific cache namespace. Native coverage is Windows, Ubuntu 24.04, macOS 15 ARM64 and Intel, each with Agda 2.8.0, 2.7.0.1 and 2.6.4.3. WASM covers the same three Agda versions.

## Results

| Experiment | Result | Run |
|---|---|---|
| Empty-cache dependency production | All 15 producers passed | [Cold matrix](https://github.com/banacorn/agda-language-server/actions/runs/43148872390) |
| Warm normal builds, tests, packaging and artifact verification | All 28 jobs passed after one unchanged failed-job retry | [Normal CI](https://github.com/banacorn/agda-language-server/actions/runs/43158725071) |
| Add the native dependency `Only` (0.1 in lts-24.1) | All 15 jobs passed; native jobs restored compatible baseline caches and compiled the new dependency | [Dependency change](https://github.com/banacorn/agda-language-server/actions/runs/43160146289) |
| Repeat the changed dependency generation | All 15 jobs passed; all 36 logical cache restores were exact hits | [Repeat](https://github.com/banacorn/agda-language-server/actions/runs/43161087268) |

The normal CI matrix also had all 36 logical cache restores hit exactly: two per native job and four per WASM job. No cache restore/save errors were observed in the completed matrix logs.

### Windows test flakiness

The first normal attempt failed one of 62 application tests on Windows/Agda 2.6 and Windows/Agda 2.7. Both failures were `copyFile ... resource busy (file is locked)`. Their dependent artifact checks could not download artifacts because the test failures prevented upload. The unchanged failed-job retry passed all application and artifact checks.

The [original upstream cold Windows/Agda 2.8 job](https://github.com/agda/agda-language-server/actions/runs/42980310444/job/130388940860) had the same exception in another test before the cache fix. This flakiness remains an application/test follow-up; no test code was changed for these experiments.

## Storage

Sizes below are sums of the committed cache entries returned by GitHub's cache API; GB uses decimal units.

| State | Entries | Bytes | GB |
|---|---:|---:|---:|
| Complete baseline | 24 | 7,017,275,751 | 7.02 |
| Warm normal CI | 24 | 7,017,275,751 | 7.02 |
| Additional native dependency generation | 36 | 8,784,438,216 | 8.78 |
| Repeat of that generation | 36 | 8,784,438,216 | 8.78 |

All 24 baseline entries remained after the dependency change and repeat: no eviction was observed. A single small dependency change added approximately 1.77 GB because each native matrix entry saves its own snapshot archive. This is not a guarantee that future dependency generations will fit. The fork's settings endpoints confirmed `max_cache_size_gb: 10` and `max_cache_retention_days: 7`. These are verified fork settings; this experiment does not establish the upstream organization's configured limits.

## Scheduled execution

Two temporary schedules were installed on the fork's default branch and explicitly enabled: a native cache observer every 15 minutes and a minimal canary every five minutes. The [canary's manual control](https://github.com/banacorn/agda-language-server/actions/runs/43155382651) passed. The default branch, workflow state and committing actor were checked. Non-skipped control commits were also tested while the fork's original CI was temporarily disabled to prevent unintended publishing.

No `schedule` events were emitted through 2026-11-12 05:41 UTC: approximately 2 hours 9 minutes after installing the cache observer, and 1 hour 15 minutes after installing the minimal canary. Automatic scheduled warming remains **unverified**. Manual dispatch is verified; it is not being counted as a scheduled execution.

## Cleanup

The temporary schedule definitions and minimal canary were removed in `01db297`. The cache-matrix workflow now accepts only manual dispatch. GitHub's API confirmed the fork's original CI and manual matrix workflow are active, and the canary is deleted. The original `.github/workflows/test.yaml` file is unchanged from the fork's pre-experiment default branch. Publishing jobs were never included in the experiment harness.
