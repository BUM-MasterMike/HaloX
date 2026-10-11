#!/bin/bash
#
# build-wrapper-linux.sh – assembles a runnable Linux HaloX wrapper.
#
# Copyright (c) 2026 BUM MasterMike. Licensed under the MIT License.
# See the LICENSE file for details.
#
# Linux counterpart of build-wrapper.sh (which builds the macOS
# .app). It produces a plain directory (default ./HaloX) containing
# the Wine engine, the game files and a launcher script, so the
# wrapper runs on Linux without installation.
#
# Usage:
#   ./scripts/build-wrapper-linux.sh \
#       --engine /path/to/wine-<ver>-amd64-wow64 \
#       --game   /path/to/game-dir   (halo.exe or haloce.exe) \
#       --arch   x86_64 \
#       --out    /path/to/HaloX
#
# --engine: a Linux Wine build (bin/wine, lib/, share/), e.g. the
#           Kron4ek/Wine-Builds "wine-<ver>-amd64-wow64" archive.
#           The wow64 variant runs the 32-bit halo.exe on a 64-bit
#           prefix without 32-bit host libraries.
#
# --game may also be a zip archive containing the full installed
# Halo folder. Optional:
#
#   --chimera github|/path/to/chimera-release.zip|dir
#       Overlays Chimera.
#
#   --dsoal bundle|github|/path/to/DSOAL.zip|dir
#       Overlays DSOAL (3D audio); bundle = checked-in tested build
#       (default, recommended).
#
#   --dsoal-hrtf
#       Force headphone HRTF (with --dsoal).
#
#   --vidmode <preset|W,H,R>
#       Bundle a -vidmode value so the game starts at the current
#       desktop resolution (wined3d skips the mode change).
#
# Not used on Linux (macOS-only, deliberately absent): the Wineskin
# wrapper runtime (--wineskin-runtime) and MoltenVK (--moltenvk).
# Linux Wine uses the system's real Vulkan. The D3D renderer
# defaults to DXVK (D3D8/9/10/11 -> Vulkan, ~1.5x faster than
# wined3d OpenGL and patched for Halo CE) when a 32-bit Vulkan ICD
# is present, and falls back to wined3d OpenGL ("gl") otherwise.
# Disable with --dxvk off.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Shared pretty-printing helpers (colors only on a TTY)
. "$SCRIPT_DIR/common-output.sh"

# App version. Single source of truth: the topmost "## [x.y.z]"
# section in CHANGELOG.md (the CI workflows read it from there too).
VERSION="$(sed -nE 's/^## \[([0-9]+\.[0-9]+\.[0-9]+)\].*/\1/p' "$SCRIPT_DIR/../CHANGELOG.md" | head -1)"
if [ -z "$VERSION" ]; then
  echo "Could not read version from CHANGELOG.md (expected a '## [x.y.z]' heading)." >&2
  exit 1
fi

ENGINE=""
GAME=""
GAME_ZIP_URL=""
ARCH="x86_64"
OUT=""
CHIMERA=""
DSOAL=""
DSOAL_HRTF=""
VIDMODE=""
DXVK=""

while [ $# -gt 0 ]; do
  case "$1" in
    --engine) ENGINE="$2"; shift 2;;
    --game)   GAME="$2";   shift 2;;
    --game-zip-url|--game_zip_url) GAME_ZIP_URL="$2"; shift 2;;
    --arch)   ARCH="$2";   shift 2;;
    --out)    OUT="$2";    shift 2;;
    --chimera) CHIMERA="$2"; shift 2;;
    --dsoal)   DSOAL="$2";   shift 2;;
    --dsoal-hrtf) DSOAL_HRTF=1; shift;;
    --vidmode) VIDMODE="$2"; shift 2;;
    --dxvk)   DXVK="$2";  shift 2;;
    *) echo "Unknown argument: $1"; exit 1;;
  esac
done

for req in ENGINE OUT; do
  if [ -z "${!req}" ]; then echo "Missing --$(echo $req | tr 'A-Z' 'a-z')"; exit 1; fi
done
if [ -z "$GAME" ] && [ -z "$GAME_ZIP_URL" ]; then echo "Missing --game or --game-zip-url"; exit 1; fi

# A Linux Wine engine: bin/ with wine (or wine64), plus lib/ and
# share/. The wow64 builds (e.g. Kron4ek "*-amd64-wow64") are the
# ones that run the 32-bit halo.exe on a 64-bit prefix.
if [ ! -d "$ENGINE/bin" ]; then
  echo "Engine dir must contain bin/ (got: $ENGINE)"
  exit 1
fi
if [ ! -x "$ENGINE/bin/wine" ] && [ ! -x "$ENGINE/bin/wine64" ]; then
  echo "Engine must contain bin/wine or bin/wine64 (got: $ENGINE)"
  exit 1
fi

# Resolve --vidmode: a preset alias (scripts/vidmode-presets.sh) or
# a literal W,H,R. The launcher passes the value to halo.exe; it
# must match the display's current "Looks like" resolution for
# wined3d to skip the mode change. Validate now so a bad value
# fails the build, not the first launch.
if [ -n "$VIDMODE" ]; then
  . "$SCRIPT_DIR/vidmode-presets.sh"
  if resolved="$(vidmode_preset_lookup "$VIDMODE")"; then
    VIDMODE="$resolved"
  fi
  if ! printf '%s' "$VIDMODE" | grep -qE '^[0-9]+,[0-9]+,[0-9]+$'; then
    echo "Invalid --vidmode value: '$VIDMODE' (expected a preset alias or W,H,R)"; exit 1
  fi
fi

# --- Show configuration ---------------------------------------------------
banner "HaloX - Linux wrapper builder" \
  "Assembles a runnable Linux HaloX wrapper from a Wine engine + game files"
section "Configuration"
kv "Engine"           "$ENGINE"
if [ -n "$GAME_ZIP_URL" ]; then kv "Game (URL)" "$GAME_ZIP_URL"; else kv "Game" "$GAME"; fi
kv "Arch"             "$ARCH"
kv "Output"           "$OUT"
kv "Chimera"          "${CHIMERA:-off}"
kv "DSOAL"            "${DSOAL:-off}"
if [ -n "$DSOAL_HRTF" ]; then kv "DSOAL HRTF" "on"; else kv "DSOAL HRTF" "off"; fi
kv "Vidmode"          "${VIDMODE:-off}"
kv "DXVK"             "${DXVK:-off}"

# --- Game source ----------------------------------------------------------
if [ -n "$GAME_ZIP_URL" ]; then
  if [ -f "$GAME_ZIP_URL" ]; then
    GAME="$GAME_ZIP_URL"
  else
    # mktemp -t would name the file <template>.<random>, not ending
    # in .zip (the extension check below requires *.zip). Use a temp
    # dir + fixed name.
    GAME_DOWNLOAD_DIR="$(mktemp -d -t game.XXXXXX)"
    GAME_DOWNLOAD_ZIP="$GAME_DOWNLOAD_DIR/Halo.zip"
    info "Downloading game zip: $GAME_ZIP_URL"
    curl -L --fail -o "$GAME_DOWNLOAD_ZIP" "$GAME_ZIP_URL"
    GAME="$GAME_DOWNLOAD_ZIP"
  fi
fi

if [ -f "$GAME" ]; then
  case "$GAME" in
    *.zip|*.ZIP)
      GAME_EXTRACT_DIR="$(mktemp -d)"
      unzip -q "$GAME" -d "$GAME_EXTRACT_DIR"
      GAME_SRC="$GAME_EXTRACT_DIR"
      ;;
    *) echo "--game must be a directory or .zip file (got: $GAME)"; exit 1;;
  esac
else
  GAME_SRC="$GAME"
fi

[ -d "$GAME_SRC" ] || { echo "Game dir not found: $GAME_SRC"; exit 1; }

# If the game data was packed with a wrapping folder on the top
# level (e.g. a zipped "Halo" directory instead of its contents),
# step into it so the game executable is found directly in the game
# dir. Only acts when there is exactly one entry and it is a
# directory.
while [ "$(find "$GAME_SRC" -mindepth 1 -maxdepth 1 | wc -l)" -eq 1 ]; do
    only="$(find "$GAME_SRC" -mindepth 1 -maxdepth 1)"
    [ -d "$only" ] || break
    GAME_SRC="$only"
done

# The game executable: halo.exe (Combat Evolved) or haloce.exe
# (Custom Edition) - both share the same installation layout, so
# either one is accepted. The detected name is recorded in the
# wrapper (game-exe) so the launcher knows what to start.
GAME_EXE=""
for exe in halo.exe haloce.exe; do
  if [ -f "$GAME_SRC/$exe" ]; then
    GAME_EXE="$exe"
    break
  fi
done
[ -n "$GAME_EXE" ] || { echo "Game dir must contain halo.exe or haloce.exe (got: $GAME_SRC)"; exit 1; }
# Archives may store read-only or exotic permission bits. Make the
# extracted game source writable, listable and executable so the
# Chimera overlay below cannot fail with EPERM when it sets
# permissions. (chflags is macOS-only; on Linux it does not exist.)
if command -v chflags >/dev/null 2>&1; then
  chflags -R nouchg,noschg "$GAME_SRC" 2>/dev/null || true
fi
chmod -R u+rwx "$GAME_SRC" 2>/dev/null || true
ok "Game source ready: $GAME_SRC ($GAME_EXE present)"

# --- Archive extraction ---------------------------------------------------
# Linux has no guaranteed bsdtar, so prefer it (handles .zip and
# .7z like the macOS build) and fall back to unzip / 7z.
extract_archive() {
  local archive="$1" dest="$2"
  case "$archive" in
    *.zip|*.ZIP)
      if command -v bsdtar >/dev/null 2>&1; then
        bsdtar -xf "$archive" -C "$dest"
      else
        unzip -q "$archive" -d "$dest"
      fi
      ;;
    *.7z|*.7Z)
      if command -v bsdtar >/dev/null 2>&1; then
        bsdtar -xf "$archive" -C "$dest"
      elif command -v 7z >/dev/null 2>&1; then
        7z x -y "-o$dest" "$archive" >/dev/null
      else
        echo "Need bsdtar or 7z to extract $archive" >&2
        exit 1
      fi
      ;;
    *)
      echo "Unsupported archive type: $archive" >&2
      exit 1
      ;;
  esac
}

# --- Overlay Chimera if provided -----------------------------------------
if [ -n "$CHIMERA" ]; then
  section "Chimera"
  if [ "$CHIMERA" = "github" ]; then
    CHIMERA_URL="$("$SCRIPT_DIR/github-latest-asset.sh" SnowyMouse/chimera '\.(zip|7z)$')"
    [ -n "$CHIMERA_URL" ] || { echo "Could not find Chimera zip release"; exit 1; }
    # Name the temp archive after the asset's real extension (.zip/.7z)
    # so extract_archive can dispatch on it (the macOS build feeds the
    # file straight to bsdtar, which sniffs the format).
    CHIMERA_EXT=".zip"
    case "$CHIMERA_URL" in
      *.7z|*.7Z) CHIMERA_EXT=".7z" ;;
    esac
    CHIMERA_DIR="$(mktemp -d -t chimera.XXXXXX)"
    CHIMERA_ZIP="$CHIMERA_DIR/chimera$CHIMERA_EXT"
    info "Chimera: downloading $CHIMERA_URL"
    curl -L -o "$CHIMERA_ZIP" "$CHIMERA_URL"
    CHIMERA_EXTRACT_DIR="$(mktemp -d)"
    extract_archive "$CHIMERA_ZIP" "$CHIMERA_EXTRACT_DIR"
    CHIMERA_SRC="$CHIMERA_EXTRACT_DIR"
    # Some release archives contain a single top-level folder; if so, use it directly.
    if [ "$(find "$CHIMERA_SRC" -mindepth 1 -maxdepth 1 | wc -l)" -eq 1 ]; then
      only="$(find "$CHIMERA_SRC" -mindepth 1 -maxdepth 1)"
      if [ -d "$only" ]; then CHIMERA_SRC="$only"; fi
    fi
  elif [ -f "$CHIMERA" ]; then
    case "$CHIMERA" in
      *.zip|*.ZIP|*.7z|*.7Z)
        CHIMERA_EXTRACT_DIR="$(mktemp -d)"
        extract_archive "$CHIMERA" "$CHIMERA_EXTRACT_DIR"
        CHIMERA_SRC="$CHIMERA_EXTRACT_DIR"
        ;;
      *) echo "--chimera must be a directory, .zip, or .7z file (got: $CHIMERA)"; exit 1;;
    esac
  else
    CHIMERA_SRC="$CHIMERA"
  fi
  [ -d "$CHIMERA_SRC" ] || { echo "Chimera dir not found: $CHIMERA_SRC"; exit 1; }
  # Strip extended attributes (quarantine/provenance, ...) from the
  # downloaded release: cp would otherwise propagate them into the
  # wrapper. (xattr is macOS-only; on Linux it does not exist.)
  if command -v xattr >/dev/null 2>&1; then
    xattr -cr "$CHIMERA_SRC" 2>/dev/null || echo "warn: could not clear all xattrs in $CHIMERA_SRC" >&2
  fi
  # Clear immutable flags and make the whole tree writable, listable
  # and executable. Archives (7z) can store non-listable or
  # read-only entries; cp then fails with "Permission denied" when
  # reading the source (readdir) or copying extended attributes,
  # even though the files are user-owned.
  if command -v chflags >/dev/null 2>&1; then
    chflags -R nouchg,noschg "$CHIMERA_SRC" 2>/dev/null || true
  fi
  chmod -R u+rwx "$CHIMERA_SRC"
  if ! cp -Rf "$CHIMERA_SRC/." "$GAME_SRC/"; then
    echo "ERROR: Chimera overlay failed. Diagnostics:" >&2
    ls -laO "$CHIMERA_SRC" 2>/dev/null | head -30 || ls -la "$CHIMERA_SRC" | head -30
    ls -la "$CHIMERA_SRC/fonts" 2>/dev/null | head
    stat -c "src=%n mode=%A owner=%U" "$CHIMERA_SRC/fonts" 2>/dev/null
    stat -c "dst=%n mode=%A owner=%U" "$GAME_SRC" 2>/dev/null
    stat -c "dst_fonts=%n mode=%A owner=%U" "$GAME_SRC/fonts" 2>/dev/null
    df -h "$GAME_SRC"
    exit 1
  fi
  ok "Applied Chimera from $CHIMERA_SRC"
fi

# --- Overlay DSOAL (DirectSound3D via OpenAL Soft) if requested ----------
# Halo is a 32-bit executable, so only the Win32 binaries matter.
# They run inside Wine on Linux exactly like on macOS.
if [ -n "$DSOAL" ]; then
  section "DSOAL"
  DSOAL_EXTRACT_DIR=""
  if [ "$DSOAL" = "bundle" ]; then
    # Checked-in, tested build (vendor/dsoal-d9fed51a). This is the
    # only DSOAL verified to run in HaloX.
    DSOAL_DIR="$(cd "$(dirname "$0")" && pwd)/../vendor/dsoal-d9fed51a"
  elif [ "$DSOAL" = "github" ]; then
    DSOAL_ARCHIVE="$(mktemp -t dsoal.XXXXXX.zip)"
    info "Downloading DSOAL (github latest-master) ..."
    curl -L --fail -o "$DSOAL_ARCHIVE" \
      "https://github.com/kcat/dsoal/releases/download/latest-master/DSOAL.zip"
    DSOAL_EXTRACT_DIR="$(mktemp -d)"
    extract_archive "$DSOAL_ARCHIVE" "$DSOAL_EXTRACT_DIR"
  elif [ -f "$DSOAL" ]; then
    DSOAL_EXTRACT_DIR="$(mktemp -d)"
    extract_archive "$DSOAL" "$DSOAL_EXTRACT_DIR"
  else
    DSOAL_DIR="$DSOAL"
  fi

  if [ -n "$DSOAL_EXTRACT_DIR" ]; then
    # The latest-master archive wraps the real build in a nested zip.
    nested="$(find "$DSOAL_EXTRACT_DIR" -maxdepth 1 -iname '*.zip' | head -1)"
    if [ -n "$nested" ]; then
      extract_archive "$nested" "$DSOAL_EXTRACT_DIR"
    fi
    DSOAL_DIR="$(find "$DSOAL_EXTRACT_DIR" -type d -name Win32 | grep -v HRTF | head -1)"
  fi

  [ -n "$DSOAL_DIR" ] && [ -d "$DSOAL_DIR" ] || { echo "Could not find DSOAL Win32 directory (got: $DSOAL)"; exit 1; }
  for f in dsound.dll dsoal-aldrv.dll alsoft.ini; do
    [ -f "$DSOAL_DIR/$f" ] && cp "$DSOAL_DIR/$f" "$GAME_SRC/"
  done

  # Optional: force binaural HRTF output for headphones.
  if [ -n "$DSOAL_HRTF" ]; then
    hrtf_ini=""
    if [ -n "$DSOAL_EXTRACT_DIR" ]; then
      hrtf_dir="$(find "$DSOAL_EXTRACT_DIR" -type d -name Win32 | grep HRTF | head -1)"
      [ -n "$hrtf_dir" ] && hrtf_ini="$hrtf_dir/alsoft.ini"
    fi
    if [ -n "$hrtf_ini" ] && [ -f "$hrtf_ini" ]; then
      cp "$hrtf_ini" "$GAME_SRC/alsoft.ini"
    else
      printf '[general]\nchannels=stereo\nstereo-mode=headphones\nstereo-encoding=hrtf\n' > "$GAME_SRC/alsoft.ini"
    fi
    echo ">> DSOAL HRTF (headphones) enabled"
  fi
  ok "Applied DSOAL from $DSOAL_DIR"
fi

# --- Bundle DXVK (Direct3D 8/9/10/11 -> Vulkan) if requested -------
# DXVK is the fast path on native Linux: ~1.5x faster than wined3d
# OpenGL and specifically patched for Halo CE. The launcher enables
# it automatically when a 32-bit Vulkan ICD is present (halo.exe is
# 32-bit) and falls back to wined3d OpenGL otherwise, so DXVK never
# breaks a system without Vulkan. Disable with --dxvk off.
DXVK_SRC=""
if [ -n "$DXVK" ] && [ "$DXVK" != "off" ]; then
  section "DXVK"
  if [ "$DXVK" = "github" ]; then
    DXVK_URL="$("$SCRIPT_DIR/github-latest-asset.sh" doitsujin/dxvk '^dxvk-%s\.tar\.gz$')"
    [ -n "$DXVK_URL" ] || { echo "Could not find the DXVK tar.gz release"; exit 1; }
    DXVK_TMP_DIR="$(mktemp -d -t dxvk.XXXXXX)"
    DXVK_ARCHIVE="$DXVK_TMP_DIR/dxvk.tar.gz"
    info "DXVK: downloading $DXVK_URL"
    curl -L --fail -o "$DXVK_ARCHIVE" "$DXVK_URL"
    DXVK_EXTRACT_DIR="$(mktemp -d)"
    tar -xzf "$DXVK_ARCHIVE" -C "$DXVK_EXTRACT_DIR"
    DXVK_SRC="$(find "$DXVK_EXTRACT_DIR" -maxdepth 1 -type d -name 'dxvk-*' | head -1)"
  elif [ -f "$DXVK" ]; then
    DXVK_EXTRACT_DIR="$(mktemp -d)"
    case "$DXVK" in
      *.tar.gz|*.tgz) tar -xzf "$DXVK" -C "$DXVK_EXTRACT_DIR" ;;
      *.zip|*.ZIP)    unzip -q "$DXVK" -d "$DXVK_EXTRACT_DIR" ;;
      *) echo "--dxvk file must be a .tar.gz or .zip (got: $DXVK)"; exit 1;;
    esac
    DXVK_SRC="$(find "$DXVK_EXTRACT_DIR" -maxdepth 1 -type d -name 'dxvk-*' | head -1)"
  else
    DXVK_SRC="$DXVK"
  fi
  [ -d "$DXVK_SRC/x32" ] && [ -d "$DXVK_SRC/x64" ] || {
    echo "DXVK source must contain x32/ and x64/ (got: $DXVK_SRC)"; exit 1; }
  ok "DXVK ready: $DXVK_SRC"
fi

# --- Assemble wrapper -----------------------------------------------------
section "Assemble wrapper"
rm -rf "$OUT"
mkdir -p "$OUT/wine"

# 1) Launcher. Copied from wrapper/ (like the macOS build
#    copies wrapper/HaloX-Launcher.sh). It sets up the Wine
#    prefix, links the game in and starts the detected
#    executable.
cp "$SCRIPT_DIR/../wrapper/HaloX-Launcher-Linux.sh" "$OUT/HaloX"
chmod +x "$OUT/HaloX"

# 2) Wine engine (bin/ lib/ share/; lib64 and share are optional).
cp -R "$ENGINE/bin" "$OUT/wine/"
for d in lib lib64 share; do
  if [ -d "$ENGINE/$d" ]; then
    cp -R "$ENGINE/$d" "$OUT/wine/"
  fi
done

# 2b) DXVK (optional). The launcher copies these into the Wine prefix
#     (syswow64/system32) and selects them natively when DXVK is the
#     active renderer; on gl/vulkan runs they are simply ignored.
if [ -n "$DXVK_SRC" ]; then
  mkdir -p "$OUT/dxvk"
  cp -R "$DXVK_SRC/x32" "$OUT/dxvk/"
  cp -R "$DXVK_SRC/x64" "$OUT/dxvk/"
  ok "Bundled DXVK (dxvk/x32, dxvk/x64)"
fi

# 3) Game executable, vidmode and version markers.
printf '%s\n' "$GAME_EXE" > "$OUT/game-exe"
if [ -n "$VIDMODE" ]; then
  printf '%s\n' "$VIDMODE" > "$OUT/vidmode.conf"
  ok "Bundled vidmode: $VIDMODE (vidmode.conf)"
fi
printf '%s\n' "$VERSION" > "$OUT/version"

# 4) Game files
cp -R "$GAME_SRC" "$OUT/game"

# 5) Make sure everything is user-writable so the wrapper can be
#    modified after download (and the quarantine flag cleared).
chmod -R u+rwX "$OUT"

section "Done"
ok "Built: $OUT"
