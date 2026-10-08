#!/bin/bash
#
# build-local.sh – local helper that drives build-wrapper.sh with the same
# defaults as the CI workflow (.github/workflows/build-wrapper.yml).
#
# Copyright (c) 2026 BUM MasterMike. Licensed under the MIT License.
# See the LICENSE file for details.
#
# It downloads and caches the same two ingredients the workflow fetches:
#   1. the WineskinCX engine (default: WS11WineCX64Bit23.7.1 – the version
#      verified to run Halo; Gcenx Wine 11 does not work)
#   2. the Wineskin wrapper runtime (Contents/Frameworks shared libraries)
# and then calls build-wrapper.sh with the workflow's default options
# (Chimera on, DSOAL = bundle, MoltenVK 1.2.5).
#
# Downloads are cached in ~/Library/Caches/HaloX so rebuilds are offline.
#
# Usage:
#   ./scripts/build-local.sh [options]
#
# Options (defaults mirror the workflow inputs):
#   --engine <name>       Engine: wineskincx-23.7.1 (default), wineskincx-23.6.0,
#                         wineskincx-23.5.0, wineskincx-22.1.1, wineskincx-21.2.0
#   --engine-url <url>    Direct engine archive URL (overrides --engine)
#   --engine-dir <dir>    Use a local engine dir (must contain bin/ lib/ share/)
#   --runtime-url <url>   Direct Wineskin wrapper runtime URL (override)
#   --runtime-dir <dir>   Use a local wrapper Contents dir (must contain Frameworks/)
#   --game <dir|zip>      Game source (default: ./game)
#   --game-url <url>      Download a game zip URL first (alias: --game-zip-url).
#                         A trailing positional URL is also accepted, e.g.:
#                           ./scripts/build-local.sh https://example.com/Halo.zip
#   --chimera / --no-chimera   Apply latest Chimera (default: on)
#   --dsoal <bundle|github|zip|dir>   DSOAL source (default: bundle)
#   --dsoal-hrtf          Force DSOAL binaural HRTF output
#   --no-dsoal            Skip DSOAL entirely
#   --moltenvk <v|path|none>  MoltenVK for the vulkan override (default: 1.2.5)
#
#   --vidmode <alias|W,H,R>
#       Bundle a -vidmode value: a preset alias from scripts/vidmode-presets.sh
#       (e.g. macbook-air-13) or a literal W,H,R (e.g. 1280,800,60). Without a
#       value, opens an interactive preset picker (terminal only). Default: off
#       (no -vidmode; Halo/Chimera handle the resolution).
#
#   --arch <arch>         x86_64 or arm64 (default: host arch)
#   --out <path>          Output .app (default: dist/HaloX.app)
#   --cache-dir <dir>     Download cache (default: ~/Library/Caches/HaloX)
#   --clear-cache         Remove the cached engine + runtime downloads. Standalone
#                         run = cache cleanup only (no build); combined with a game
#                         source (--game / --game-url / URL) it clears the cache
#                         and then proceeds with the build.
#   --no-cache            Ignore the cache: download/extract to a temp dir instead
#                         and remove it afterwards (nothing is stored persistently).
#
set -euo pipefail

# Repo root: one level above scripts/
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_WRAPPER="$ROOT/scripts/build-wrapper.sh"

# Run from the repo root so relative paths (--out dist/HaloX.app, --game ...)
# always resolve against the root, no matter where the script is invoked from.
cd "$ROOT"

# Shared pretty-printing helpers (colors only on a TTY)
. "$ROOT/scripts/common-output.sh"

# --- Defaults: mirror the workflow inputs --------------------------------
ENGINE="wineskincx-23.7.1"
ENGINE_URL=""
ENGINE_DIR=""
RUNTIME_URL="https://github.com/The-Wineskin-Project/Wrapper/releases/download/v1.0/Wineskin-3.0.6_1.tar.7z"
RUNTIME_DIR=""
GAME="$ROOT/game"
GAME_ZIP_URL=""
WITH_CHIMERA=1
WITH_DSOAL=1
DSOAL="bundle"
DSOAL_HRTF=""
MOLTENVK="1.2.5"
ARCH="$(uname -m)"
OUT="dist/HaloX.app"
CACHE_DIR="${HALOX_CACHE_DIR:-"$HOME/Library/Caches/HaloX"}"
CLEAR_CACHE=0
NO_CACHE=0
GAME_GIVEN=0
VIDMODE=""
VIDMODE_PROMPT=0

usage() {
  sed -n '2,/^set -euo pipefail/p' "$0" | sed '$d'
  echo
  echo "Positional URL (optional): a game zip URL, same as --game-url."
  exit "${1:-0}"
}

# Positional game URL support: a single trailing http(s) URL is the game zip,
# mirroring how the workflow's game_zip_url input works next to ./game.
GAME_URL_POS=""
while [ $# -gt 0 ]; do
  case "$1" in
    --engine)         ENGINE="$2"; shift 2 ;;
    --engine-url)     ENGINE_URL="$2"; shift 2 ;;
    --engine-dir)     ENGINE_DIR="$2"; shift 2 ;;
    --runtime-url)    RUNTIME_URL="$2"; shift 2 ;;
    --runtime-dir)    RUNTIME_DIR="$2"; shift 2 ;;
    --game)           GAME_GIVEN=1; GAME="$2"; shift 2 ;;
    --game-url|--game-zip-url) GAME_GIVEN=1; GAME_URL="$2"; shift 2 ;;
    --chimera)        WITH_CHIMERA=1; shift ;;
    --no-chimera)     WITH_CHIMERA=0; shift ;;
    --no-dsoal)       WITH_DSOAL=0; shift ;;
    --dsoal)          DSOAL="$2"; shift 2 ;;
    --dsoal-hrtf)     DSOAL_HRTF=1; shift ;;
    --moltenvk)       MOLTENVK="$2"; shift 2 ;;
    --vidmode)
      # Optional value: --vidmode <alias|W,H,R>. Bare --vidmode (no value)
      # opens the interactive preset picker.
      shift
      if [ $# -gt 0 ] && [[ "$1" != -* ]]; then
        VIDMODE="$1"
        shift
      else
        VIDMODE_PROMPT=1
      fi
      ;;
    --arch)           ARCH="$2"; shift 2 ;;
    --out)            OUT="$2"; shift 2 ;;
    --cache-dir)      CACHE_DIR="$2"; shift 2 ;;
    --clear-cache)    CLEAR_CACHE=1; shift ;;
    --no-cache)       NO_CACHE=1; shift ;;
    -h|--help)        usage 0 ;;
    http://*|https://*) GAME_GIVEN=1; GAME_URL_POS="$1"; shift ;;
    *) echo "Unknown argument: $1"; usage 1 ;;
  esac
done

[ -x "$BUILD_WRAPPER" ] || { echo "build-wrapper.sh not found at $BUILD_WRAPPER"; exit 1; }

# --- Cache handling --------------------------------------------------------
if [ "$CLEAR_CACHE" = 1 ]; then
  section "Clear cache"
  REMOVED=0
  for SUB in engine runtime; do
    if [ -d "$CACHE_DIR/$SUB" ]; then
      info "Removing $CACHE_DIR/$SUB"
      rm -rf "$CACHE_DIR/$SUB"
      REMOVED=1
    fi
  done
  if [ "$REMOVED" = 1 ]; then
    ok "Cache cleared: $CACHE_DIR"
  else
    ok "Cache already empty: $CACHE_DIR"
  fi
  if [ "$GAME_GIVEN" = 0 ]; then
    info "Standalone --clear-cache: nothing else to do."
    exit 0
  fi
  echo
fi

if [ "$NO_CACHE" = 1 ]; then
  # One-off run: download/extract to a temp dir, cleaned up on exit.
  NO_CACHE_DIR="$(mktemp -d -t halox-nocache.XXXXXX)"
  trap 'rm -rf "$NO_CACHE_DIR"' EXIT
  CACHE_DIR="$NO_CACHE_DIR"
fi

# --- Interactive --vidmode selection -------------------------------------
# Bare --vidmode opens a picker of the known display presets plus a custom
# W,H,R option. The picker reads the same table as build-wrapper.sh
# (scripts/vidmode-presets.sh), so the shown values are never duplicated.
if [ "$VIDMODE_PROMPT" = 1 ]; then
  if [ ! -t 0 ]; then
    fail "--vidmode without a value needs a terminal (use '--vidmode <alias|W,H,R>' instead)"
    exit 1
  fi
  . "$ROOT/scripts/vidmode-presets.sh"

  PRESET_NAMES=()
  PRESET_VALUES=()
  PRESET_DESCS=()
  while IFS='|' read -r name val desc; do
    [ -n "$name" ] || continue
    PRESET_NAMES+=("$name")
    PRESET_VALUES+=("$val")
    PRESET_DESCS+=("$desc")
  done <<< "$VIDMODE_PRESET_DEFS"

  section "Vidmode"
  echo "Pick a display preset, or enter a custom W,H,R that matches the"
  echo "current 'Looks like' resolution (System Settings > Displays)."
  echo
  PS3="Select a preset (last option = custom input): "
  while true; do
    n=0
    for i in "${!PRESET_NAMES[@]}"; do
      n=$((n + 1))
      printf '%2d) %s (%s) - %s\n' "$n" "${PRESET_NAMES[$i]}" "${PRESET_VALUES[$i]}" "${PRESET_DESCS[$i]}"
    done
    n=$((n + 1))
    printf '%2d) Custom input (W,H,R)\n' "$n"
    if ! read -rp "$PS3"; then
      echo "Aborted (no input)."
      exit 1
    fi
    case "$REPLY" in
      ''|*[!0-9]*)
        echo "Invalid choice: '$REPLY'"
        ;;
      *)
        if [ "$REPLY" -ge 1 ] && [ "$REPLY" -le "$n" ]; then
          if [ "$REPLY" -eq "$n" ]; then
            if ! read -rp "Enter custom W,H,R (e.g. 1280,800,60): " VIDMODE; then
              echo "Aborted (no input)."
              exit 1
            fi
          else
            VIDMODE="${PRESET_VALUES[$((REPLY - 1))]}"
          fi
          break
        fi
        echo "Invalid choice: $REPLY"
        ;;
    esac
  done
fi

# --- Show configuration ---------------------------------------------------
banner "HaloX - local build" \
  "Assembles HaloX.app with the same defaults as the CI workflow"
section "Configuration"
kv "Engine"      "$ENGINE"
kv "Engine URL"  "${ENGINE_URL:-<default for chosen engine>}"
kv "Engine dir"  "${ENGINE_DIR:-<downloaded + cached on first run>}"
kv "Runtime URL" "$RUNTIME_URL"
kv "Runtime dir" "${RUNTIME_DIR:-<downloaded + cached on first run>}"
kv "Game"        "$GAME"
kv "Game URL"    "${GAME_URL:-${GAME_URL_POS:-none}}"
kv "Arch"        "$ARCH"
if [ "$WITH_CHIMERA" = 1 ]; then kv "Chimera" "on"; else kv "Chimera" "off"; fi
if [ "$WITH_DSOAL" = 1 ]; then kv "DSOAL" "$DSOAL"; else kv "DSOAL" "off"; fi
if [ -n "$DSOAL_HRTF" ]; then kv "DSOAL HRTF" "on"; else kv "DSOAL HRTF" "off"; fi
kv "MoltenVK"    "$MOLTENVK"
kv "Vidmode"     "${VIDMODE:-off}"
kv "Output"      "$OUT"
if [ "$CLEAR_CACHE" = 1 ]; then kv "Clear cache" "on"; fi
if [ "$NO_CACHE" = 1 ]; then
  kv "Cache dir"  "off (temp only)"
else
  kv "Cache dir"  "$CACHE_DIR"
fi

# --- Resolve the game source ---------------------------------------------
section "Game source"
GAME_URL="${GAME_URL:-$GAME_URL_POS}"
if [ -n "$GAME_URL" ]; then
  # mktemp -t appends the random suffix AFTER the literal template, so the
  # archive name never ends in .zip and build-wrapper.sh would reject it.
  # Download into a temp dir under a fixed name that ends in .zip.
  GAME_ZIP_DIR="$(mktemp -d -t halox-game.XXXXXX)"
  GAME_ZIP="$GAME_ZIP_DIR/halo.zip"
  info "Downloading game zip: $GAME_URL"
  curl -L --fail -o "$GAME_ZIP" "$GAME_URL"
  GAME="$GAME_ZIP"
fi
[ -f "$GAME" ] || [ -d "$GAME" ] || { fail "Game source not found: $GAME (use --game, --game-url, or a trailing URL)"; exit 1; }
ok "Game source: $GAME"

# --- Resolve the WineskinCX engine --------------------------------------
section "Wine engine"
if [ -n "$ENGINE_DIR" ]; then
  [ -d "$ENGINE_DIR/bin" ] || { fail "--engine-dir must contain bin/ (got: $ENGINE_DIR)"; exit 1; }
  ok "Using local engine dir: $ENGINE_DIR"
else
  if [ -n "$ENGINE_URL" ]; then
    ENGINE_ARCHIVE="$(basename "$ENGINE_URL")"
    ENGINE_LABEL="${ENGINE_ARCHIVE%.tar.7z}"
  else
    # Map the friendly name to the PortingKit archive (same as the workflow)
    case "$ENGINE" in
      wineskincx-23.7.1) ENGINE_ARCHIVE="WS11WineCX64Bit23.7.1.tar.7z" ;;
      wineskincx-23.6.0) ENGINE_ARCHIVE="WS11WineCX64Bit23.6.0.tar.7z" ;;
      wineskincx-23.5.0) ENGINE_ARCHIVE="WS11WineCX64Bit23.5.0.tar.7z" ;;
      wineskincx-22.1.1) ENGINE_ARCHIVE="WS11WineCX64Bit22.1.1.tar.7z" ;;
      wineskincx-21.2.0) ENGINE_ARCHIVE="WS11WineCX64Bit21.2.0.tar.7z" ;;
      *) fail "Unknown engine '$ENGINE'"; exit 1 ;;
    esac
    ENGINE_URL="https://github.com/vitor251093/porting-kit-engines/releases/download/wineskin/${ENGINE_ARCHIVE}"
    ENGINE_LABEL="${ENGINE_ARCHIVE%.tar.7z}"
  fi

  ENGINE_CACHE="$CACHE_DIR/engine"
  ENGINE_DIR="$ENGINE_CACHE/$ENGINE_LABEL"
  mkdir -p "$ENGINE_CACHE"

  if [ ! -d "$ENGINE_DIR" ]; then
    ARCHIVE_PATH="$ENGINE_CACHE/$ENGINE_ARCHIVE"
    if [ ! -f "$ARCHIVE_PATH" ]; then
      info "Downloading engine: $ENGINE_URL"
      curl -L --fail -o "$ARCHIVE_PATH" "$ENGINE_URL"
    else
      info "Engine archive cached: $ARCHIVE_PATH"
    fi
    mkdir -p "$ENGINE_DIR"
    info "Extracting engine..."
    tar -xJf "$ARCHIVE_PATH" -C "$ENGINE_DIR"
  else
    info "Engine extracted cache hit: $ENGINE_DIR"
  fi

  # The archive wraps everything in a bundle dir (wswine.bundle): find it and
  # point ENGINE_DIR at that subdirectory (this is what build-wrapper.sh needs).
  BUNDLE="$(find "$ENGINE_DIR" -maxdepth 2 -type d -name bin -exec dirname {} \; | head -1)"
  [ -n "$BUNDLE" ] || { fail "Could not locate engine bin/ under $ENGINE_DIR"; exit 1; }
  ENGINE_DIR="$BUNDLE"
  [ -x "$ENGINE_DIR/bin/wine64" ] || { fail "No bin/wine64 in $ENGINE_DIR"; exit 1; }
fi
ok "Engine: $("$ENGINE_DIR/bin/wine64" --version 2>/dev/null || echo unknown)"

# --- Resolve the Wineskin wrapper runtime (Contents/Frameworks) ----------
section "Wineskin runtime"
if [ -n "$RUNTIME_DIR" ]; then
  [ -d "$RUNTIME_DIR/Frameworks" ] || { fail "--runtime-dir must contain Frameworks/ (got: $RUNTIME_DIR)"; exit 1; }
  ok "Using local runtime dir: $RUNTIME_DIR"
else
  RUNTIME_ARCHIVE="$(basename "$RUNTIME_URL")"
  RUNTIME_LABEL="${RUNTIME_ARCHIVE%.tar.7z}"
  RUNTIME_CACHE="$CACHE_DIR/runtime"
  RUNTIME_DIR="$RUNTIME_CACHE/$RUNTIME_LABEL"
  mkdir -p "$RUNTIME_CACHE"

  if [ ! -d "$RUNTIME_DIR" ]; then
    ARCHIVE_PATH="$RUNTIME_CACHE/$RUNTIME_ARCHIVE"
    if [ ! -f "$ARCHIVE_PATH" ]; then
      info "Downloading Wineskin runtime: $RUNTIME_URL"
      curl -L --fail -o "$ARCHIVE_PATH" "$RUNTIME_URL"
    else
      info "Runtime archive cached: $ARCHIVE_PATH"
    fi
    mkdir -p "$RUNTIME_DIR"
    info "Extracting runtime..."
    tar -xJf "$ARCHIVE_PATH" -C "$RUNTIME_DIR"
  else
    info "Runtime extracted cache hit: $RUNTIME_DIR"
  fi

  # The archive wraps everything in a .app; locate the Contents dir holding
  # Frameworks/ and point RUNTIME_DIR there.
  CONTENTS="$(find "$RUNTIME_DIR" -maxdepth 3 -type d -name Frameworks -exec dirname {} \; | head -1)"
  [ -n "$CONTENTS" ] || { fail "Could not locate Frameworks/ under $RUNTIME_DIR"; exit 1; }
  RUNTIME_DIR="$CONTENTS"
  [ -d "$RUNTIME_DIR/Frameworks" ] || { fail "No Frameworks/ in $RUNTIME_DIR"; exit 1; }
fi
ok "Runtime frameworks: $RUNTIME_DIR/Frameworks"

# --- Assemble the build-wrapper.sh arguments -----------------------------
BUILD_ARGS=()
BUILD_ARGS+=(--engine "$ENGINE_DIR")
BUILD_ARGS+=(--wineskin-runtime "$RUNTIME_DIR")
BUILD_ARGS+=(--game "$GAME")
BUILD_ARGS+=(--arch "$ARCH")
BUILD_ARGS+=(--out "$OUT")
BUILD_ARGS+=(--moltenvk "$MOLTENVK")
if [ -n "$VIDMODE" ]; then
  BUILD_ARGS+=(--vidmode "$VIDMODE")
fi
if [ "$WITH_CHIMERA" = 1 ]; then
  BUILD_ARGS+=(--chimera github)
fi
if [ "$WITH_DSOAL" = 1 ]; then
  BUILD_ARGS+=(--dsoal "$DSOAL")
  if [ -n "$DSOAL_HRTF" ]; then
    BUILD_ARGS+=(--dsoal-hrtf)
  fi
fi

section "Assemble wrapper"
ok "Invoking: ${BUILD_ARGS[*]}"
exec "$BUILD_WRAPPER" "${BUILD_ARGS[@]}"