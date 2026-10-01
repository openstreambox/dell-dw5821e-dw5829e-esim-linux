#!/usr/bin/env bash
# esim-switch-profile.sh — atomically switch the active eSIM profile
# and bring up the data bearer on Dell DW5829e-eSIM (QMI).
#
# Sequence:
#   1. Stop WDS + clean routing
#   2. USB rebind (clean QMI for lpac)
#   3. Start qmi-proxy + lpac profile enable (handles disable of old)
#   4. DMS reset (modem reboots, re-reads eUICC)
#   5. Wait 30s + USB rebind
#   6. raw_ip + WDS start + routing
#
# usage:  sudo ./esim-switch-profile.sh <PROFILE_AID> <APN>

set -euo pipefail
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH:-}"

PROFILE_AID="${1:?usage: $0 <PROFILE_AID> <APN>}"
APN="${2:?apn required}"

TBL=100
RULE_PRIO=1000
IFACE=wwan0
STATE=/run/esim-dw5829e.state
CID_FILE=/run/esim-wds-cid
QMI_DEV=""

[ "$(id -u)" -ne 0 ] && exec sudo -E "$0" "$@"

resolve_qmi_dev() {
  local d
  for d in /dev/cdc-wdm*; do
    [ -c "$d" ] || continue
    if qmicli -d "$d" --uim-get-slot-status >/dev/null 2>&1; then
      printf '%s' "$d"; return 0
    fi
  done
  return 1
}

find_modem() {
  BUSPATH="" BUSDEV=""
  for p in /sys/bus/usb/devices/*/idVendor; do
    [ "$(cat "$p" 2>/dev/null)" = "413c" ] || continue
    [ "$(cat "${p%idVendor}idProduct" 2>/dev/null)" = "81e4" ] || continue
    BUSPATH="${p%/idVendor}"; BUSDEV="$(basename "$BUSPATH")"
  done
}

usb_rebind() {
  find_modem
  [ -n "$BUSDEV" ] || { echo "modem not found"; return 1; }
  echo "$BUSDEV" > /sys/bus/usb/drivers/usb/unbind 2>/dev/null || true
  sleep 3
  echo "$BUSDEV" > /sys/bus/usb/drivers/usb/bind 2>/dev/null || true
  sleep 3
  echo 1 > "$BUSPATH/bConfigurationValue" 2>/dev/null || { sleep 2; find_modem; echo 1 > "$BUSPATH/bConfigurationValue" 2>/dev/null || true; }
  sleep 5
}

wait_qmi() {
  for i in $(seq 1 14); do
    if d=$(resolve_qmi_dev); then
      QMI_DEV="$d"; echo "[switch] QMI=$QMI_DEV (attempt $i)"; return 0
    fi
    sleep 3
  done
  echo "QMI not ready" >&2; return 1
}

# Step 1: Stop WDS + clean routing
echo "[switch] stopping WDS..."
systemctl stop ModemManager 2>/dev/null || true
if d=$(resolve_qmi_dev); then
  QMI_DEV="$d"
  if [ -f "$CID_FILE" ]; then
    qmicli -d "$QMI_DEV" --wds-stop-network=4294967295 --client-cid="$(cat $CID_FILE)" 2>&1 || true
    rm -f "$CID_FILE"
  fi
fi
while ip rule show 2>/dev/null | grep -q "lookup ${TBL}"; do ip rule del table "$TBL" 2>/dev/null || break; done
ip route flush table "$TBL" 2>/dev/null || true
ip addr flush dev "$IFACE" 2>/dev/null || true
ip link set "$IFACE" down 2>/dev/null || true
rm -f "$STATE"

# Step 2: USB rebind
echo "[switch] USB rebind (clean QMI)..."
usb_rebind
wait_qmi

# Step 3: Enable profile via lpac (with qmi-proxy)
echo "[switch] enabling profile $PROFILE_AID..."
pkill -f qmi-proxy 2>/dev/null || true
sleep 1
/usr/libexec/qmi-proxy &
QMI_PROXY_PID=$!
sleep 2

# lpac binary has /tmp/lpac/build/ baked into its RPATH at compile time,
# so it can ONLY find its shared objects through that path. The persistent
# install lives in /usr/local/share/lpac/ and is bridged at boot via
# `lpac-setup-tmpdir.sh` (run by esim-prepare.service). If /tmp was wiped
# and the service hasn't run yet, do it inline — this is what historically
# made the script "just work" after install.sh + reboot.
if [ ! -x /tmp/lpac/build/src/lpac ] && [ -x /usr/local/bin/lpac-setup-tmpdir.sh ]; then
  /usr/local/bin/lpac-setup-tmpdir.sh
fi

LPAC_ROOT=/tmp/lpac/build
export LPAC_APDU=qmi LPAC_HTTP=curl
export APDU_INTERFACE=$LPAC_ROOT/driver/driver_apdu_qmi.so
export HTTP_INTERFACE=$LPAC_ROOT/driver/driver_http_curl.so
export LIBEUICC_DRIVER_LOADER_PATH=$LPAC_ROOT/driver
export LD_LIBRARY_PATH=$LPAC_ROOT/euicc:$LPAC_ROOT/utils:$LPAC_ROOT/driver:$LPAC_ROOT/cjson
export LPAC_APDU_QMI_DEVICE=$QMI_DEV
export LPAC_APDU_QMI_UIM_SLOT=2

lpac_out=$(timeout 20 "$LPAC_ROOT/src/lpac" profile enable "$PROFILE_AID" 2>&1) || true
kill $QMI_PROXY_PID 2>/dev/null || true
echo "  lpac: $lpac_out"

if echo "$lpac_out" | grep -q '"code":0'; then
  echo "[switch] profile enabled OK"
elif echo "$lpac_out" | grep -q 'not in disabled state'; then
  echo "[switch] profile already active"
else
  echo "[switch] lpac error — trying after DMS reset..."
  qmicli -d "$QMI_DEV" --dms-set-operating-mode=reset 2>&1 || true
  sleep 30
  usb_rebind
  wait_qmi
  pkill -f qmi-proxy 2>/dev/null || true; sleep 1
  /usr/libexec/qmi-proxy &
  QMI_PROXY_PID=$!; sleep 2
  export LPAC_APDU_QMI_DEVICE=$QMI_DEV
  lpac_out=$(timeout 20 "$LPAC_ROOT/src/lpac" profile enable "$PROFILE_AID" 2>&1) || true
  kill $QMI_PROXY_PID 2>/dev/null || true
  echo "  lpac retry: $lpac_out"
  if ! echo "$lpac_out" | grep -q '"code":0'; then
    echo "lpac enable failed"; exit 1
  fi
fi

# Step 4: DMS reset (always — modem must re-read eUICC)
echo "[switch] DMS reset..."
qmicli -d "$QMI_DEV" --dms-set-operating-mode=reset 2>&1 || true
echo "[switch] waiting 30s..."
sleep 30

# Step 5: USB rebind
echo "[switch] USB rebind..."
usb_rebind
wait_qmi

echo "[switch] slot:"
qmicli -d "$QMI_DEV" --uim-get-slot-status 2>&1 | grep ICCID || true

# Step 6: WDS start + routing
ip link set "$IFACE" down 2>/dev/null || true
echo Y > "/sys/class/net/${IFACE}/qmi/raw_ip" 2>/dev/null || true

wds_started=0; out=""
for attempt in $(seq 1 10); do
  echo "[switch] wds attempt $attempt apn=$APN..."
  echo Y > "/sys/class/net/${IFACE}/qmi/raw_ip" 2>/dev/null || true
  probe=$(qmicli -d "$QMI_DEV" --wds-get-current-settings 2>&1 || true)
  if echo "$probe" | grep -qE 'IPv4 address:[[:space:]]*[0-9]'; then
    wds_started=1; out="existing session"; break
  fi
  out=$(qmicli -d "$QMI_DEV" --wds-start-network="apn='${APN}',ip-type=4" --client-no-release-cid 2>&1) || true
  if echo "$out" | grep -q "Network started"; then wds_started=1; break; fi
  sleep 6
  d=$(resolve_qmi_dev) && QMI_DEV="$d"
done

[ "$wds_started" != 1 ] && { echo "WDS failed: $out"; exit 1; }

CID=$(echo "$out" | grep -oP "CID: '\K[0-9]+" || true)
[ -n "$CID" ] && echo "$CID" > "$CID_FILE"
sleep 2

settings=$(qmicli -d "$QMI_DEV" --wds-get-current-settings 2>&1)
IP=$(echo "$settings"  | awk -F: '/IPv4 address:/{gsub(/ /,"",$2); print $2}')
MASK=$(echo "$settings" | awk -F: '/IPv4 subnet mask:/{gsub(/ /,"",$2); print $2}')
GW=$(echo "$settings"  | awk -F: '/IPv4 gateway address:/{gsub(/ /,"",$2); print $2}')
MTU=$(echo "$settings" | awk -F: '/MTU:/{gsub(/ /,"",$2); print $2}')
[ -z "$IP" ] && { echo "no IPv4"; exit 1; }

PFX=$(python3 -c "import ipaddress; print(ipaddress.ip_network('0.0.0.0/${MASK}').prefixlen)")

ip link set "$IFACE" up
ip link set dev "$IFACE" mtu "${MTU:-1500}" 2>/dev/null || true
ip addr add "${IP}/${PFX}" dev "$IFACE" 2>/dev/null || true

SUBNET=$(python3 -c "import ipaddress; print(ipaddress.ip_network('${IP}/${PFX}', strict=False))")
ip route flush table "$TBL" 2>/dev/null || true
ip route add "$SUBNET" dev "$IFACE" src "$IP" table "$TBL"
ip route add default via "$GW" dev "$IFACE" table "$TBL"
while ip rule show | grep -q "lookup ${TBL}"; do ip rule del table "$TBL" 2>/dev/null || break; done
ip rule add from "$IP" table "$TBL" priority "$RULE_PRIO"

echo 2 > /proc/sys/net/ipv4/conf/"$IFACE"/rp_filter
echo 2 > /proc/sys/net/ipv4/conf/all/rp_filter

cat >"$STATE" <<EOF2
IP=$IP
PFX=$PFX
GW=$GW
TBL=$TBL
RULE_PRIO=$RULE_PRIO
IFACE=$IFACE
APN=$APN
PROFILE_AID=$PROFILE_AID
EOF2

echo ""
echo "[switch] DONE  ip=$IP/$PFX  gw=$GW  apn=$APN"
