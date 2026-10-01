#!/usr/bin/env bash
# esim-switch-profile-ppp.sh — switch eSIM profile on Dell DW5821e-eSIM
# (Foxconn T77W968) using lpac AT+CSIM backend + PPP data.
#
# Hardened against the historical hang where:
#   - lpac (from boot bootstrap) failed to release /dev/ttyUSB0
#   - this script's step 2 then opened the same port concurrently
#   - pyserial.write() spun forever on EAGAIN with no write_timeout
# All inline python3 helpers are now wrapped in `timeout` and use
# write_timeout=2 so they cannot wedge silently.
#
# Sequence:
#   0. flock single-instance lock
#   1. Kill pppd, stale lpac; wait for /dev/ttyUSB0 to free (hard fail/kill)
#   2. Close stale logical channels (1..3 only)
#   3. Disable current profile via lpac (if different)
#   4. Enable target profile via lpac
#   4b. CFUN cycle + CREG poll
#   5. Start PPP with target APN
#   6. Reconfigure policy routing + netns
#
# usage: sudo ./esim-switch-profile-ppp.sh <PROFILE_AID> <APN> [PPP_PEER]

set -euo pipefail

# Ensure lpac /tmp/ RPATH symlinks exist (recreated at boot by esim-prepare.service,
# but /tmp may be cleared. Idempotent — no-op if already present).
[ -e /tmp/lpac-build/build/src/lpac ] || /usr/local/bin/lpac-setup-tmpdir-at.sh
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

PROFILE_AID="${1:?usage: $0 <PROFILE_AID> <APN> [PPP_PEER]}"
APN="${2:?apn required}"
PPP_PEER="${3:-}"

# Stable per-interface symlink from `78-dell-dw5821e.rules` (if 02 =
# AT control). Falls back to /dev/ttyUSB0 on nodes where the rule
# isn't installed yet, so this script keeps working pre- and
# post-migration.
SERIAL=$([ -c /dev/dw5821e-at ] && echo /dev/dw5821e-at || echo /dev/ttyUSB0)
LPAC_ROOT=/tmp/lpac-build/build
TBL=100
RULE_PRIO=1000
STATE=/run/esim-dw5829e.state
LOCK=/run/esim-switch-ppp.lock
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

[ "$(id -u)" -ne 0 ] && exec sudo -E "$0" "$@"

. "${SCRIPT_DIR}/_ppp-peer-template.sh"

# ── Step 0: Single-instance lock ─────────────────────────────────────
# Two parallel switches racing on /dev/ttyUSB0 is half the bugs we're
# trying to prevent.
exec 9>"$LOCK"
# Wait up to 60s for a concurrent invocation to finish. `-n` (non-blocking)
# and `-w` (wait) are mutually exclusive — flock prefers -n and would fail
# immediately, so we use `-w` alone.
if ! flock -w 60 9; then
  echo "[switch] another esim-switch-profile-ppp.sh is in progress, giving up" >&2
  exit 2
fi

export LD_LIBRARY_PATH="$LPAC_ROOT:$LPAC_ROOT/driver:$LPAC_ROOT/utils:$LPAC_ROOT/euicc"
export LPAC_APDU=at_csim
export LPAC_APDU_AT_DEVICE="$SERIAL"
export LPAC_HTTP=curl
LPAC="$LPAC_ROOT/src/lpac"

# Free /dev/ttyUSB0 by any means before we touch the modem. Anything still
# holding it is, by definition, stale (we own the modem now).
release_serial() {
  killall -q pppd       2>/dev/null || true
  # stop any legacy pppd unit of your own here, e.g. `systemctl stop my-ppp`
  for i in $(seq 1 5); do
    fuser "$SERIAL" >/dev/null 2>&1 || return 0
    sleep 2
  done
  echo "[switch] $SERIAL still held by: $(fuser "$SERIAL" 2>&1 | tr -s ' '); forcing release"
  fuser -k -TERM "$SERIAL" 2>/dev/null || true
  sleep 2
  fuser -k -KILL "$SERIAL" 2>/dev/null || true
  sleep 1
  # Also nuke any lpac stuck in poll() on a sibling FD.
  pkill -x lpac 2>/dev/null || true
  sleep 1
  if fuser "$SERIAL" >/dev/null 2>&1; then
    echo "[switch] FATAL: $SERIAL still busy after kill: $(fuser "$SERIAL" 2>&1)" >&2
    return 1
  fi
}

# ── Step 1: Stop PPP & free serial ───────────────────────────────────
echo "[switch] freeing $SERIAL..."
if ! release_serial; then
  exit 1
fi

# ── Step 2: Close stale logical channels ──────────────────────────────
# AT+CSIM=10,"007080XX00" = ISO 7816 MANAGE CHANNEL CLOSE. Standard
# SIMs only have logical channels 1..3, so we iterate 1..3 not 1..19.
# Wrapped in `timeout 30s` + write_timeout=2 so a misbehaving USB-serial
# can't lock the script up (the historical 5-day hang).
echo "[switch] closing stale logical channels..."
timeout 30s python3 -c '
import serial, time
port = serial.Serial("'"$SERIAL"'", 115200, timeout=2, write_timeout=2)
time.sleep(0.3)
def at(cmd):
    port.reset_input_buffer()
    try:
        port.write((cmd + "\r").encode())
    except serial.SerialTimeoutException:
        return ""
    time.sleep(0.5)
    return port.read(4096).decode(errors="replace")
for ch in range(1, 4):
    at("AT+CSIM=10,\"007080%02X00\"" % ch)
port.close()
' || echo "[switch] channel-close helper exited non-zero (timeout or error) — continuing"

# ── Step 2b: Radio off? Bring it up BEFORE touching lpac ──────────────
# A previous switch that died between AT+CFUN=0 and AT+CFUN=1 (helper
# timeout, agent restart, modem hiccup) leaves the modem at +CFUN: 0. In
# that state the eUICC is unpowered: `lpac profile list/enable` fail,
# AT+CPIN? answers +CME ERROR 13 and the PPP chatscript aborts on ATH →
# ERROR. Step 4b (the documented CFUN cycle) sits AFTER lpac and is never
# reached, so the node loops on «lpac did not report active profile» —
# the DW5821e node sat like this from 2026-09-30 02:00 (11 592 uplink_switch per
# night). One CFUN=1 here, then wait for CPIN READY; the CFUN-storm guard
# is the caller's cooldown ladder, not this script.
echo "[switch] checking radio state (AT+CFUN?)..."
timeout 60s python3 -c '
import serial, time, sys
port = serial.Serial("'"$SERIAL"'", 115200, timeout=3, write_timeout=3)
time.sleep(0.3)
def at(cmd, wait=1.5):
    port.reset_input_buffer()
    try:
        port.write((cmd + "\r").encode())
    except serial.SerialTimeoutException:
        return ""
    time.sleep(wait)
    return port.read(4096).decode(errors="replace")
r = at("AT+CFUN?")
if "+CFUN: 0" not in r and "+CFUN: 4" not in r:
    print("  radio state ok:", " ".join(r.split()))
    port.close(); sys.exit(0)
print("  radio is OFF (" + " ".join(r.split()) + ") — AT+CFUN=1")
print("  CFUN=1:", " ".join(at("AT+CFUN=1", 5).split()))
for i in range(12):
    time.sleep(3)
    c = at("AT+CPIN?")
    if "READY" in c:
        print("  eUICC ready after %ds" % ((i + 1) * 3)); port.close(); sys.exit(0)
print("  WARNING: CPIN not READY after 36s:", " ".join(c.split()))
port.close()
' || echo "[switch] CFUN pre-check helper timed out — continuing"

# ── Step 3: Get current profiles state ────────────────────────────────
echo "[switch] listing profiles..."
list_out=$(timeout 20 "$LPAC" profile list 2>&1 || true)
echo "$list_out" | python3 -c '
import sys, json
for line in sys.stdin:
    line = line.strip()
    if not line.startswith("{"):
        continue
    try:
        obj = json.loads(line)
    except Exception:
        continue
    if obj.get("type") == "lpa":
        for p in obj["payload"].get("data", []):
            state = p.get("profileState", "?")
            sp = p.get("serviceProviderName", "?")
            aid = p.get("isdpAid", "?")
            print(f"  {sp}: {state} ({aid})")
' || true

current_aid=$(echo "$list_out" | python3 -c '
import sys, json
for line in sys.stdin:
    line = line.strip()
    if not line.startswith("{"):
        continue
    try:
        obj = json.loads(line)
    except Exception:
        continue
    if obj.get("type") == "lpa":
        for p in obj["payload"].get("data", []):
            if p.get("profileState") == "enabled":
                print(p["isdpAid"])
                break
' 2>/dev/null || true)

if [ "$current_aid" = "$PROFILE_AID" ]; then
  echo "[switch] target profile already enabled"
  NEED_CFUN=0
  if ! ip link show ppp0 >/dev/null 2>&1; then
    NEED_CFUN=1
  fi
else
  if [ -n "$current_aid" ]; then
    echo "[switch] disabling current profile ($current_aid)..."
    timeout 20 "$LPAC" profile disable "$current_aid" 2>&1 | tail -1 || true
  fi

  # ── Step 4: Enable target profile ────────────────────────────────────
  echo "[switch] enabling profile $PROFILE_AID..."
  enable_out=$(timeout 20 "$LPAC" profile enable "$PROFILE_AID" 2>&1 || true)
  echo "  $enable_out" | tail -1
  if ! echo "$enable_out" | grep -q '"code":0'; then
    echo "ERROR: lpac enable failed" >&2
    exit 1
  fi
  NEED_CFUN=1
fi

# ── Step 4b: Modem reset (AT+CFUN=0/1) ──────────────────────────────
# DW5821e needs a functional reset to re-read eUICC after profile switch.
# lpac should have released ttyUSB0 by now; re-check.
if [ "${NEED_CFUN:-1}" = "1" ]; then
  echo "[switch] freeing $SERIAL before CFUN cycle..."
  for i in $(seq 1 5); do
    fuser "$SERIAL" >/dev/null 2>&1 || break
    sleep 1
  done
  if fuser "$SERIAL" >/dev/null 2>&1; then
    pkill -x lpac 2>/dev/null || true
    sleep 1
  fi

  echo "[switch] resetting modem (AT+CFUN cycle)..."
  timeout 30s python3 -c '
import serial, time
port = serial.Serial("'"$SERIAL"'", 115200, timeout=5, write_timeout=3)
time.sleep(0.3)
def at(cmd, wait=3):
    port.reset_input_buffer()
    try:
        port.write((cmd + "\r").encode())
    except serial.SerialTimeoutException:
        return "(write timeout)"
    time.sleep(wait)
    return port.read(4096).decode(errors="replace").strip()
print("  CFUN=0:", at("AT+CFUN=0", 3))
time.sleep(2)
print("  CFUN=1:", at("AT+CFUN=1", 5))
port.close()
' || echo "[switch] CFUN helper timed out — continuing to CREG poll anyway"

  echo "[switch] waiting for network registration..."
  timeout 60s python3 -c '
import serial, time, sys
port = serial.Serial("'"$SERIAL"'", 115200, timeout=3, write_timeout=3)
time.sleep(2)
def at(cmd):
    port.reset_input_buffer()
    try:
        port.write((cmd + "\r").encode())
    except serial.SerialTimeoutException:
        return ""
    time.sleep(1.5)
    return port.read(4096).decode(errors="replace").strip()
for attempt in range(15):
    time.sleep(3)
    r = at("AT+CREG?")
    if ",1" in r or ",5" in r:
        cops = at("AT+COPS?")
        first = (cops.splitlines() or [""])[0]
        print(f"  registered after {(attempt+1)*3}s: {first}")
        port.close()
        sys.exit(0)
    print(f"  not yet ({attempt+1})...")
port.close()
print("  WARNING: not registered after 45s, trying PPP anyway")
' || echo "[switch] CREG poll timed out — trying PPP anyway"
fi

# ── Step 4c: attach context must carry the target APN ────────────
# CFUN=1 attaches with the APN cid 1 held BEFORE (the previous operator);
# CGDCONT is refused at CFUN=0 and the chatscript sets it after the attach.
# esim-ensure-apn.sh compares +CGCONTRDP with $APN and re-attaches if needed.
"$(dirname "$0")/esim-ensure-apn.sh" "$APN" || true

# ── Step 5: Start PPP ─────────────────────────────────────────────────
[ -z "$PPP_PEER" ] && PPP_PEER="esim-auto"

# Always (re)write the peer + chatscript from the canonical template
# for the current APN. A switch is the right place to refresh these:
# the APN may have changed since the file was last written.
write_ppp_peer "$PPP_PEER" "$APN"

echo "[switch] starting PPP (peer=$PPP_PEER, apn=$APN)..."
ip link del ppp0 2>/dev/null || true
rm -f /var/lock/LCK..ttyUSB0 /var/lock/LCK..USB0 /run/lock/LCK..ttyUSB0 2>/dev/null || true

# Make sure ttyUSB0 is free for pppd — same fuser dance, hard kill.
for i in $(seq 1 5); do
  fuser "$SERIAL" >/dev/null 2>&1 || break
  sleep 1
done
if fuser "$SERIAL" >/dev/null 2>&1; then
  echo "[switch] $SERIAL busy before pppd — forcing release"
  fuser -k -TERM "$SERIAL" 2>/dev/null || true
  sleep 2
  fuser -k -KILL "$SERIAL" 2>/dev/null || true
  sleep 1
fi

pppd call "$PPP_PEER" 9>&- &
PPP_IP=""
for i in $(seq 1 60); do
  sleep 2
  PPP_IP=$(ip -4 addr show ppp0 2>/dev/null | grep -oP "inet \K[0-9.]+" || true)
  [ -n "$PPP_IP" ] && break
done

if [ -z "$PPP_IP" ]; then
  echo "ERROR: PPP failed — no IP after 120s" >&2
  killall -q pppd 2>/dev/null || true
  exit 1
fi

# ── Step 6: Policy routing ────────────────────────────────────────────
ip route flush table "$TBL" 2>/dev/null || true
ip route add default dev ppp0 table "$TBL"
while ip rule show | grep -q "lookup ${TBL}"; do
  ip rule del table "$TBL" 2>/dev/null || break
done
ip rule add from "$PPP_IP" table "$TBL" priority "$RULE_PRIO"

cat >"$STATE" <<EOF
IP=$PPP_IP
PFX=32
GW=10.64.64.64
TBL=$TBL
RULE_PRIO=$RULE_PRIO
IFACE=ppp0
APN=$APN
PROFILE_AID=$PROFILE_AID
PEER=$PPP_PEER
EOF

# ── Step 7: Refresh netns ─────────────────────────────────────────────
if [ -x "${SCRIPT_DIR}/netns-esim-up.sh" ]; then
  "${SCRIPT_DIR}/netns-esim-up.sh" || echo "[switch] netns refresh failed (non-fatal)"
fi

echo
echo "[switch] DONE  ip=$PPP_IP  apn=$APN  profile=$PROFILE_AID"
