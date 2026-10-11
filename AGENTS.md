# AGENTS.md

Guidance for AI coding agents (and humans) working in this repository.

## Project layout

- `scripts/build-wrapper.sh` – assembles `HaloX.app` from a Wine engine + game files
- `scripts/build-local.sh` – local build driver: calls `build-wrapper.sh` with the same defaults as the CI workflow (downloads/caches the WineskinCX engine + Wineskin wrapper runtime; accepts a game dir, zip, or URL)
- `scripts/build-wrapper-linux.sh` – assembles a runnable Linux wrapper (a plain directory) from a Linux Wine engine + game files; copies the launcher from wrapper/
- `scripts/build-local-linux.sh` – local Linux build driver: calls `build-wrapper-linux.sh` with the same defaults (Kron4ek wow64 engine, Chimera on, DSOAL bundle, DXVK on)
- `scripts/github-latest-asset.sh` – shared platform-independent helper (curl + awk, no python3): resolves the download URL of an asset of the latest GitHub release (used for the Chimera, DXVK and Kron4ek Wine-engine lookups)
- `wrapper/HaloX-Launcher.sh` – macOS in-bundle launcher: sets `WINEPREFIX`, runs Wine (via Rosetta 2 on Apple Silicon), starts `halo.exe`
- `wrapper/HaloX-Launcher-Linux.sh` – Linux launcher: sets `WINEPREFIX`, detects `halo.exe`/`haloce.exe`, picks the D3D renderer (DXVK with an automatic OpenGL fallback), starts the game
- `ui/` – `HaloXBuilder.app` GUI: Swift/AppKit source (`HaloXBuilder.swift`), build script (`build.sh`, universal arm64 + x86_64 by default), app icon; the built app is never checked in
- `.github/workflows/build-wrapper.yml` – manual-only CI: builds the app ZIPs and the Linux wrapper tar.gz (`platform: all` = Intel + Apple Silicon + Linux; also `intel`/`silicon`/`linux` alone) and uploads them as run artifacts. It **never** creates a GitHub Release.
- `.github/workflows/build.yml` – manual-only: builds a fresh universal (arm64 + x86_64) `HaloXBuilder.app` on a macOS runner and packages it with the **project** (source + build scripts) into a `HaloX-builder-vX.Y.Z.zip`. A "Publish release" checkbox on the manual run (checked by default) decides: checked → the ZIP is published as a GitHub Release; unchecked → the ZIP is only uploaded as a run artifact. It **never** publishes the built `HaloX.app` artifacts.
- `CHANGELOG.md` – single source of truth for the changelog; only include sections that actually have entries (no TBD placeholders)
- `assets/` – app icon (`AppIcon.icns`, bundled as `Contents/Resources/AppIcon.icns`), README logo (`shield.png`) and GUI screenshot (`halox-builder.webp`, shown in the README)

## Conventions

- All scripts, comments, and log messages must be **in English**.
- CI trigger: `workflow_dispatch` only – no `push` trigger.
- `build-wrapper.yml` builds and uploads the app ZIPs (macOS) and/or the Linux wrapper tar.gz (`platform: all|intel|silicon|linux`) as run artifacts; it never creates a GitHub Release.
- `build.yml` publishes the **project** (source + build scripts + freshly built `HaloXBuilder.app`) – never of the built `HaloX.app` artifacts. Publishing is optional: the manual run has a "Publish release" checkbox (default on); unchecked it only uploads the ZIP as a run artifact.
- Version is the topmost `CHANGELOG.md` section (e.g. `## [1.0.0]`); the workflows and `build-wrapper.sh` read it from there, so the CHANGELOG is the single source of truth.
- Game binaries/assets (`halo.exe`, maps, etc.) are not redistributable – never commit them. CI expects them at `./game/` (provided privately).
- Do not commit automatically; ask before every `git commit`.
- **Never `git push`** – the user pushes. Commit locally, tell the user, and stop.
- Engine: **WineskinCX 23.7.1** (`WS11WineCX64Bit23.7.1`, engine input `wineskincx-23.7.1`) is the verified engine for Halo. Gcenx Wine 11 does not work (data-cache errors). The build also bundles the Wineskin wrapper runtime (`Contents/Frameworks`, `GStreamer.framework` excluded) via `--wineskin-runtime`.
- Linux renderer: **DXVK** (D3D8/9/10/11 → Vulkan) is the default on Linux when a 32-bit Vulkan ICD is present; the launcher falls back to wined3d OpenGL (`gl`) otherwise. macOS always uses wined3d (`gl`, or MoltenVK via `HALOX_D3D_RENDERER=vulkan`).

## Build

The recommended way is `scripts/build-local.sh` – it uses the same defaults as
the CI workflow (WineskinCX 23.7.1 engine, Wineskin wrapper runtime, Chimera on,
DSOAL bundle, MoltenVK 1.2.5) and caches downloads in `~/Library/Caches/HaloX`:

```bash
./scripts/build-local.sh                # game data in ./game
./scripts/build-local.sh --game ./Halo.zip
./scripts/build-local.sh --game-url https://example.com/Halo.zip
```

Directly (engine = a WineskinCX `wswine.bundle` dir, runtime = wrapper `Contents` dir):

```bash
./scripts/build-wrapper.sh \
  --engine /path/to/wswine.bundle \
  --wineskin-runtime /path/to/WineskinWrapper.app/Contents \
  --game ./game \
  --arch x86_64 \
  --out HaloX.app
```

## Linux build

The recommended Linux way is `scripts/build-local-linux.sh` – it
uses the same defaults (Kron4ek `*-amd64-wow64` engine, Chimera on,
DSOAL bundle, DXVK on) and caches downloads in `~/.cache/HaloX`:

```bash
./scripts/build-local-linux.sh                # game data in ./game
./scripts/build-local-linux.sh --game ./Halo.zip
./scripts/build-local-linux.sh --game-url https://example.com/Halo.zip
```

Directly (engine = a Linux Wine dir, e.g. the extracted Kron4ek
`wine-<ver>-amd64-wow64`):

```bash
./scripts/build-wrapper-linux.sh \
  --engine /path/to/wine-<ver>-amd64-wow64 \
  --game ./game \
  --arch x86_64 \
  --out dist/HaloX
```

The macOS and Linux build scripts are deliberately **separate** (no
shared build-logic `common.sh`), so a change to one platform cannot
break the other. Only the platform-independent helpers
(`common-output.sh` for printing, `vidmode-presets.sh` for the
`-vidmode` presets, `github-latest-asset.sh` for the GitHub
"latest release" URL lookups) are shared.

## Release flow

1. Add/update the topmost section in `CHANGELOG.md` (this is the version).
2. Commit (user pushes).
3. Actions → *Build HaloX Wrapper* → Run workflow → download the app ZIPs from the run's Artifacts.
4. Actions → *Build project (optional release)* → Run workflow → either creates the GitHub Release with the `HaloX-builder-vX.Y.Z.zip` asset (project + built `HaloXBuilder.app`), or – with "Publish release" unchecked – only uploads the ZIP as a run artifact.

## Planned (not implemented)

- **Linux wrapper – remaining work**: the Linux wrapper itself is
  implemented (`build-wrapper-linux.sh` + `build-local-linux.sh`,
  plain directory, Kron4ek wow64 engine, DXVK with an automatic
  wined3d-OpenGL fallback, x86_64 only). Still open:
  - **ARM** hosts (`box64`/`FEX` for the x86_64 engine).
  - **Packaging**: AppDir/AppImage vs the current plain directory.
  - **GUI**: `HaloXBuilder.swift` (AppKit) stays macOS-only; Linux
    is CLI-only.
- The build only validates the game executable (`halo.exe`/`haloce.exe`);
  `MAPS/` (Combat Evolved) vs `maps/` (Custom Edition) is **not**
  checked — Wine resolves Windows paths case-insensitively, so both
  layouts work.
