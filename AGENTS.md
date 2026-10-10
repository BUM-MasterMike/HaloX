# AGENTS.md

Guidance for AI coding agents (and humans) working in this repository.

## Project layout

- `scripts/build-wrapper.sh` – assembles `HaloX.app` from a Wine engine + game files
- `scripts/build-local.sh` – local build driver: calls `build-wrapper.sh` with the same defaults as the CI workflow (downloads/caches the WineskinCX engine + Wineskin wrapper runtime; accepts a game dir, zip, or URL)
- `wrapper/HaloX-Launcher.sh` – in-bundle launcher: sets `WINEPREFIX`, runs Wine (via Rosetta 2 on Apple Silicon), starts `halo.exe`
- `ui/` – `HaloXBuilder.app` GUI: Swift/AppKit source (`HaloXBuilder.swift`), build script (`build.sh`, universal arm64 + x86_64 by default), app icon; the built app is never checked in
- `.github/workflows/build-wrapper.yml` – manual-only CI: builds the app ZIPs and uploads them as run artifacts. It **never** creates a GitHub Release.
- `.github/workflows/build.yml` – manual-only: builds a fresh universal (arm64 + x86_64) `HaloXBuilder.app` on a macOS runner and packages it with the **project** (source + build scripts) into a `HaloX-builder-vX.Y.Z.zip`. A "Publish release" checkbox on the manual run (checked by default) decides: checked → the ZIP is published as a GitHub Release; unchecked → the ZIP is only uploaded as a run artifact. It **never** publishes the built `HaloX.app` artifacts.
- `CHANGELOG.md` – single source of truth for the changelog; only include sections that actually have entries (no TBD placeholders)
- `assets/` – app icon (`AppIcon.icns`, bundled as `Contents/Resources/AppIcon.icns`), README logo (`shield.png`) and GUI screenshot (`halox-builder.webp`, shown in the README)

## Conventions

- All scripts, comments, and log messages must be **in English**.
- CI trigger: `workflow_dispatch` only – no `push` trigger.
- `build-wrapper.yml` builds and uploads the app ZIPs as run artifacts; it never creates a GitHub Release.
- `build.yml` publishes the **project** (source + build scripts + freshly built `HaloXBuilder.app`) – never of the built `HaloX.app` artifacts. Publishing is optional: the manual run has a "Publish release" checkbox (default on); unchecked it only uploads the ZIP as a run artifact.
- Version is the topmost `CHANGELOG.md` section (e.g. `## [1.0.0]`); the workflows and `build-wrapper.sh` read it from there, so the CHANGELOG is the single source of truth.
- Game binaries/assets (`halo.exe`, maps, etc.) are not redistributable – never commit them. CI expects them at `./game/` (provided privately).
- Do not commit automatically; ask before every `git commit`.
- **Never `git push`** – the user pushes. Commit locally, tell the user, and stop.
- Engine: **WineskinCX 23.7.1** (`WS11WineCX64Bit23.7.1`, engine input `wineskincx-23.7.1`) is the verified engine for Halo. Gcenx Wine 11 does not work (data-cache errors). The build also bundles the Wineskin wrapper runtime (`Contents/Frameworks`, `GStreamer.framework` excluded) via `--wineskin-runtime`.

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

## Release flow

1. Add/update the topmost section in `CHANGELOG.md` (this is the version).
2. Commit (user pushes).
3. Actions → *Build HaloX Wrapper* → Run workflow → download the app ZIPs from the run's Artifacts.
4. Actions → *Build project (optional release)* → Run workflow → either creates the GitHub Release with the `HaloX-builder-vX.Y.Z.zip` asset (project + built `HaloXBuilder.app`), or – with "Publish release" unchecked – only uploads the ZIP as a run artifact.
