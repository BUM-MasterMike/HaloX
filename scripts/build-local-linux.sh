#!/bin/bash
#
# build-local-linux.sh – local helper that drives build-wrapper-linux.sh
# with the same defaults as the macOS build-local.sh (adapted for Linux).
#
# Copyright (c) 2026 BUM MasterMike. Licensed under the MIT License.
# See the LICENSE file for details.
#
# It downloads and caches the one ingredient the Linux build needs:
#   1. a Linux Wine engine (default: the latest Kron4ek/Wine-Builds
#      "wine-<ver>-amd64-wow64" archive – the wow64 variant runs the
#      32-bit halo.exe on a 64-bit prefix without 32-bit host libraries)
# and then calls build-wrapper-linux.sh with the default options
# (Chimera on, DSOAL = bundle, DXVK = github).
#
# There is no Wineskin wrapper runtime on Linux: the Kron4ek Wine is
# self-contained (bin/ lib/ share/), so nothing extra is bundled.
#
# Downloads are cached in ~/.cache/HaloX so rebuilds are offline.
#
# NOTE: This script is deliberately self-contained (like
# build-wrapper-linux.sh). It does NOT share the build logic with the
# macOS build-local.sh, so changes to one platform cannot break the
# other. Only the platform-independent helpers (common-output.sh for
# printing, vidmode-presets.sh for the -vidmode presets) are sourced.
#
# Usage:
#   ./scripts/build-local-linux.sh [options]
#
# Options:
#   --engine <latest|ver>  Wine engine: latest (default), or a pinned
#                          version (e.g. 11.19) from Kron4ek/Wine-Builds
#   --engine-url <url>     Direct Wine archive URL (overrides --engine)
#   --engine-dir <dir>     Use a local Wine dir (must contain bin/wine)
#   --game <dir|zip>       Game source (default: ./game)
#   --game-url <url>       Download a game zip URL first (alias:
#                          --game-zip-url). A trailing positional URL is
#                          also accepted, e.g.:
#                            ./scripts/build-local-linux.sh https://example.com/Halo.zip
#   --chimera / --no-chimera   Apply latest Chimera (default: on)
#   --dsoal <bundle|github|zip|dir>   DSOAL source (default: bundle)
#   --dsoal-hrtf           Force DSOAL binaural HRTF output
#   --no-dsoal             Skip DSOAL entirely
#
#   --dxvk <github|tar.gz|zip|dir>
#                          DXVK source (default: github). DXVK is the
#                          fast D3D path (D3D8/9/10/11 -> Vulkan); the
#                          launcher uses it automatically when a 32-bit
#                          Vulkan ICD is present, else falls back to
#                          wined3d OpenGL.
#   --no-dxvk            Skip DXVK (renderer stays wined3d OpenGL).
#
#   --vidmode <alias|W,H,R>
#       Bundle a -vidmode value: a preset alias from scripts/vidmode-presets.sh
#       (e.g. macbook-air-13) or a literal W,H,R (e.g. 1280,800,60). Without a
#       value, opens an interactive preset picker (terminal only). Default: off
#       (no -vidmode; Halo/Chimera handle the resolution).
#
#   --arch <arch>         x86_64 (default; ARM via box64/FEX is planned)
#   --out <path>          Output directory (default: dist/HaloX)
#   --cache-dir <dir>     Download cache (default: ~/.cache/HaloX)
#   --clear-cache         Remove the cached engine download. Standalone
#                         run = cache cleanup only (no build); combined with a
#                         game source it clears the cache and then builds.
#   --no-cache            Ignore the cache: download/extract to a temp dir
#                         instead and remove it afterwards.
#
set -euo pipefail

# Repo root: one level above scripts/
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_WRAPPER="$ROOT/scripts/build-wrapper-linux.sh"

# Run from the repo root so relative paths (--out dist/HaloX, --game ...)
# always resolve against the root, no matter where the script is invoked from.
cd "$ROOT"

# Shared pretty-printing helpers (colors only on a TTY). Platform-
# independent, so sharing them cannot couple the two build paths.
. "$ROOT/scripts/common-output.sh"

# --- Defaults -----------------------------------------------------------
ENGINE="latest"
ENGINE_URL=""
ENGINE_DIR=""
GAME="$ROOT/game"
GAME_URL=""
WITH_CHIMERA=1
WITH_DSOAL=1
DSOAL="bundle"
DSOAL_HRTF=""
WITH_DXVK=1
DXVK="github"
ARCH="x86_64"
OUT="dist/HaloX"
CACHE_DIR="${HALOX_CACHE_DIR:-"${XDG_CACHE_HOME:-$HOME/.cache}/HaloX"}"
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

# Positional game URL support: a single trailing http(s) URL is the game
# zip.
GAME_URL_POS=""
while [ $# -gt 0 ]; do
  case "$1" in
    --engine)         ENGINE="$2"; shift 2 ;;
    --engine-url)     ENGINE_URL="$2"; shift 2 ;;
    --engine-dir)     ENGINE_DIR="$2"; shift 2 ;;
    --game)           GAME_GIVEN=1; GAME="$2"; shift 2 ;;
    --game-url|--game-zip-url) GAME_GIVEN=1; GAME_URL="$2"; shift 2 ;;
    --chimera)        WITH_CHIMERA=1; shift ;;
    --no-chimera)     WITH_CHIMERA=0; shift ;;
    --no-dsoal)       WITH_DSOAL=0; shift ;;
    --dsoal)          DSOAL="$2"; shift 2 ;;
    --dsoal-hrtf)     DSOAL_HRTF=1; shift ;;
    --dxvk)           DXVK="$2"; shift 2 ;;
    --no-dxvk)        WITH_DXVK=0; shift ;;
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

[ -x "$BUILD_WRAPPER" ] || { echo "build-wrapper-linux.sh not found at $BUILD_WRAPPER"; exit 1; }

# --- Cache handling --------------------------------------------------------
if [ "$CLEAR_CACHE" = 1 ]; then
  section "Clear cache"
  if [ -d "$CACHE_DIR/engine" ]; then
    info "Removing $CACHE_DIR/engine"
    rm -rf "$CACHE_DIR/engine"
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
# W,H,R option. The picker reads the same table as build-wrapper-linux.sh
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
  echo "current display resolution."
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
banner "HaloX - local Linux build" \
  "Assembles a Linux HaloX wrapper with Wine + the game files"
section "Configuration"
kv "Engine"      "$ENGINE"
kv "Engine URL"  "${ENGINE_URL:-<default for chosen engine>}"
kv "Engine dir"  "${ENGINE_DIR:-<downloaded + cached on first run>}"
kv "Game"        "$GAME"
kv "Game URL"    "${GAME_URL:-${GAME_URL_POS:-none}}"
kv "Arch"        "$ARCH"
if [ "$WITH_CHIMERA" = 1 ]; then kv "Chimera" "on"; else kv "Chimera" "off"; fi
if [ "$WITH_DSOAL" = 1 ]; then kv "DSOAL" "$DSOAL"; else kv "DSOAL" "off"; fi
if [ -n "$DSOAL_HRTF" ]; then kv "DSOAL HRTF" "on"; else kv "DSOAL HRTF" "off"; fi
if [ "$WITH_DXVK" = 1 ]; then kv "DXVK" "$DXVK"; else kv "DXVK" "off"; fi
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
  # archive name never ends in .zip and build-wrapper-linux.sh would reject
  # it. Download into a temp dir under a fixed name that ends in .zip.
  GAME_ZIP_DIR="$(mktemp -d -t halox-game.XXXXXX)"
  GAME_ZIP="$GAME_ZIP_DIR/halo.zip"
  info "Downloading game zip: $GAME_URL"
  curl -L --fail --retry 5 --retry-delay 5 --retry-all-errors -o "$GAME_ZIP" "$GAME_URL"
  GAME="$GAME_ZIP"
fi
[ -f "$GAME" ] || [ -d "$GAME" ] || { fail "Game source not found: $GAME (use --game, --game-url, or a trailing URL)"; exit 1; }
ok "Game source: $GAME"

# --- Resolve the Linux Wine engine --------------------------------------
section "Wine engine (Linux)"
if [ -n "$ENGINE_DIR" ]; then
  [ -d "$ENGINE_DIR/bin" ] || { fail "--engine-dir must contain bin/ (got: $ENGINE_DIR)"; exit 1; }
  ok "Using local engine dir: $ENGINE_DIR"
else
  if [ -n "$ENGINE_URL" ]; then
    ENGINE_ARCHIVE="$(basename "$ENGINE_URL")"
    ENGINE_LABEL="${ENGINE_ARCHIVE%.tar.xz}"
  elif [ "$ENGINE" = "latest" ]; then
    # Latest stable Kron4ek/Wine-Builds "*-amd64-wow64" archive.
    ENGINE_URL="$("$ROOT/scripts/github-latest-asset.sh" Kron4ek/Wine-Builds '^wine-%s-amd64-wow64\.tar\.xz$')"
    [ -n "$ENGINE_URL" ] || { fail "Could not find the latest Wine wow64 build on GitHub"; exit 1; }
    ENGINE_ARCHIVE="$(basename "$ENGINE_URL")"
    ENGINE_LABEL="${ENGINE_ARCHIVE%.tar.xz}"
  else
    # A pinned version, e.g. --engine 11.19
    if ! printf '%s' "$ENGINE" | grep -qE '^[0-9]+(\.[0-9]+)+$'; then
      fail "Unknown engine '$ENGINE' (use 'latest', a version like '11.19', or --engine-url)"; exit 1
    fi
    ENGINE_URL="https://github.com/Kron4ek/Wine-Builds/releases/download/$ENGINE/wine-$ENGINE-amd64-wow64.tar.xz"
    ENGINE_ARCHIVE="wine-$ENGINE-amd64-wow64.tar.xz"
    ENGINE_LABEL="${ENGINE_ARCHIVE%.tar.xz}"
  fi

  ENGINE_CACHE="$CACHE_DIR/engine"
  ENGINE_DIR="$ENGINE_CACHE/$ENGINE_LABEL"
  mkdir -p "$ENGINE_CACHE"

  if [ ! -d "$ENGINE_DIR" ]; then
    ARCHIVE_PATH="$ENGINE_CACHE/$ENGINE_ARCHIVE"
    if [ ! -f "$ARCHIVE_PATH" ]; then
      info "Downloading Wine engine: $ENGINE_URL"
      curl -L --fail --retry 5 --retry-delay 5 --retry-all-errors -o "$ARCHIVE_PATH" "$ENGINE_URL"
    else
      info "Engine archive cached: $ARCHIVE_PATH"
    fi
    mkdir -p "$ENGINE_DIR"
    info "Extracting engine..."
    tar -xJf "$ARCHIVE_PATH" -C "$ENGINE_DIR"
  else
    info "Engine extracted cache hit: $ENGINE_DIR"
  fi

  # The archive may wrap everything in a versioned folder; find the dir
  # that holds bin/ (that is what build-wrapper-linux.sh expects).
  FOUND="$(find "$ENGINE_DIR" -maxdepth 2 -type d -name bin -exec dirname {} \; | head -1)"
  [ -n "$FOUND" ] && ENGINE_DIR="$FOUND"
  if [ ! -x "$ENGINE_DIR/bin/wine" ] && [ ! -x "$ENGINE_DIR/bin/wine64" ]; then
    fail "No bin/wine or bin/wine64 in $ENGINE_DIR"; exit 1
  fi
fi
ok "Engine: $("$ENGINE_DIR/bin/wine" --version 2>/dev/null || echo unknown)"

# --- Assemble the build-wrapper-linux.sh arguments ---------------------
# No --wineskin-runtime and no --moltenvk: both are macOS-only (the
# Wineskin wrapper runtime and MoltenVK). Linux Wine uses the system's
# real Vulkan; the D3D renderer defaults to DXVK (with a wined3d
# OpenGL fallback when no 32-bit Vulkan ICD is present).
BUILD_ARGS=()
BUILD_ARGS+=(--engine "$ENGINE_DIR")
BUILD_ARGS+=(--game "$GAME")
BUILD_ARGS+=(--arch "$ARCH")
BUILD_ARGS+=(--out "$OUT")
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
if [ "$WITH_DXVK" = 1 ]; then
  BUILD_ARGS+=(--dxvk "$DXVK")
fi

section "Assemble wrapper"
ok "Invoking: ${BUILD_ARGS[*]}"
exec "$BUILD_WRAPPER" "${BUILD_ARGS[@]}"
