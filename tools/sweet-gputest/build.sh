#!/bin/sh
# Builds sweet-gputest for iOS arm64 on a Mac without an iOS SDK (like
# tools/sweet-netconfig/build.sh): IOKit is dlopen'ed, libSystem comes from
# a .tbd stub, and the ABI header is taken from xnu patch 0090.
#   tools/sweet-gputest/build.sh [OUT]
set -eu
cd "$(dirname "$0")"
out=${1:-sweet-gputest}
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p ../../xnu/out-abi
# The header is added whole by the patch; strip the diff's "+" prefixes.
awk '/^\+\+\+ b\/iokit\/Kernel\/arm\/NativeAdrenoABI.h/{f=1;next} f&&/^(diff|---) /{f=0} f&&/^@@/{next} f{sub(/^\+/,"");print}' \
	../../xnu/patches/0090-joyeuse-gpu-user-client.patch > ../../xnu/out-abi/NativeAdrenoABI.h
cat > "$tmp/libSystem.tbd" <<'EOF'
--- !tapi-tbd
tbd-version:     4
targets:         [ arm64-ios ]
install-name:    '/usr/lib/libSystem.B.dylib'
current-version: 1319
exports:
  - targets:         [ arm64-ios ]
    symbols:         [ _dlopen, _dlsym, _dlerror, _dprintf, _atoi, _memset, _memcpy,
                       _mach_absolute_time, _usleep ]
...
EOF
clang -target arm64-apple-ios16.0 -Os -Wall -Wno-incompatible-sysroot -ffreestanding \
	-fno-stack-protector -c sweet-gputest.c -o "$tmp/sweet-gputest.o"
clang -target arm64-apple-ios16.0 -nostdlib -Wno-incompatible-sysroot -Wl,-e,_main \
	"$tmp/sweet-gputest.o" "$tmp/libSystem.tbd" -o "$out"
codesign -f -s - "$out"
file "$out"
