# Windows copyFile source-lock reproduction

Separate checkout: `/private/tmp/als-hover-copy-repro`

Base commit: `5189cca2e3f0dbbb01b0e88dfd9dae1205394427`.
The original working directory and all tracked project files are unchanged.
The supplied issue is preserved in `repro/issue.md`.

## Status

**Reproduced on Windows in the fork's GitHub Actions.**

Run: https://github.com/banacorn/agda-language-server/actions/runs/44695866005

Reproducer commit: `094f8cb`. Runner: `windows-latest`, GHC 9.10.2,
directory-1.3.8.5, Win32-2.14.1.0, default I/O manager.

| Fixture | Successful copies | Failed copies | Total |
| --- | ---: | ---: | ---: |
| Hover | 870 | 2,330 | 3,200 |
| HoverLibrary | 1,285 | 1,915 | 3,200 |

All twenty sampled stress exceptions exactly match the issue:

```text
copyFile:atomicCopyFileContents:withReplacementFile:copyFileToHandle:openFile: resource busy (file is locked)
```

The forced overlap probe also reproduced that exception. The ByteString
control succeeded with the same source reader held open and preserved file
contents. Raw Windows output is in `windows-run-44695866005/` and in the
workflow's `windows-copyfile-reproduction` artifact. The workflow fails because
the stress executable exits nonzero when it observes copy exceptions.

This reproduces the fixture-copy failure independently of ALS. The full ALS
hover suite was not run. No fix was applied to the project.

## macOS control

The local host is macOS arm64, with GHC 9.10.2 and directory-1.3.8.5.

The standalone reproducer builds with `-Wall -Werror`. Actual macOS results:

* `overlap`: both copyFile and ByteString copying succeed with a source reader held open.
* `stress`: 3,200 copies of Hover and 3,200 copies of HoverLibrary, zero failures.

Raw output is in `overlap-macos.log` and `stress-macos.log`.
These are platform controls for comparison with the Windows results above.

## Run on Windows with GHC 9.10.2

From the root of this checkout, in PowerShell:

```powershell
ghc --version
ghc-pkg list directory
ghc -Wall -Werror -threaded -rtsopts -with-rtsopts=-N -outputdir repro/build repro/CopyRace.hs -o repro/copy-race.exe
if ($LASTEXITCODE -ne 0) { throw 'Compilation failed' }
./repro/copy-race.exe overlap
./repro/copy-race.exe stress
```

`overlap` holds a normal `ReadMode` handle open on the shared
HoverLibrary fixture, then calls the unmodified `System.Directory.copyFile`.
This forces overlapping source reads without relying on scheduling. Under the
Windows runtime described in the issue, the expected copyFile result is
`Left ... resource busy (file is locked)`. A ByteString copy runs with the same
reader held open as a control, and its bytes are checked against the source.
The probe reports REPRODUCED only on Windows when copyFile raises an
already-in-use IOError and the ByteString control succeeds. This isolates the
source-lock conflict; it does not execute two concurrent copyFile calls or ALS.
Use the default I/O manager from the failing CI, without enabling WinIO.

`stress` uses the unchanged copyTree implementation from Test.Hover, with
32 workers copying the same fixture to separate destinations, across 100 rounds
per fixture. It exercises concurrent copyFile calls without the held-reader
probe. It exits nonzero on any copy exception and prints up to ten failures.
A passing run does not rule out the timing-dependent race. No ALS executable,
Agda dependency, or network access is required. Temporary copies are removed
after each invocation, including on failure.

For the full native hover tests on Windows, using the repository's Stack setup:

```powershell
stack test --stack-yaml stack-9.10.2-Agda-2.7.0.1.yaml --test-arguments='-p /Hover/'
```

Repeat this command to check the original intermittent failure. Unlike the
standalone harness, it builds ALS and its Agda dependencies.

## macOS control commands

```sh
ghc -Wall -Werror -threaded -rtsopts -with-rtsopts=-N -outputdir repro/build repro/CopyRace.hs -o repro/copy-race
repro/copy-race overlap
repro/copy-race stress
```
