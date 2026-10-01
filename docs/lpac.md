# lpac on these modems

[lpac](https://github.com/estkme-group/lpac) (AGPL-3.0, not redistributed
here) talks to the eUICC through an APDU backend and to the SM-DP+ through an
HTTP backend. Two builds are needed for the two modems:

| modem | APDU backend | device | notes |
|---|---|---|---|
| DW5829e-eSIM | `qmi` (`driver_apdu_qmi.so`) | `/dev/cdc-wdm0` via `qmi-proxy`, UIM slot 2 | USB config 1 required |
| DW5821e-eSIM | `at_csim` | `/dev/dw5821e-at` | port must be exclusively free |

HTTP backend: `curl` (`LPAC_HTTP=curl`).

```
# DW5821e
export LPAC_APDU=at_csim LPAC_APDU_AT_DEVICE=/dev/dw5821e-at LPAC_HTTP=curl
lpac profile list
lpac profile download -s <SM-DP+ host> -m <matching id>
lpac profile enable <AID>
lpac notification process -a      # send pending notifications to the SM-DP+
```

Check the variable names against the lpac version you build — they have
changed between releases; `lpac --help` and the upstream README are the source
of truth.

## The RPATH symlink layout

Our binaries were built in `/tmp/lpac/build` (QMI) and `/tmp/lpac-build/build`
(AT) and carry that path in their RPATH, so the shared objects are installed
once under `/usr/local/share/lpac` (QMI) or `/usr/local/share/lpac-at` (AT) and
[`scripts/common/lpac-setup-tmpdir.sh`](../scripts/common/lpac-setup-tmpdir.sh) /
[`lpac-setup-tmpdir-at.sh`](../scripts/common/lpac-setup-tmpdir-at.sh)
recreate the expected symlink tree at boot
([`systemd/esim-prepare.service`](../systemd/esim-prepare.service) /
[`esim-prepare-at.service`](../systemd/esim-prepare-at.service)); `/tmp` is
volatile, so a reboot without the unit leaves lpac unable to load its drivers.
If you build lpac yourself, set `CMAKE_INSTALL_RPATH` (or install into the
system library path) and skip this.

## Profiles and AIDs

`lpac profile list` prints each profile's ISD-P AID
(`a0000005591010ffffffff89000011xx`), ICCID and state. The scripts identify
profiles by AID, never by ICCID, and the uplink declaration
([`examples/uplinks.example.yaml`](../examples/uplinks.example.yaml)) pairs
each AID with its APN. Keep matching IDs and activation codes out of version
control: a matching ID is a one-time credential for downloading the profile.
