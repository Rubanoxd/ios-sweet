#!/bin/bash
# macOS version of tools/mkiosroot.sh: the same case-sensitive journaled HFS+
# iOS root (OS volume + cryptexes, dyld links, logd stores, system keybag),
# built with hdiutil instead of apfs-fuse/mkfs.hfsplus/loop mounts, followed
# by tools/sweet-root-tweaks.py. Run as root (owners and modes are preserved):
#
#   sudo tools/mkiosroot-macos.sh OS.dmg SYSTEMOS.dmg APPOS.dmg OUT.img [SIZE] [--touch-fw DIR]
#
# SIZE defaults to 16g. OUT.img is a raw HFS+ volume image for
# `fastboot flash userdata` (fastboot sparses it on the fly). macOS reads the
# IPSW's LZBITMAP-compressed files decompressed; the copy is written
# uncompressed (no decmpfs xattrs), like the Linux script's.
# Needs Homebrew rsync 3 (hard links): /opt/homebrew/bin/rsync.
set -euo pipefail

usage() { sed -n '2,13p' "$0"; exit 2; }
fw=()
args=()
while [[ $# -gt 0 ]]; do
	case $1 in
	--touch-fw) [[ $# -ge 2 ]] || usage; fw=(--touch-fw "$(cd "$2" && pwd)"); shift 2 ;;
	*) args+=("$1"); shift ;;
	esac
done
[[ ${#args[@]} -ge 4 ]] || usage
[[ $(id -u) == 0 ]] || { echo "run with sudo" >&2; exit 1; }
here=$(cd "$(dirname "$0")" && pwd)
os=$(realpath "${args[0]}") sysos=$(realpath "${args[1]}") appos=$(realpath "${args[2]}")
out=${args[3]} size=${args[4]:-16g}
[[ ! -e $out ]] || { echo "refusing to overwrite $out" >&2; exit 1; }
RSYNC=/opt/homebrew/bin/rsync
[[ -x $RSYNC ]] || { echo "need Homebrew rsync 3 at $RSYNC" >&2; exit 1; }

work=$(mktemp -d /tmp/mkiosroot.XXXXXX)
devs=()
cleanup() {
	for d in ${devs[@]+"${devs[@]}"}; do hdiutil detach -force "$d" >/dev/null 2>&1 || true; done
	rm -f "$work/root.dmg"
	rmdir "$work"/* "$work" 2>/dev/null || true
}
trap cleanup EXIT

# attach IMAGE MOUNTPOINT [hdiutil options]: read-only, owners honoured.
attach() {
	local img=$1 mnt=$2
	shift 2
	mkdir -p "$mnt"
	local dev
	dev=$(hdiutil attach -nobrowse -noautoopen -noverify -owners on -mountpoint "$mnt" "$@" "$img" |
		awk '/\/dev\/disk/ {print $1; exit}')
	[[ -n $dev ]] || { echo "attach failed: $img" >&2; exit 1; }
	devs=("$dev" ${devs[@]+"${devs[@]}"})
	echo "$img -> $mnt ($dev)"
}
# The OS image is UDIF; the cryptexes are raw APFS images.
attach "$os" "$work/os" -readonly
attach "$sysos" "$work/sysos" -readonly -imagekey diskimage-class=CRawDiskImage
attach "$appos" "$work/appos" -readonly -imagekey diskimage-class=CRawDiskImage

hdiutil create -size "$size" -fs "Case-sensitive Journaled HFS+" -volname iOSRoot \
	-layout NONE -type UDIF -o "$work/root.dmg" >/dev/null
attach "$work/root.dmg" "$work/root"
root=$work/root

copy() {
	echo "copying $1 -> ${2#"$root"}"
	mkdir -p "$2"
	"$RSYNC" -aH --numeric-ids "$1/" "$2/"
}
copy "$work/os" "$root"
copy "$work/sysos" "$root/private/preboot/Cryptexes/OS"
copy "$work/appos" "$root/private/preboot/Cryptexes/App"
# Volume-level metadata of the source APFS volumes is not part of iOS.
rm -rf "$root/.fseventsd" "$root/.Spotlight-V100" "$root/.Trashes"

# Shared cache where dyld looks at ignition level 1: hard links, no extra space.
dsc=private/preboot/Cryptexes/OS/System/Library/Caches/com.apple.dyld
mkdir -p "$root/System/Library/Caches/com.apple.dyld"
for f in "$root/$dsc"/*; do
	ln "$f" "$root/System/Library/Caches/com.apple.dyld/${f##*/}"
done

# Every cryptex file without a counterpart in the OS root, linked to its root
# path (dyld does not search the cryptexes at ignition level 1).
for c in OS App; do
	(cd "$root/private/preboot/Cryptexes/$c" && find . ! -type d ! -path './System/Library/Caches/com.apple.dyld/*') |
	while IFS= read -r f; do
		f=${f#./}
		if [[ ! -e $root/$f && ! -L $root/$f ]]; then
			mkdir -p "$root/$(dirname "$f")"
			src=$root/private/preboot/Cryptexes/$c/$f
			if [[ -L $src ]]; then cp -P "$src" "$root/$f"; else ln "$src" "$root/$f"; fi
			echo "linked $c:/$f"
		fi
	done
done

# logd's log stores (owner _logd 272, .migrated markers), made at restore on iOS.
db=$root/private/var/db
install -d -o 272 -g 272 -m 0751 "$db/diagnostics"
install -d -o 272 -g 272 -m 0755 "$db/uuidtext" "$db/diagnostics/timesync"
for d in diagnostics uuidtext diagnostics/timesync; do
	install -o 272 -g 272 -m 0644 /dev/null "$db/$d/.migrated"
done

# System keybag for the built-in AppleKeyStore (no passcode).
install -d -m 0700 -o 0 -g 0 "$root/private/var/keybags"
printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>' \
	'<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
	'<plist version="1.0"><dict><key>KeyBagKeys</key><data>U1dFRVQ=</data></dict></plist>' \
	>"$root/private/var/keybags/systembag.kb"
chown 0:0 "$root/private/var/keybags/systembag.kb"
chmod 0600 "$root/private/var/keybags/systembag.kb"

python3 -I "$here/sweet-root-tweaks.py" "$root" ${fw[@]+"${fw[@]}"}

df -h "$root"
dev=${devs[0]}
diskutil unmount "$root" >/dev/null
fsck_hfs -f -y "$dev" || true
fsck_hfs -f -n "$dev"
hdiutil detach "$dev" >/dev/null
devs=(${devs[@]+"${devs[@]:1}"})

# UDIF read-write -> raw volume bytes for fastboot.
hdiutil convert "$work/root.dmg" -format UDTO -o "$work/root" >/dev/null
mv "$work/root.cdr" "$out"
[[ -n ${SUDO_UID:-} ]] && chown "$SUDO_UID:${SUDO_GID:-$SUDO_UID}" "$out"
ls -l "$out"
