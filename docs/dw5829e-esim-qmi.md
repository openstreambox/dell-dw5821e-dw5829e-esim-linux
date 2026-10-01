# Dell DW5829e-eSIM over QMI

USB `413c:81e4`, Qualcomm Snapdragon X20. The eUICC sits on **UIM slot 2**.

## 1. USB configuration

The modem enumerates in configuration 2 (MBIM) by default. lpac's QMI APDU
driver and `qmicli` WDS sessions need configuration 1 (QMI), which exposes
`/dev/cdc-wdm0` through `qmi_wwan` and `wwan0`. [`udev/78-dell-dw5829e.rules`](../udev/78-dell-dw5829e.rules)
pins it at enumeration time:

```
ACTION=="add", SUBSYSTEM=="usb", ATTR{idVendor}=="413c", ATTR{idProduct}=="81e4", ATTR{bConfigurationValue}=="2", ATTR{bConfigurationValue}="1"
```

Verify: `cat /sys/bus/usb/devices/<bus-port>/bConfigurationValue` → `1`, and
`ls /dev/cdc-wdm*` shows the control device.

## 2. ModemManager

Disable and mask it. With MM running, the QMI client IDs are taken and lpac
fails to open an APDU channel with errors that look like eUICC faults.

## 3. lpac over QMI

Run lpac through `qmi-proxy` (ships with libqmi) so the control device can be
shared with `qmicli`. The `lpac-qmi` wrapper we use does, in order: stop MM
(belt and braces), USB unbind/rebind of the modem, start `qmi-proxy`, run lpac
with the QMI APDU backend on `/dev/cdc-wdm0` and UIM slot 2. See
[`lpac.md`](lpac.md) for the backend/environment details and the RPATH note.

```
lpac-qmi profile list
lpac-qmi profile enable <AID>
lpac-qmi profile download -s <SM-DP+ host> -m <matching id>
```

## 4. Switching a profile — the full cycle

[`scripts/dw5829e-qmi/esim-switch-profile.sh <AID> <APN>`](../scripts/dw5829e-qmi/esim-switch-profile.sh):

1. stop the WDS session (`esim-bearer-down.sh`);
2. USB unbind/rebind so nothing holds the control device;
3. `lpac profile disable <current>` / `lpac profile enable <target>`;
4. **DMS reset** — `qmicli -d /dev/cdc-wdm0 --dms-set-operating-mode=reset`.
   The modem re-enumerates on USB; wait for it (≈30 s) instead of polling the
   device node that is about to disappear;
5. USB rebind again, then start the data session (step 5 below);
6. routing + network namespace.

A switch takes 40–60 s. Do not call lpac while a DMS reset is in flight.

## 5. Data session (WDS)

[`esim-bearer-up.sh <APN>`](../scripts/dw5829e-qmi/esim-bearer-up.sh):

```
echo Y > /sys/class/net/wwan0/qmi/raw_ip      # raw-IP mode, interface down first
qmicli -d /dev/cdc-wdm0 -p --wds-start-network="apn=<APN>,ip-type=4" --client-no-release-cid
qmicli -d /dev/cdc-wdm0 -p --wds-get-current-settings   # IP, gateway, DNS, MTU
```

Assign the address to `wwan0`, add the default route **in a dedicated routing
table** (we use table 100) with an `ip rule from <wwan ip> lookup 100`, never
in `main`: the box keeps its wired default. The session state (IP, prefix,
gateway, table, APN, profile) is written to `/run/esim-dw5829e.state` so the
other scripts and the namespace helper can find it.

`esim-bearer-refresh.sh` restarts the session for a carrier-side idle timeout
(NAT/PDP expiry after minutes of silence). **Caveat:** our refresh script
calls `esim-bearer-up.sh`, which does a full USB unbind/rebind — the modem
disappears from `/dev` for 10–20 s. A watchdog that treats that window as
"modem gone" will escalate on its own side effect; see
[`pitfalls.md`](pitfalls.md#5).

## 6. Network namespace

[`scripts/common/netns-esim-up.sh`](../scripts/common/netns-esim-up.sh) creates
namespace `esim` with a veth pair (`10.200.200.0/30`), a default route through
the host side, SNAT on the host to the modem address, and a resolv.conf for the
namespace. Anything run with `ip netns exec esim …` uses the mobile uplink and
nothing else — the clean way to measure "what does this operator pass" without
touching the host's routing.
