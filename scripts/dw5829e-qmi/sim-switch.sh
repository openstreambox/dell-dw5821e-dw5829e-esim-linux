#!/usr/bin/env bash
# sim-switch.sh <slot> [apn] — atomic eSIM/SIM slot switch on DW5829e.
#
# 1. Tears down the old bearer (no-op if already down).
# 2. Stops ModemManager, asks QMI to switch the UIM slot.
# 3. Brings up the bearer on the new slot.
# 4. Re-runs netns-esim-up.sh so the SNAT rule points at the new bearer IP.
#
# Does not touch the host default route.

set -eu
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH:-}"
SLOT="${1:?slot required (1 or 2)}"
APN="${2:-}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

if [ "$(id -u)" -ne 0 ]; then
  exec sudo -E "$0" "$@"
fi

# Auto-detect QMI device (Dell DW5829e may enumerate as cdc-wdm0 or cdc-wdm1)
QMI_DEV="$(ls /dev/cdc-wdm* 2>/dev/null | head -1)"
[ -z "\$QMI_DEV" ] && { echo "no QMI device (/dev/cdc-wdm*) found"; exit 1; }

"${SCRIPT_DIR}/esim-bearer-down.sh" || true

systemctl stop ModemManager 2>/dev/null || true
sleep 1

# Ensure USB config=1 (QMI mode)
for p in /sys/bus/usb/devices/*/idVendor; do
  [ "$(cat "$p" 2>/dev/null)" = "413c" ] || continue
  [ "$(cat "${p%idVendor}idProduct" 2>/dev/null)" = "81e4" ] || continue
  BUSPATH="${p%/idVendor}"
  cur=$(cat "$BUSPATH/bConfigurationValue" 2>/dev/null || echo "?")
  if [ "$cur" != "1" ]; then
    echo "[sim-switch] switching USB config ${cur} -> 1 (QMI)"
    echo 1 > "$BUSPATH/bConfigurationValue"
    sleep 3
  fi
done

qmicli -d "$QMI_DEV" --uim-switch-slot="$SLOT" || {
  echo "qmicli slot switch failed" >&2
}
sleep 8

if [ -n "$APN" ]; then
  "${SCRIPT_DIR}/esim-bearer-up.sh" "$APN"
else
  "${SCRIPT_DIR}/esim-bearer-up.sh"
fi

"${SCRIPT_DIR}/netns-esim-up.sh"
