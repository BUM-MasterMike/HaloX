#!/bin/bash
#
# common-output.sh – shared pretty-printing helpers for the HaloX build scripts.
#
# Provides:
#   banner "Title" "subtitle"   – big header block
#   section "Name"              – task section heading
#   kv "Key" "value"            – aligned key/value line for config lists
#   ok / warn / fail "message"  – status lines (warn/fail go to stderr)
#   info "message"              – dimmed detail line
#
# Colors are only used when stdout is a TTY and NO_COLOR is not set, so CI
# logs stay plain and grep-friendly.
#
# NOTE: Keep output ASCII-only. macOS bash 3.2 can mis-parse non-ASCII bytes
# that follow a variable name (e.g. "$VAR…"), which broke builds before.

C_RESET=""
C_BOLD=""
C_DIM=""
C_BLUE=""
C_GREEN=""
C_YELLOW=""
C_RED=""

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  C_RESET=$'\033[0m'
  C_BOLD=$'\033[1m'
  C_DIM=$'\033[2m'
  C_BLUE=$'\033[34m'
  C_GREEN=$'\033[32m'
  C_YELLOW=$'\033[33m'
  C_RED=$'\033[31m'
fi

banner() {
  local title="$1"
  local subtitle="${2:-}"
  echo
  echo "${C_BOLD}${C_BLUE}============================================================${C_RESET}"
  echo "${C_BOLD}${C_BLUE}  ${title}${C_RESET}"
  if [ -n "$subtitle" ]; then
    echo "${C_DIM}  ${subtitle}${C_RESET}"
  fi
  echo "${C_BOLD}${C_BLUE}============================================================${C_RESET}"
  echo
}

section() {
  echo
  echo "${C_BOLD}${C_BLUE}--- ${1}${C_RESET}"
}

kv() {
  printf '  %-18s %s\n' "${C_DIM}${1}${C_RESET}" "${2}"
}

info() {
  echo "${C_DIM}  ${1}${C_RESET}"
}

ok() {
  echo "${C_GREEN}  OK: ${1}${C_RESET}"
}

warn() {
  echo "${C_YELLOW}  WARN: ${1}${C_RESET}" >&2
}

fail() {
  echo "${C_RED}  FAIL: ${1}${C_RESET}" >&2
}