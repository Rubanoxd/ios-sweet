#!/bin/sh
# Builds SweetMetalProbe.bundle (see SweetMetalProbe.m) for iOS 16 arm64
# with the Theos SDK (see tools/build-turnip-ios.sh for the layout).
#   tools/sweet-metalprobe/build.sh [OUTDIR]
# Also builds OUTDIR/sweet-mtlquery (prints what MTLCreateSystemDefaultDevice
# returns). Install: copy OUTDIR/SweetMetalProbe.bundle to /System/Library/Extensions
# on the phone and boot with sweetmetal=1.
set -eu
cd "$(dirname "$0")"
top=$(cd ../../.. && pwd)
out=${1:-out}
b="$out/SweetMetalProbe.bundle"
rm -rf "$b"
mkdir -p "$b"
cp Info.plist "$b/Info.plist"
clang -target arm64-apple-ios16.0 -isysroot "$top/sdk/theos-sdks/iPhoneOS16.5.sdk" -Os -Wall \
	-fno-objc-arc -bundle -framework Foundation -framework Metal \
	SweetMetalProbe.m -o "$b/SweetMetalProbe"
codesign -f -s - "$b"
file "$b/SweetMetalProbe"
clang -target arm64-apple-ios16.0 -isysroot "$top/sdk/theos-sdks/iPhoneOS16.5.sdk" -Os -Wall \
	-fobjc-arc -framework Foundation -framework Metal sweet-mtlquery.m -o "$out/sweet-mtlquery"
codesign -f -s - "$out/sweet-mtlquery"
