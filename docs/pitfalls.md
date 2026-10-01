# Pitfalls — how each failure looks and what fixed it

Everything below happened on production nodes between May and October 2026.

## 1. ModemManager

Grabs `/dev/cdc-wdm0` and the AT ports on enumeration; lpac then fails in ways
that look like eUICC faults. `systemctl disable --now ModemManager && systemctl
mask ModemManager`. A `wwan-up@.service` driven by udev and built around
`mmcli` (we had one) then fails on every modem re-enumeration — harmless, but
remove it rather than read its red lines in the journal.

## 2. DW5829e enumerates as MBIM

Configuration 2 by default; the QMI drivers need configuration 1. One udev
line fixes it ([`udev/78-dell-dw5829e.rules`](../udev/78-dell-dw5829e.rules)).

## 3. Radio left off after an interrupted `CFUN=0/1` (DW5821e)

A profile switch that dies between `AT+CFUN=0` and `AT+CFUN=1` (helper
timeout, agent restart, modem hiccup) leaves `+CFUN: 0`: the eUICC is
unpowered, `lpac profile list` is empty, `AT+CPIN?` → `+CME ERROR: 13`, the
chatscript aborts on `ATH → ERROR`. Because the documented CFUN cycle sits
*after* lpac in the switch flow, it is never reached and the node loops on
"profile not found" forever — ours did for 30 hours. Fix: check `AT+CFUN?`
before calling lpac and send `AT+CFUN=1` if it is 0 or 4
([`esim-switch-profile-ppp.sh`](../scripts/dw5821e-ppp/esim-switch-profile-ppp.sh), step 2b).
Rate-limit CFUN cycles: 170 of them in two hours once put the firmware into a
state where the modem stayed on the USB bus but answered nothing.

## 4. LTE attach with the previous operator's APN (DW5821e)

The modem rejects `AT+CGDCONT` while `CFUN=0` and, at `CFUN=1`, attaches with
the APN context 1 held before. The classic chatscript sets `CGDCONT=1` only
right before `ATD*99#`, after the attach, and the bearer keeps the stale APN.
How it looked per operator with the wrong APN: one black-holed everything,
one answered TCP with `RST` and dropped ICMP, one redirected every HTTP
request to its "wrong APN / balance" portal. Diagnose with `AT+CGCONTRDP=1` on
the second AT port — the APN field is the attach APN, and the PPP address
should equal the context address. Fix:
[`esim-ensure-apn.sh`](../scripts/dw5821e-ppp/esim-ensure-apn.sh) —
`CGDCONT=1` with the radio on, compare with `+CGCONTRDP`, `AT+CGATT=0` /
`AT+CGATT=1` on mismatch. The bug hid for months because the other operators'
profile switches kept failing at lpac, leaving the working operator's APN in
place; the first successful foreign switch broke every operator at once.

## 5. "Bearer refresh" that is a USB unbind/rebind (DW5829e)

Our refresh calls the full bring-up, which unbinds and rebinds the modem on
USB: it vanishes from `/dev` for 10–20 s and dmesg shows `qmi_wwan …
register` every minute if the refresh is triggered every minute. A health
ladder tuned to "one failed 4-second probe every 20 s → refresh" produced
exactly that: tasks in flight died in the rebind window, the next probe hit
the next window, operator switches could not complete inside their timeout,
and a one-shot "is the modem on the USB bus?" check landed inside a rebind and
opened a one-hour circuit breaker on a healthy modem. Settled values: probe
every 60 s, 8 s timeout, three consecutive failures before a refresh, and
"modem absent" only after four checks over ~30 s.

## 6. Recovery ladder

probe → bearer refresh → profile re-switch → modem reset, with per-rung
cooldowns (60 s / 5 min / 15 min), at most three modem resets per hour, then an
hour of silence. While an uplink is recovering, do not dispatch work on it.
With a carrier-side block (next item) the ladder cannot help and will reset the
modem three times an hour indefinitely — cap it or disable the uplink.

## 7. Carrier-side states look exactly like modem faults

Registered (`+CEREG: 0,1`), PDP active (`+CGACT: 1,1`), IP assigned, PPP up,
and zero payload. Before touching the modem:

- fetch the operator's own portal from inside the namespace — if
  `login.<operator>` or `balance.<operator>` answers while `1.1.1.1` does not,
  the subscriber is in a walled state (cooling period, captcha, suspended
  service), not the modem;
- `AT+CGCONTRDP=1` for the attach APN (item 4);
- `AT+CMGL="ALL"` (set `AT+CMGF=1`, `AT+CSCS="UCS2"`) — operators often SMS
  the reason;
- USSD balance requests (`AT+CUSD=1,"*100#",15`, UCS2-encoded under
  `CSCS="UCS2"`) may be refused by the network (`+CUSD: 5`); that itself is a
  hint;
- the same operators working on another node with other SIMs rules out an
  operator-wide outage.

## 8. Measure from the namespace or do not measure

If a switch fails and the measurement runs anyway, it silently runs over the
wired uplink and gets recorded under the operator's name. Make the switch
raise, check the namespace exists before dispatch, and refuse to run a
mobile measurement without it. We found weeks of "mobile" successes that were
wire.

## 9. Small things that cost a deploy each

- Stale `/var/lock/LCK..ttyUSB0` after a dead pppd → the next dial fails.
- `lpac` left holding the AT port → `pppd` starves; `fuser -k` it.
- A peer file with the wrong device path (`/dev/ttyUSB0` after the udev
  rename) → pppd "unrecognized option"; regenerate the peer from the template
  on every bring-up instead of editing it.
- Writing to the ppp stdout pipe and exiting immediately truncates output;
  ask the shell, not the pipe, when the output matters.
