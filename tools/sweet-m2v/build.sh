#!/bin/sh
# Builds sweet-m2vtest (metal2vulkan's runtime on Turnip) for iOS arm64.
# Needs: metal2vulkan cloned beside ios-sweet (../metal2vulkan from the
# ios-sweet checkout), rustup with the aarch64-apple-ios target (Rust 1.98+),
# llvm-as with opaque pointers (Homebrew llvm 15+), the iPhoneOS SDK of
# sweet-metalprobe/build.sh. Output: $top/m2v-out/sweet-m2vtest (ad-hoc signed).
set -e
here=$(cd "$(dirname "$0")" && pwd)
top=$(cd "$here/../../.." && pwd)
m2v="$top/metal2vulkan"
out="$top/m2v-out"
sdk="$top/sdk/theos-sdks/iPhoneOS16.5.sdk"
llvm_as=${LLVM_AS:-$(ls -d /opt/homebrew/opt/llvm@2*/bin/llvm-as /opt/homebrew/opt/llvm/bin/llvm-as 2>/dev/null | tail -1)}
mkdir -p "$out"

"$llvm_as" "$m2v/crates/metal2vulkan-validation/fixtures/public/examples/runtime_examples.ll" -o "$out/runtime_examples.air"

export SWEET_M2V_FIXTURE="$out/runtime_examples.air"
# Only the iOS link sees the SDK; build scripts link for the Mac.
cat > "$out/ios-cc" <<EOF2
#!/bin/sh
exec clang -target arm64-apple-ios16.0 -isysroot "$sdk" "\$@"
EOF2
chmod +x "$out/ios-cc"
export CARGO_TARGET_AARCH64_APPLE_IOS_LINKER="$out/ios-cc"
export IPHONEOS_DEPLOYMENT_TARGET=16.0
export CARGO_TARGET_DIR="$out/target"
cargo build --manifest-path "$here/Cargo.toml" --release --target aarch64-apple-ios
cp "$out/target/aarch64-apple-ios/release/sweet-m2vtest" "$out/"
codesign -f -s - "$out/sweet-m2vtest"
ls -l "$out/sweet-m2vtest"
