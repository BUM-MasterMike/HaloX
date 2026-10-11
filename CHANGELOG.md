# Changelog

All notable changes to HaloX are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [1.5.0]

### Changed
- **MoltenVK is now off by default everywhere**: MoltenVK is optional
  and only needed for the experimental `HALOX_D3D_RENDERER=vulkan`
  override (macOS runs on wined3d `gl`), so `HaloXBuilder.app` now
  prefills the MoltenVK field with `none` (marked as experimental) and
  the README and script docs no longer claim `1.2.5` as the default —
  the local scripts (`build-local.sh`, `build-wrapper.sh`) and the CI
  workflow now default to `none` too. The README troubleshooting
  section also briefly explains what "experimental" means here (it
  needs a Metal-capable Mac and is far less tested than the OpenGL
  `gl` path).
- **Linux: no wine-mono/gecko prompt**: the Linux launcher now sets
  `WINEDLLOVERRIDES="mscoree,mshtml=;…"`, so the first start no longer
  shows Wine's mono/gecko install dialog — Halo is pure C++ and needs
  neither. The README "First run" note was updated accordingly.

## [1.4.0]

### Added
- **Linux wrapper**: a runnable Linux wrapper (a plain directory,
  e.g. `dist/HaloX`) in addition to the macOS `.app`. New
  `scripts/build-wrapper-linux.sh` assembles it and
  `scripts/build-local-linux.sh` drives it with the same defaults
  (Kron4ek `*-amd64-wow64` Wine engine, Chimera on, DSOAL `bundle`,
  DXVK on; downloads cached in `~/.cache/HaloX`). The Linux launcher
  is a checked-in file (`wrapper/HaloX-Launcher-Linux.sh`), exactly
  like the macOS one (`wrapper/HaloX-Launcher.sh`). x86_64 only —
  ARM (`box64`/`FEX`) is planned.
- **DXVK** on Linux: the Direct3D renderer now defaults to **DXVK**
  (D3D8/9/10/11 → Vulkan, ~1.5× faster than Wine's OpenGL path and
  patched for Halo CE) whenever a 32-bit Vulkan ICD is present, and
  automatically falls back to Wine's OpenGL (`gl`) otherwise, so a
  system without Vulkan still runs. Override per run with
  `HALOX_D3D_RENDERER=gl|dxvk|vulkan|auto`; skip DXVK at build time
  with `--no-dxvk`. macOS is unchanged (wined3d `gl`, MoltenVK
  available via `HALOX_D3D_RENDERER=vulkan`).

### Changed
- **No `python3` needed**: the GitHub "latest release" lookups
  (Chimera, DXVK, latest Kron4ek Wine engine) now use the shared
  `scripts/github-latest-asset.sh` (`curl` + `awk` instead of
  python3), so the build runs on plain systems without python.
- **Linux CI**: `build-wrapper.yml` gained `platform: linux`
  (ubuntu-latest, x86_64), which builds the Linux wrapper with
  `scripts/build-wrapper-linux.sh` and uploads
  `HaloX-Linux-vX.Y.Z.tar.gz` as a run artifact; new `with_dxvk`
  input (default on) controls the DXVK bundling. The former
  `platform: both` (macOS Intel + Apple Silicon) is now
  `platform: all` and also builds the Linux wrapper.
- README: the macOS and Linux build documentation now lives under one
  "Building the wrapper" chapter (`### macOS` / `### Linux`) with a
  shared "Build options" table — macOS stays the primary platform,
  no information was lost.
- **Robust downloads**: every `curl` download (game, Wine engine,
  Wineskin runtime, Chimera, DSOAL, DXVK, MoltenVK and the
  latest-release lookup) now retries transient network/DNS failures
  (`--retry 5 --retry-delay 5 --retry-all-errors`), so a flaky
  GitHub runner no longer aborts the build.
- **MoltenVK caching (local)**: `scripts/build-local.sh` now resolves
  MoltenVK once into the download cache
  (`~/Library/Caches/HaloX/moltenvk/<version>/libMoltenVK.dylib`) and
  hands the dylib path to `build-wrapper.sh`, so local rebuilds no
  longer re-download the ~46 MB `MoltenVK-macos.tar`; a user-supplied
  path or `--moltenvk none` is passed through unchanged and
  `--clear-cache` removes it too.

## [1.3.0]

### Added
- **Halo: Custom Edition** support: a `haloce.exe` installation is
  now accepted alongside the `halo.exe` (Combat Evolved) layout. The
  build detects the game executable (`halo.exe` or `haloce.exe`),
  records it in the bundle (`Contents/Resources/game-exe`) and the
  launcher starts the right one — the same builder works for both
  editions.

### Changed
- The game data check accepts `halo.exe` or `haloce.exe` (build
  scripts and the `build-wrapper.yml` workflow).
- The README documents both supported editions and the Chimera patch
  requirement (official patch **1.00.10.xxxx**, applied on Windows
  before the installation is used for HaloX; patching afterwards
  inside the Wine wrapper is possible but involved and needs wine
  expertise).

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

### Fixed
- The Chimera overlay could fail with `cp ... Permission denied`
  exactly on `fonts/`: the release archive stores entries that extract
  without read/execute bits (`d-----x---` with the system `bsdtar`,
  e.g. when the Builder app runs the script). The build now clears
  immutable flags (`chflags -R nouchg,noschg`) and sets `u+rwx` on
  the game source and the extracted Chimera tree before copying, and
  prints diagnostics (modes, flags, owner, free space) if the copy
  still fails.
- The `build.yml` "Publish release" checkbox was ignored: the boolean
  input was compared to the string `'true'`, which is always false, so
  all release steps were skipped. The condition now compares against
  the boolean directly (`inputs.publish == true`).

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
