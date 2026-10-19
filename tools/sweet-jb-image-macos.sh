#!/bin/bash
# macOS: run tools/sweet-jb-install.py on a raw iOS root image (the
# ios16-root.img that mkiosroot-macos.sh writes), then fsck it.
#
#   sudo tools/sweet-jb-image-macos.sh ROOT.img BOOTSTRAP.tar.zst [--deb X.deb ...] [--authorized-key K.pub]
set -euo pipefail
[[ $# -ge 2 ]] || { sed -n '2,6p' "$0"; exit 2; }
[[ $(id -u) == 0 ]] || { echo "run with sudo" >&2; exit 1; }
here=$(cd "$(dirname "$0")" && pwd)
img=$(realpath "$1") bootstrap=$(realpath "$2")
shift 2
mnt=$(mktemp -d /tmp/sweetjb.XXXXXX)
dev=$(hdiutil attach -nobrowse -noautoopen -noverify -owners on -mountpoint "$mnt" \
	-imagekey diskimage-class=CRawDiskImage "$img" | awk '/\/dev\/disk/ {print $1; exit}')
[[ -n $dev ]] || { echo "attach failed" >&2; exit 1; }
trap 'hdiutil detach -force "$dev" >/dev/null 2>&1 || true; rmdir "$mnt" 2>/dev/null || true' EXIT
echo "$img -> $mnt ($dev)"
PATH=/opt/homebrew/bin:$PATH python3 -I "$here/sweet-jb-install.py" "$mnt" --bootstrap "$bootstrap" "$@"
df -h "$mnt"
diskutil unmount "$mnt" >/dev/null
fsck_hfs -f -y "$dev" || true
fsck_hfs -f -n "$dev"
hdiutil detach "$dev" >/dev/null
trap - EXIT
rmdir "$mnt" 2>/dev/null || true
echo "done: $img"
