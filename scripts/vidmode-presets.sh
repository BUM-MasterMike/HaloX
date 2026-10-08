#!/bin/bash
#
# vidmode-presets.sh – single source of truth for the -vidmode presets.
#
# Copyright (c) 2026 BUM MasterMike. Licensed under the MIT License.
# See the LICENSE file for details.
#
# A "Looks like" (logical) display resolution is passed to halo.exe via
# -vidmode so the game requests the mode already active on the desktop;
# wined3d then skips the mode change entirely. This is required on scaled
# displays (e.g. MacBook Air) that refuse the mode change Halo requests on
# first run (640x480), which otherwise surfaces as a Direct3D error dialog.
#
# Values are the logical resolutions for each device's scaling level, with
# refresh 60 (fixed-refresh panels). MacBook Pro 14"/16" have ProMotion
# (120 Hz capable); if such a display runs at 120 Hz, pass a custom W,H,R
# instead of the 60 Hz preset.
#
# Format per line:  name | W,H,R | description
# "-max" = the "maximum area" scaling level. Sourced by build-wrapper.sh
# and build-local.sh; the CI workflow lists the same names in its "vidmode"
# input choices (it re-runs the mapping via build-wrapper.sh).
VIDMODE_PRESET_DEFS='
macbook-air-13|1470,956,60|MacBook Air 13" (M2/M3/M5) - standard scaling
macbook-air-13-max|1710,1112,60|MacBook Air 13" (M2/M3/M5) - maximum area
macbook-air-13-old|1440,900,60|MacBook Air 13" (M1/Intel) - standard scaling
macbook-air-13-old-max|1680,1050,60|MacBook Air 13" (M1/Intel) - maximum area
macbook-air-15|1710,1107,60|MacBook Air 15" (M3/M5) - standard scaling
macbook-air-15-max|1920,1243,60|MacBook Air 15" (M3/M5) - maximum area
macbook-pro-14|1512,982,60|MacBook Pro 14" (M-chips) - standard scaling
macbook-pro-14-max|1800,1169,60|MacBook Pro 14" (M-chips) - maximum area
macbook-pro-16|1728,1117,60|MacBook Pro 16" (M-chips) - standard scaling
macbook-pro-16-max|2056,1329,60|MacBook Pro 16" (M-chips) - maximum area
'

# vidmode_preset_lookup <arg> – prints the W,H,R value for a preset name and
# returns 0; prints nothing and returns 1 when <arg> is not a preset.
vidmode_preset_lookup() {
  local arg="$1" name val
  while IFS='|' read -r name val _desc; do
    [ -n "$name" ] || continue
    if [ "$name" = "$arg" ]; then
      printf '%s' "$val"
      return 0
    fi
  done <<< "$VIDMODE_PRESET_DEFS"
  return 1
}