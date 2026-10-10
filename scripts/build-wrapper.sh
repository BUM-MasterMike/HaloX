#!/bin/bash
#
# build-wrapper.sh – assembles a runnable HaloX.app wine wrapper.
#
# Copyright (c) 2026 BUM MasterMike. Licensed under the MIT License.
# See the LICENSE file for details.
#
# Usage:
#   ./scripts/build-wrapper.sh \
#       --engine /path/to/wine/Contents/Resources/wine \
#       --game   /path/to/game-dir   (must contain halo.exe) \
#       --arch   x86_64|arm64 \
#       --out    /path/to/HaloX.app
#
# --game may also be a zip archive containing the full installed Halo folder.
# Optional:
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
#   The D3D renderer is always wined3d OpenGL ("gl"), exactly like the
#   reference wrapper (which sets no renderer key). Vulkan is available only
#   as a per-run override: HALOX_D3D_RENDERER=vulkan.
#
#   --moltenvk 1.2.5|/path/to/libMoltenVK.dylib|none
#       MoltenVK (Vulkan -> Metal) bundled with the engine for the vulkan
#       override (default 1.2.5; newer ones crash on old GPUs).
#
#   --wineskin-runtime <Contents-dir-of-wrapper>
#       Wineskin wrapper runtime (a dir containing Frameworks/). WineskinCX
#       engines (WS11WineCX64Bit...) load shared libs (MoltenVK, SDL2, ICU,
#       ...) from Contents/Frameworks at runtime; without them wine fails
#       with "Library not loaded". GStreamer.framework is excluded (crash
#       source).
#
#   --vidmode <preset|W,H,R>
#       Bundle a -vidmode value: the launcher passes it to halo.exe so the
#       game starts at the current desktop resolution and wined3d skips the
#       mode change. Needed on scaled "Looks like" displays (e.g. MacBook
#       Air) that refuse Halo's first-run 640x480 mode change. Default: off.
#       <preset> is an alias from scripts/vidmode-presets.sh (e.g.
#       macbook-air-13); W,H,R is a literal value (e.g. 1280,800,60).
#
set -euo pipefail

# Repo root / script dir for locating assets and the shared helpers
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Shared pretty-printing helpers (colors only on a TTY)
. "$SCRIPT_DIR/common-output.sh"

# App version for the Info.plist written below. Single source of truth:
# the topmost "## [x.y.z]" section in CHANGELOG.md (the CI workflows read
# it from there too), so there is only one place to bump the version.
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
MOLTENVK="1.2.5"
WINESKIN_RUNTIME=""
VIDMODE=""

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
    --moltenvk) MOLTENVK="$2"; shift 2;;
    --wineskin-runtime) WINESKIN_RUNTIME="$2"; shift 2;;
    --vidmode) VIDMODE="$2"; shift 2;;
    *) echo "Unknown argument: $1"; exit 1;;
  esac
done

for req in ENGINE OUT; do
  if [ -z "${!req}" ]; then echo "Missing --$(echo $req | tr 'A-Z' 'a-z')"; exit 1; fi
done
if [ -z "$GAME" ] && [ -z "$GAME_ZIP_URL" ]; then echo "Missing --game or --game-zip-url"; exit 1; fi

[ -d "$ENGINE/bin" ] || { echo "Engine dir must contain bin/ (got: $ENGINE)"; exit 1; }

# Resolve --vidmode: a preset alias (scripts/vidmode-presets.sh) or a literal
# W,H,R. The launcher passes the value to halo.exe; it must match the
# display's current "Looks like" resolution for wined3d to skip the mode
# change. Validate now so a bad value fails the build, not the first launch.
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
banner "HaloX - wrapper builder" \
  "Assembles a runnable HaloX.app from a Wine engine + game files"
section "Configuration"
kv "Engine"           "$ENGINE"
if [ -n "$GAME_ZIP_URL" ]; then kv "Game (URL)" "$GAME_ZIP_URL"; else kv "Game" "$GAME"; fi
kv "Arch"             "$ARCH"
kv "Output"           "$OUT"
kv "Chimera"          "${CHIMERA:-off}"
kv "DSOAL"            "${DSOAL:-off}"
if [ -n "$DSOAL_HRTF" ]; then kv "DSOAL HRTF" "on"; else kv "DSOAL HRTF" "off"; fi
kv "MoltenVK"         "$MOLTENVK"
kv "Wineskin runtime" "${WINESKIN_RUNTIME:-off}"
kv "Vidmode"          "${VIDMODE:-off}"

if [ -n "$GAME_ZIP_URL" ]; then
  if [ -f "$GAME_ZIP_URL" ]; then
    GAME="$GAME_ZIP_URL"
  else
    # mktemp -t would name the file <template>.<random>, not ending in .zip
    # (the extension check below requires *.zip). Use a temp dir + fixed name.
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

# If the game data was packed with a wrapping folder on the top level (e.g. a
# zipped "Halo" directory instead of its contents), step into it so the game
# executable is found directly in the game dir. Only acts when there is exactly
# one entry and it is a directory.
while [ "$(find "$GAME_SRC" -mindepth 1 -maxdepth 1 | wc -l)" -eq 1 ]; do
    only="$(find "$GAME_SRC" -mindepth 1 -maxdepth 1)"
    [ -d "$only" ] || break
    GAME_SRC="$only"
done

# The game executable: halo.exe (Combat Evolved) or haloce.exe
# (Custom Edition) - both share the same installation layout, so
# either one is accepted. The detected name is recorded in the
# bundle (Resources/game-exe) so the launcher knows what to start.
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
# permissions or extended attributes.
chflags -R nouchg,noschg "$GAME_SRC" 2>/dev/null || true
chmod -R u+rwx "$GAME_SRC" 2>/dev/null || true
ok "Game source ready: $GAME_SRC ($GAME_EXE present)"

# Overlay Chimera if provided
if [ -n "$CHIMERA" ]; then
  section "Chimera"
  if [ "$CHIMERA" = "github" ]; then
    CHIMERA_ZIP="$(mktemp -t chimera.XXXXXX.archive)"
    CHIMERA_URL="$(python3 - <<'PY'
import json, urllib.request, os
req_headers = {"User-Agent": "HaloX", "Accept": "application/vnd.github+json"}
token = os.environ.get("GITHUB_TOKEN")
if token:
    req_headers["Authorization"] = f"Bearer {token}"
req = urllib.request.Request("https://api.github.com/repos/SnowyMouse/chimera/releases/latest",
                             headers=req_headers)
with urllib.request.urlopen(req) as r:
    d = json.load(r)
for a in d.get("assets", []):
    name = a["name"].lower()
    if name.endswith(".zip") or name.endswith(".7z"):
        print(a["browser_download_url"])
        break
PY
)"
    [ -n "$CHIMERA_URL" ] || { echo "Could not find Chimera zip release"; exit 1; }
    info "Chimera: downloading $CHIMERA_URL"
    curl -L -o "$CHIMERA_ZIP" "$CHIMERA_URL"
    CHIMERA_EXTRACT_DIR="$(mktemp -d)"
    bsdtar -xf "$CHIMERA_ZIP" -C "$CHIMERA_EXTRACT_DIR"
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
        bsdtar -xf "$CHIMERA" -C "$CHIMERA_EXTRACT_DIR"
        CHIMERA_SRC="$CHIMERA_EXTRACT_DIR"
        ;;
      *) echo "--chimera must be a directory, .zip, or .7z file (got: $CHIMERA)"; exit 1;;
    esac
  else
    CHIMERA_SRC="$CHIMERA"
  fi
  [ -d "$CHIMERA_SRC" ] || { echo "Chimera dir not found: $CHIMERA_SRC"; exit 1; }
  # Strip extended attributes (quarantine/provenance, ...) from the
  # downloaded release: cp would otherwise propagate them into the app
  # bundle and can fail with "Permission denied" while doing so (seen on
  # runs with a nearly full disk, where APFS xattr writes fail with EPERM).
  xattr -cr "$CHIMERA_SRC" 2>/dev/null || echo "warn: could not clear all xattrs in $CHIMERA_SRC" >&2
  # Clear immutable flags and make the whole tree writable, listable and
  # executable. Archives (7z) can store non-listable or read-only entries;
  # cp then fails with "Permission denied" when reading the source (readdir)
  # or copying extended attributes, even though the files are user-owned.
  chflags -R nouchg,noschg "$CHIMERA_SRC" 2>/dev/null || true
  chmod -R u+rwx "$CHIMERA_SRC"
  if ! cp -Rf "$CHIMERA_SRC/." "$GAME_SRC/"; then
    echo "ERROR: Chimera overlay failed. Diagnostics:" >&2
    ls -laO "$CHIMERA_SRC" | head -30
    ls -laO "$CHIMERA_SRC/fonts" 2>/dev/null | head
    stat -f "src=%N mode=%Sp owner=%Su flags=%Sf" "$CHIMERA_SRC/fonts" 2>/dev/null
    stat -f "dst=%N mode=%Sp owner=%Su flags=%Sf" "$GAME_SRC" 2>/dev/null
    stat -f "dst_fonts=%N mode=%Sp owner=%Su flags=%Sf" "$GAME_SRC/fonts" 2>/dev/null
    xattr -l "$CHIMERA_SRC/fonts" 2>/dev/null | head
    df -h "$GAME_SRC"
    exit 1
  fi
  ok "Applied Chimera from $CHIMERA_SRC"
fi

# Overlay DSOAL (DirectSound3D via OpenAL Soft) if requested. Halo is a 32-bit
# executable, so only the Win32 binaries matter.
if [ -n "$DSOAL" ]; then
  section "DSOAL"
  DSOAL_EXTRACT_DIR=""
  if [ "$DSOAL" = "bundle" ]; then
    # Checked-in, tested build (vendor/dsoal-d9fed51a). This is the only DSOAL
    # verified to run in HaloX: newer builds (github latest-master) abort on
    # Wine's missing msvcp140.dll._Throw_Cpp_error (see PROVENANCE.md there).
    DSOAL_DIR="$(cd "$(dirname "$0")" && pwd)/../vendor/dsoal-d9fed51a"
  elif [ "$DSOAL" = "github" ]; then
    DSOAL_ARCHIVE="$(mktemp -t dsoal.XXXXXX.zip)"
    info "Downloading DSOAL (github latest-master) ..."
    curl -L --fail -o "$DSOAL_ARCHIVE" \
      "https://github.com/kcat/dsoal/releases/download/latest-master/DSOAL.zip"
    DSOAL_EXTRACT_DIR="$(mktemp -d)"
    bsdtar -xf "$DSOAL_ARCHIVE" -C "$DSOAL_EXTRACT_DIR"
  elif [ -f "$DSOAL" ]; then
    DSOAL_EXTRACT_DIR="$(mktemp -d)"
    bsdtar -xf "$DSOAL" -C "$DSOAL_EXTRACT_DIR"
  else
    DSOAL_DIR="$DSOAL"
  fi

  if [ -n "$DSOAL_EXTRACT_DIR" ]; then
    # The latest-master archive wraps the real build in a nested zip.
    nested="$(find "$DSOAL_EXTRACT_DIR" -maxdepth 1 -iname '*.zip' | head -1)"
    if [ -n "$nested" ]; then
      bsdtar -xf "$nested" -C "$DSOAL_EXTRACT_DIR"
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

section "Assemble wrapper"
rm -rf "$OUT"
mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Resources/wine"

# 1) Launcher + Info.plist
cp "$SCRIPT_DIR/../wrapper/HaloX-Launcher.sh" "$OUT/Contents/MacOS/HaloX"
chmod +x "$OUT/Contents/MacOS/HaloX"

cat > "$OUT/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>             <string>HaloX</string>
    <key>CFBundleDisplayName</key>       <string>HaloX</string>
    <key>CFBundleIdentifier</key>        <string>com.halox.app</string>
    <key>CFBundleExecutable</key>        <string>HaloX</string>
    <key>CFBundlePackageType</key>       <string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key>           <string>${VERSION}</string>
    <key>LSMinimumSystemVersion</key>    <string>11.0</string>
    <key>NSHighResolutionCapable</key>   <true/>
    <!-- LSApplicationCategoryType: macOS uses this to recognize the app as a
         game and enables Game Mode automatically in fullscreen (CPU/GPU
         priority, reduced background load). -->
    <key>LSApplicationCategoryType</key> <string>public.app-category.games</string>
    <!-- LSSupportsGameMode: macOS 26+ moves Game Mode to this explicit
         opt-in; LSApplicationCategoryType covers Sonoma/Sequoia (14/15). -->
    <key>LSSupportsGameMode</key>        <true/>
    <!-- NSAppSleepDisabled: prevents App Nap from periodically throttling the
         process (timer coalescing / background scheduling). -->
    <key>NSAppSleepDisabled</key>        <true/>
    <key>CFBundleIconFile</key>          <string>AppIcon.icns</string>
    <!-- LSUIElement: no own Dock icon -> only the in-game (Windows) icon
         shows while halo.exe runs, so the Dock stops bouncing. -->
    <key>LSUIElement</key>               <true/>
</dict>
</plist>
EOF

# 2) Wine engine (bin/ lib/ share/)
cp -R "$ENGINE/bin" "$ENGINE/lib" "$ENGINE/share" "$OUT/Contents/Resources/wine/"

# 2a) Wineskin wrapper runtime (Contents/Frameworks). WineskinCX engines load
#     their shared libraries (MoltenVK, SDL2, ICU, ...) from Contents/Frameworks
#     at runtime via the launcher's DYLD_FALLBACK_LIBRARY_PATH. GStreamer.framework
#     is deliberately not bundled: its plugin scan crashes the engine, and the
#     launcher disables host GStreamer anyway.
if [ -n "$WINESKIN_RUNTIME" ]; then
  if [ ! -d "$WINESKIN_RUNTIME/Frameworks" ]; then
    echo "--wineskin-runtime must point to a wrapper Contents dir containing Frameworks/ (got: $WINESKIN_RUNTIME)"
    exit 1
  fi
  mkdir -p "$OUT/Contents/Frameworks"
  cp -R "$WINESKIN_RUNTIME/Frameworks/." "$OUT/Contents/Frameworks/"
  rm -rf "$OUT/Contents/Frameworks/GStreamer.framework"
  echo ">> Bundled Wineskin runtime frameworks (excluding GStreamer.framework)"
fi

# 2b) Replace the engine's bundled MoltenVK. Current engines ship 1.4.x, whose
#     Metal placement heaps crash on older/patched Metal drivers (e.g. NVIDIA
#     GPUs on OpenCore-patched macOS). 1.2.5 works on both old and new GPUs.
#     With a WineskinCX engine the dylib lives in Contents/Frameworks; newer
#     layouts keep it in wine/lib.
MVK_DEST="$OUT/Contents/Frameworks/libMoltenVK.dylib"
if [ ! -f "$MVK_DEST" ]; then
  MVK_DEST="$OUT/Contents/Resources/wine/lib/libMoltenVK.dylib"
fi
if [ "$MOLTENVK" != "none" ] && [ -f "$MVK_DEST" ]; then
  MVK_SRC="$MOLTENVK"
  if [ ! -f "$MVK_SRC" ]; then
    MVK_TAR="$(mktemp -t moltenvk.XXXXXX.tar)"
    info "Downloading MoltenVK $MOLTENVK..."
    curl -L --fail -o "$MVK_TAR" \
      "https://github.com/KhronosGroup/MoltenVK/releases/download/v$MOLTENVK/MoltenVK-macos.tar"
    MVK_DIR="$(mktemp -d)"
    tar -xf "$MVK_TAR" -C "$MVK_DIR" "MoltenVK/MoltenVK/dylib/macOS/libMoltenVK.dylib"
    MVK_SRC="$MVK_DIR/MoltenVK/MoltenVK/dylib/macOS/libMoltenVK.dylib"
  fi
  [ -f "$MVK_SRC" ] || { echo "MoltenVK dylib not found: $MVK_SRC"; exit 1; }
  cp "$MVK_SRC" "$MVK_DEST"
  ok "Bundled MoltenVK $MOLTENVK"
fi

# 2c) App icon
if [ -f "$SCRIPT_DIR/../assets/AppIcon.icns" ]; then
  cp "$SCRIPT_DIR/../assets/AppIcon.icns" "$OUT/Contents/Resources/AppIcon.icns"
  ok "Bundled app icon (AppIcon.icns)"
fi

# 2d) Optional -vidmode preset (Resources/vidmode.conf). The launcher passes
#     it to halo.exe so the game starts at the current desktop resolution
#     (wined3d skips the mode change). Needed for scaled "Looks like"
#     displays (e.g. MacBook Air) that refuse Halo's first-run 640x480
#     mode change.
if [ -n "$VIDMODE" ]; then
  printf '%s\n' "$VIDMODE" > "$OUT/Contents/Resources/vidmode.conf"
  ok "Bundled vidmode: $VIDMODE (Resources/vidmode.conf)"
fi

# 2d-2) Record the game executable (halo.exe for Combat Evolved,
#       haloce.exe for Custom Edition) so the launcher starts the
#       right one.
printf '%s\n' "$GAME_EXE" > "$OUT/Contents/Resources/game-exe"

# 3) Game files
cp -R "$GAME_SRC" "$OUT/Contents/Resources/game"

# 3a) Make sure everything is user-writable so the app can be modified and
#     its quarantine flag can be cleared without sudo after download.
chmod -R u+rwX "$OUT"

# 3b) Add LC_RPATH entries pointing at Contents/Frameworks to the engine
#     binaries. Intel's dyld falls back to DYLD_FALLBACK_LIBRARY_PATH for
#     @rpath, but Rosetta's dyld does not (x86_64 wine on Apple Silicon fails
#     with "no LC_RPATH's found"); a real rpath fixes both. --no-sign: the
#     codesign step right below signs the whole bundle once; --quiet: keep
#     builds concise (per-file lines are for manual debugging).
"$SCRIPT_DIR/patch-engine-rpath.sh" "$OUT" --no-sign --quiet

# 4) Ad-hoc signature so Gatekeeper on Sonoma is less picky
codesign --force --deep --sign - "$OUT" 2>/dev/null || echo "!! codesign failed (ok for local test)"

section "Done"
ok "Built: $OUT"
