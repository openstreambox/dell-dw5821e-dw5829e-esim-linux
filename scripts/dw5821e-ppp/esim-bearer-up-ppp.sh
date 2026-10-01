#!/usr/bin/env bash
# esim-bearer-up-ppp.sh — bring up DW5821e eSIM data via PPP and
# install policy-routing rules. Replacement for QMI-based bearer script.
set -eu
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APN="${1:-internet}"
TBL=100
RULE_PRIO=1000
STATE=/run/esim-dw5829e.state

[ "$(id -u)" -ne 0 ] && exec sudo -E "$0" "$@"

. "${SCRIPT_DIR}/_ppp-peer-template.sh"

systemctl stop ModemManager 2>/dev/null || true

# Ensure the AT control port is free — boot-time lpac sometimes hangs
# in poll() on it and starves pppd of the modem. Kill anything left.
# Stable symlink from `78-dell-dw5821e.rules`; ttyUSB0 fallback covers
# nodes that haven't picked up the udev rule yet.
SERIAL=$([ -c /dev/dw5821e-at ] && echo /dev/dw5821e-at || echo /dev/ttyUSB0)
for i in $(seq 1 5); do
  fuser "$SERIAL" >/dev/null 2>&1 || break
  sleep 1
done
if fuser "$SERIAL" >/dev/null 2>&1; then
  echo "[*] $SERIAL busy; killing holders"
  pkill -x lpac 2>/dev/null || true
  sleep 1
  fuser -k -TERM "$SERIAL" 2>/dev/null || true
  sleep 2
  fuser -k -KILL "$SERIAL" 2>/dev/null || true
  sleep 1
fi
rm -f /var/lock/LCK..ttyUSB0 /var/lock/LCK..USB0 /run/lock/LCK..ttyUSB0 2>/dev/null || true

# Detect existing-and-healthy PPP. If ppp0 exists but has no IP it's
# a leftover from a dead pppd — drop it before starting a new one.
PPP_IP=""
if ip link show ppp0 >/dev/null 2>&1; then
  PPP_IP=$(ip -4 addr show ppp0 2>/dev/null | grep -oP "inet \K[0-9.]+" || true)
  if [ -n "$PPP_IP" ]; then
    echo "[*] PPP already up ip=$PPP_IP"
  else
    echo "[*] stale ppp0 without IP — removing"
    ip link del ppp0 2>/dev/null || true
  fi
fi

PEER="mts-esim"
if [ -z "$PPP_IP" ]; then
  # Self-heal: validate the peer file and regenerate it from the
  # canonical template if it's missing or malformed. The historical
  # failure mode was pppd refusing a broken peer with "unrecognized
  # option '/dev/ttyUSB0'" and the recovery-ladder eating its budget
  # on bug-fix attempts that couldn't help.
  ensure_ppp_peer "$PEER" "$APN"
  # attach context must carry $APN (see esim-ensure-apn.sh)
  "$(dirname "$0")/esim-ensure-apn.sh" "$APN" || true
  echo "[*] Starting PPP (peer=$PEER, APN=$APN)..."
  # & — pppd should detach by default, but if peer config sets nodetach
  # this prevents the script from blocking on it.
  pppd call "$PEER" &
  for i in $(seq 1 30); do
    sleep 2
    PPP_IP=$(ip -4 addr show ppp0 2>/dev/null | grep -oP "inet \K[0-9.]+" || true)
    [ -n "$PPP_IP" ] && break
  done
fi

[ -z "$PPP_IP" ] && { echo "PPP failed — no IP"; exit 1; }

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
PEER=$PEER
EOF

echo "[*] DONE ip=$PPP_IP dev=ppp0"
