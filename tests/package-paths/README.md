# Package directory paths (issue #216)

Run the same separator cases on Windows and Linux:

```sh
dotnet run --project tests/package-paths/PackagePaths.csproj --configuration Release
```

No Business Central artifacts or extra test framework are needed for these
13 cases. `test-package-paths.yml` runs them on both operating systems. The
cases include root entries, nested resources, mixed/backslash separators and
the other directories that share BC's `ReadDirectoryFilePaths` predicate.

The end-to-end guard is smoke codeunit 70080, which checks that installing
the smoke app registered its existing JavaScript control in `NAV App Tenant
Add-In`. It runs in the BC version matrix. Unlike a test that only invokes a
procedure on a headless TestPage, this catches a silently skipped registration.

Local BC 27.5.46862.52969 US verification used codeunits `70000|70051|70080`
with upstream's WebSocket runner and a focused build of those fixtures:

* Stock runner: 4 tests, 3 passed, 1 failed (70080 expected one registration,
  found zero).
* Rebuilt patcher and entrypoint layered on the same runner: 4 tests,
  4 passed, 0 failed, with a fresh stock artifact database and service cache.
* The minimal app from issue #216 installed with a registration and resource
  blob; the real patched package reader returned its docket and ZIP.

Patcher checks also covered applying the patch twice (byte-identical output)
and passing an unrelated assembly (nonzero exit and no output written).
This local runtime verification covers BC 27.5; the version-matrix workflow
provides the other supported runtime legs.
