#!/usr/bin/env bash
# _ppp-peer-template.sh — shared helpers for managing pppd peer files
# on DW5821e (PPP) nodes.
#
# Source from another script:
#   . "$(dirname "$0")/_ppp-peer-template.sh"
#
# Public functions:
#   write_ppp_peer    <peer-name> <apn>
#   validate_ppp_peer <peer-name>          (rc 0 if valid, 1 otherwise)
#   ensure_ppp_peer   <peer-name> <apn>    (validate, regenerate if broken)
#
# This exists because today (2026-05-12) on the DW5821e node a peer file got into a
# state where pppd rejected it with "unrecognized option '/dev/ttyUSB0'".
# Recovery-ladder then walked 7 escalations without ever fixing the root
# cause (a broken text file). ensure_ppp_peer at the start of every
# bring-up path makes this self-healing — broken peer = regenerated peer.

# Stable per-interface symlink provided by udev rule
# `78-dell-dw5821e.rules`. Falls back to the legacy ttyUSB0 if the
# rule isn't installed yet (e.g. pre-migration nodes), so this stays
# safe to deploy ahead of the udev rule. Once the symlink exists,
# both paths resolve to the same FD.
if [ -c /dev/dw5821e-at ]; then
    : "${SERIAL:=/dev/dw5821e-at}"
else
    : "${SERIAL:=/dev/ttyUSB0}"
fi

# Write a clean peer + matching chatscript. Overwrites any existing files.
write_ppp_peer() {
    local peer="$1" apn="$2"
    if [ -z "$peer" ] || [ -z "$apn" ]; then
        echo "[ppp-peer] write_ppp_peer: peer and apn are required" >&2
        return 2
    fi
    mkdir -p /etc/ppp/peers /etc/ppp/chatscripts

    cat > "/etc/ppp/chatscripts/$peer" <<EOF_CHAT
ABORT "BUSY"
ABORT "NO CARRIER"
ABORT "ERROR"
"" AT
OK ATH
OK AT+CGDCONT=1,"IP","$apn"
OK ATD*99#
CONNECT ""
EOF_CHAT

    cat > "/etc/ppp/peers/$peer" <<EOF_PEER
$SERIAL
115200
connect "/usr/sbin/chat -v -f /etc/ppp/chatscripts/$peer"
noauth
usepeerdns
noipdefault
nopcomp
noaccomp
novj
nobsdcomp
nodeflate
maxfail 5
holdoff 10
EOF_PEER
}

# Returns 0 if the peer file looks like one we wrote with the CURRENT
# $SERIAL, 1 otherwise. Matching the device path exactly means old peer
# files that point at /dev/ttyUSB0 will be regenerated automatically
# on the first bring-up after the udev migration to /dev/dw5821e-at.
validate_ppp_peer() {
    local peer="$1"
    local pf="/etc/ppp/peers/$peer"
    local cf="/etc/ppp/chatscripts/$peer"
    [ -s "$pf" ] || return 1
    local first
    first=$(awk 'NF{print; exit}' "$pf")
    [ "$first" = "$SERIAL" ] || return 1
    grep -q "^connect .*chatscripts/$peer\"" "$pf" || return 1
    [ -f "$cf" ] || return 1
    return 0
}

# Validate; if broken, regenerate. Always log what happened so the
# refresh/up scripts surface this clearly in journalctl.
ensure_ppp_peer() {
    local peer="$1" apn="$2"
    if validate_ppp_peer "$peer"; then
        return 0
    fi
    echo "[ppp-peer] $peer invalid or missing — regenerating (apn=$apn)"
    write_ppp_peer "$peer" "$apn"
}
