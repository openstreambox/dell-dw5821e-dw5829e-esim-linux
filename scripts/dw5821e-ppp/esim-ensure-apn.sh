#!/usr/bin/env bash
# esim-ensure-apn.sh <APN> — make sure the LTE attach context (cid 1) really
# carries <APN> before PPP is started.
#
# Why this exists (the DW5821e node, 2026-10-01): the DW5821e refuses AT+CGDCONT while
# the radio is off (+CFUN: 0 → ERROR) and, at AT+CFUN=1, attaches with whatever
# cid 1 held before — i.e. the PREVIOUS operator's APN. The PPP chatscript sets
# CGDCONT=1 only right before ATD*99#, after the attach, so the bearer keeps
# the foreign APN: a Beeline IMSI sat on internet.mts.ru (every HTTP answered
# 302 to balance.beeline.ru/?a=internet.beeline.ru), MTS sat on
# internet.beeline.ru. Measured, not theorised: +CGCONTRDP=1 showed it.
#
# Fix, all documented 3GPP AT: set CGDCONT=1 with the radio ON, compare with
# +CGCONTRDP=1, and if the active context carries another APN do a
# detach/attach (AT+CGATT=0 → AT+CGATT=1): the default bearer is then
# re-established with the new APN (verified live: internet.beeline.ru →
# internet.mts.ru in 8 s). Uses the spare AT port (/dev/dw5821e-at2 from
# 78-dell-dw5821e.rules) so it never competes with pppd/lpac for the primary
# port; falls back to the primary port only when it is free. Never fails the
# caller: a warning is printed and PPP is attempted anyway.
set -u
APN="${1:?usage: $0 <APN>}"
if [ -c /dev/dw5821e-at2 ]; then
  PORT=/dev/dw5821e-at2
elif [ -c /dev/dw5821e-at ] && ! fuser /dev/dw5821e-at >/dev/null 2>&1; then
  PORT=/dev/dw5821e-at
elif [ -c /dev/ttyUSB1 ]; then
  PORT=/dev/ttyUSB1
else
  echo "[ensure-apn] no free AT port — skipping"; exit 0
fi
timeout 75s python3 - "$PORT" "$APN" <<'PY' || echo "[ensure-apn] helper timed out — continuing"
import sys, time, re
import serial
port_name, apn = sys.argv[1], sys.argv[2]
port = serial.Serial(port_name, 115200, timeout=2, write_timeout=3)
time.sleep(0.3)
def at(cmd, wait=1.5):
    port.reset_input_buffer()
    try:
        port.write((cmd + "\r").encode())
    except serial.SerialTimeoutException:
        return ""
    time.sleep(wait)
    return port.read(4096).decode(errors="replace")
def ctx_apn():
    r = at("AT+CGCONTRDP=1", 2)
    m = re.search(r"\+CGCONTRDP:\s*1,\d+,([^,\s]*)", r)
    return (m.group(1) if m else "").strip()
r = at('AT+CGDCONT=1,"IP","%s"' % apn, 2)
print("[ensure-apn] CGDCONT=1 %s: %s" % (apn, " ".join(r.split())[:40]))
cur = ctx_apn()
if cur.lower() == apn.lower():
    print("[ensure-apn] attach context already on %s" % apn); port.close(); sys.exit(0)
print("[ensure-apn] attach context on '%s', want '%s' — detach/attach" % (cur or "-", apn))
print("[ensure-apn] CGATT=0:", " ".join(at("AT+CGATT=0", 4).split())[:20])
t0 = time.time()
print("[ensure-apn] CGATT=1:", " ".join(at("AT+CGATT=1", 5).split())[:20])
for _ in range(15):
    if "+CGATT: 1" in at("AT+CGATT?", 1):
        break
    time.sleep(2)
cur = ctx_apn()
print("[ensure-apn] attached in %.0fs, context now '%s' (%s)" % (time.time() - t0, cur or "-", "ok" if cur.lower() == apn.lower() else "WARNING: still not the target APN"))
port.close()
PY
exit 0
