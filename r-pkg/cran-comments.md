## Submission notes

This is a patch release (0.2.0 -> 0.2.1) that fixes the MKL check error
reported by CRAN, caused by a race condition in our mock server tests.
There are no user-facing changes.

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
