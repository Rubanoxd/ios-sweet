#!/bin/sh
# Builds sweet-netconfig for iOS arm64 on a Mac without an iOS SDK: the
# source declares what it needs, and libSystem comes from a minimal .tbd
# stub (CoreFoundation/SystemConfiguration are dlopen'ed at run time).
# The result is ad-hoc signed.   tools/sweet-netconfig/build.sh [OUT]
set -eu
cd "$(dirname "$0")"
out=${1:-sweet-netconfig}
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
cat > "$tmp/libSystem.tbd" <<'EOF'
--- !tapi-tbd
tbd-version:     4
targets:         [ arm64-ios ]
install-name:    '/usr/lib/libSystem.B.dylib'
current-version: 1319
exports:
  - targets:         [ arm64-ios ]
    symbols:         [ _dlopen, _dlsym, _dlerror, _printf, _strcmp ]
...
EOF
clang -target arm64-apple-ios16.0 -Os -Wall -Wextra -ffreestanding -fno-stack-protector \
	-c sweet-netconfig.c -o "$tmp/sweet-netconfig.o"
clang -target arm64-apple-ios16.0 -nostdlib -Wl,-e,_main "$tmp/sweet-netconfig.o" \
	"$tmp/libSystem.tbd" -o "$out"
codesign -f -s - "$out"
file "$out"
