# Windows runtime DLL packaging: reproduction and fix

Recorded 2026-10-23. Work was based on `0ff4166` and pushed only to
[`banacorn/agda-language-server`](https://github.com/banacorn/agda-language-server).

## Result

The Windows release packaging omitted three MinGW runtime DLLs required by
its bundled ICU libraries:

- `libgcc_s_seh-1.dll`
- `libstdc++-6.dll`
- `libwinpthread-1.dll`

Newly built baseline packages for Agda 2.6.4.3, 2.7.0.1, and 2.8.0 all failed
native startup with `0xC0000135` (`STATUS_DLL_NOT_FOUND`) when the server's
PATH contained only Windows system directories.

After bundling those runtimes from the same MinGW directory as ICU, all three
packages started, initialized LSP, and completed an Agda load. Removing each
runtime individually reproduced the missing-DLL failure, demonstrating that
the hardened checks detect the omission.

## Why the previous checks missed it

The packaging step in `.github/workflows/test.yaml` copied `als.exe`, Agda
data, and ICU libraries matching `*libicudt*`, `*libicuin*`, and `*libicuuc*`.
It did not copy ICU's MinGW runtime dependencies.

The existing artifact-verification job ran on a separate hosted runner without
Haskell setup or cache restoration, but inherited the runner's PATH.
Preinstalled developer tools could therefore supply DLLs missing from the
archive. A separate runner did not establish runtime dependency isolation.

Static inspection of the inspected baseline package found these ICU imports:

| Importing DLL | MinGW runtime imports |
| --- | --- |
| `libicuin78.dll` | `libgcc_s_seh-1.dll`, `libstdc++-6.dll` |
| `libicuuc78.dll` | `libgcc_s_seh-1.dll`, `libstdc++-6.dll`, `libwinpthread-1.dll` |

The inspected fixed package contains all six DLLs: the three ICU libraries
and the three runtimes. Inspection of those DLLs' import tables found their
remaining non-system dependencies present in the package.

## Changes

The implementation branch is
[`fix/windows-runtime-packaging`](https://github.com/banacorn/agda-language-server/tree/fix/windows-runtime-packaging).

| Commit | Change |
| --- | --- |
| [`606ef87`](https://github.com/banacorn/agda-language-server/commit/606ef8737cd2ab03f8cc637c2cda6efa85d115a6) | Restrict Windows artifact checks to a system-only child PATH; add a startup-only probe with native exit-code diagnostics. |
| [`643b72c`](https://github.com/banacorn/agda-language-server/commit/643b72cdbc16c1c1734a386dbd97860e38170da8) | Focus this investigation branch on Windows and allow it to save native build caches. |
| [`3213763`](https://github.com/banacorn/agda-language-server/commit/32137636f0af6a5843588320872545a9972fa378) | Copy the three runtimes from ICU's MinGW directory into the archive and add individual DLL-removal controls. |

The production changes are in `.github/workflows/test.yaml` and
`.github/scripts/check-artifact-lsp.py`:

- Both Windows startup and completed-load checks restrict the server's child
  PATH to `C:\Windows\System32;C:\Windows`, using the actual `SystemRoot`.
  Python and CI tooling retain their own PATH.
- The probe launches the extracted executable by absolute path from a fresh
  temporary working directory, suppresses unattended Windows loader dialogs,
  and bounds execution with a timeout.
- The existing LSP probe removes inherited `Agda_datadir`, uses a fresh
  `AGDA_DIR`, and waits for a completed load reporting `*All Done*`.
- Packaging copies the runtimes from the same directory as ICU and fails if
  copying a required runtime fails.
- Each DLL-removal control temporarily moves one bundled runtime outside the
  release directory, requires exactly `STATUS_DLL_NOT_FOUND`, and restores
  the DLL afterward.

The branch also contains investigation-specific CI configuration: a push
trigger for this branch, Windows-only build/verification matrices, native
cache writes, and skipped WASM builds on this branch. Other branches retain
the normal platform matrix. These investigation settings should be reviewed
separately when preparing an upstream change.

## Native Windows evidence

### Baseline: omission exposed

[Baseline CI run 39896011479](https://github.com/banacorn/agda-language-server/actions/runs/39896011479)
ran commit `643b72cdbc16c1c1734a386dbd97860e38170da8`, with the hardened checks
and unchanged DLL packaging.

All three build/source-test jobs succeeded. All three extracted-artifact
startup checks failed with empty process output and exit code `3221225781`
(`0xC0000135`). These were actual Windows process executions.

### Fix: startup and completed loads succeed

[Fixed CI run 39900060689, attempt 2](https://github.com/banacorn/agda-language-server/actions/runs/39900060689/attempts/2)
ran commit `32137636f0af6a5843588320872545a9972fa378`. The entire run succeeded.

| Agda variant | Baseline startup | Fixed startup | Fixed LSP initialization and completed load | Individual DLL-removal controls |
| --- | --- | --- | --- | --- |
| 2.6.4.3 | `0xC0000135` | Exit 0 | Passed, `*All Done*` | 3 passed |
| 2.7.0.1 | `0xC0000135` | Exit 0 | Passed, `*All Done*` | 3 passed |
| 2.8.0 | `0xC0000135` | Exit 0 | Passed, `*All Done*` | 3 passed |

All nine removal controls observed exactly `0xC0000135`. The checked fixture
was `test/data/Unicode.agda`.

The fixed 2.8.0 cold build was cancelled and restarted after the baseline's
compiled-dependency cache became available. The already successful fixed
2.6.4.3 and 2.7.0.1 build jobs were retained. All three extracted-artifact
verification jobs ran in attempt 2 on separate consumer runners.

### Additional consumer experiment

While 2.8.0 was building, a separate experiment consumed the already uploaded
2.6.4.3 and 2.7.0.1 baseline/fixed archives:

- Branch: [`probe/windows-runtime-packaging`](https://github.com/banacorn/agda-language-server/tree/probe/windows-runtime-packaging)
- Commit: [`de77ee8`](https://github.com/banacorn/agda-language-server/commit/de77ee8)
- [Consumer run 39900809519](https://github.com/banacorn/agda-language-server/actions/runs/39900809519)

Its two baseline jobs failed startup as expected; its two fixed jobs passed
startup, completed loads, and all six removal controls. The overall run is
intentionally red because the baseline jobs require successful startup.
This experiment workflow uses fixed run IDs and lives only on the probe
branch; the permanent regression checks are on the implementation branch.

The initial broad [run 39895481292](https://github.com/banacorn/agda-language-server/actions/runs/39895481292)
was superseded after unrelated macOS SDK/GHC linker failures would have
skipped the shared artifact-verification job. This led to focusing the
investigation branch on Windows.

## Running the checks

On Windows, extract a package into `release/` beside a checkout of this branch:

```powershell
python .github/scripts/check-artifact-lsp.py release/als.exe test/data/Unicode.agda --startup-only
python .github/scripts/check-artifact-lsp.py release/als.exe test/data/Unicode.agda
```

After temporarily moving one required runtime outside `release/`, the
negative control is:

```powershell
python .github/scripts/check-artifact-lsp.py release/als.exe test/data/Unicode.agda --startup-only --expect-missing-dll
```

Restore the runtime before testing the next one. The workflow automates this
for all three DLLs with restoration in a `finally` block.

## Scope and preserved evidence

This verifies newly built Windows packages for the three tested Agda
versions. It exercises packaged ALS directly; it does not exercise the VS
Code extension's download-selection, extraction, or UI flow. Hosted runners
are not pristine Windows installations; the isolation established here is
the restricted child PATH and temporary working directory.

No changes were pushed to `agda/agda-language-server`, and no stable or
development release was published.

Local evidence is preserved under `/private/tmp/als-windows-runtime-evidence/`:

| Archive | SHA-256 |
| --- | --- |
| Baseline Agda 2.7.0.1 | `3c0099c6c710d3f4a9ef297e79cd31db2e2be73349055fa78c525947e410f6a2` |
| Fixed Agda 2.6.4.3 | `53b309864a5f02af60979e2ba4f6c9f520259db67cb37a0556fd9d9c2a6e9a39` |

That directory also contains `baseline-failures.log`,
`consumer-experiment.log`, and `fixed-success.log`. Temporary files and
GitHub Actions artifacts have finite lifetimes; the report and linked
commits preserve the findings and reproduction code.
