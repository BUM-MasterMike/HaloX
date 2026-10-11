#!/bin/bash
# HaloX Launcher (Linux)
# Starts Halo (halo.exe / haloce.exe) via the bundled Wine engine.
#
# Copyright (c) 2026 BUM MasterMike. Licensed under the MIT License.
# See the LICENSE file for details.
set -u

APP_DIR="$(cd "$(dirname "$0")" && pwd)"
RES="$APP_DIR"
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

# Game executable: halo.exe (Combat Evolved) or haloce.exe
# (Custom Edition). The build records the detected name in
# game-exe; default to halo.exe.
GAME_EXE="halo.exe"
if [ -f "$RES/game-exe" ]; then
    GAME_EXE="$(tr -d '[:space:]' < "$RES/game-exe")"
fi

# Only x86_64 hosts are supported for now (the bundled engine is
# x86_64). ARM hosts need box64/FEX (planned, see AGENTS.md).
if [ "$(uname -m)" != "x86_64" ]; then
    echo "HaloX: this build supports x86_64 Linux only (host is $(uname -m)). ARM support (box64/FEX) is planned."
    exit 1
fi

# Per-user Wine prefix (writable, persistent)
PREFIX="$HOME/.local/share/HaloX/prefix"
mkdir -p "$(dirname "$PREFIX")"

export WINEPREFIX="$PREFIX"
# Default to no debug output, but honor an externally set WINEDEBUG
# so a diagnosis run can do e.g. WINEDEBUG=+d3d.
export WINEDEBUG="${WINEDEBUG:--all}"

# The engine loads its own libraries from wine/lib (and wine/lib64
# when present); fall back to the engine's lib dirs.
export LD_LIBRARY_PATH="$WINE_DIR/lib${WINE_DIR/lib64:+:$WINE_DIR/lib64}${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

# gstreamer: a bug in winegstreamer can hang prefix
# creation/updating. Disable it (Halo runs with -novideo and needs
# no host media plugins anyway).
export WINEDLLOVERRIDES="winegstreamer=${WINEDLLOVERRIDES:+:$WINEDLLOVERRIDES}"
export GST_PLUGIN_SYSTEM_PATH=""
export GST_PLUGIN_PATH=""

# Initialize prefix on first run
if [ ! -f "$PREFIX/system.reg" ]; then
    "$WINE" wineboot --init
    # Wait until wineboot finishes initialization
    while pgrep -f "wineserver" >/dev/null 2>&1 && [ -z "$(ls -A "$PREFIX/drive_c" 2>/dev/null)" ]; do
        sleep 1
    done
fi

# If DSOAL ships next to the game executable (dsound.dll +
# dsoal-aldrv.dll), use it as the native DirectSound so
# DirectSound3D/EAX positional audio works.
if [ -f "$GAME_DIR/dsound.dll" ]; then
    "$WINE" reg add "HKCU\\Software\\Wine\\DllOverrides" \
        /v dsound /d native /f >/dev/null 2>&1 || true
fi

# Direct3D renderer.
#   gl     - wined3d OpenGL: always works, the safe fallback.
#   dxvk   - DXVK (D3D8/9/10/11 -> Vulkan): ~1.5x faster than
#            wined3d OpenGL and patched for Halo CE, but needs a
#            32-bit Vulkan ICD (halo.exe is 32-bit).
#   vulkan - wined3d's own Vulkan backend.
#   auto   - (default) DXVK when a 32-bit Vulkan ICD is present,
#            otherwise gl.
RENDERER="${HALOX_D3D_RENDERER:-}"
if [ -z "$RENDERER" ] && [ -f "$RES/renderer.conf" ]; then
    RENDERER="$(tr -d '[:space:]' < "$RES/renderer.conf")"
fi
[ -n "$RENDERER" ] || RENDERER="auto"

# Conservative 32-bit Vulkan check for the "auto" mode. A miss is a
# safe fallback to gl; a false positive would start DXVK without a
# usable Vulkan device and crash the game, so only a confirmed
# 32-bit loader plus a registered GPU ICD enables DXVK.
dxvk_vulkan_available() {
    found32=0
    # 32-bit Vulkan loader (halo.exe is 32-bit). Check the common
    # multiarch locations directly; ldconfig -p covers custom paths.
    for p in \
        /usr/lib/i386-linux-gnu/libvulkan.so.1 \
        /usr/lib32/libvulkan.so.1 \
        /usr/lib/libvulkan.so.1; do
        if [ -e "$p" ]; then found32=1; break; fi
    done
    if [ "$found32" = 0 ] && command -v ldconfig >/dev/null 2>&1; then
        if ldconfig -p 2>/dev/null | grep 'libvulkan.so.1' | grep -Eq 'i386|lib32'; then
            found32=1
        fi
    fi
    [ "$found32" = 1 ] || return 1
    # A GPU ICD (discrete, integrated or software rasterizer) must be
    # registered; without it DXVK has no device to use.
    ls /usr/share/vulkan/icd.d/*.json /etc/vulkan/icd.d/*.json \
       /usr/local/share/vulkan/icd.d/*.json 2>/dev/null | grep -q .
}

# wined3d path (gl/vulkan): set the renderer key and make sure the
# D3D DLLs are builtin (undoes any DXVK install from a previous run).
use_wined3d() {
    "$WINE" reg add "HKCU\\Software\\Wine\\Direct3D" \
        /v renderer /d "$1" /f >/dev/null 2>&1 || true
    for dll in d3d8 d3d9 dxgi; do
        "$WINE" reg add "HKCU\\Software\\Wine\\DllOverrides" \
            /v "$dll" /d builtin /f >/dev/null 2>&1 || true
    done
}

# Copy a DLL into the prefix only when the target is
# missing or differs from the source, so a launch does not
# re-copy ~10MB of DXVK DLLs every time. A DXVK update in
# the wrapper still re-copies (the source changed), and a
# manually deleted DLL is restored.
install_dll() {
    if [ ! -f "$2" ] || ! cmp -s "$1" "$2"; then
        cp -f "$1" "$2" 2>/dev/null || true
    fi
}

# DXVK path: copy the bundled DXVK DLLs into the prefix (32-bit ->
# syswow64, 64-bit -> system32) and select them natively. The wined3d
# renderer key is set to gl so that, if DXVK fails to load, Wine
# falls back to the always-works OpenGL backend.
use_dxvk() {
    local dxvk_dir="$RES/dxvk" dll
    if [ ! -d "$dxvk_dir/x32" ] || [ ! -d "$dxvk_dir/x64" ]; then
        echo "HaloX: dxvk requested but dxvk/ is not bundled; falling back to gl" >&2
        use_wined3d gl
        return
    fi
    for dll in "$dxvk_dir/x32/"*.dll; do
        [ -f "$dll" ] || continue
        install_dll "$dll" "$PREFIX/drive_c/windows/syswow64/$(basename "$dll")"
    done
    for dll in "$dxvk_dir/x64/"*.dll; do
        [ -f "$dll" ] || continue
        install_dll "$dll" "$PREFIX/drive_c/windows/system32/$(basename "$dll")"
    done
    "$WINE" reg add "HKCU\\Software\\Wine\\Direct3D" \
        /v renderer /d gl /f >/dev/null 2>&1 || true
    for dll in d3d8 d3d9 dxgi; do
        "$WINE" reg add "HKCU\\Software\\Wine\\DllOverrides" \
            /v "$dll" /d native,builtin /f >/dev/null 2>&1 || true
    done
}

case "$RENDERER" in
    auto)
        if dxvk_vulkan_available; then
            use_dxvk
        else
            use_wined3d gl
        fi
        ;;
    dxvk)   use_dxvk ;;
    gl)     use_wined3d gl ;;
    vulkan) use_wined3d vulkan ;;
    *)
        echo "HaloX: unknown renderer '$RENDERER' (use gl, dxvk, vulkan or auto)" >&2
        exit 1
        ;;
esac

# Link game files into the prefix (symlink keeps user Mods/saves alongside).
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

# Optional build-time -vidmode (vidmode.conf, e.g. "1470,956,60").
# Scaled displays refuse the mode change Halo requests on first run
# (640x480); forcing the current desktop resolution makes wined3d
# skip the mode change. A -vidmode passed explicitly on the command
# line wins.
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
exec "$WINE" "$GAME_EXE" -novideo -use21 -console "$@"
