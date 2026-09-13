# Windows build compatibility contract

This document describes the compatibility boundary for this repository's Windows packages. It is deliberately based on the Fritzing source checked out for a build, rather than on version values copied into several workflow files.

## What the build learns from Fritzing

Before installing Qt or compiling a dependency, the build reads `phoenix.pro` and its included `pri/*.pri` files. At the time this document was written, Fritzing declares a Qt range of 6.5.3 through 6.10.10, a C++20 build, and Windows dependency locations relative to `phoenix.pro`. [Fritzing's `phoenix.pro`](https://raw.githubusercontent.com/fritzing/fritzing-app/develop/phoenix.pro) is the source of truth for that contract.

The parser extracts the following values on every run:

| Item | Source declaration | CI behaviour |
| --- | --- | --- |
| Qt | `QT_LEAST` and `QT_MOST` in `phoenix.pro` | GitHub installs a version in the declared range; other forges validate the runner's installed Qt kit. |
| libgit2 | `LIBGIT_VERSION` | Downloads, builds, and places `git2.lib` in Fritzing's expected layout. |
| QuaZip | `QUAZIP_VERSION` | Builds and names the directory with the selected Qt version, as Fritzing requires. |
| Clipper, Boost, SVG++ | Their detect `.pri` files | Downloads the declared versions and validates their expected headers/libraries. |
| ngspice | `spicedetect.pri` | Uses the declared directory name and verifies that the DLL is for the requested CPU. |

This follows the upstream detection scripts for [libgit2](https://raw.githubusercontent.com/fritzing/fritzing-app/develop/pri/libgit2detect.pri), [QuaZip](https://raw.githubusercontent.com/fritzing/fritzing-app/develop/pri/quazipdetect.pri), [Clipper](https://raw.githubusercontent.com/fritzing/fritzing-app/develop/pri/clipper1detect.pri), [Boost](https://raw.githubusercontent.com/fritzing/fritzing-app/develop/pri/boostdetect.pri), [SVG++](https://raw.githubusercontent.com/fritzing/fritzing-app/develop/pri/svgppdetect.pri), and [ngspice](https://raw.githubusercontent.com/fritzing/fritzing-app/develop/pri/spicedetect.pri).

## Reliability measures

The common implementation is [`build-windows.ps1`](../.ci/windows/build-windows.ps1). Every GitHub, GitLab, Gitea, Forgejo, and Codeberg build ultimately uses this script.

- Dependencies come from the checked-out Fritzing contract, not duplicated workflow constants. A normal upstream dependency or Qt-range bump therefore selects the new compatible values automatically.
- The GitHub workflows use [aqtinstall](https://aqtinstall.readthedocs.io/en/latest/getting_started.html) to list Qt versions in Fritzing's declared range, verify the required architecture and modules, then install one exact compatible version. This avoids passing a range to a wrapper that expects strict SemVer.
- Cached dependencies are treated as untrusted input. Their headers, static libraries, directory layout, and ngspice PE architecture are rechecked. A partial or incompatible cache is deleted and rebuilt instead of producing a confusing linker failure later.
- Downloads retry four times and reject empty files. Build commands check their exit code immediately; `git2.lib` and QuaZip are located by file search, avoiding assumptions about a CMake output subdirectory.
- The package is verified for a non-trivial `Fritzing.exe`, the requested PE machine type, the Qt Windows platform plugin, runtime data, and the parts tree. Each portable ZIP contains `build-manifest.json` with the actual Fritzing and parts commits, Qt version, dependency versions, architecture, and UTC build time.
- Builds accept branch, tag, or 40-character commit inputs for Fritzing and Fritzing Parts. For a reproducible release, use commit IDs rather than the moving `develop` defaults and retain the package manifest.

## CPU architecture boundary

The x64 workflow uses `windows-2022`, a native MSVC x64 environment, and a `win64_msvc2022_64` Qt kit. The ARM64 workflow uses `windows-11-arm`, native MSVC ARM64 tools, and a `windows_arm64` / `win64_msvc2022_arm64` Qt kit. aqt's documentation describes querying available versions, architectures, and modules before installing a Qt kit. [aqtinstall documentation](https://aqtinstall.readthedocs.io/en/latest/getting_started.html)

Fritzing's current Windows qmake condition sends every non-x64 target to the 32-bit output location. The ARM64 build applies one narrowly-scoped change to its temporary checkout so that `arm64` follows the 64-bit branch. It does not alter upstream source in this repository. If upstream restructures that exact condition, the build stops with an explicit message instead of applying a guessing rewrite. This is the intended “massive change” boundary.

The public Windows ngspice archive used for x64 is not an ARM64 binary. ARM64 builds therefore require an `NGSPICE_ARM64_ARCHIVE_URL` secret or a manual workflow input. The archive must contain `include/` and an ARM64 DLL; the build reads the PE header before it is copied into the package. This prevents a ZIP whose filename says ARM64 while simulation support is x64-only.

## Provider behaviour

All workflows are manual-only. A push, pull request, merge request, or schedule does not consume any build minutes. GitHub builds use the **Run workflow** button; GitLab's top-level `workflow: rules` permits only the **Run pipeline** (`web`) source.

| Provider | Definition | Runner model |
| --- | --- | --- |
| GitHub | `.github/workflows/build-win-*.yml` | Hosted x64; native ARM64 runner for the ARM job. |
| GitLab | `.gitlab-ci.yml` | Self-hosted Windows x64 and ARM64 runners. |
| Gitea | `.gitea/workflows/build-win.yml` | Self-hosted Windows x64 and ARM64 runners. |
| Forgejo / Codeberg | `.forgejo/workflows/build-win.yml` | Self-hosted Windows x64 and ARM64 runners. |

GitLab, Gitea, Forgejo, and Codeberg runners must provide Visual Studio C++ tools, CMake, 7-Zip, Git, and a Qt MSVC kit in `QT_ROOT_DIR`. The script then checks that kit against the Fritzing revision's declared Qt range. Codeberg runs Forgejo Actions, so it uses the Forgejo definition. Forgejo documents its Actions implementation as GitHub Actions-compatible, with its own runner and instance configuration requirements. [Forgejo Actions reference](https://forgejo.org/docs/latest/user/actions/reference/)

The “universal” workflows create a delivery ZIP containing the separate native x64 and ARM64 packages. It is not a single mixed-architecture executable.

## When a future update fails

The failure should identify the boundary that changed:

| Message or stage | Meaning | Required response |
| --- | --- | --- |
| `Could not read … from the Fritzing source` | Upstream renamed or removed a build-contract declaration. | Review the new upstream qmake files and update `Get-FritzingBuildContract.ps1`. |
| `Qt … is outside Fritzing's declared range` | A self-hosted runner's kit is too old or too new. | Install a supported MSVC Qt kit or use the matching GitHub workflow. |
| `upstream ARM64 output-path condition changed` | Fritzing changed its Windows architecture logic. | Review the new condition; do not weaken the patch blindly. |
| Dependency download/layout error | An upstream archive or directory contract changed. | Update the downloader for that dependency and keep its layout validation. |
| PE architecture error | An x64 artifact was supplied to ARM64 or vice versa. | Replace the ngspice archive or correct the runner/toolchain. |

This approach makes ordinary source, Qt-range, and declared dependency version updates self-adjusting. A new build system, removed qmake declarations, renamed directory contract, or a genuine upstream Windows ARM64 implementation is intentionally surfaced for human review rather than being hidden behind a best-effort CI patch.
