#!/bin/sh
# Builds SweetMetalProbe.bundle (see SweetMetalProbe.m) for iOS 16 arm64
# with the Theos SDK and metal2vulkan-runtime on Turnip (sweet-metalbridge).
# The device needs Turnip at /var/jb/usr/lib/libvulkan_freedreno.dylib.
#   tools/sweet-metalprobe/build.sh [OUTDIR]
# Also builds into OUTDIR: sweet-mtlquery (what MTLCreateSystemDefaultDevice
# returns), sweet-mtltest (the client test) with sweet-mtltest.metallib,
# sweet-carender (QuartzCore's CARenderer on the device), and copies
# libsweet_metalbridge.dylib.
# Install: OUTDIR/SweetMetalProbe.bundle into /System/Library/Extensions
# on the phone, boot with sweetmetal=1.
set -eu
cd "$(dirname "$0")"
top=$(cd ../../.. && pwd)
out=${1:-$top/metalprobe-out}
sdk="$top/sdk/theos-sdks/iPhoneOS16.5.sdk"
cc="clang -target arm64-apple-ios16.0 -isysroot $sdk -Os -Wall -Wno-missing-braces"
cxx="clang++ -target arm64-apple-ios16.0 -isysroot $sdk -Os -std=c++17 -Wno-deprecated-declarations"

mkdir -p "$out"

# 1. Ensure sweet_metalbridge is built
if [ ! -f "$top/m2v-out/libsweet_metalbridge.a" ]; then
	echo "Building sweet-metalbridge..."
	"$top/ios-sweet/tools/sweet-metalbridge/build.sh"
fi

b="$out/SweetMetalProbe.bundle"
rm -rf "$b"
mkdir -p "$b"
cp Info.plist "$b/Info.plist"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# Background Turnip compute check for SpringBoard
glslangValidator -V --target-env vulkan1.1 --vn spv_compute_comp -o "$tmp/compute_comp.h" \
	../sweet-vktest/compute.comp >/dev/null
$cc -fno-objc-arc -I "$top/mesa/src/include" -I . -c SweetMetalProbe.m -o "$tmp/probe.o"
$cxx -fobjc-arc -I . -c SweetMetalFrontend.mm -o "$tmp/frontend.o"
$cc -I "$top/mesa/src/include" -I "$tmp" -c turnip-job.c -o "$tmp/job.o"

# Link SweetMetalProbe.bundle
clang++ -target arm64-apple-ios16.0 -isysroot "$sdk" -bundle -fobjc-arc \
	-framework Foundation -framework Metal -framework QuartzCore -framework IOSurface \
	-framework Security -framework CoreFoundation \
	"$tmp/probe.o" "$tmp/frontend.o" "$tmp/job.o" "$top/m2v-out/libsweet_metalbridge.a" \
	-o "$b/SweetMetalProbe"
codesign -f -s - "$b"
file "$b/SweetMetalProbe"

# Copy dylib if available
if [ -f "$top/m2v-out/libsweet_metalbridge.dylib" ]; then
	cp "$top/m2v-out/libsweet_metalbridge.dylib" "$out/"
fi

# Build test binaries
$cc -fobjc-arc -framework Foundation -framework Metal sweet-mtlquery.m -o "$out/sweet-mtlquery"
codesign -f -s - "$out/sweet-mtlquery"

$cc -fobjc-arc -framework Foundation -framework Metal -framework QuartzCore -framework CoreGraphics \
	-framework ImageIO -framework IOSurface sweet-mtltest.m -o "$out/sweet-mtltest"
codesign -f -s - "$out/sweet-mtltest"

$cc -fobjc-arc -framework Foundation -framework Metal -framework QuartzCore -framework CoreGraphics \
	sweet-carender.m -o "$out/sweet-carender"
codesign -f -s - "$out/sweet-carender"

# The test kernels
metal=${METAL:-}
if [ -z "$metal" ]; then
	mnt="$top/metal-toolchain"
	if [ ! -x "$mnt/Metal.xctoolchain/usr/bin/metal" ]; then
		dmg=$(ls /System/Library/AssetsV2/com_apple_MobileAsset_MetalToolchain/*/AssetData/Restore/*.dmg 2>/dev/null | head -1 || true)
		if [ -n "$dmg" ]; then
			mkdir -p "$mnt"
			hdiutil attach -readonly -nobrowse -noverify -mountpoint "$mnt" "$dmg" >/dev/null || true
		fi
	fi
	if [ -x "$mnt/Metal.xctoolchain/usr/bin/metal" ]; then
		metal="$mnt/Metal.xctoolchain/usr/bin/metal"
	fi
fi
if [ -n "$metal" ] && [ -x "$metal" ]; then
	"$metal" -std=ios-metal2.4 -target air64-apple-ios16.0 -O2 -c sweet-mtltest.metal -o "$tmp/kernels.air"
	"$(dirname "$metal")/metallib" "$tmp/kernels.air" -o "$out/sweet-mtltest.metallib"
fi

ls -la "$out"
