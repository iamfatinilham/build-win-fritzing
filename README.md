# Fritzing Windows CI builds

This repository builds native Fritzing packages for Windows x64 and ARM64.

> **⚠️ Disclaimer:** This is an unofficial educational project and is not affiliated with or endorsed by [Fritzing GmbH](https://fritzing.org/). The Fritzing name, related logos, trademarks, and copyrighted materials remain the property of their respective rights holders.

## Running builds

All CI definitions are manual-only to preserve hosted-runner minutes. A push,
pull request, merge request, or schedule does not start a build. Use the
provider's **Run workflow** or **Run pipeline** button when you intend to build.

The GitHub Actions entry points are:

- `build-win-X64.yml` — normal x64 build; a GitHub Release is only created
  when manually dispatched with `publish_release` enabled.
- `build-win-ARM64.yml` — native ARM64 build.
- `build-win-All.yml` — one run that produces separate x64 and ARM64 artifacts.
- `build-win-64-Universal.yml` — the same two builds plus a ZIP containing
  both packages.

`Universal` does **not** mean one executable. Win32 desktop applications are
compiled for one CPU architecture; a native universal delivery is a bundle of
the separate x64 and ARM64 packages.

Each GitHub workflow also accepts optional Fritzing app and parts refs. Leave
them at `develop` for the current upstream version, or supply 40-character
commit IDs when you need a repeatable package. Every ZIP includes a
`build-manifest.json` recording the exact commits, Qt kit, dependencies, and
architecture used.

## ARM64 prerequisite

Fritzing upstream currently has no Windows ARM64 release configuration: its
`phoenix.pro` classifies ARM64 as 32-bit. The shared build script patches its
temporary checkout to classify ARM64 as 64-bit. It also requires an ARM64
ngspice archive containing `include/` and ARM64 DLLs. The public ngspice 42
Windows archive used by x64 is x64-only. Configure its replacement as the
`NGSPICE_ARM64_ARCHIVE_URL` repository secret, or supply the optional manual
workflow input. This prevents a package that starts but has broken simulation
support.

## Build compatibility

The build reads Fritzing's own qmake files on every run to select its supported
Qt range and the versions of Fritzing-declared dependencies. It validates
caches and PE architectures, retries downloads, and stops with a specific
message when the upstream build contract has materially changed. The detailed
design, provider requirements, and failure guide are in
[BUILD_COMPATIBILITY.md](docs/BUILD_COMPATIBILITY.md).

## Other CI providers

`.gitlab-ci.yml`, `.gitea/workflows/build-win.yml`, and
`.forgejo/workflows/build-win.yml` use the shared
`.ci/windows/build-windows.ps1` script. They need self-hosted Windows runners:

- x64: labels/tags `windows`, `x64`; a Qt `win64_msvc2022_64` kit supported by
  the Fritzing revision being built.
- ARM64: labels/tags `windows`, `arm64`; a Qt `win64_msvc2022_arm64` kit
  supported by the Fritzing revision, Visual Studio ARM64 C++ tools, and the
  `NGSPICE_ARM64_ARCHIVE_URL` secret/variable.

Codeberg runs Forgejo, so its active workflow is
`.forgejo/workflows/build-win.yml`. Public/shared Codeberg runners do not
provide the required Windows toolchains, so Windows builds must use a
self-hosted runner. Each non-GitHub provider keeps its separate native x64 and
ARM64 artifacts and additionally creates a universal ZIP containing both.
