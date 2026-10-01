#!/usr/bin/env bash
# netns-esim-up.sh — create or refresh the `esim` network namespace so
# processes started inside it egress through wwan0 (via SNAT to the current
# bearer IP) without touching the host default route.
#
# Idempotent: safe to call after every bearer bring-up / IP change. The
# source IP used for SNAT is auto-updated from /run/esim-dw5829e.state.
#
# usage:  sudo ./netns-esim-up.sh [NS_NAME]

set -eu
# Make sure root-only tooling (sysctl, iptables, ip) is found regardless
# of how the caller's PATH was stripped down by systemd.
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH:-}"
NS="${1:-esim}"
VETH_H="veth-${NS}-h"
VETH_N="veth-${NS}-n"
HOST_ADDR="10.200.200.1/30"
NS_ADDR="10.200.200.2/30"
NS_NET="10.200.200.0/30"

if [ "$(id -u)" -ne 0 ]; then
  exec sudo -E "$0" "$@"
fi

STATE=/run/esim-dw5829e.state
if [ ! -f "$STATE" ]; then
  echo "bearer state missing ($STATE); run esim-bearer-up.sh first" >&2
  exit 1
fi
# shellcheck source=/dev/null
. "$STATE"

if ! ip netns list | awk '{print $1}' | grep -qx "$NS"; then
  ip netns add "$NS"
fi

if ! ip link show "$VETH_H" >/dev/null 2>&1; then
  ip link add "$VETH_H" type veth peer name "$VETH_N"
  ip link set "$VETH_N" netns "$NS"
  ip addr add "$HOST_ADDR" dev "$VETH_H"
  ip link set "$VETH_H" up
  ip -n "$NS" addr add "$NS_ADDR" dev "$VETH_N"
  ip -n "$NS" link set "$VETH_N" up
  ip -n "$NS" link set lo up
  ip -n "$NS" route add default via 10.200.200.1
fi

sysctl -qw net.ipv4.ip_forward=1

# Refresh SNAT to the currently-active bearer IP. Remove any stale rule
# first so slot-switches that change the src IP don't leave double entries.
iptables -t nat -S POSTROUTING 2>/dev/null | awk -v ns="$NS_NET" -v ifc="$IFACE" '
  $0 ~ "-s "ns" " && $0 ~ "-o "ifc" " && $0 ~ "-j SNAT" {
    sub(/^-A /,"-D "); print
  }' | while read -r rule; do
  # shellcheck disable=SC2086
  iptables -t nat $rule || true
done
iptables -t nat -A POSTROUTING -s "$NS_NET" -o "$IFACE" -j SNAT --to-source "$IP"

iptables -C FORWARD -s "$NS_NET" -j ACCEPT 2>/dev/null || iptables -I FORWARD -s "$NS_NET" -j ACCEPT
iptables -C FORWARD -d "$NS_NET" -j ACCEPT 2>/dev/null || iptables -I FORWARD -d "$NS_NET" -j ACCEPT

# Force the netns subnet through the eSIM policy table so forwarded
# packets egress via wwan0 *before* POSTROUTING SNAT rewrites their
# source. Without this the routing decision picks the main-table
# default (the wired interface) and the packet leaves the wire with a private
# 10.200.200.2 source, never reaching SNAT.
NS_RULE_PRIO=999
ip rule show | awk -v tbl="$TBL" -v prio="$NS_RULE_PRIO" '$1 == prio":" && $NF == tbl {found=1} END{exit !found}' \
  || ip rule add from "$NS_NET" table "$TBL" priority "$NS_RULE_PRIO"

mkdir -p "/etc/netns/$NS"
cat >"/etc/netns/$NS/resolv.conf" <<'EOF'
nameserver 77.88.8.8
nameserver 77.88.8.1
EOF

echo "ns=$NS src-ip=$IP iface=$IFACE"
