#!/bin/sh
# Cross-builds Turnip (Mesa's freedreno Vulkan driver) for iOS 16 arm64 with
# UniXNU's darwin kernel backend, which talks to this kernel's Adreno user
# client (xnu patch 0090, NativeAdrenoGpuPublished, NativeAdreno ABI v1).
# Follows UniXNU scripts/build-turnip-darwin.py --target ios, with the Theos
# iPhoneOS16.5 SDK instead of Xcode.
#
# Layout (outside git, next to this checkout), see JOYEUSE.md "Turnip":
#   ../mesa/src        Mesa at 85fda3b3 + UniXNU's five patches/mesa patches
#   ../mesa/venv       python venv with meson, mako, pyyaml, packaging
#   ../sdk/theos-sdks/iPhoneOS16.5.sdk
# Needs glslangValidator, ninja and Homebrew bison (>= 3.x).
#   tools/build-turnip-ios.sh [--configure-only]
set -eu
here=$(cd "$(dirname "$0")/.." && pwd)
top=$(dirname "$here")
src=$top/mesa/src
out=$top/mesa/build-ios
sdk=$top/sdk/theos-sdks/iPhoneOS16.5.sdk
abi=$here/xnu/out-abi
[ -d "$src" ] && [ -d "$sdk" ] || { echo "missing $src or $sdk" >&2; exit 1; }
# The ABI header, as the kernel patch adds it.
mkdir -p "$abi"
awk '/^\+\+\+ b\/iokit\/Kernel\/arm\/NativeAdrenoABI.h/{f=1;next} f&&/^(diff|---) /{f=0} f&&/^@@/{next} f{sub(/^\+/,"");print}' \
	"$here/xnu/patches/0090-joyeuse-gpu-user-client.patch" > "$abi/NativeAdrenoABI.h"

export PATH=$top/mesa/venv/bin:/opt/homebrew/opt/bison/bin:$PATH
cross=$top/mesa/ios16.cross
flags="'-target', 'arm64-apple-ios16.0', '-isysroot', '$sdk', '-fstack-protector-strong'"
cat > "$cross" <<EOF
[binaries]
c = '/usr/bin/clang'
cpp = '/usr/bin/clang++'
objc = '/usr/bin/clang'
ar = '/usr/bin/ar'
strip = '/usr/bin/strip'
pkg-config = '/usr/bin/false'
[host_machine]
system = 'darwin'
cpu_family = 'aarch64'
cpu = 'arm64'
endian = 'little'
[properties]
needs_exe_wrapper = true
[built-in options]
c_args = [$flags]
cpp_args = [$flags]
objc_args = [$flags]
c_link_args = [$flags]
cpp_link_args = [$flags]
objc_link_args = [$flags]
EOF
if [ ! -f "$out/build.ninja" ]; then
	env -u CFLAGS -u CXXFLAGS -u CPPFLAGS -u LDFLAGS meson setup "$out" "$src" --wrap-mode=nodownload \
		--cross-file "$cross" --buildtype=release \
		-Dgallium-drivers= -Dvulkan-drivers=freedreno -Dfreedreno-kmds=darwin \
		-Dtu-darwin-abi-dir="$abi" -Dplatforms=macos -Dglx=disabled -Degl=disabled -Dgbm=disabled \
		-Dopengl=false -Dgles1=disabled -Dgles2=disabled -Dllvm=disabled -Dshared-glapi=disabled \
		-Dxmlconfig=disabled -Dshader-cache=disabled -Dtools= -Dbuild-tests=false -Dvideo-codecs= \
		-Dvulkan-layers= -Dlibunwind=disabled -Dlmsensors=disabled -Dvalgrind=disabled -Dexpat=disabled \
		-Dzstd=disabled
fi
[ "${1:-}" = --configure-only ] && exit 0
ninja -C "$out"
lib=$out/src/freedreno/vulkan/libvulkan_freedreno.dylib
file "$lib"
nm -gU "$lib" | grep -c ' _vk' | sed 's/^/exported vk symbols: /'
