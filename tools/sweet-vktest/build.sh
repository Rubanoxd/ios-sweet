#!/bin/sh
# Builds sweet-vktest for iOS 16 arm64: GLSL -> SPIR-V headers with
# glslangValidator, then clang with the Theos SDK and Mesa's Vulkan headers
# (layout: see tools/build-turnip-ios.sh).
#   tools/sweet-vktest/build.sh [OUT]
set -eu
cd "$(dirname "$0")"
top=$(cd ../../.. && pwd)
out=${1:-sweet-vktest}
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
for s in compute.comp triangle.vert triangle.frag; do
	n=$(echo "$s" | tr . _)
	glslangValidator -V --target-env vulkan1.1 --vn "spv_$n" -o "$tmp/$n.h" "$s" >/dev/null
done
clang -target arm64-apple-ios16.0 -isysroot "$top/sdk/theos-sdks/iPhoneOS16.5.sdk" -O2 -Wall \
	-Wno-missing-braces -I "$top/mesa/src/include" -I "$tmp" sweet-vktest.c -o "$out"
codesign -f -s - "$out"
file "$out"
