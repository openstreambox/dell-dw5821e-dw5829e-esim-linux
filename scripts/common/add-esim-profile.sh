#!/usr/bin/env bash
# add-esim-profile.sh — download, enable and configure a new eSIM profile
# on the Dell DW5829e eUICC in one command.
#
# usage:
#   sudo ./add-esim-profile.sh <SMDP_SERVER> <MATCHING_ID> <PROVIDER_NAME> <APN>
#
# example:
#   sudo ./add-esim-profile.sh smdp.example.net XXXXXXXX-XXXXXXXX-XXXXXXXX-XXXXXXXX OperatorA internet.example
#
# What it does:
#   1. Lists current profiles (shows what's already installed)
#   2. Downloads the new profile from SM-DP+
#   3. Enables it (disabling the previously active one)
#   4. Sends notifications to SM-DP+ server
#   5. Resets modem so it re-reads the eUICC
#   6. Brings up the bearer and tests connectivity
#   7. Prints the AID for uplinks.yaml
#
# The wired (ethernet) internet is NEVER touched.

set -euo pipefail
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH:-}"

SMDP="${1:?usage: $0 <SMDP_SERVER> <MATCHING_ID> <PROVIDER_NAME> <APN>}"
MATCH_ID="${2:?matching id required}"
PROVIDER="${3:?provider name required (e.g. Beeline, Tele2, MTS)}"
APN="${4:?apn required (e.g. internet.beeline.ru)}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LPAC="$SCRIPT_DIR/../bin/lpac-qmi"
UPLINKS="$SCRIPT_DIR/../uplinks.yaml"

if [ "$(id -u)" -ne 0 ]; then
  exec sudo -E "$0" "$@"
fi

# Fallback lpac location
if [ ! -x "$LPAC" ]; then
  LPAC="/usr/local/bin/lpac-qmi"
fi
[ -x "$LPAC" ] || { echo "lpac-qmi not found"; exit 1; }

echo "============================================"
echo "  Add eSIM profile: $PROVIDER"
echo "  SM-DP+: $SMDP"
echo "  Matching ID: $MATCH_ID"
echo "  APN: $APN"
echo "============================================"
echo

# ── Step 1: Show current profiles ──────────────────────────────────
echo "[1/7] Current profiles on eUICC:"
profiles_before=$("$LPAC" profile list 2>&1)
echo "$profiles_before" | python3 -c "
import sys, json
try:
    data = json.loads(sys.stdin.read())
    for p in data.get('payload',{}).get('data',[]):
        state = '● ENABLED' if p['profileState'] == 'enabled' else '  disabled'
        print(f\"  {state}  {p['serviceProviderName']:<12}  ICCID={p['iccid']}  AID={p['isdpAid']}\")
except: print('  (could not parse)')
"
echo

# Check if provider profile already exists
if echo "$profiles_before" | python3 -c "
import sys, json
data = json.loads(sys.stdin.read())
names = [p['serviceProviderName'].lower() for p in data.get('payload',{}).get('data',[])]
sys.exit(0 if '${PROVIDER,,}' in names else 1)
" 2>/dev/null; then
  echo "WARNING: A profile from '$PROVIDER' already exists on the eUICC!"
  echo "Press Ctrl+C within 5s to abort, or wait to continue..."
  sleep 5
fi

# ── Step 2: Download profile ───────────────────────────────────────
echo "[2/7] Downloading profile from $SMDP..."
"$LPAC" profile download -s "$SMDP" -m "$MATCH_ID" 2>&1
echo "  Download complete."
echo

# ── Step 3: Find the new profile's AID ─────────────────────────────
echo "[3/7] Looking up new profile..."
profiles_after=$("$LPAC" profile list 2>&1)
NEW_AID=$(echo "$profiles_after" | python3 -c "
import sys, json
before = json.loads('''$profiles_before''').get('payload',{}).get('data',[])
after  = json.loads(sys.stdin.read()).get('payload',{}).get('data',[])
old_aids = {p['isdpAid'] for p in before}
for p in after:
    if p['isdpAid'] not in old_aids:
        print(p['isdpAid'])
        break
")

if [ -z "$NEW_AID" ]; then
  echo "  Could not determine new profile AID. Listing all:"
  echo "$profiles_after" | python3 -c "
import sys, json
data = json.loads(sys.stdin.read())
for p in data.get('payload',{}).get('data',[]):
    print(f\"  {p['serviceProviderName']:<12}  AID={p['isdpAid']}  state={p['profileState']}\")
"
  echo
  read -rp "  Enter the AID to enable: " NEW_AID
fi
echo "  New profile AID: $NEW_AID"
echo

# ── Step 4: Enable the new profile ─────────────────────────────────
echo "[4/7] Enabling profile $NEW_AID..."
"$LPAC" profile enable "$NEW_AID" 2>&1
echo "  Profile enabled."
echo

# ── Step 5: Send notifications ──────────────────────────────────────
echo "[5/7] Processing SM-DP+ notifications..."
"$LPAC" notification process -a -r 2>&1 || echo "  (some notifications may have failed — non-critical)"
echo

# ── Step 6: USB rebind to re-read eUICC ────────────────────────────
echo "[6/7] USB rebind to re-read eUICC (QMI reset alone is not reliable)..."
BUSDEV=""
for p in /sys/bus/usb/devices/*/idVendor; do
  [ "$(cat "$p" 2>/dev/null)" = "413c" ] || continue
  [ "$(cat "${p%idVendor}idProduct" 2>/dev/null)" = "81e4" ] || continue
  BUSDEV="$(basename "${p%/idVendor}")"
done
if [ -n "$BUSDEV" ]; then
  echo "$BUSDEV" > /sys/bus/usb/drivers/usb/unbind 2>/dev/null || true
  sleep 3
  echo "$BUSDEV" > /sys/bus/usb/drivers/usb/bind 2>/dev/null || true
  sleep 3
  echo 1 > "/sys/bus/usb/devices/$BUSDEV/bConfigurationValue" 2>/dev/null || true
  sleep 5
fi

echo "  Waiting for QMI..."
for i in 1 2 3 4 5 6 7 8; do
  qmicli -d "$(ls /dev/cdc-wdm* 2>/dev/null | head -1)" --uim-get-slot-status >/dev/null 2>&1 && break
  sleep 3
done

echo "  Slot status:"
qmicli -d "$(ls /dev/cdc-wdm* 2>/dev/null | head -1)" --uim-get-slot-status 2>&1 | grep -A5 "Physical slot 2"
echo

# ── Step 7: Bring up bearer and test ───────────────────────────────
echo "[7/7] Bringing up bearer (APN=$APN) and testing..."
"$SCRIPT_DIR/esim-bearer-up.sh" "$APN" 2>&1

if [ -f /run/esim-dw5829e.state ]; then
  . /run/esim-dw5829e.state
  echo
  echo "  Testing ya.ru..."
  code=$(curl -sk --interface "$IP" --max-time 8 -w '%{http_code}' -o /dev/null https://ya.ru/ 2>/dev/null || echo 000)
  if [ "$code" != "000" ]; then
    echo "  ✓ ya.ru responded HTTP $code via $PROVIDER (IP=$IP)"
  else
    echo "  ✗ ya.ru timeout — bearer may need a refresh"
  fi
fi

# ── Summary ─────────────────────────────────────────────────────────
echo
echo "============================================"
echo "  DONE: $PROVIDER eSIM profile active"
echo
echo "  AID:  $NEW_AID"
echo "  APN:  $APN"
echo "  IP:   ${IP:-unknown}"
echo
echo "  To add to uplinks.yaml:"
echo
echo "  - name: $PROVIDER"
echo "    type: sim"
echo "    provider: $PROVIDER"
echo "    modem_slot: 2"
echo "    profile_aid: $NEW_AID"
echo "    apn: $APN"
echo "    netns: esim"
echo "    carrier: ${PROVIDER,,}"
echo "============================================"
