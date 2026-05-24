# Offline Translator KOPlugin

Offline translation and OCR bridge for KOReader. It uses Firefox translation
models for local Bergamot translation, KOReader's own `data/tessdata`
directory for Tesseract OCR, and optional PaddleOCR/PPOCR MNN models for
speech-bubble OCR. Japanese manga bubbles can also use Manga OCR through
ONNX Runtime when the Manga OCR model files are installed.

## Runtime

The plugin is available from the Search settings menu in both the file manager
and the reader. In the reader, selected text also gets an `Offline Translation`
entry at the end of the long-press lookup menu.

Menu paths:

- File manager: `Search` > `Settings` > `Offline Translator`
- Reader: `Search` > `Settings` > `Offline Translator`
- Selected text in reader: long press text > select text > `Offline Translation`

Use the plugin menu to update the model catalog, download explicit translation
directions, choose the default installed direction, choose the OCR engine, and
configure the selected OCR engine. The translation result window shows the
selected original text before the translation by default; use `Show original` /
`Hide original` to toggle it.

Downloaded data is stored under KOReader's data directory:

- Model catalog: `<KOReader data dir>/offlinetranslator/models/models.json`
- Translation model files: `<KOReader data dir>/offlinetranslator/models/models/...`
- PPOCR model files: `<KOReader data dir>/offlinetranslator/ppocr/`
- Manga OCR model files: `<KOReader data dir>/offlinetranslator/manga-ocr/`

PPOCR uses PP-OCRv5 MNN files. Download URLs and filenames are generated from
David Ventura's PPOCR catalog generator:
https://github.com/DavidVentura/offline-translator/blob/master/catalog_ppocr.py

The catalog mirror base is:
https://offline-translator.davidv.dev/ocr/1/PP-OCRv5/

All PPOCR setups need the detector pack files:

| URL | Save as |
| --- | --- |
| https://offline-translator.davidv.dev/ocr/1/PP-OCRv5/PP-OCRv5_mobile_det_int8.mnn | `PP-OCRv5_mobile_det_int8.mnn` |
| https://offline-translator.davidv.dev/ocr/1/PP-OCRv5/PULC_int8.mnn | `PULC_int8.mnn` |
| https://offline-translator.davidv.dev/ocr/1/PP-OCRv5/textline_ori_x0_25_wq8.mnn | `textline_ori_x0_25_wq8.mnn` |

Recognizer packs are script-based, not one model per language. Put the
recognizer model and keys file for the selected script in the same PPOCR
directory. The plugin accepts both direct files under
`<KOReader data dir>/offlinetranslator/ppocr/` and catalog-style files under
`<KOReader data dir>/offlinetranslator/ppocr/PP-OCRv5/`.

| Languages | Script | Recognizer URL | Save recognizer as | Keys URL | Save keys as |
| --- | --- | --- | --- | --- | --- |
| `ja`, `zh`, `zh_hant` | `cj` | https://offline-translator.davidv.dev/ocr/1/PP-OCRv5/PP-OCRv5_mobile_rec_int8.mnn | `PP-OCRv5_mobile_rec_int8.mnn` | https://offline-translator.davidv.dev/ocr/1/PP-OCRv5/cj_PP-OCRv5_keys.txt | `cj_PP-OCRv5_keys.txt` |
| `az`, `bs`, `ca`, `cs`, `da`, `de`, `en`, `es`, `et`, `fi`, `fr`, `hr`, `hu`, `id`, `is`, `it`, `lt`, `lv`, `ms`, `nb`, `nl`, `nn`, `no`, `pl`, `pt`, `ro`, `sk`, `sl`, `sq`, `sv`, `tr`, `vi` | `latin` | https://offline-translator.davidv.dev/ocr/1/PP-OCRv5/latin_PP-OCRv5_mobile_rec_infer_int8.mnn | `latin_PP-OCRv5_mobile_rec_infer_int8.mnn` | https://offline-translator.davidv.dev/ocr/1/PP-OCRv5/latin_PP-OCRv5_keys.txt | `latin_PP-OCRv5_keys.txt` |
| `ko` | `korean` | https://offline-translator.davidv.dev/ocr/1/PP-OCRv5/korean_PP-OCRv5_mobile_rec_infer_int8.mnn | `korean_PP-OCRv5_mobile_rec_infer_int8.mnn` | https://offline-translator.davidv.dev/ocr/1/PP-OCRv5/korean_PP-OCRv5_keys.txt | `korean_PP-OCRv5_keys.txt` |
| `ar`, `fa` | `arabic` | https://offline-translator.davidv.dev/ocr/1/PP-OCRv5/arabic_PP-OCRv5_mobile_rec_infer_int8.mnn | `arabic_PP-OCRv5_mobile_rec_infer_int8.mnn` | https://offline-translator.davidv.dev/ocr/1/PP-OCRv5/arabic_PP-OCRv5_keys.txt | `arabic_PP-OCRv5_keys.txt` |
| `bg`, `sr` | `cyrillic` | https://offline-translator.davidv.dev/ocr/1/PP-OCRv5/cyrillic_PP-OCRv5_mobile_rec_infer_int8.mnn | `cyrillic_PP-OCRv5_mobile_rec_infer_int8.mnn` | https://offline-translator.davidv.dev/ocr/1/PP-OCRv5/cyrillic_PP-OCRv5_keys.txt | `cyrillic_PP-OCRv5_keys.txt` |
| `be`, `ru`, `uk` | `eslav` | https://offline-translator.davidv.dev/ocr/1/PP-OCRv5/eslav_PP-OCRv5_mobile_rec_infer_int8.mnn | `eslav_PP-OCRv5_mobile_rec_infer_int8.mnn` | https://offline-translator.davidv.dev/ocr/1/PP-OCRv5/eslav_PP-OCRv5_keys.txt | `eslav_PP-OCRv5_keys.txt` |
| `el` | `el` | https://offline-translator.davidv.dev/ocr/1/PP-OCRv5/el_PP-OCRv5_mobile_rec_infer_int8.mnn | `el_PP-OCRv5_mobile_rec_infer_int8.mnn` | https://offline-translator.davidv.dev/ocr/1/PP-OCRv5/el_PP-OCRv5_keys.txt | `el_PP-OCRv5_keys.txt` |
| `hi` | `devanagari` | https://offline-translator.davidv.dev/ocr/1/PP-OCRv5/devanagari_PP-OCRv5_mobile_rec_infer_int8.mnn | `devanagari_PP-OCRv5_mobile_rec_infer_int8.mnn` | https://offline-translator.davidv.dev/ocr/1/PP-OCRv5/devanagari_PP-OCRv5_keys.txt | `devanagari_PP-OCRv5_keys.txt` |
| `ta` | `ta` | https://offline-translator.davidv.dev/ocr/1/PP-OCRv5/ta_PP-OCRv5_mobile_rec_infer_int8.mnn | `ta_PP-OCRv5_mobile_rec_infer_int8.mnn` | https://offline-translator.davidv.dev/ocr/1/PP-OCRv5/ta_PP-OCRv5_keys.txt | `ta_PP-OCRv5_keys.txt` |
| `te` | `te` | https://offline-translator.davidv.dev/ocr/1/PP-OCRv5/te_PP-OCRv5_mobile_rec_infer_int8.mnn | `te_PP-OCRv5_mobile_rec_infer_int8.mnn` | https://offline-translator.davidv.dev/ocr/1/PP-OCRv5/te_PP-OCRv5_keys.txt | `te_PP-OCRv5_keys.txt` |
| `th` | `th` | https://offline-translator.davidv.dev/ocr/1/PP-OCRv5/th_PP-OCRv5_mobile_rec_infer_int8.mnn | `th_PP-OCRv5_mobile_rec_infer_int8.mnn` | https://offline-translator.davidv.dev/ocr/1/PP-OCRv5/th_PP-OCRv5_keys.txt | `th_PP-OCRv5_keys.txt` |

The plugin expects these catalog-provided MNN files directly.

Manga OCR is Japanese-only and expects these files directly under
`<KOReader data dir>/offlinetranslator/manga-ocr/`:

| URL | Save as |
| --- | --- |
| https://huggingface.co/l0wgear/manga-ocr-2025-onnx/resolve/main/encoder_model.onnx | `encoder_model.onnx` |
| https://huggingface.co/l0wgear/manga-ocr-2025-onnx/resolve/main/decoder_model.onnx | `decoder_model.onnx` |
| https://huggingface.co/l0wgear/manga-ocr-2025-onnx/resolve/main/tokenizer.json | `tokenizer.json` |
| https://huggingface.co/l0wgear/manga-ocr-2025-onnx/resolve/main/generation_config.json | `generation_config.json` |

Manga OCR also needs ONNX Runtime next to those files. The tested Linux runtime
is bundled in release/build packages and copied automatically into
`<KOReader data dir>/offlinetranslator/manga-ocr/` when Manga OCR is used.

Android arm64-v8a and Linux x86_64 builds include Manga OCR support. The Android
package also ships `libc++_shared.so`, which is required by the native
Tesseract/Slimt/MNN stack.

## Lua API

Other plugins can use `require("pluginshare").offlinetranslator`:

- `translate(text, from_code, to_code)`
- `getInstalledPairs()` returns `{ from, to, label }` rows.
- `getDirection()` and `setDirection(from_code, to_code)`
- `getInstalledTessdataLanguages()`
- `getTessdataLanguage()` and `setTessdataLanguage(language)`
- `getOcrEngines()`, `getOcrEngine()`, and `setOcrEngine(engine)`
- `getOcrPsmModes()`, `getOcrPsmMode()`, and `setOcrPsmMode(mode)`
- `getPpocrScripts()`, `getPpocrScript()`, and `setPpocrScript(script)`
- `isPpocrScriptInstalled(script)`
- `isMangaOcrInstalled()` and `getMangaOcrDir()`
- `ocrImageRgba(image, bbox, language, psm, engine, ppocr_script)`

`ocrImageRgba` accepts the same image table used internally by the plugin and an
optional bbox table `{ x, y, w, h }`. If `language` is omitted, the configured
Tesseract language is used. If `engine` is `ppocr`, `language` and `psm` are
ignored and `ppocr_script` defaults to the configured PPOCR script. If `engine`
is `manga_ocr`, the plugin uses the configured Manga OCR model directory and
ignores Tesseract/PPOCR-specific arguments.

## Build Dependencies

- Rust toolchain with `cargo` and `rustc`
- Android arm64 Rust target installed by the build script via `rustup target add`
- `ANDROID_NDK_HOME` for Android builds
- `git` for Rust git dependencies and MNN submodules
- `cmake`
- `clang` and `libclang` for bindgen
- `curl`
- `unzip`
- `gzip` at runtime for unpacking Firefox model files
- Manga OCR uses Rust `ort` with dynamic ONNX Runtime loading. Build packages
  ship `libonnxruntime.so*`; advanced users can set `OFFLINETRANSLATOR_ONNXRUNTIME`
  to an absolute ONNX Runtime shared library path.

## Build

```sh
make all
```

The build script downloads the currently selected latest `translator-rs` commit
used by this plugin, applies the local KOReader bridge patches, and builds the
Lua FFI native library.

Packaged plugin trees are written as:

- `build/linux-x86_64/offlinetranslator.koplugin`
- `build/android-arm64-v8a/offlinetranslator.koplugin`

Native libraries are also staged under `libs/` for local development.

## Credits

- translator-rs: https://github.com/DavidVentura/translator-rs
- offline-translator PPOCR catalog and model mirror: https://github.com/DavidVentura/offline-translator
- l0wgear manga-ocr implementation reference: https://github.com/l0wgear/manga-ocr
- manga-ocr 2025 ONNX models: https://huggingface.co/l0wgear/manga-ocr-2025-onnx
- Offline Translator KOPlugin bridge and integration work: ChatGPT Codex
