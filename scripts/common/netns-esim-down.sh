#!/usr/bin/env bash
# netns-esim-down.sh — remove the `esim` namespace, veth pair and SNAT rules.

set -eu
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH:-}"
NS="${1:-esim}"
VETH_H="veth-${NS}-h"
NS_NET="10.200.200.0/30"

if [ "$(id -u)" -ne 0 ]; then
  exec sudo -E "$0" "$@"
fi

# Drop iptables rules referencing our subnet; tolerate missing rules.
iptables -t nat -S POSTROUTING 2>/dev/null | awk -v ns="$NS_NET" '
  $0 ~ "-s "ns" " && $0 ~ "-j SNAT" { sub(/^-A /,"-D "); print }' | \
  while read -r rule; do
    # shellcheck disable=SC2086
    iptables -t nat $rule || true
  done

for chain in FORWARD; do
  iptables -S "$chain" 2>/dev/null | awk -v ns="$NS_NET" '
    ( $0 ~ "-s "ns ) || ( $0 ~ "-d "ns ) { sub(/^-A /,"-D "); print }' | \
    while read -r rule; do
      # shellcheck disable=SC2086
      iptables $rule || true
    done
done

# Drop the policy rule we added in netns-esim-up.sh.
ip rule del from "$NS_NET" 2>/dev/null || true

ip link del "$VETH_H" 2>/dev/null || true
if ip netns list | awk '{print $1}' | grep -qx "$NS"; then
  ip netns del "$NS"
fi
rm -f "/etc/netns/$NS/resolv.conf" 2>/dev/null || true
