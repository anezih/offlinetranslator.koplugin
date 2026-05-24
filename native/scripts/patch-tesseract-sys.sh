#!/usr/bin/env sh
set -eu

CARGO_HOME_DIR="${CARGO_HOME:-$HOME/.cargo}"
CHECKOUTS="$CARGO_HOME_DIR/git/checkouts"

if [ ! -d "$CHECKOUTS" ]; then
    exit 0
fi

find "$CHECKOUTS" -path '*/tesseract-sys-*/build.rs' -print | while IFS= read -r build_rs; do
    perl -0pi -e 's/\.define\("ENABLE_LTO", "ON"\)/.define("ENABLE_LTO", "OFF")/' "$build_rs"
    perl -0pi -e 's/println!\("cargo:rustc-link-lib=stdc\+\+"\);/if std::env::var("CARGO_CFG_TARGET_OS").ok().as_deref() == Some("android") {\n        println!("cargo:rustc-link-lib=c++_shared");\n    } else {\n        println!("cargo:rustc-link-lib=stdc++");\n    }/' "$build_rs"
done
