#!/usr/bin/env bash
# uplink-bootstrap.sh — one-shot "bring everything up to a sane starting
# state" script. Invoked from UplinkManager on agent start.
#
# If a profile_aid is specified and differs from the currently active eSIM
# profile, performs a full esim-switch-profile.sh (lpac enable + DMS reset +
# USB rebind + WDS). Otherwise just brings up the bearer idempotently.
#
# usage: sudo ./uplink-bootstrap.sh <APN> [PROFILE_AID]

set -eu
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH:-}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APN="${1:-internet}"
PROFILE_AID="${2:-}"

if [ "$(id -u)" -ne 0 ]; then
  exec sudo -E "$0" "$@"
fi

needs_switch=false
if [ -n "$PROFILE_AID" ]; then
  # Check if the requested profile is already active
  state_aid=""
  if [ -f /run/esim-dw5829e.state ]; then
    state_aid=$(grep -oP 'PROFILE_AID=\K.*' /run/esim-dw5829e.state 2>/dev/null || true)
  fi
  if [ "$state_aid" != "$PROFILE_AID" ]; then
    needs_switch=true
  fi
fi

if [ "$needs_switch" = "true" ]; then
  echo "[bootstrap] profile mismatch: switching to $PROFILE_AID (apn=$APN)"
  "${SCRIPT_DIR}/esim-switch-profile.sh" "$PROFILE_AID" "$APN"
else
  "${SCRIPT_DIR}/esim-bearer-up.sh" "$APN"
fi

"${SCRIPT_DIR}/netns-esim-up.sh"
