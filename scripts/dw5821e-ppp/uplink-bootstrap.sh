#!/usr/bin/env bash
# uplink-bootstrap.sh — DW5821e PPP variant
# Smart bootstrap: checks if the correct eSIM profile is active.
# If wrong profile → delegates to esim-switch-profile-ppp.sh.
# If correct profile → just ensures PPP is up.
set -eu
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APN="${1:-internet}"
TARGET_AID="${2:-}"

[ "$(id -u)" -ne 0 ] && exec sudo -E "$0" "$@"

# If PPP is already up with an IP, just refresh netns and exit
if ip link show ppp0 >/dev/null 2>&1; then
  PPP_IP=$(ip -4 addr show ppp0 2>/dev/null | grep -oP "inet \K[0-9.]+" || true)
  if [ -n "$PPP_IP" ]; then
    echo "[bootstrap] PPP already up ip=$PPP_IP, refreshing netns"
    "${SCRIPT_DIR}/esim-bearer-up-ppp.sh" "$APN"
    "${SCRIPT_DIR}/netns-esim-up.sh"
    exit 0
  fi
fi

# Stable per-interface symlink from `78-dell-dw5821e.rules`; legacy
# /dev/ttyUSB0 fallback covers nodes where the udev rule isn't deployed
# yet.
SERIAL=$([ -c /dev/dw5821e-at ] && echo /dev/dw5821e-at || echo /dev/ttyUSB0)

# If a target profile AID is given, check if it matches the currently active profile
if [ -n "$TARGET_AID" ] && [ -c "$SERIAL" ]; then
  LPAC_ROOT=/tmp/lpac-build/build
  if [ -x "$LPAC_ROOT/src/lpac" ]; then
    export LD_LIBRARY_PATH="$LPAC_ROOT:$LPAC_ROOT/driver:$LPAC_ROOT/utils:$LPAC_ROOT/euicc"
    export LPAC_APDU=at_csim
    export LPAC_APDU_AT_DEVICE="$SERIAL"
    export LPAC_HTTP=curl

    CURRENT_AID=$(timeout 15 "$LPAC_ROOT/src/lpac" profile list 2>/dev/null | python3 -c '
import sys, json
for line in sys.stdin:
    line = line.strip()
    if not line.startswith("{"):
        continue
    try:
        obj = json.loads(line)
    except:
        continue
    if obj.get("type") == "lpa":
        for p in obj["payload"].get("data", []):
            if p.get("profileState") == "enabled":
                print(p["isdpAid"])
                break
' 2>/dev/null || true)

    # `timeout 15 lpac` sends SIGTERM, but lpac stuck in poll() on a
    # serial AT response sometimes ignores TERM. Force-kill any lpac
    # still around so the next step doesn't race on /dev/ttyUSB0.
    pkill -x lpac 2>/dev/null || true

    if [ -n "$CURRENT_AID" ] && [ "$CURRENT_AID" != "$TARGET_AID" ]; then
      echo "[bootstrap] Wrong profile active ($CURRENT_AID), need $TARGET_AID — switching"
      exec "${SCRIPT_DIR}/esim-switch-profile-ppp.sh" "$TARGET_AID" "$APN"
    fi
    if [ -n "$CURRENT_AID" ]; then
      echo "[bootstrap] Correct profile active ($CURRENT_AID)"
    else
      # lpac can't see the eUICC — radio off (+CFUN: 0) or a wedged port.
      # «Proceeding to PPP anyway» never worked in that state (chatscript
      # aborts on ATH → ERROR); the switch script frees the port, fixes
      # CFUN (step 2b) and does the documented cycle.
      echo "[bootstrap] lpac did not report active profile — delegating to esim-switch-profile-ppp.sh"
      exec "${SCRIPT_DIR}/esim-switch-profile-ppp.sh" "$TARGET_AID" "$APN"
    fi
  fi
fi

# Profile is correct (or no AID given) — just bring up PPP
"${SCRIPT_DIR}/esim-bearer-up-ppp.sh" "$APN"
"${SCRIPT_DIR}/netns-esim-up.sh"
