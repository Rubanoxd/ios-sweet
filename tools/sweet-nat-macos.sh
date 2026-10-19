#!/bin/sh
# Shares the Mac's internet with the phone over its USB Ethernet
# (tools/sweet-usbnet-macos.sh, 192.168.7.0/24): IP forwarding plus a pf NAT
# rule in the anchor com.apple/sweet-nat, which the stock /etc/pf.conf
# already evaluates (nat-anchor "com.apple/*"). Lasts until the Mac reboots;
# "off" removes the rule and turns forwarding off again.
#   sudo tools/sweet-nat-macos.sh [EXTERNAL_IF | off]
set -eu
anchor=com.apple/sweet-nat
if [ "${1:-}" = off ]; then
	pfctl -a "$anchor" -F all 2>/dev/null || true
	sysctl -w net.inet.ip.forwarding=0
	exit 0
fi
ext=${1:-$(route -n get default | awk '/interface:/{print $2}')}
[ -n "$ext" ] || { echo "no default route on the Mac" >&2; exit 1; }
sysctl -w net.inet.ip.forwarding=1
echo "nat on $ext inet from 192.168.7.0/24 to any -> ($ext)" | pfctl -a "$anchor" -f -
pfctl -E 2>&1 | grep -v "^No ALTQ" || true
pfctl -a "$anchor" -s nat
echo "phone 192.168.7.2 -> internet through $ext" >&2
