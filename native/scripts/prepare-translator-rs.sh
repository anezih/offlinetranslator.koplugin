#!/usr/bin/env sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
NATIVE_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
VENDOR_DIR="$NATIVE_DIR/vendor"
SRC_DIR="$VENDOR_DIR/translator-rs"
ZIP_PATH="$VENDOR_DIR/translator-rs.zip"
COMMIT="1ce400128b9fecdc988d0e0b768bd091af8586d6"
URL="https://github.com/DavidVentura/translator-rs/archive/$COMMIT.zip"

COMMIT_MARKER="$SRC_DIR/.translator-rs-commit"

if [ -f "$SRC_DIR/Cargo.toml" ] && [ -f "$COMMIT_MARKER" ] && [ "$(cat "$COMMIT_MARKER")" = "$COMMIT" ]; then
    exit 0
fi

mkdir -p "$VENDOR_DIR"
if [ ! -f "$ZIP_PATH.commit" ] || [ "$(cat "$ZIP_PATH.commit")" != "$COMMIT" ]; then
    rm -f "$ZIP_PATH"
fi
if [ ! -f "$ZIP_PATH" ]; then
    curl -L --fail "$URL" -o "$ZIP_PATH"
fi
printf "%s" "$COMMIT" > "$ZIP_PATH.commit"

rm -rf "$VENDOR_DIR"/translator-rs-"$COMMIT" "$SRC_DIR"
unzip -q "$ZIP_PATH" -d "$VENDOR_DIR"
mv "$VENDOR_DIR"/translator-rs-"$COMMIT" "$SRC_DIR"
printf "%s" "$COMMIT" > "$COMMIT_MARKER"

# translator-rs 59a2212c references crate::coords from ocr.rs when the
# tesseract feature is enabled, but coords/homography are gated only behind
# ppocr/planar-tracker upstream. Keep this local bridge build minimal by
# exposing those small utility modules for tesseract too.
perl -0pi -e 's/#\[cfg\(any\(feature = "ppocr", feature = "planar-tracker"\)\)\]\npub mod coords;/#[cfg(any(feature = "ppocr", feature = "planar-tracker", feature = "tesseract"))]\npub mod coords;/' "$SRC_DIR/src/lib.rs"
perl -0pi -e 's/#\[cfg\(any\(feature = "ppocr", feature = "planar-tracker"\)\)\]\npub mod homography;/#[cfg(any(feature = "ppocr", feature = "planar-tracker", feature = "tesseract"))]\npub mod homography;/' "$SRC_DIR/src/lib.rs"

perl -0pi -e 's/    pub fn get_word_boxes\(&mut self\) -> Result<Vec<DetectedWord>, Box<dyn std::error::Error>> \{/    pub fn get_text\(\&mut self\) -> Result<String, Box<dyn std::error::Error>> {\n        if let Some(ref mut engine) = self.engine {\n            return engine.get_text().map_err(|err| Box::new(err) as Box<dyn std::error::Error>);\n        }\n        Err(Box::new(std::io::Error::other(\n            "get_text called but engine is None",\n        )))\n    }\n\n    pub fn get_word_boxes\(\&mut self\) -> Result<Vec<DetectedWord>, Box<dyn std::error::Error>> {/g' "$SRC_DIR/src/tesseract.rs"

# KOReader uses its own tessdata directory, so the bridge catalog may contain
# translation-only languages without bundled Tesseract packs.
perl -0pi -e 's/    let tesseract_pack_id = resources\n        \.ocr_packs\n        \.iter\(\)\n        \.find\(\|\(engine, _\)\| engine == "tesseract"\)\n        \.map\(\|\(_, pack_id\)\| pack_id\)\?;\n    let tesseract_pack = packs\.get\(tesseract_pack_id\)\?;\n    let tess_file = tesseract_pack\.files\.first\(\)\?;\n    let tess_name = tess_file\.name\.strip_suffix\("\.traineddata"\)\?\.to_string\(\);\n    let tessdata_size_bytes = tesseract_pack\n        \.files\n        \.iter\(\)\n        \.map\(\|file\| file\.size_bytes\)\n        \.sum\(\);/    let (tess_name, tessdata_size_bytes) = resources\n        .ocr_packs\n        .iter()\n        .find(|(engine, _)| engine == "tesseract")\n        .and_then(|(_, pack_id)| packs.get(pack_id))\n        .and_then(|pack| {\n            let tess_file = pack.files.first()?;\n            Some((\n                tess_file.name.strip_suffix(".traineddata")?.to_string(),\n                pack.files.iter().map(|file| file.size_bytes).sum(),\n            ))\n        })\n        .unwrap_or_else(|| (entry.meta.code.clone(), 0));/' "$SRC_DIR/src/catalog_wire.rs"
