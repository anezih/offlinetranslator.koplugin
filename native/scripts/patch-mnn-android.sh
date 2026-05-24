#!/usr/bin/env sh
set -eu

CARGO_HOME_DIR="${CARGO_HOME:-$HOME/.cargo}"
CHECKOUTS="$CARGO_HOME_DIR/git/checkouts"

if [ ! -d "$CHECKOUTS" ]; then
    exit 0
fi

find "$CHECKOUTS" -path '*/mnn-sys-*/build.rs' -print | while IFS= read -r build_rs; do
    perl -0pi -e 's/println!\("cargo:rustc-link-lib=c\+\+_static"\);/println!("cargo:rustc-link-lib=c++_shared");/' "$build_rs"
done
