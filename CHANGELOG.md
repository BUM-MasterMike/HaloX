# Changelog

All notable changes to HaloX are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [1.0.0]

### Added
- Initial Wine-based wrapper build for macOS (Intel + Apple Silicon)
- GitHub Actions workflow producing `HaloX-Intel` and `HaloX-Silicon` artifacts
- Automatic release creation with notes extracted from this file
- Launcher runs the game with the known-good flags `-novideo -use21 -console`
  and supports WineskinCX-style engines (`bin/wine64` + `Contents/Frameworks`)
- `scripts/build-local.sh`: builds with the same defaults as the CI workflow
  (downloads/caches the WineskinCX engine and the Wineskin wrapper runtime)
- CI lets you pick the engine (`engine` input, default `wineskincx-23.7.1`)
  or pass a direct archive URL (`engine_url`)

### Changed
- Engine is now **WineskinCX 23.7.1** (`WS11WineCX64Bit23.7.1`,
  wine-8.0.1) – the engine the known-good reference wrapper uses. The
  previous Gcenx Wine 11 engine is not supported (data-cache errors).
- The build bundles the Wineskin **wrapper runtime** (`Contents/Frameworks`)
  via a new `--wineskin-runtime` option; `GStreamer.framework` is excluded
  (its plugin scan crashes the engine).

### Fixed
- Crash at startup ("The game has encountered a segmentation fault" watson
  dialog): the default DSOAL build was the moving GitHub `latest-master`
  snapshot, whose modern C++ runtime calls `msvcp140.dll._Throw_Cpp_error` —
  an export Wine's builtin `msvcp140` does not provide, so wine aborted.
  DSOAL is now pinned to the checked-in, tested build
  (`vendor/dsoal-d9fed51a`: DSOAL `d9fed51a` + OpenAL Soft 1.23.1),
  byte-identical to the known-good reference wrapper.
- Engine startup crash on hosts with a system GStreamer install: the
  `winegstreamer` plugin scanner could crash on unclean host plugins. The
  launcher now disables the system plugin scan (`GST_PLUGIN_SYSTEM_PATH=""`).
- Direct3D renderer default is now `gl` (wined3d OpenGL) for Intel **and**
  Silicon, matching the reference wrapper which sets no renderer key at all.
  The explicit `gl|vulkan` build choice is gone; Vulkan/MoltenVK remains
  available only as a per-run override (`HALOX_D3D_RENDERER=vulkan`).
