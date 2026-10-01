#!/usr/bin/env bash
# esim-bearer-up.sh — bring up the DW5829e data bearer for the currently
# active eSIM slot via QMI WDS and install policy-routing rules.
#
# Uses qmicli --wds-start-network directly because mmcli simple-connect
# does not properly activate the QMI data path in USB config=1.
#
# Leaves the host default route (the wired interface) untouched.
#
# usage:  sudo ./esim-bearer-up.sh [APN]

set -euo pipefail
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH:-}"
APN="${1:-internet}"
TBL=100
RULE_PRIO=1000
IFACE=wwan0
STATE=/run/esim-dw5829e.state
CID_FILE=/run/esim-wds-cid

if [ "$(id -u)" -ne 0 ]; then
  exec sudo -E "$0" "$@"
fi

resolve_qmi_dev() {
  local d
  for d in /dev/cdc-wdm*; do
    [ -c "$d" ] || continue
    if qmicli -d "$d" --uim-get-slot-status >/dev/null 2>&1; then
      printf '%s' "$d"
      return 0
    fi
  done
  return 1
}

systemctl stop ModemManager 2>/dev/null || true
sleep 1

# Find the modem's USB bus path
BUSPATH=""
for p in /sys/bus/usb/devices/*/idVendor; do
  [ "$(cat "$p" 2>/dev/null)" = "413c" ] || continue
  [ "$(cat "${p%idVendor}idProduct" 2>/dev/null)" = "81e4" ] || continue
  BUSPATH="${p%/idVendor}"
done
BUSDEV=$(basename "${BUSPATH:-none}")

# USB unbind/rebind guarantees a clean QMI data path after profile switches.
if [ -n "$BUSPATH" ]; then
  echo "[*] USB rebind $BUSDEV for clean QMI state"
  echo "$BUSDEV" > /sys/bus/usb/drivers/usb/unbind 2>/dev/null || true
  sleep 3
  echo "$BUSDEV" > /sys/bus/usb/drivers/usb/bind 2>/dev/null || true
  sleep 3
  echo 1 > "$BUSPATH/bConfigurationValue" 2>/dev/null || true
  sleep 5
fi

# raw_ip MUST be set before WDS start, while interface is still down.
ip link set "$IFACE" down 2>/dev/null || true
echo Y > "/sys/class/net/${IFACE}/qmi/raw_ip" 2>/dev/null || true

# Wait for QMI readiness (after modem reset, QMI CTL needs 5-15s to stabilize)
echo "[*] waiting for QMI readiness..."
QMI_DEV=""
for attempt in 1 2 3 4 5 6 7 8 9 10 11 12 13 14; do
  if d=$(resolve_qmi_dev); then
    QMI_DEV="$d"
    echo "[*] QMI ready on $QMI_DEV (attempt $attempt)"
    break
  fi
  [ "$attempt" -eq 14 ] && { echo "QMI not ready after 14 attempts"; exit 1; }
  sleep 3
done

# WDS start with retry loop — after profile switch or DMS reset the modem
# may need several seconds to register on the network before WDS succeeds.
wds_started=0
out=""
for attempt in 1 2 3 4 5 6 7 8; do
  echo "[*] wds-start-network attempt $attempt apn=$APN dev=$QMI_DEV..."
  echo Y > "/sys/class/net/${IFACE}/qmi/raw_ip" 2>/dev/null || true
  # Check if a session is already up (auto-connect after DMS reset)
  probe=$(qmicli -d "$QMI_DEV" --wds-get-current-settings 2>&1 || true)
  if echo "$probe" | grep -qE 'IPv4 address:[[:space:]]*[0-9]'; then
    echo "[*] WDS already has IPv4 (skipping start)"
    wds_started=1
    out="Network started (existing session)"
    break
  fi
  out=$(qmicli -d "$QMI_DEV" \
    --wds-start-network="apn='${APN}',ip-type=4" \
    --client-no-release-cid 2>&1) || true
  echo "  $out"
  if echo "$out" | grep -q "Network started"; then
    wds_started=1
    break
  fi
  echo "[*] WDS not ready, sleeping 5s..."
  sleep 5
  if d=$(resolve_qmi_dev); then
    QMI_DEV="$d"
  fi
done

if [ "$wds_started" != 1 ]; then
  echo "WDS start failed after $attempt attempts; last output: $out"
  exit 1
fi

CID=$(echo "$out" | grep -oP "CID: '\K[0-9]+" || true)
[ -n "$CID" ] && echo "$CID" > "$CID_FILE"

sleep 2

wds_settings=$(qmicli -d "$QMI_DEV" --wds-get-current-settings 2>&1)

IP=$(echo "$wds_settings"  | awk -F: '/IPv4 address:/{gsub(/ /,"",$2); print $2}')
MASK=$(echo "$wds_settings" | awk -F: '/IPv4 subnet mask:/{gsub(/ /,"",$2); print $2}')
GW=$(echo "$wds_settings"  | awk -F: '/IPv4 gateway address:/{gsub(/ /,"",$2); print $2}')
MTU=$(echo "$wds_settings" | awk -F: '/MTU:/{gsub(/ /,"",$2); print $2}')
[ -z "$IP" ] && { echo "no IPv4 from WDS"; exit 1; }

PFX=$(python3 -c "import ipaddress; print(ipaddress.ip_network('0.0.0.0/${MASK}').prefixlen)")
echo "[*] ip=$IP/$PFX gw=$GW mtu=$MTU"

ip link set "$IFACE" up
ip link set dev "$IFACE" mtu "${MTU:-1500}" 2>/dev/null || true

if ! ip -4 addr show dev "$IFACE" | grep -qF "inet ${IP}/${PFX}"; then
  ip addr flush dev "$IFACE" 2>/dev/null || true
  ip addr add "${IP}/${PFX}" dev "$IFACE"
fi

SUBNET=$(python3 -c "import ipaddress; print(ipaddress.ip_network('${IP}/${PFX}', strict=False))")

ip route flush table "$TBL" 2>/dev/null || true
ip route add "$SUBNET" dev "$IFACE" src "$IP" table "$TBL"
ip route add default via "$GW" dev "$IFACE" table "$TBL"

# Clean stale rules, add fresh
while ip rule show | grep -q "lookup ${TBL}"; do
  ip rule del table "$TBL" 2>/dev/null || break
done
ip rule add from "$IP" table "$TBL" priority "$RULE_PRIO"

echo 2 > /proc/sys/net/ipv4/conf/"$IFACE"/rp_filter
echo 2 > /proc/sys/net/ipv4/conf/all/rp_filter

cat >"$STATE" <<EOF
IP=$IP
PFX=$PFX
GW=$GW
TBL=$TBL
RULE_PRIO=$RULE_PRIO
IFACE=$IFACE
APN=$APN
EOF

echo
echo "[*] DONE  ip=$IP/$PFX  gw=$GW"
echo "    main default: $(ip -4 route show default | head -1)"
echo "    test: curl --interface $IP https://ya.ru/"
