#!/usr/bin/env bash
# esim-bearer-refresh.sh — DW5821e PPP variant
# Restart PPP without switching profiles. Used by health loop when bearer drops.
set -eu
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APN="${1:-internet}"
STATE=/run/esim-dw5829e.state
TBL=100
RULE_PRIO=1000

[ "$(id -u)" -ne 0 ] && exec sudo -E "$0" "$@"

. "${SCRIPT_DIR}/_ppp-peer-template.sh"

echo "[refresh] killing pppd..."
killall -q pppd 2>/dev/null || true
sleep 2
ip link del ppp0 2>/dev/null || true
rm -f /var/lock/LCK..ttyUSB0 /var/lock/LCK..USB0 /run/lock/LCK..ttyUSB0 2>/dev/null || true
sleep 1

# Make sure the AT port isn't being held by a stale process (lpac at
# boot occasionally wedges in poll() on it and would block our pppd).
# Stable symlink from `78-dell-dw5821e.rules`; legacy ttyUSB0 fallback.
SERIAL=$([ -c /dev/dw5821e-at ] && echo /dev/dw5821e-at || echo /dev/ttyUSB0)
for i in $(seq 1 3); do
  fuser "$SERIAL" >/dev/null 2>&1 || break
  sleep 1
done
if fuser "$SERIAL" >/dev/null 2>&1; then
  pkill -x lpac 2>/dev/null || true
  sleep 1
  fuser -k -KILL "$SERIAL" 2>/dev/null || true
  sleep 1
fi

# Pick PPP peer from state (written by bearer-up/switch). Falling back
# to the per-carrier file `mts-esim` keeps us on the proven config when
# state is missing — the auto-generated `esim-auto` file has been seen
# to fail pppd parsing under race conditions, while mts-esim/beeline-esim
# are stable and pre-installed.
PEER=""
if [ -f "$STATE" ]; then
  PEER=$(awk -F= '/^PEER=/{print $2; exit}' "$STATE" 2>/dev/null || true)
fi
[ -z "$PEER" ] && PEER="mts-esim"

# Self-heal: validate the peer file and regenerate it from the canonical
# template if it's missing or malformed. ensure_ppp_peer covers the
# "file missing" fallback that used to live here.
ensure_ppp_peer "$PEER" "$APN"
# attach context must carry $APN (see esim-ensure-apn.sh)
"${SCRIPT_DIR}/esim-ensure-apn.sh" "$APN" || true

echo "[refresh] starting PPP (peer=$PEER, apn=$APN)..."
pppd call "$PEER" &
PPP_IP=""
for i in $(seq 1 45); do
  sleep 2
  PPP_IP=$(ip -4 addr show ppp0 2>/dev/null | grep -oP "inet \K[0-9.]+" || true)
  [ -n "$PPP_IP" ] && break
done

[ -z "$PPP_IP" ] && { echo "[refresh] FAILED — no IP after 90s"; exit 2; }

# Rebuild routing
ip route flush table "$TBL" 2>/dev/null || true
ip route add default dev ppp0 table "$TBL"
while ip rule show | grep -q "lookup ${TBL}"; do
  ip rule del table "$TBL" 2>/dev/null || break
done
ip rule add from "$PPP_IP" table "$TBL" priority "$RULE_PRIO"

# Update state file
if [ -f "$STATE" ]; then
  . "$STATE"
fi
cat >"$STATE" <<STEOF
IP=$PPP_IP
PFX=32
GW=10.64.64.64
TBL=$TBL
RULE_PRIO=$RULE_PRIO
IFACE=ppp0
APN=$APN
PROFILE_AID=${PROFILE_AID:-}
PEER=$PEER
STEOF

# Refresh netns SNAT
if [ -x "${SCRIPT_DIR}/netns-esim-up.sh" ]; then
  "${SCRIPT_DIR}/netns-esim-up.sh" >/dev/null || true
fi

# Verify connectivity
code=$(ip netns exec esim curl -sk -o /dev/null --max-time 6 \
         -w '%{http_code}' https://ya.ru/ 2>/dev/null || echo 000)
if [ "$code" = "000" ]; then
  echo "[refresh] FAILED (ya.ru code=000 src=$PPP_IP)" >&2
  exit 2
fi
echo "[refresh] OK ya.ru code=$code src=$PPP_IP"
