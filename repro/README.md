# Hover fixture copy reproduction

Separate checkout: `/private/tmp/als-hover-copy-repro`

Base commit: `5189cca2e3f0dbbb01b0e88dfd9dae1205394427`.
The original working directory and all tracked project files are unchanged.
The supplied issue is preserved in `repro/issue.md`.

## Status

**The Windows failure has not been reproduced here.** This host is macOS
arm64, with GHC 9.10.2 and directory-1.3.8.5. No Windows runtime is available.

The standalone reproducer builds with `-Wall -Werror`. Actual macOS results:

* `overlap`: both copyFile and ByteString copying succeed with a source reader held open.
* `stress`: 3,200 copies of Hover and 3,200 copies of HoverLibrary, zero failures.

Raw output is in `overlap-macos.log` and `stress-macos.log`.
These are platform controls, not evidence of a Windows reproduction or a fix.
The ALS hover suite itself was not run.

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
