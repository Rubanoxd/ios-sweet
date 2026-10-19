#!/bin/sh
# macOS host side of the phone's USB Ethernet (kernel sweetusb=2), like
# tools/sweet-usbnet.sh: waits for the CDC-ECM interface (host MAC
# 02:00:5e:77:ee:01), gives it 192.168.7.1/24 and prints the live kernel
# console the phone streams to UDP 5140 (appended to LOGFILE if given).
# Keeps running across phone reboots: each new interface is configured again.
#   sudo tools/sweet-usbnet-macos.sh [LOGFILE]
set -u
mac=02:00:5e:77:ee:01
find_if() {
	ifconfig -a | awk -v m="$mac" '/^[a-z]/{i=$1} $1=="ether" && tolower($2)==m {sub(":","",i); print i}'
}
while :; do
	echo "waiting for the phone's USB Ethernet ($mac)..." >&2
	ifname=
	until [ -n "$ifname" ]; do
		ifname=$(find_if)
		[ -n "$ifname" ] || sleep 1
	done
	ifconfig "$ifname" inet 192.168.7.1 netmask 255.255.255.0 up
	echo "$ifname up: 192.168.7.1 <-> phone 192.168.7.2; live log on udp/5140" >&2
	if [ $# -ge 1 ]; then
		nc -ukl 5140 | tee -a "$1" &
	else
		nc -ukl 5140 &
	fi
	while [ "$(find_if)" = "$ifname" ]; do
		sleep 2
	done
	echo "$ifname gone (phone rebooted?)" >&2
	pkill -f "nc -ukl 5140"
	wait 2>/dev/null
done
