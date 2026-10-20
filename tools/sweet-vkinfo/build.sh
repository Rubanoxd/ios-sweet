#!/bin/sh
# Builds sweet-vkinfo for iOS 16 arm64 with the Theos SDK and Mesa's Vulkan
# headers (see tools/build-turnip-ios.sh for the layout).
#   tools/sweet-vkinfo/build.sh [OUT]
set -eu
cd "$(dirname "$0")"
top=$(cd ../../.. && pwd)
out=${1:-sweet-vkinfo}
clang -target arm64-apple-ios16.0 -isysroot "$top/sdk/theos-sdks/iPhoneOS16.5.sdk" -Os -Wall \
	-I "$top/mesa/src/include" sweet-vkinfo.c -o "$out"
codesign -f -s - "$out"
file "$out"
