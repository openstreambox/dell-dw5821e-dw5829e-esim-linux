#!/usr/bin/env bash
# esim-bearer-down.sh — tear down DW5829e bearer + policy rule.
# The host default route on the wired interface is never touched.

set -eu
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH:-}"
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

STATE=/run/esim-dw5829e.state
CID_FILE=/run/esim-wds-cid

if [ -f "$STATE" ]; then
  # shellcheck source=/dev/null
  . "$STATE"
else
  IP=""
  TBL=100
  RULE_PRIO=1000
  IFACE=wwan0
fi

[ -n "${IP:-}" ] && ip rule del from "$IP" table "$TBL" 2>/dev/null || true
ip rule  del table "$TBL"     2>/dev/null || true
ip route flush table "$TBL"   2>/dev/null || true
ip addr  flush dev "$IFACE"   2>/dev/null || true
ip link  set "$IFACE" down    2>/dev/null || true

# Stop QMI WDS network — auto-detect QMI device (cdc-wdm0 or cdc-wdm1)
QMI_DEV=""
if d=$(resolve_qmi_dev); then
  QMI_DEV="$d"
elif [ -e /dev/cdc-wdm1 ]; then
  QMI_DEV="/dev/cdc-wdm1"
elif [ -e /dev/cdc-wdm0 ]; then
  QMI_DEV="/dev/cdc-wdm0"
fi

if [ -n "$QMI_DEV" ] && [ -f "$CID_FILE" ]; then
  CID=$(cat "$CID_FILE")
  qmicli -d "$QMI_DEV" --wds-stop-network=4294967295 --client-cid="$CID" 2>/dev/null || true
  rm -f "$CID_FILE"
fi

# Also try mmcli disconnect as fallback
MI=$(mmcli -L 2>/dev/null | grep -oE '/Modem/[0-9]+' | head -1 | tr -dc '0-9' || true)
if [ -n "${MI:-}" ]; then
  mmcli -m "$MI" --simple-disconnect >/dev/null 2>&1 || true
fi

rm -f "$STATE"
