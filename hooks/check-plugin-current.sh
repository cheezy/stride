#!/usr/bin/env bash
# check-plugin-current.sh — Step 0 plugin-currency check (W2251).
#
# Prints ONE line when the installed stride plugin is older than the version
# the stride-marketplace catalog publishes, and nothing otherwise. Always
# exits 0: it is a warning, never a gate.
#
# WHY: dispatched agents load from the installed plugin cache, so a stale
# install silently runs without shipped fixes. skills_version is "1.0" for
# every release, so the server's skills_update_required cannot see this, and
# the local marketplace clone under ~/.claude/plugins/marketplaces can be just
# as stale as the install — so the comparison reads the PUBLISHED pin.
#
# USAGE: check-plugin-current.sh <skill-base-directory>
#   The skill base directory is .../stride/<version>/skills/stride-workflow
#   for a marketplace install, so the installed version is the name of the
#   directory two levels up. A local-path install has no version directory;
#   then <base>/../../.claude-plugin/plugin.json supplies it. Neither readable
#   -> silence.
#
# SILENCE, exit 0, whenever: the argument is missing, the installed version is
# unreadable or not version-shaped, curl or jq is absent, the pin cannot be
# fetched within the timeout, the catalog does not parse, it has no "stride"
# entry, or the installed version is equal to or newer than the pin.
#
# SECURITY: the pin is read over HTTPS from the canonical catalog only — the
# URL is a constant, not an input. Nothing fetched is executed or sourced; it is
# parsed by jq as data and only a version-shaped string is ever printed. No
# credential is sent: no Authorization header, no token, no cookie.
#
# COMPARISON is numeric per dot-separated component (1.80.0 > 1.9.0), missing
# components count as 0, and a pre-release suffix sorts below its release
# (1.83.0-rc.1 < 1.83.0). Two pre-releases of the same core are not ordered —
# that is reported as silence rather than a guess.
#
# No pipes, no eval, no network beyond the one bounded curl.

set -u

PIN_URL="https://raw.githubusercontent.com/cheezy/stride-marketplace/main/.claude-plugin/marketplace.json"
UPDATE_CMD="/plugin marketplace update stride-marketplace, then /plugin update stride@stride-marketplace"
VERSION_RE='^[0-9]+(\.[0-9]+)*(-[0-9A-Za-z.-]+)?$'

# Echo the installed version for a skill base directory, or nothing.
installed_version() {
  _base="${1%/}"
  _dir_version="$(basename "$(dirname "$(dirname "$_base")")")"
  if [[ "$_dir_version" =~ $VERSION_RE ]]; then
    printf '%s' "$_dir_version"
    return
  fi
  _manifest="$_base/../../.claude-plugin/plugin.json"
  [ -f "$_manifest" ] || return
  command -v jq > /dev/null 2>&1 || return
  jq -r 'if (.version | type) == "string" then .version else empty end' "$_manifest" 2> /dev/null
}

# Echo the published stride version from catalog JSON on stdin, or nothing.
published_version() {
  jq -r 'first(.plugins[]? | select(.name == "stride") | .version | select(type == "string")) // empty' 2> /dev/null
}

# Compare two version-shaped strings. Exit 0 when $1 is strictly older than $2.
version_older() {
  _a_core="${1%%-*}"; _b_core="${2%%-*}"
  _a_pre=""; _b_pre=""
  [ "$_a_core" != "$1" ] && _a_pre="${1#*-}"
  [ "$_b_core" != "$2" ] && _b_pre="${2#*-}"
  IFS=. read -r -a _a_parts <<< "$_a_core"
  IFS=. read -r -a _b_parts <<< "$_b_core"
  _n=${#_a_parts[@]}
  [ "${#_b_parts[@]}" -gt "$_n" ] && _n=${#_b_parts[@]}
  _i=0
  while [ "$_i" -lt "$_n" ]; do
    _x=$(( 10#${_a_parts[$_i]:-0} ))
    _y=$(( 10#${_b_parts[$_i]:-0} ))
    [ "$_x" -lt "$_y" ] && return 0
    [ "$_x" -gt "$_y" ] && return 1
    _i=$(( _i + 1 ))
  done
  # Equal cores: only "pre-release vs its release" is ordered.
  [ -n "$_a_pre" ] && [ -z "$_b_pre" ] && return 0
  return 1
}

main() {
  [ "$#" -ge 1 ] && [ -n "$1" ] || return 0
  _installed="$(installed_version "$1")"
  [[ "$_installed" =~ $VERSION_RE ]] || return 0
  command -v curl > /dev/null 2>&1 || return 0
  command -v jq > /dev/null 2>&1 || return 0
  _body="$(curl -sS --proto '=https' --connect-timeout 2 --max-time 3 -A 'curl/stride-plugin-check' "$PIN_URL" 2> /dev/null)" || return 0
  [ -n "$_body" ] || return 0
  _published="$(published_version <<< "$_body")"
  [[ "$_published" =~ $VERSION_RE ]] || return 0
  if version_older "$_installed" "$_published"; then
    printf 'stride plugin %s is installed but the marketplace publishes %s - update with: %s\n' \
      "$_installed" "$_published" "$UPDATE_CMD"
  fi
  return 0
}

main "$@"
exit 0
