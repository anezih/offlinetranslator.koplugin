#!/usr/bin/env sh
set -eu

if [ -z "${ANDROID_NDK_HOME:-}" ]; then
    echo "ANDROID_NDK_HOME is required" >&2
    exit 1
fi

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PLUGIN_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
BRIDGE_DIR="$SCRIPT_DIR/bridge"
OUT_DIR="$PLUGIN_DIR/libs/android"
TOOLCHAIN="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/bin"
API="${ANDROID_API:-21}"
ORT_VERSION="${ONNXRUNTIME_VERSION:-1.22.0}"
ORT_DIR="$SCRIPT_DIR/onnxruntime/android-arm64-v8a"
ORT_LIB="$ORT_DIR/libonnxruntime.so"

ensure_android_onnxruntime() {
    if [ -f "$ORT_LIB" ]; then
        return
    fi
    mkdir -p "$SCRIPT_DIR/onnxruntime"
    aar="$SCRIPT_DIR/onnxruntime/onnxruntime-android-$ORT_VERSION.aar"
    if [ ! -f "$aar" ]; then
        curl -L --fail \
            "https://repo1.maven.org/maven2/com/microsoft/onnxruntime/onnxruntime-android/$ORT_VERSION/onnxruntime-android-$ORT_VERSION.aar" \
            -o "$aar"
    fi
    rm -rf "$ORT_DIR"
    mkdir -p "$ORT_DIR"
    unzip -p "$aar" "jni/arm64-v8a/libonnxruntime.so" > "$ORT_LIB"
}

sh "$SCRIPT_DIR/scripts/prepare-translator-rs.sh"

if ! command -v cmake >/dev/null 2>&1; then
    echo "cmake is required to build translator-rs native dependencies" >&2
    exit 1
fi

if [ -z "${LIBCLANG_PATH:-}" ] && ! ldconfig -p 2>/dev/null | grep -q 'libclang.*\.so'; then
    echo "libclang is required by bindgen; install libclang-dev or set LIBCLANG_PATH" >&2
    exit 1
fi

cargo fetch --manifest-path "$BRIDGE_DIR/Cargo.toml"
sh "$SCRIPT_DIR/scripts/patch-tesseract-sys.sh"
sh "$SCRIPT_DIR/scripts/patch-slimt-android.sh"
sh "$SCRIPT_DIR/scripts/patch-mnn-android.sh"
ensure_android_onnxruntime

build_one() {
    abi="$1"
    rust_target="$2"
    clang_target="$3"
    ar_name="$4"
    android_abi="$5"
    sysroot_arch="$6"
    out="$OUT_DIR/$abi"
    mkdir -p "$out"

    rustup target add "$rust_target" >/dev/null 2>&1 || true
    target_env=$(printf "%s" "$rust_target" | tr '[:lower:]-' '[:upper:]_')
    sysroot="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/sysroot"
    bindgen_args="--sysroot=$sysroot -I$sysroot/usr/include -I$sysroot/usr/include/$sysroot_arch"
    env \
    RUSTFLAGS="-A dead_code -C link-arg=-Wl,--allow-multiple-definition" \
    CC="$TOOLCHAIN/${clang_target}${API}-clang" \
    CXX="$TOOLCHAIN/${clang_target}${API}-clang++" \
    AR="$TOOLCHAIN/$ar_name" \
    BINDGEN_EXTRA_CLANG_ARGS="$bindgen_args" \
    CMAKE_TOOLCHAIN_FILE="$ANDROID_NDK_HOME/build/cmake/android.toolchain.cmake" \
    CMAKE_SYSTEM_NAME=Android \
    CMAKE_ANDROID_ARCH_ABI="$android_abi" \
    ANDROID_ABI="$android_abi" \
    ANDROID_PLATFORM="android-$API" \
    "CARGO_TARGET_${target_env}_LINKER=$TOOLCHAIN/${clang_target}${API}-clang" \
    CARGO_TARGET_DIR="$BRIDGE_DIR/target/android-$abi" \
    cargo build --manifest-path "$BRIDGE_DIR/Cargo.toml" --release --target "$rust_target"

    cp "$BRIDGE_DIR/target/android-$abi/$rust_target/release/libofflinetranslator.so" \
        "$out/libofflinetranslator.so"
    cp "$sysroot/usr/lib/$sysroot_arch/libc++_shared.so" "$out/libc++_shared.so"
    cp "$ORT_LIB" "$out/libonnxruntime.so"
}

build_one arm64-v8a aarch64-linux-android aarch64-linux-android llvm-ar arm64-v8a aarch64-linux-android

abis="arm64-v8a"

for abi in $abis; do
    build_dir="$PLUGIN_DIR/build/android-$abi/offlinetranslator.koplugin"
    rm -rf "$build_dir"
    mkdir -p "$build_dir/libs/android/$abi"
    cp "$PLUGIN_DIR"/README.md "$build_dir"/
    cp "$PLUGIN_DIR"/*.lua "$build_dir"/
    cp -R "$PLUGIN_DIR"/resources "$build_dir"/
    cp "$OUT_DIR/$abi"/*.so "$build_dir/libs/android/$abi"/
done
