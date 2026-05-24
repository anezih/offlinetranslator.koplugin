#!/usr/bin/env sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PLUGIN_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
BRIDGE_DIR="$SCRIPT_DIR/bridge"
OUT_DIR="$PLUGIN_DIR/libs/linux/x86_64"
BUILD_DIR="$PLUGIN_DIR/build/linux-x86_64/offlinetranslator.koplugin"
ORT_VERSION="${ONNXRUNTIME_VERSION:-1.22.0}"
ORT_DIR="$SCRIPT_DIR/onnxruntime/linux-x86_64"
ORT_LIB="$ORT_DIR/libonnxruntime.so.$ORT_VERSION"

ensure_linux_onnxruntime() {
    if [ -f "$ORT_LIB" ]; then
        return
    fi
    mkdir -p "$SCRIPT_DIR/onnxruntime"
    archive="$SCRIPT_DIR/onnxruntime/onnxruntime-linux-x64-$ORT_VERSION.tgz"
    if [ ! -f "$archive" ]; then
        curl -L --fail \
            "https://github.com/microsoft/onnxruntime/releases/download/v$ORT_VERSION/onnxruntime-linux-x64-$ORT_VERSION.tgz" \
            -o "$archive"
    fi
    rm -rf "$ORT_DIR"
    mkdir -p "$ORT_DIR"
    tar -xzf "$archive" -C "$ORT_DIR" --strip-components=2 \
        "onnxruntime-linux-x64-$ORT_VERSION/lib/libonnxruntime.so.$ORT_VERSION"
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
ensure_linux_onnxruntime

mkdir -p "$OUT_DIR"
RUSTFLAGS="-A dead_code -C link-arg=-Wl,--allow-multiple-definition" \
    cargo build --manifest-path "$BRIDGE_DIR/Cargo.toml" --release
cp "$BRIDGE_DIR/target/release/libofflinetranslator.so" "$OUT_DIR/libofflinetranslator.so"
cp "$ORT_LIB" "$OUT_DIR/libonnxruntime.so.$ORT_VERSION"

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR/libs/linux/x86_64"
cp "$PLUGIN_DIR"/README.md "$BUILD_DIR"/
cp "$PLUGIN_DIR"/*.lua "$BUILD_DIR"/
cp -R "$PLUGIN_DIR"/resources "$BUILD_DIR"/
cp "$OUT_DIR"/*.so* "$BUILD_DIR/libs/linux/x86_64"/
