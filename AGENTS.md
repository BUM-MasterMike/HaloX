# AGENTS.md

Guidance for AI coding agents (and humans) working in this repository.

## Project layout

- `scripts/build-wrapper.sh` – assembles `HaloX.app` from a Wine engine + game files
- `scripts/build-local.sh` – local build driver: calls `build-wrapper.sh` with the same defaults as the CI workflow (downloads/caches the WineskinCX engine + Wineskin wrapper runtime; accepts a game dir, zip, or URL)
- `wrapper/HaloX-Launcher.sh` – in-bundle launcher: sets `WINEPREFIX`, runs Wine (via Rosetta 2 on Apple Silicon), starts `halo.exe`
- `.github/workflows/build-wrapper.yml` – manual-only CI (builds + uploads artifacts; no GitHub Release)
- `CHANGELOG.md` – single source of truth for the changelog; only include sections that actually have entries (no TBD placeholders)
- `assets/` – app icon (`AppIcon.icns`, bundled as `Contents/Resources/AppIcon.icns`) and README logo (`shield.png`)

## Conventions

- All scripts, comments, and log messages must be **in English**.
- CI trigger: `workflow_dispatch` only – no `push` trigger.
- The workflow never creates GitHub Releases – it builds and uploads the ZIPs as run artifacts.
- Version is fixed at the top of the workflow via `env.VERSION` and must match the topmost section in `CHANGELOG.md` (e.g. `## [1.0.0]`).
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

1. Update `env.VERSION` in the workflow.
2. Add the matching section in `CHANGELOG.md`.
3. Commit (user pushes).
4. Actions → *Build HaloX Wrapper* → Run workflow → download the ZIPs from the run's Artifacts.
