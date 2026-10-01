#!/usr/bin/env bash
# esim-bearer-refresh.sh — kick the DW5829e bearer after an idle NAT/PDP
# expiry (wwan0 TX grows but RX stays flat).
#
# Performs a QMI WDS stop + start on the SAME slot and APN — no slot
# switch, no LTE re-attach — and then re-applies the policy-routing +
# netns SNAT via the usual helpers. Typically ~3-4s.
#
# usage:  sudo ./esim-bearer-refresh.sh [APN]

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

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
STATE=/run/esim-dw5829e.state
CID_FILE=/run/esim-wds-cid
QMI_DEV=""
if d=$(resolve_qmi_dev); then
  QMI_DEV="$d"
else
  QMI_DEV="$(ls /dev/cdc-wdm* 2>/dev/null | head -1)"
fi
[ -z "$QMI_DEV" ] && { echo "no QMI device (/dev/cdc-wdm*) found"; exit 1; }

if [ -f "$STATE" ]; then
  # shellcheck source=/dev/null
  . "$STATE"
fi
APN="${1:-${APN:-internet}}"

echo "[refresh] stopping WDS network"
if [ -f "$CID_FILE" ]; then
  CID=$(cat "$CID_FILE")
  qmicli -d "$QMI_DEV" --wds-stop-network=4294967295 --client-cid="$CID" 2>/dev/null || true
  rm -f "$CID_FILE"
fi
sleep 2

echo "[refresh] re-starting bearer via esim-bearer-up.sh apn=$APN"
"$SCRIPT_DIR/esim-bearer-up.sh" "$APN"

if [ -f "$STATE" ]; then
  . "$STATE"
fi

if [ -x "$SCRIPT_DIR/netns-esim-up.sh" ] && ip netns list 2>/dev/null | awk '{print $1}' | grep -qx esim; then
  "$SCRIPT_DIR/netns-esim-up.sh" esim >/dev/null || true
fi

SRC="${IP:-}"
if [ -z "$SRC" ]; then
  echo "[refresh] no bearer src IP after reconnect" >&2
  exit 2
fi
code=$(curl -sk -o /dev/null --interface "$SRC" --max-time 6 \
           -w '%{http_code}' https://ya.ru/ 2>/dev/null || echo 000)
if [ "$code" = "000" ]; then
  echo "[refresh] FAILED (ya.ru code=000 src=$SRC)" >&2
  exit 2
fi
echo "[refresh] OK ya.ru code=$code src=$SRC"
