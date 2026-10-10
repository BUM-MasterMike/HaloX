# Changelog

All notable changes to HaloX are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [1.2.0]

### Added
- **`HaloXBuilder.app`**: a native Swift/AppKit GUI front-end for
  `scripts/build-local.sh` (`ui/HaloXBuilder.swift`, built by `ui/build.sh`),
  so local builds can now be made from a window instead of the terminal.
  Every `build-local.sh` option is a field prefilled with the script's
  defaults (arch, output, engine/runtime, game source/URL, Chimera, DSOAL,
  MoltenVK, vidmode presets or a custom `W,H,R`, cache dir); the output
  streams live, the result appears in a sheet, and a button clears the
  download cache. It has an Edit menu (Cmd+C/V/X/A), a Window menu and an
  About dialog with build date and a link to github.com/BUM-MasterMike.
- The release ZIP (`HaloX-builder-vX.Y.Z.zip` from the `build.yml` workflow)
  now contains a **freshly cross-compiled universal (arm64 + x86_64)**
  `HaloXBuilder.app`, built on CI on every run — the `.app` is never
  checked in.
- The version is now read from the topmost `CHANGELOG.md` section in both
  workflows and both build scripts, so there is exactly one place to bump it.

## [1.1.0]

### Added
- A short "HaloX is starting..." dialog (with the app icon) appears the moment
  the app opens, so the game's startup is visible even though the wrapper has
  no Dock icon. It closes by itself after a short fixed time.

### Changed
- The Info.plist declares the app as a game (`LSApplicationCategoryType` =
  `public.app-category.games`, so macOS can apply Game Mode in fullscreen) and
  disables App Nap (`NSAppSleepDisabled`); `LSSupportsGameMode` covers Game
  Mode on macOS 26+. Note: this does not remove periodic ping spikes - those
  come from macOS Wi-Fi/AWDL background activity, see the README.

## [1.0.0]

### Added
- Initial Wine-based wrapper build for macOS (Intel + Apple Silicon)
- GitHub Actions workflow producing `HaloX-Intel` and `HaloX-Silicon` artifacts
- Launcher runs the game with the known-good flags `-novideo -use21 -console`
  and supports WineskinCX-style engines (`bin/wine64` + `Contents/Frameworks`)
- `scripts/build-local.sh`: builds with the same defaults as the CI workflow
  (downloads/caches the WineskinCX engine and the Wineskin wrapper runtime)
- CI lets you pick the engine (`engine` input, default `wineskincx-23.7.1`)
  or pass a direct archive URL (`engine_url`)
- `--vidmode` build option: bundles a `-vidmode` value
  (`Contents/Resources/vidmode.conf`) that the launcher passes to `halo.exe`,
  so the game starts at the current desktop resolution. `--vidmode` accepts a
  preset alias (e.g. `macbook-air-13`) or a literal `W,H,R`; the presets live
  in `scripts/vidmode-presets.sh` (single source of truth). Bare
  `--vidmode` in `build-local.sh` opens an interactive preset picker with a
  custom `W,H,R` option; the CI workflow gained `vidmode` (choice) and
  `vidmode_custom` (free text) inputs.
- Game zips whose data is wrapped in a single top-level folder (e.g. a zipped
  `Halo` directory instead of its contents) are detected and stepped into
  automatically – `--game` now accepts both archive layouts.

### Changed
- Engine is now **WineskinCX 23.7.1** (`WS11WineCX64Bit23.7.1`,
  wine-8.0.1) – the engine the known-good reference wrapper uses. The
  previous Gcenx Wine 11 engine is not supported (data-cache errors).
- The build bundles the Wineskin **wrapper runtime** (`Contents/Frameworks`)
  via a new `--wineskin-runtime` option; `GStreamer.framework` is excluded
  (its plugin scan crashes the engine).
- Launcher runs Wine with debug output disabled (`WINEDEBUG=-all`) unless an
  external `WINEDEBUG` is set – a stray `WINEDEBUG=+d3d` run otherwise writes
  multi-GB logs that stall the game (stutter, unresponsive UI).

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
- The Dock permanently bounced the `HaloX` app icon while the game ran under
  the separate in-game (Windows) icon. The app now sets `LSUIElement`: no own
  Dock icon, only the in-game icon shows – no more bouncing.
- Direct3D renderer default is now `gl` (wined3d OpenGL) for Intel **and**
  Silicon, matching the reference wrapper which sets no renderer key at all.
  The explicit `gl|vulkan` build choice is gone; Vulkan/MoltenVK remains
  available only as a per-run override (`HALOX_D3D_RENDERER=vulkan`).
- Direct3D error dialog on scaled ("Looks like") displays such as the MacBook
  Air: on first run Halo requests `640x480`, macOS refuses the mode change
  (`NtUserChangeDisplaySettings` -> `DISP_CHANGE_BADMODE`), and the launch
  aborts. A `--vidmode` build makes the game request the current desktop
  resolution, so wined3d skips the mode change entirely. The value must match
  the display's current "Looks like" resolution; the preset table documents
  the known devices (`scripts/vidmode-presets.sh`). Default builds (without
  `--vidmode`) are unchanged – Halo/Chimera handle the resolution as before.
- Documented that the startup lines `Failed to read data file header` and
  `### FAILED TO OPEN DATA-CACHE FILE.` are cosmetic on Apple Silicon: Halo
  1.0.10 no longer halts on cache verify errors, and every game file is
  byte-identical to the reference build (verified via SHA-256 of all maps).
  No fix is needed.
