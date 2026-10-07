#!/bin/bash
#
# build-wrapper.sh – assembles a runnable HaloX.app wine wrapper.
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
#   --chimera github|/path/to/chimera-release.zip|dir  overlays Chimera
#   --dsoal   bundle|github|/path/to/DSOAL.zip|dir     overlays DSOAL (3D audio);
#                                                      bundle = checked-in tested
#                                                      build (default, recommended)
#   --dsoal-hrtf                                       force headphone HRTF (with --dsoal)
#   The D3D renderer is always wined3d OpenGL ("gl"), exactly like the
#   reference wrapper (which sets no renderer key). Vulkan is available only
#   as a per-run override: HALOX_D3D_RENDERER=vulkan.
#   --moltenvk 1.2.5|/path/to/libMoltenVK.dylib|none   MoltenVK (Vulkan->Metal)
#                                                      bundled with the engine for
#                                                      the vulkan override
#                                                      (default 1.2.5; newer ones
#                                                      crash on old GPUs)
#   --wineskin-runtime <Contents-dir-of-wrapper>       Wineskin wrapper runtime
#                                                      (a dir containing
#                                                      Frameworks/). WineskinCX
#                                                      engines (WS11WineCX64Bit...)
#                                                      load shared libs (MoltenVK,
#                                                      SDL2, ICU, ...) from
#                                                      Contents/Frameworks at
#                                                      runtime; without them wine
#                                                      fails with
#                                                      "Library not loaded".
#                                                      GStreamer.framework is
#                                                      excluded (crash source).
#
set -euo pipefail

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
    *) echo "Unknown argument: $1"; exit 1;;
  esac
done

for req in ENGINE OUT; do
  if [ -z "${!req}" ]; then echo "Missing --$(echo $req | tr 'A-Z' 'a-z')"; exit 1; fi
done
if [ -z "$GAME" ] && [ -z "$GAME_ZIP_URL" ]; then echo "Missing --game or --game-zip-url"; exit 1; fi

[ -d "$ENGINE/bin" ] || { echo "Engine dir must contain bin/ (got: $ENGINE)"; exit 1; }

if [ -n "$GAME_ZIP_URL" ]; then
  if [ -f "$GAME_ZIP_URL" ]; then
    GAME="$GAME_ZIP_URL"
  else
    GAME_DOWNLOAD_ZIP="$(mktemp -t game.XXXXXX.zip)"
    echo "Downloading Game zip..."
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
[ -f "$GAME_SRC/halo.exe" ] || { echo "Game dir must contain halo.exe (got: $GAME_SRC)"; exit 1; }

# Overlay Chimera if provided
if [ -n "$CHIMERA" ]; then
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
  cp -R "$CHIMERA_SRC/." "$GAME_SRC/"
fi

# Overlay DSOAL (DirectSound3D via OpenAL Soft) if requested. Halo is a 32-bit
# executable, so only the Win32 binaries matter.
if [ -n "$DSOAL" ]; then
  DSOAL_EXTRACT_DIR=""
  if [ "$DSOAL" = "bundle" ]; then
    # Checked-in, tested build (vendor/dsoal-d9fed51a). This is the only DSOAL
    # verified to run in HaloX: newer builds (github latest-master) abort on
    # Wine's missing msvcp140.dll._Throw_Cpp_error (see PROVENANCE.md there).
    DSOAL_DIR="$(cd "$(dirname "$0")" && pwd)/../vendor/dsoal-d9fed51a"
  elif [ "$DSOAL" = "github" ]; then
    DSOAL_ARCHIVE="$(mktemp -t dsoal.XXXXXX.zip)"
    echo "Downloading DSOAL (github latest-master) ..."
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
  echo ">> Applied DSOAL from $DSOAL_DIR"
fi

echo ">> Assembling $OUT"
rm -rf "$OUT"
mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Resources/wine"

# 1) Launcher + Info.plist
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
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
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key>           <string>1</string>
    <key>LSMinimumSystemVersion</key>    <string>11.0</string>
    <key>NSHighResolutionCapable</key>   <true/>
    <key>CFBundleIconFile</key>          <string>AppIcon.icns</string>
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
    echo ">> Downloading MoltenVK $MOLTENVK..."
    curl -L --fail -o "$MVK_TAR" \
      "https://github.com/KhronosGroup/MoltenVK/releases/download/v$MOLTENVK/MoltenVK-macos.tar"
    MVK_DIR="$(mktemp -d)"
    tar -xf "$MVK_TAR" -C "$MVK_DIR" "MoltenVK/MoltenVK/dylib/macOS/libMoltenVK.dylib"
    MVK_SRC="$MVK_DIR/MoltenVK/MoltenVK/dylib/macOS/libMoltenVK.dylib"
  fi
  [ -f "$MVK_SRC" ] || { echo "MoltenVK dylib not found: $MVK_SRC"; exit 1; }
  cp "$MVK_SRC" "$MVK_DEST"
  echo ">> Bundled MoltenVK $MOLTENVK"
fi

# 2c) App icon
if [ -f "$SCRIPT_DIR/../assets/AppIcon.icns" ]; then
  cp "$SCRIPT_DIR/../assets/AppIcon.icns" "$OUT/Contents/Resources/AppIcon.icns"
fi

# 3) Game files
cp -R "$GAME_SRC" "$OUT/Contents/Resources/game"

# 3a) Make sure everything is user-writable so the app can be modified and
#     its quarantine flag can be cleared without sudo after download.
chmod -R u+rwX "$OUT"

# 4) Ad-hoc signature so Gatekeeper on Sonoma is less picky
codesign --force --deep --sign - "$OUT" 2>/dev/null || echo "!! codesign failed (ok for local test)"

echo ">> Done: $OUT"
