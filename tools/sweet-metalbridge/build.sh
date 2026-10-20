#!/bin/sh
# Builds sweet_metalbridge (the Native Metal C ABI bridge over metal2vulkan) for iOS arm64.
set -e
here=$(cd "$(dirname "$0")" && pwd)
top=$(cd "$here/../../.." && pwd)
m2v="$top/metal2vulkan"
out="$top/m2v-out"
sdk="$top/sdk/theos-sdks/iPhoneOS16.5.sdk"
llvm_as=${LLVM_AS:-$(ls -d /opt/homebrew/opt/llvm@2*/bin/llvm-as /opt/homebrew/opt/llvm/bin/llvm-as 2>/dev/null | tail -1)}
mkdir -p "$out"

"$llvm_as" "$m2v/crates/metal2vulkan-validation/fixtures/public/examples/runtime_examples.ll" -o "$out/runtime_examples.air"
"$llvm_as" "$m2v/crates/metal2vulkan-validation/fixtures/public/kernel_function_constant_gate_fold.ll" -o "$out/kernel_function_constant_gate_fold.air"

export NMB_FIXTURE_AIR="$out/runtime_examples.air"
export NMB_FC_AIR="$out/kernel_function_constant_gate_fold.air"

# Only the iOS link sees the SDK; build scripts link for the Mac.
cat > "$out/ios-cc" <<EOF2
#!/bin/sh
exec clang -target arm64-apple-ios16.0 -isysroot "$sdk" "\$@"
EOF2
chmod +x "$out/ios-cc"
export CARGO_TARGET_AARCH64_APPLE_IOS_LINKER="$out/ios-cc"
export IPHONEOS_DEPLOYMENT_TARGET=16.0
export CARGO_TARGET_DIR="$out/target"
export RUSTUP_HOME="$top/rust/rustup"
export CARGO_HOME="$top/rust/cargo"
export PATH="$top/rust/rustup/toolchains/stable-aarch64-apple-darwin/bin:/opt/homebrew/bin:$PATH"

cargo build --manifest-path "$here/Cargo.toml" --release --target aarch64-apple-ios

cp "$out/target/aarch64-apple-ios/release/libsweet_metalbridge.a" "$out/" 2>/dev/null || true
if [ -f "$out/target/aarch64-apple-ios/release/libsweet_metalbridge.dylib" ]; then
    cp "$out/target/aarch64-apple-ios/release/libsweet_metalbridge.dylib" "$out/"
    codesign -f -s - "$out/libsweet_metalbridge.dylib"
fi
ls -la "$out/libsweet_metalbridge".*
