#!/bin/sh
# Builds SweetMetalProbe.bundle (see SweetMetalProbe.m) for iOS 16 arm64
# with the Theos SDK and Mesa's Vulkan headers (see tools/build-turnip-ios.sh
# for the layout). Shaders: Darling's Iridium (../../../indium, patched with
# tools/iridium-patches) over LLVM 14 for iOS (tools/build-llvm-ios.sh).
# The device needs Turnip at /var/jb/usr/lib/libvulkan_freedreno.dylib.
#   tools/sweet-metalprobe/build.sh [OUTDIR]
# Also builds into OUTDIR: sweet-mtlquery (what MTLCreateSystemDefaultDevice
# returns), sweet-mtltest (the client test) with sweet-mtltest.metallib, and
# sweet-air2spv (Iridium on the phone). The metallib needs Apple's metal
# compiler: $METAL, or the MetalToolchain asset of this Mac, mounted at
# ../../../metal-toolchain. Install: OUTDIR/SweetMetalProbe.bundle into
# /System/Library/Extensions on the phone, boot with sweetmetal=1.
set -eu
cd "$(dirname "$0")"
top=$(cd ../../.. && pwd)
out=${1:-out}
sdk="$top/sdk/theos-sdks/iPhoneOS16.5.sdk"
cc="clang -target arm64-apple-ios16.0 -isysroot $sdk -Os -Wall -Wno-missing-braces"
cxx="clang++ -target arm64-apple-ios16.0 -isysroot $sdk -Os -std=c++17 -Wno-deprecated-declarations \
	-I$top/indium/include -I$top/indium/private-include -I$top/llvm-project/llvm/include \
	-I$top/llvm-ios/build/include -D__STDC_CONSTANT_MACROS -D__STDC_FORMAT_MACROS -D__STDC_LIMIT_MACROS"
llvm="-L$top/llvm-ios/build/lib -lLLVMBitReader -lLLVMCore -lLLVMBitstreamReader -lLLVMRemarks \
	-lLLVMBinaryFormat -lLLVMSupport -lLLVMDemangle"
b="$out/SweetMetalProbe.bundle"
rm -rf "$b"
mkdir -p "$b"
cp Info.plist "$b/Info.plist"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# Iridium (AIR -> SPIR-V) with LLVM linked in
for s in air spirv iridium; do
	$cxx -c "$top/indium/src/iridium/$s.cpp" -o "$tmp/iridium-$s.o"
done
$cxx -c iridium-static-llvm.cpp -o "$tmp/iridium-static-llvm.o"
$cxx -c sweet-iridium.cpp -o "$tmp/sweet-iridium.o"
iridium="$tmp/iridium-air.o $tmp/iridium-spirv.o $tmp/iridium-iridium.o $tmp/iridium-static-llvm.o $tmp/sweet-iridium.o"

glslangValidator -V --target-env vulkan1.1 --vn spv_compute_comp -o "$tmp/compute_comp.h" \
	../sweet-vktest/compute.comp >/dev/null
$cc -fno-objc-arc -I "$top/mesa/src/include" -c SweetMetalProbe.m -o "$tmp/probe.o"
$cc -fobjc-arc -I "$top/mesa/src/include" -c SweetMetalDevice.m -o "$tmp/device.o"
$cc -I "$top/mesa/src/include" -I "$tmp" -c turnip-job.c -o "$tmp/job.o"
$cc -I "$top/mesa/src/include" -c sweet-mtl-vk.c -o "$tmp/vk.o"
clang++ -target arm64-apple-ios16.0 -isysroot "$sdk" -bundle -fobjc-arc \
	-framework Foundation -framework Metal -framework QuartzCore \
	"$tmp/probe.o" "$tmp/device.o" "$tmp/job.o" "$tmp/vk.o" $iridium $llvm -o "$b/SweetMetalProbe"
codesign -f -s - "$b"
file "$b/SweetMetalProbe"

$cc -fobjc-arc -framework Foundation -framework Metal sweet-mtlquery.m -o "$out/sweet-mtlquery"
codesign -f -s - "$out/sweet-mtlquery"
$cc -fobjc-arc -framework Foundation -framework Metal -framework QuartzCore sweet-mtltest.m -o "$out/sweet-mtltest"
codesign -f -s - "$out/sweet-mtltest"
$cc -c sweet-air2spv.c -o "$tmp/air2spv.o"
clang++ -target arm64-apple-ios16.0 -isysroot "$sdk" "$tmp/air2spv.o" $iridium $llvm -o "$out/sweet-air2spv"
codesign -f -s - "$out/sweet-air2spv"

# the test kernels
metal=${METAL:-}
if [ -z "$metal" ]; then
	mnt="$top/metal-toolchain"
	if [ ! -x "$mnt/Metal.xctoolchain/usr/bin/metal" ]; then
		dmg=$(ls /System/Library/AssetsV2/com_apple_MobileAsset_MetalToolchain/*/AssetData/Restore/*.dmg | head -1)
		mkdir -p "$mnt"
		hdiutil attach -readonly -nobrowse -noverify -mountpoint "$mnt" "$dmg" >/dev/null
	fi
	metal="$mnt/Metal.xctoolchain/usr/bin/metal"
fi
"$metal" -std=ios-metal2.4 -target air64-apple-ios16.0 -O2 -c sweet-mtltest.metal -o "$tmp/kernels.air"
"$(dirname "$metal")/metallib" "$tmp/kernels.air" -o "$out/sweet-mtltest.metallib"
ls -l "$out"
