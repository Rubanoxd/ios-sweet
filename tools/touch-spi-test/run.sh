#!/bin/sh
# Host test of bsd/dev/sweet_touch_spi.c (xnu patch 0082) against the
# simulated FT8756 and NT36675 in test.c, with the phone's real firmware:
#   tools/touch-spi-test/run.sh focaltech_ts_fw_huaxing.bin novatek_ts_tianma_fw.bin
# The blobs come from the stock vendor partition (/vendor/firmware); they are
# Xiaomi's and stay out of git.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
patch="$here/../../xnu/patches/0082-joyeuse-touch-spi.patch"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
# The driver is a new file in the patch: take its added lines.
awk '/^\+\+\+ b\/bsd\/dev\/sweet_touch_spi\.c$/ { f = 1; next }
     f && /^@@/ { next }
     f && /^(---|diff) / { f = 0 }
     f { print substr($0, 2) }' "$patch" > "$tmp/sweet_touch_spi.c"
cc -std=c11 -Wall -Wextra -Wshadow -Werror -Wno-unused-function -O1 -g \
    -fsanitize=address,undefined -fno-sanitize-recover=all \
    -I "$tmp" -o "$tmp/test" "$here/test.c"
"$tmp/test" "$@"
