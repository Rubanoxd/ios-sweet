#!/bin/sh
# Cross-builds the LLVM libraries the Metal plugin's AIR translator
# (Darling's Iridium) needs: Core and BitReader with their C APIs, and ipo
# for the always-inliner Iridium runs before translating (iridium-patches
# 0003), with their dependencies; no targets, no tools; for iOS 16 arm64
# with the Theos SDK.
# LLVM 14 on purpose: AIR has typed pointers and Iridium reads pointee types
# (LLVMGetElementType on pointers), which LLVM 17+ no longer has.
# Layout next to this repo (outside git):
#   llvm-project/   git clone --depth 1 --branch llvmorg-14.0.6 --sparse
#                   https://github.com/llvm/llvm-project (llvm cmake third-party)
#   llvm-ios/       build and install tree (install: llvm-ios/install)
# The host llvm-tblgen must be the same version: Homebrew llvm@14 (14.0.6).
#   tools/build-llvm-ios.sh
set -eu
cd "$(dirname "$0")"
top=$(cd ../.. && pwd)
src="$top/llvm-project/llvm"
build="$top/llvm-ios/build"
sdk="$top/sdk/theos-sdks/iPhoneOS16.5.sdk"
host=$(brew --prefix llvm@14)/bin
"$host/llvm-tblgen" --version | grep -q 14.0.6 || { echo "need llvm-tblgen 14.0.6" >&2; exit 1; }
mkdir -p "$build"
cmake -S "$src" -B "$build" -G Ninja \
	-DCMAKE_BUILD_TYPE=MinSizeRel \
	-DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_SYSROOT="$sdk" -DCMAKE_OSX_ARCHITECTURES=arm64 \
	-DCMAKE_OSX_DEPLOYMENT_TARGET=16.0 \
	-DCMAKE_C_COMPILER=/usr/bin/clang -DCMAKE_CXX_COMPILER=/usr/bin/clang++ \
	-DCMAKE_INSTALL_PREFIX="$top/llvm-ios/install" \
	-DLLVM_TARGETS_TO_BUILD= -DLLVM_TARGET_ARCH=AArch64 -DLLVM_DEFAULT_TARGET_TRIPLE=arm64-apple-ios16.0 \
	-DLLVM_NATIVE_TOOL_DIR="$host" -DLLVM_TABLEGEN="$host/llvm-tblgen" \
	-DLLVM_ENABLE_ZLIB=OFF -DLLVM_ENABLE_ZSTD=OFF -DLLVM_ENABLE_LIBXML2=OFF -DLLVM_ENABLE_LIBEDIT=OFF \
	-DLLVM_ENABLE_TERMINFO=OFF -DLLVM_ENABLE_ASSERTIONS=OFF -DLLVM_ENABLE_RTTI=OFF \
	-DLLVM_INCLUDE_TESTS=OFF -DLLVM_INCLUDE_EXAMPLES=OFF -DLLVM_INCLUDE_BENCHMARKS=OFF \
	-DLLVM_INCLUDE_TOOLS=OFF -DLLVM_INCLUDE_UTILS=OFF -DLLVM_BUILD_TOOLS=OFF -DLLVM_INCLUDE_DOCS=OFF \
	-DLLVM_ENABLE_BINDINGS=OFF -DLLVM_ENABLE_OCAMLDOC=OFF -DLLVM_BUILD_UTILS=OFF -DCMAKE_MACOSX_BUNDLE=OFF
ninja -C "$build" LLVMBitReader LLVMCore LLVMSupport LLVMBinaryFormat LLVMBitstreamReader LLVMRemarks LLVMDemangle \
	LLVMipo
ls -l "$build"/lib/libLLVM*.a
