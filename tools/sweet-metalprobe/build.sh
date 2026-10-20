#!/bin/sh
# Builds SweetMetalProbe.bundle (see SweetMetalProbe.m) for iOS 16 arm64
# with the Theos SDK and Mesa's Vulkan headers (see tools/build-turnip-ios.sh
# for the layout); the Turnip job needs the ICD at
# /var/jb/usr/lib/libvulkan_freedreno.dylib on the phone.
#   tools/sweet-metalprobe/build.sh [OUTDIR]
# Also builds OUTDIR/sweet-mtlquery (prints what MTLCreateSystemDefaultDevice
# returns) and OUTDIR/sweet-mtltest (the stage-3 client test). Install: copy OUTDIR/SweetMetalProbe.bundle to /System/Library/Extensions
# on the phone and boot with sweetmetal=1.
set -eu
cd "$(dirname "$0")"
top=$(cd ../../.. && pwd)
out=${1:-out}
b="$out/SweetMetalProbe.bundle"
rm -rf "$b"
mkdir -p "$b"
cp Info.plist "$b/Info.plist"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
glslangValidator -V --target-env vulkan1.1 --vn spv_compute_comp -o "$tmp/compute_comp.h" \
	../sweet-vktest/compute.comp >/dev/null
clang -target arm64-apple-ios16.0 -isysroot "$top/sdk/theos-sdks/iPhoneOS16.5.sdk" -Os -Wall \
	-Wno-missing-braces -fno-objc-arc -I "$top/mesa/src/include" -c SweetMetalProbe.m -o "$tmp/probe.o"
clang -target arm64-apple-ios16.0 -isysroot "$top/sdk/theos-sdks/iPhoneOS16.5.sdk" -Os -Wall \
	-Wno-missing-braces -fobjc-arc -I "$top/mesa/src/include" -c SweetMetalDevice.m -o "$tmp/device.o"
clang -target arm64-apple-ios16.0 -isysroot "$top/sdk/theos-sdks/iPhoneOS16.5.sdk" -Os -Wall \
	-Wno-missing-braces -I "$top/mesa/src/include" -I "$tmp" -c turnip-job.c -o "$tmp/job.o"
clang -target arm64-apple-ios16.0 -isysroot "$top/sdk/theos-sdks/iPhoneOS16.5.sdk" -Os -Wall \
	-Wno-missing-braces -I "$top/mesa/src/include" -c sweet-mtl-vk.c -o "$tmp/vk.o"
clang -target arm64-apple-ios16.0 -isysroot "$top/sdk/theos-sdks/iPhoneOS16.5.sdk" -bundle -fobjc-arc \
	-framework Foundation -framework Metal -framework QuartzCore \
	"$tmp/probe.o" "$tmp/device.o" "$tmp/job.o" "$tmp/vk.o" -o "$b/SweetMetalProbe"
codesign -f -s - "$b"
file "$b/SweetMetalProbe"
clang -target arm64-apple-ios16.0 -isysroot "$top/sdk/theos-sdks/iPhoneOS16.5.sdk" -Os -Wall \
	-fobjc-arc -framework Foundation -framework Metal sweet-mtlquery.m -o "$out/sweet-mtlquery"
codesign -f -s - "$out/sweet-mtlquery"
clang -target arm64-apple-ios16.0 -isysroot "$top/sdk/theos-sdks/iPhoneOS16.5.sdk" -Os -Wall \
	-fobjc-arc -framework Foundation -framework Metal -framework QuartzCore sweet-mtltest.m -o "$out/sweet-mtltest"
codesign -f -s - "$out/sweet-mtltest"
