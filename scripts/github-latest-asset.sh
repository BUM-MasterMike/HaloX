#!/bin/bash
#
# github-latest-asset.sh – resolve the download URL of a release asset of
# the latest GitHub release, without needing python3.
#
# Copyright (c) 2026 BUM MasterMike. Licensed under the MIT License.
# See the LICENSE file for details.
#
# Usage:
#   ./scripts/github-latest-asset.sh <owner/repo> <asset-name-pattern>
#
# Fetches https://api.github.com/repos/<owner/repo>/releases/latest and
# prints the browser_download_url of the first asset whose name matches
# <asset-name-pattern>. The pattern is a POSIX ERE matched against the
# *lowercased* asset name. A literal "%s" in the pattern (if present) is
# replaced by the release tag with a leading "v" stripped (lowercased, and
# regex metacharacters escaped), so an exact tag-derived asset name can be
# matched:
#
#   github-latest-asset.sh SnowyMouse/chimera '\.(zip|7z)$'
#   github-latest-asset.sh doitsujin/dxvk        '^dxvk-%s\.tar\.gz$'
#   github-latest-asset.sh Kron4ek/Wine-Builds   '^wine-%s-amd64-wow64\.tar\.xz$'
#
# When the release has no matching asset, nothing is printed and the exit
# status is 0 – the callers validate the (empty) result themselves, exactly
# like the python3 lookups did before. On a network/API error the script
# exits non-zero (curl -f), which aborts the caller via set -e – also
# exactly like before.
#
# GITHUB_TOKEN (optional) is sent as a Bearer Authorization header, which
# raises the GitHub API rate limit. Set it before calling when you build
# repeatedly (CI does this via secrets.GITHUB_TOKEN).
#
set -euo pipefail

if [ $# -ne 2 ]; then
  echo "Usage: $0 <owner/repo> <asset-name-pattern>" >&2
  exit 2
fi
repo="$1"
pattern="$2"

headers=(-H "User-Agent: HaloX" -H "Accept: application/vnd.github+json")
if [ -n "${GITHUB_TOKEN:-}" ]; then
  headers+=(-H "Authorization: Bearer $GITHUB_TOKEN")
fi

# Note: the API can serve both compact (single line) and pretty-printed
# JSON; the awk scanner below handles both.
json="$(curl -fsSL --retry 5 --retry-delay 5 --retry-all-errors "${headers[@]}" "https://api.github.com/repos/$repo/releases/latest")"

# Release tag, e.g. "v1.2.3" (a leading "v" is stripped below).
# The JSON is split on '"'; the key "tag_name" is followed by a ":" field
# and then the tag value, independent of pretty printing.
tag="$(printf '%s\n' "$json" | awk -F'"' '{ for (i = 1; i <= NF; i++) if ($i == "tag_name") { print $(i + 2); exit } }')"
tag_lc="$(printf '%s' "$tag" | tr 'A-Z' 'a-z')"
tag_lc="${tag_lc#v}"
# Escape regex metacharacters in the tag so "%s" matches the name exactly
# (e.g. "3.1.1" -> "3\.1\.1").
tag_esc="$(printf '%s' "$tag_lc" | sed 's/[^[:alnum:]]/\\&/g')"

# Lowercased pattern with %s substituted by the escaped tag.
pattern_lc="$(printf '%s' "$pattern" | tr 'A-Z' 'a-z')"
pat="${pattern_lc//%s/$tag_esc}"

# Scan the JSON as a token stream. JSON objects are released with their
# "name" before their "browser_download_url"; walk through every occurrence
# of both keys (in stream order) so the pairing works on compact JSON too.
# Print the first URL whose (lowercased) name matches the pattern.
url="$(printf '%s\n' "$json" | awk -v pat="$pat" '
BEGIN { pending = "" }
{
  rest = $0
  while (length(rest) > 0) {
    if (match(rest, /"name": *"[^"]*"/)) { p1 = RSTART; l1 = RLENGTH } else { p1 = 0; l1 = 0 }
    if (match(rest, /"browser_download_url": *"[^"]*"/)) { p2 = RSTART; l2 = RLENGTH } else { p2 = 0; l2 = 0 }
    if (p1 == 0 && p2 == 0) break
    if (p1 > 0 && (p2 == 0 || p1 < p2)) {
      tok = substr(rest, p1, l1)
      sub(/.*"name": *"/, "", tok)
      sub(/"$/, "", tok)
      pending = tok
      rest = substr(rest, p1 + l1)
    } else {
      tok = substr(rest, p2, l2)
      sub(/.*"browser_download_url": *"/, "", tok)
      sub(/"$/, "", tok)
      if (pending != "" && tolower(pending) ~ pat) { print tok; exit }
      pending = ""
      rest = substr(rest, p2 + l2)
    }
  }
}
')"

if [ -n "$url" ]; then
  printf '%s\n' "$url"
fi
exit 0