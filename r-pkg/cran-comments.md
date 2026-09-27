## Submission notes

This is a minor release (0.1.1 -> 0.2.0) that updates package metadata
only; there are no code or user-facing API changes.

- The project repository has moved from `grantmcdermott/jgd` to the
  `REditorSupport` GitHub organization, which also maintains the VS Code R
  extension that now ships native `jgd` support. The `URL` and `BugReports`
  fields, and the repository links in the documentation, have been updated
  to point to the new canonical location
  (<https://github.com/REditorSupport/jgd>). The maintainer is unchanged.
- Although GitHub currently redirects the old URLs, we would prefer the CRAN
  metadata to reference the canonical repository rather than rely on
  redirects indefinitely.

## Test environments

- Arch Linux (x86_64), R 4.6.1
- Win Builder (x86_64), R-devel / R-release
- GitHub Actions: Ubuntu (R-devel, R-release), Windows (R-release),
  macOS (R-release)

## R CMD check results

0 errors | 0 warnings | 0 notes

## Additional notes

- This package contains compiled C code with no external library
  dependencies. The only vendored code is cJSON (`src/cjson/`), which is
  MIT-licensed; its copyright and license details are recorded in
  `inst/COPYRIGHTS` and the upstream headers are preserved in the
  vendored source files. cJSON has been patched to replace `sprintf`
  with `snprintf` for CRAN compliance; all upstream diagnostic-suppression
  pragmas have been removed (patches tracked in `src/cjson/patches/`).
- All examples are wrapped in `\dontrun{}` because the device requires a
  running external renderer (e.g., a VS Code extension or browser-based
  server) to function.
