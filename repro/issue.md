# Hover tests fail on Windows with "resource busy (file is locked)" when they copy their fixtures at the same time

## What happens

On Windows, a hover test can fail before its language server even starts:

```
only the include dirs change, making an import ambiguous:          FAIL
  Exception: copyFile:atomicCopyFileContents:withReplacementFile:copyFileToHandle:openFile: resource busy (file is locked)
```

It has failed six times across two runs, on every Windows job, each time in exactly one test. A different test fails each time, but each failing test copies either the `Hover` or the `HoverLibrary` fixture:

| Run | Job (windows-latest) | Failing test | Fixture |
|---|---|---|---|
| Fork dry run, attempt 1 | Agda-2.7.0.1 | `only the include dirs change, making an import ambiguous` | `HoverLibrary` |
| Fork dry run, attempt 2 | Agda-2.7.0.1 | `remove a flag the hovered file needs` | `HoverLibrary` |
| Fork dry run, attempt 3 | Agda-2.7.0.1 | `Dep keeps its path but has a postulate under --safe` | `Hover` |
| PR #81 | Agda-2.7.0.1 | `two imports break, Z imported first` | `Hover` |
| PR #81 | Agda-2.8.0 | `only the include dirs change, making an import ambiguous` | `HoverLibrary` |
| PR #81 | Agda-2.9.0 | `Dep keeps its path but imports a missing module` | `Hover` |

In every case, all the other tests passed (66 of 67 on 2.7.0.1 and 2.8.0, 89 of 90 on 2.9.0). The source and test code in all these runs are the same as on `master` at `7f06730`, whose CI passed on every platform. The fork dry run then passed on attempt 4 with no change. So whether it fails depends on timing.

Consequence: `publish-release` needs every build job to pass, so if this happens on a `master` push, the release is skipped until someone reruns the failed jobs.

## Cause

Two tests that copy the same fixture file at the same moment race on GHC's in-process file lock. On Windows, `copyFile` takes that lock **for writing on the source file**, so two concurrent copies of one source file exclude each other.

1. **Tests run in parallel.** The test suite is built with `-threaded -with-rtsopts=-N` (`package.yaml`, `tests.als-test`), and tasty runs that many tests at once by default.
2. **They copy the same files.** Every hover test calls `withFixtures` (`test/Test/Hover.hs`), which runs `copyTree` to copy a shared directory from `test/data/` into its own temp directory with `System.Directory.copyFile`. Seven tests copy `test/data/HoverLibrary`. Many more copy `test/data/Hover`, so they can race the same way.
3. **`copyFile` opens the source with a write lock on Windows.** Traced through the library sources (`directory-1.3.8.5`, the version shipped with GHC 9.10.2; `Win32-2.14.1.0`; GHC 9.10.2's `ghc-internal`):
   - `copyFileToHandle` opens the source with `openFileForRead` (`System/Directory/OsPath.hs`).
   - On Windows, `openFileForRead` calls Win32 `createFile` with `GENERIC_READ` and full sharing, then wraps the result with `hANDLEToHandle` (`System/Directory/Internal/Windows.hsc`).
   - Under the default (non-WinIO) I/O manager, `hANDLEToHandle` does `_open_osfhandle … >>= fdToHandle` (`System/Win32/Types.hsc`).
   - `fdToHandle` gets the mode from `fdGetMode`, which on Windows always returns `ReadWriteMode`: "We don't have a way of finding out which flags are set on FDs on Windows … so make a handle that thinks that anything goes" (`GHC/Internal/System/Posix/Internals.hs`).
   - `mkFD` therefore calls the RTS `lockFile` with `for_writing = 1` (`GHC/Internal/IO/FD.hs`).
   - `lockFile` (`rts/FileLock.c`) allows one writer or many readers per file. A second open of a file that already holds a write lock returns `-1`. `mkFD` turns that into `IOError ResourceBusy "openFile" "file is locked"`, which is exactly the message in the log.

   So when two tests copy, for example, `test/data/HoverLibrary/hover-library.agda-lib` at the same time, the second open fails. Windows itself would allow it (the file is opened with full sharing). This is GHC's own lock refusing it.

   The `openFile` in the message (rather than `hANDLEToHandle`) shows the run took the non-WinIO path described above.

This was not seen on Linux or macOS. There, `fdGetMode` reads the real flags with `fcntl`, the source is locked for reading, and concurrent readers are allowed.

ALS's own code (`src/`, `app/`) does not call `copyFile` or `hANDLEToHandle`, so this is in the test harness only.

## Possible fixes

- **Copy without `copyFile` in `copyTree`** (smallest change): read the source with `Data.ByteString.readFile` and write it with `Data.ByteString.writeFile`. `readFile` opens with `ReadMode`, which takes a read lock, so concurrent copies of the same source no longer exclude each other.
- **Serialize fixture copying** with one global `MVar ()` around `copyTree`. This keeps `copyFile` but adds a lock to the test harness.
- **Run the hover tests sequentially** (tasty `sequentialTestGroup`). This avoids the race, but makes the suite slower and hides the cause.

A regression test is hard to make deterministic. The direct check is to run the hover group on Windows several times and see that it never fails this way.

## Evidence

- Fork CI run (release dry run): https://github.com/banacorn/agda-language-server/actions/runs/44672626423, attempts 1 to 3, job `Build and Test (windows-latest, Agda-2.7.0.1)`.
- PR #81 CI run: https://github.com/agda/agda-language-server/actions/runs/44688508646, attempt 1, jobs `Build and Test (windows-latest, Agda-2.7.0.1 / 2.8.0 / 2.9.0)`.
- In both runs, the `Verify Native Artifact (windows-latest, …)` failure that follows each build failure is only `Artifact not found for name: als-dev-Agda-…-windows`, because the build job never uploaded one.
