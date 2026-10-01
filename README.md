# Dell DW5821e eSIM and DW5829e eSIM on Linux

Working notes, scripts and udev/systemd glue for running the two Dell
**Snapdragon X20** LTE modems with their **built-in eUICC (eSIM)** on a plain
Linux box: downloading and switching eSIM profiles with
[lpac](https://github.com/estkme-group/lpac), bringing up data sessions over
**QMI** (DW5829e) or **PPP** (DW5821e), isolating each mobile uplink in its own
network namespace with policy routing, and recovering from the failure modes
these modems actually exhibit in production.

Everything here is used in production by
[Freedom Checker](https://freedomchecker.ateo.digital/) — a measurement network
inside Russia that checks, from real subscriber connections of several mobile
operators, which VPN protocols and proxies still work — since May 2026.
No Dell firmware or proprietary binaries are redistributed: the kernel already
has the drivers; this repository is the userspace that was missing.

| | DW5829e-eSIM | DW5821e-eSIM |
|---|---|---|
| USB ID | `413c:81e4` | `413c:81e0` (`81d7` is the non-eSIM DW5821e) |
| Chipset / module | Qualcomm Snapdragon X20 | Qualcomm Snapdragon X20, Foxconn T77W968 |
| Firmware seen | — | `T77W968.F1.0.0.5.2.GC.013` (2021-05) |
| Kernel drivers | `qmi_wwan`, `cdc_mbim`, `option` | `cdc_mbim`, `option`, `qmi_wwan` |
| USB configuration | **must be 1 (QMI)**, default is 2 (MBIM) — [udev rule](udev/78-dell-dw5829e.rules) | default |
| eUICC access (lpac APDU backend) | `qmi` via `/dev/cdc-wdm0` + `qmi-proxy`, UIM slot 2 | `at_csim` over the AT serial port |
| Data path | QMI WDS, `wwan0` in raw-IP mode | `pppd` + `ATD*99#` over the AT port |
| Profile switch | lpac enable → DMS reset (`qmicli --dms-set-operating-mode=reset`) | lpac enable → `AT+CFUN=0` / `AT+CFUN=1` |
| Tested on | Ubuntu 24.04, kernel 6.8, libqmi 1.36, libmbim 1.32, pppd 2.4.9 | same |

## What is in here

| Path | Purpose |
|---|---|
| [`docs/dw5829e-esim-qmi.md`](docs/dw5829e-esim-qmi.md) | DW5829e: USB config, qmi-proxy, lpac over QMI, WDS session, routing |
| [`docs/dw5821e-esim-ppp.md`](docs/dw5821e-esim-ppp.md) | DW5821e: AT port map, lpac over `AT+CSIM`, CFUN cycle, PPP peer and chatscript |
| [`docs/lpac.md`](docs/lpac.md) | Building/installing lpac for both backends, the RPATH symlink trick, environment variables |
| [`docs/pitfalls.md`](docs/pitfalls.md) | **Read this first.** Every failure mode we hit, how it looks from outside and the fix |
| [`scripts/dw5829e-qmi/`](scripts/dw5829e-qmi/) | Profile switch, bearer up/down/refresh, bootstrap for the QMI modem |
| [`scripts/dw5821e-ppp/`](scripts/dw5821e-ppp/) | The same for the PPP modem, plus `esim-ensure-apn.sh` |
| [`scripts/common/`](scripts/common/) | Per-uplink network namespace with SNAT, lpac RPATH setup, profile download helper |
| [`udev/`](udev/) | Stable `/dev/dw5821e-*` names for the four serial ports; USB config pin for DW5829e |
| [`systemd/`](systemd/) | One-shots that recreate the lpac symlink layout at boot (QMI and AT builds) |
| [`examples/uplinks.example.yaml`](examples/uplinks.example.yaml) | How uplinks (profiles × APNs) are declared for the bootstrap script |

## The three things nobody tells you

1. **ModemManager must be disabled and masked.** It grabs the QMI/MBIM device
   and the AT ports the moment the modem enumerates, and lpac's APDU channel
   silently fails behind it. Both modems run fine without it: the scripts here
   do the bearer and routing work themselves.
2. **Switching an eSIM profile is not enough — the modem must re-read the
   eUICC.** DW5829e: a DMS reset (the modem re-enumerates on USB, wait for it).
   DW5821e: `AT+CFUN=0` then `AT+CFUN=1`. If anything dies between the two,
   the radio stays off: the eUICC is unpowered, `lpac profile list` returns
   nothing, `AT+CPIN?` answers `+CME ERROR: 13`, and a PPP chatscript aborts on
   `ATH → ERROR`. Check `AT+CFUN?` *before* calling lpac
   ([`esim-switch-profile-ppp.sh`](scripts/dw5821e-ppp/esim-switch-profile-ppp.sh), step 2b).
3. **On the DW5821e the LTE attach uses whatever APN context 1 held *before*
   `AT+CFUN=1`** — i.e. the previous operator's APN — and the modem rejects
   `AT+CGDCONT` while `CFUN=0`. The usual chatscript (`AT+CGDCONT=1,…` right
   before `ATD*99#`) runs after the attach and never changes the bearer. The
   result looks like a carrier problem: registered, PDP active, IP assigned,
   zero payload (one operator black-holes, another injects RST, a third serves
   its "wrong APN" portal). `+CGCONTRDP=1` shows the foreign APN.
   [`esim-ensure-apn.sh`](scripts/dw5821e-ppp/esim-ensure-apn.sh) sets the APN
   with the radio on, compares it with the active context and does a
   `AT+CGATT=0` / `AT+CGATT=1` re-attach when they disagree — all documented
   3GPP commands, 14 s.

More in [`docs/pitfalls.md`](docs/pitfalls.md): the "bearer refresh" that is
really a USB unbind/rebind, a recovery ladder that looped the modem into a
USB-zombie state, and how to tell a carrier-side block from a modem fault.

## Quick start

```bash
# both modems
systemctl disable --now ModemManager && systemctl mask ModemManager
cp udev/*.rules /etc/udev/rules.d/ && udevadm control --reload-rules && udevadm trigger
cp scripts/common/lpac-setup-tmpdir*.sh /usr/local/bin/ && cp systemd/esim-prepare*.service /etc/systemd/system/
systemctl enable --now esim-prepare.service        # DW5829e; esim-prepare-at.service for DW5821e

# DW5829e (QMI): list and switch profiles, start the data session
lpac-qmi profile list
scripts/dw5829e-qmi/esim-switch-profile.sh <PROFILE_AID> <APN>

# DW5821e (PPP)
export LPAC_APDU=at_csim LPAC_APDU_AT_DEVICE=/dev/dw5821e-at LPAC_HTTP=curl
lpac profile list
scripts/dw5821e-ppp/esim-switch-profile-ppp.sh <PROFILE_AID> <APN>

# either: put the uplink into its own namespace (default route via the modem, SNAT)
scripts/common/netns-esim-up.sh esim
ip netns exec esim curl -s https://example.com/
```

`<PROFILE_AID>` is the ISD-P AID printed by `lpac profile list`
(`a0000005591010ffffffff89000011xx`).

## Used by

- [Freedom Checker](https://freedomchecker.ateo.digital/) — which VPN and
  proxy protocols work in Russia right now, measured per mobile operator from
  these modems ([methodology](https://freedomchecker.ateo.digital/methodology/),
  [open dataset](https://freedomcomedelivery.github.io/ateo.digital/)).
- [Ateo Digital](https://ateo.digital/) — the project hub.

Contributions welcome, especially other Snapdragon X20 modules (Foxconn
T77W968 appears under several OEM names) and the DW5821e in MBIM mode, which
we did not need and did not test.

## License

Scripts and documentation: [MIT](LICENSE). lpac itself is AGPL-3.0 and is
not included — see [`docs/lpac.md`](docs/lpac.md) for how it was built.

---

## Кратко по-русски

Dell DW5829e-eSIM (QMI) и DW5821e-eSIM (PPP, Foxconn T77W968) на Linux со
встроенной eSIM: скачивание и переключение профилей через lpac, сессии данных
по QMI WDS или PPP, отдельный network namespace с policy routing на каждый
мобильный аплинк и восстановление после реальных отказов. Три главных грабли:
ModemManager надо выключить и замаскировать; после смены профиля модему нужен
reset (DMS reset / `AT+CFUN=0/1`), и прерванный `CFUN=0` оставляет радио
выключенным; DW5821e при `CFUN=1` цепляется к сети с APN *предыдущего*
оператора, потому что `AT+CGDCONT` при `CFUN=0` отвергается, а chatscript ставит
APN уже после attach — лечится `esim-ensure-apn.sh` (`CGATT=0/1`). Всё это в
продакшене у [Freedom Checker](https://freedomchecker.ateo.digital/) с мая 2026.
