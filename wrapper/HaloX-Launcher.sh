#!/bin/bash
# HaloX Launcher
# Starts Halo (halo.exe) via the bundled Wine engine.
#
# Copyright (c) 2026 BUM MasterMike. Licensed under the MIT License.
# See the LICENSE file for details.
set -u

APP_DIR="$(cd "$(dirname "$0")/.." && pwd)"
RES="$APP_DIR/Resources"
WINE_DIR="$RES/wine"
if [ -x "$WINE_DIR/bin/wine" ]; then
    WINE="$WINE_DIR/bin/wine"
elif [ -x "$WINE_DIR/bin/wine64" ]; then
    WINE="$WINE_DIR/bin/wine64"
else
    echo "HaloX: no wine binary found in $WINE_DIR/bin"
    exit 1
fi
GAME_DIR="$RES/game"

# Per-user Wine prefix (writable, persistent)
PREFIX="$HOME/Library/Application Support/HaloX/prefix"
mkdir -p "$(dirname "$PREFIX")"

# A quarantined .app is started by macOS from a read-only App Translocation
# copy; the game (and Chimera) need a writable folder, so refuse to run and
# tell the user how to clear the quarantine once.
case "$APP_DIR" in
    */AppTranslocation/*)
        osascript -e 'display dialog "HaloX is running from a read-only quarantine copy and cannot work.\n\nQuit HaloX, then run this once in Terminal:\n\n  chmod -R u+w ~/Downloads/HaloX.app\n  xattr -cr ~/Downloads/HaloX.app\n\nThen open HaloX again." buttons {"OK"} default button "OK" with title "HaloX"'
        exit 1
        ;;
esac

# Immediate launch feedback: the wrapper runs agent-style (no Dock icon) and
# Wine needs a moment before the game window appears. The banner fades on its
# own, so nothing stays on screen once the game is running.
osascript -e 'display notification "HaloX is starting..." with title "HaloX"' 2>/dev/null || true

export WINEPREFIX="$PREFIX"
# Default to no debug output, but honor an externally set WINEDEBUG so a
# diagnosis run can do e.g. WINEDEBUG=+d3d (the launcher must not kill it).
export WINEDEBUG="${WINEDEBUG:--all}"

# WineskinCX-style engines load their bundled libraries (including MoltenVK)
# from Contents/Frameworks and wine/lib via the fallback dylib search path.
export DYLD_FALLBACK_LIBRARY_PATH="$APP_DIR/Frameworks:$WINE_DIR/lib${DYLD_FALLBACK_LIBRARY_PATH:+:$DYLD_FALLBACK_LIBRARY_PATH}"

# MoltenVK (the Vulkan -> Metal layer used by the "vulkan" renderer) needs full
# image-view swizzling, otherwise wined3d's swapchain views fail on some GPUs.
# Metal placement heaps are disabled because older/patched Metal drivers (e.g.
# NVIDIA on OpenCore-patched macOS) do not support them.
export MVK_CONFIG_FULL_IMAGE_VIEW_SWIZZLE=1
export MVK_CONFIG_USE_MTLHEAP=0
# Quiet MoltenVK's very verbose info logging (keep errors only).
export MVK_CONFIG_LOG_LEVEL=1

# Host GStreamer installs (e.g. a stale Homebrew one) can crash winegstreamer's
# plugin scanner at engine startup. The game runs with -novideo and needs no
# host media plugins, so disable the hostile system plugin scan entirely.
export GST_PLUGIN_SYSTEM_PATH=""
export GST_PLUGIN_PATH=""

# Apple Silicon: our bundled engine is x86_64, so run Wine through Rosetta 2.
if [ "$(uname -m)" = "arm64" ]; then
    if ! /usr/bin/arch -x86_64 /usr/bin/true 2>/dev/null; then
        osascript -e 'display dialog "Rosetta 2 is required. Please run in Terminal:\n\nsoftwareupdate --install-rosetta --agree-to-license" buttons {"OK"} default button "OK" with title "HaloX"'
        exit 1
    fi
    WINE_CMD=(/usr/bin/arch -x86_64)
else
    WINE_CMD=()
fi

# Initialize prefix on first run
if [ ! -f "$PREFIX/system.reg" ]; then
    ${WINE_CMD[@]+"${WINE_CMD[@]}"} "$WINE" wineboot --init
    # Wait until wineboot finishes initialization
    while pgrep -f "wineserver" >/dev/null 2>&1 && [ -z "$(ls -A "$PREFIX/drive_c" 2>/dev/null)" ]; do
        sleep 1
    done
fi

# Direct3D renderer: always "gl" (wined3d OpenGL), exactly like the reference
# wrapper (which sets no renderer key, so wined3d uses its default GL
# backend). "vulkan" (MoltenVK) remains available as a per-run experiment:
#   HALOX_D3D_RENDERER=vulkan ./HaloX
# A Resources/renderer.conf from older builds is still honored if present.
RENDERER="${HALOX_D3D_RENDERER:-}"
if [ -z "$RENDERER" ] && [ -f "$RES/renderer.conf" ]; then
    RENDERER="$(tr -d '[:space:]' < "$RES/renderer.conf")"
fi
[ -n "$RENDERER" ] || RENDERER="gl"
${WINE_CMD[@]+"${WINE_CMD[@]}"} "$WINE" reg add "HKCU\\Software\\Wine\\Direct3D" \
    /v renderer /d "$RENDERER" /f >/dev/null 2>&1 || true

# If DSOAL ships next to halo.exe (dsound.dll + dsoal-aldrv.dll), use it as the
# native DirectSound so DirectSound3D/EAX positional audio works.
if [ -f "$GAME_DIR/dsound.dll" ]; then
    ${WINE_CMD[@]+"${WINE_CMD[@]}"} "$WINE" reg add "HKCU\\Software\\Wine\\DllOverrides" \
        /v dsound /d native /f >/dev/null 2>&1 || true
fi

# Link game files into the prefix (symlink keeps user Mods/saves alongside).
# Always (re)point the link at this bundle's game folder: a quarantined app
# that was once launched leaves a stale link to a read-only AppTranslocation
# path behind, which makes the game unable to write (Chimera breaks).
TARGET="$PREFIX/drive_c/Program Files/Halo"
mkdir -p "$(dirname "$TARGET")"
if [ -L "$TARGET" ]; then
    if [ "$(readlink "$TARGET")" != "$GAME_DIR" ]; then
        rm -f "$TARGET"
        ln -s "$GAME_DIR" "$TARGET"
    fi
elif [ ! -e "$TARGET" ]; then
    ln -s "$GAME_DIR" "$TARGET"
fi

# Optional build-time -vidmode (Contents/Resources/vidmode.conf, e.g.
# "1470,956,60"). Scaled "Looks like" displays (e.g. MacBook Air) refuse
# the mode change Halo requests on first run (640x480), which surfaces as a
# Direct3D error dialog. Forcing the game to start at the current desktop
# resolution makes wined3d skip the mode change entirely. A -vidmode passed
# explicitly on the command line wins.
VIDMODE=""
if [ -f "$RES/vidmode.conf" ]; then
    VIDMODE="$(tr -d '[:space:]' < "$RES/vidmode.conf")"
fi
for a in "$@"; do
    case "$a" in
        -vidmode) VIDMODE="" ;;
    esac
done
if [ -n "$VIDMODE" ]; then
    set -- "$@" -vidmode "$VIDMODE"
fi

# -novideo -use21 -console: exactly the flags used by the known-good
#   WineskinCX 23.7.1 wrapper (skip intro movies, D3D2.0 path, in-game console)
cd "$TARGET"
exec ${WINE_CMD[@]+"${WINE_CMD[@]}"} "$WINE" "halo.exe" -novideo -use21 -console "$@"
