#!/bin/bash
#
# patch-engine-rpath.sh – adds real LC_RPATH entries to every bundled engine
# binary/dylib that references @rpath, so the bundle works on Apple Silicon.
#
# Why: the WineskinCX engine links its shared libs as @rpath without any
# LC_RPATH entry (e.g. wineserver -> @rpath/libinotify.0.dylib). Intel's dyld
# silently falls back to DYLD_FALLBACK_LIBRARY_PATH for such lookups, but
# Rosetta's dyld (x86_64 wine on Apple Silicon) does not and aborts with
# "Library not loaded: @rpath/... (no LC_RPATH's found)". Adding real LC_RPATHs
# fixes Apple Silicon and is harmless on Intel.
#
# Two rpaths are added per file:
#   @loader_path                      – resolves @rpath/<sibling>.so refs inside
#                                       the wine unix-dll directory
#   @loader_path/../../../Frameworks  – resolves @rpath/lib*.dylib refs against
#                                       the bundled Frameworks (libinotify,
#                                       libglib, libgst*, libpcap, ...)
#
# Usage:
#   ./scripts/patch-engine-rpath.sh /path/to/HaloX.app [--no-sign] [--quiet]
#
# Scans <app>/Contents/Resources/wine/bin, .../wine/lib and
# <app>/Contents/Frameworks, patches each Mach-O that references @rpath, then
# re-signs the bundle ad-hoc (unless --no-sign, for when the caller signs right
# after, as build-wrapper.sh does). --quiet suppresses the per-file lines and
# keeps only the summary (used during builds; errors are still printed).

set -uo pipefail

APP="${1:-}"
SIGN=1
QUIET=0
shift || true
while [ "$#" -gt 0 ]; do
  case "$1" in
    --no-sign) SIGN=0 ;;
    --quiet) QUIET=1 ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
  shift
done
if [ -z "$APP" ] || [ ! -d "$APP/Contents" ]; then
  echo "Usage: $0 /path/to/HaloX.app [--no-sign] [--quiet]" >&2
  exit 1
fi

CONTENTS="$APP/Contents"
FRAMEWORKS="$CONTENTS/Frameworks"

# The only places Mach-O binaries/dylibs live in the bundle. wine/share and
# lib/wine/x86_64-windows (PE DLLs) are intentionally not scanned.
TARGETS=(
  "$CONTENTS/Resources/wine/bin"
  "$CONTENTS/Resources/wine/lib"
  "$FRAMEWORKS"
)

PATCHED=0
BIN_COUNT=0
LIB_COUNT=0
FW_COUNT=0

# rpath_to_frameworks <path-below-Contents> – prints @loader_path/<up>Frameworks
# where <up> climbs from the file's directory back up to Contents/.
rpath_to_frameworks() {
  local rel="$1" dir up depth i
  dir="${rel%/*}"
  depth=1
  if [[ "$dir" == */* ]]; then
    depth="$(printf '%s' "$dir" | awk -F/ '{print NF}')"
  fi
  up=""
  i=0
  while [ "$i" -lt "$depth" ]; do up="${up}../"; i=$((i + 1)); done
  printf '@loader_path/%sFrameworks' "$up"
}

# add_rpath <file> <rpath> – adds the rpath unless already present.
# Returns 0 when patched, 1 when already present (skipped), 2 on failure.
# The presence check matches the full "path <rpath> (offset" token so that
# e.g. "@loader_path" does not false-positive on "@loader_path/../../Frameworks".
add_rpath() {
  local f="$1" rp="$2"
  if otool -l "$f" 2>/dev/null | grep -qF "path $rp (offset"; then
    return 1
  fi
  if ! install_name_tool -add_rpath "$rp" "$f" 2>/dev/null; then
    echo "  !! install_name_tool failed: ${f#$CONTENTS/} ($rp)" >&2
    return 2
  fi
  if [ "$QUIET" = 0 ]; then
    echo "  patched rpath $rp -> ${f#$CONTENTS/}"
  fi
}

# plural <n> <word> – "1 executable", "2 executables", ...
plural() {
  local n="$1" w="$2"
  if [ "$n" = 1 ]; then echo "1 $w"; else echo "$n ${w}s"; fi
}

while IFS= read -r -d '' F; do
  # Mach-O only (skips scripts, text files, PE DLLs, ...).
  file -b "$F" 2>/dev/null | grep -q 'Mach-O' || continue
  # Only files that actually use @rpath for their own dependencies.
  otool -L "$F" 2>/dev/null | grep -q '@rpath' || continue

  REL="${F#$CONTENTS/}"
  RP_FW="$(rpath_to_frameworks "$REL")"

  changed=0
  if add_rpath "$F" '@loader_path'; then changed=1; fi
  if add_rpath "$F" "$RP_FW"; then changed=1; fi
  if [ "$changed" = 1 ]; then
    PATCHED=$((PATCHED + 1))
    case "$REL" in
      Resources/wine/bin/*) BIN_COUNT=$((BIN_COUNT + 1)) ;;
      Resources/wine/lib/*) LIB_COUNT=$((LIB_COUNT + 1)) ;;
      Frameworks/*) FW_COUNT=$((FW_COUNT + 1)) ;;
    esac
  fi
done < <(find "${TARGETS[@]}" -type f \( -name '*.so' -o -name '*.dylib' -o -perm -111 \) -print0 2>/dev/null)

if [ "$PATCHED" -gt 0 ] && [ "$SIGN" = 1 ]; then
  # install_name_tool invalidates the ad-hoc signature – re-sign.
  echo "Re-signing $APP (ad-hoc)..."
  codesign --force --deep --sign - "$APP"
fi

if [ "$PATCHED" -gt 0 ]; then
  echo "Done. Patched $PATCHED engine binaries with Rosetta-safe rpaths" \
    "($(plural "$BIN_COUNT" executable), $(plural "$LIB_COUNT" "wine dll")," \
    "$(plural "$FW_COUNT" "framework dylib")) - library loading no longer" \
    "depends on DYLD_FALLBACK_LIBRARY_PATH."
else
  echo "Done. All engine binaries already carry Rosetta-safe rpaths."
fi