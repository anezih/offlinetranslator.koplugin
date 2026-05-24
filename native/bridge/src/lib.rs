use std::cmp::Reverse;
use std::collections::HashMap;
use std::ffi::{CStr, CString};
use std::os::raw::{c_char, c_int, c_uchar, c_uint};
use std::path::{Path, PathBuf};
use std::ptr;
use std::sync::{Arc, Mutex, OnceLock};

use image::{DynamicImage, GrayImage, ImageBuffer, Rgba};
#[cfg(feature = "manga-ocr")]
mod manga_ocr;
#[cfg(feature = "manga-ocr")]
use manga_ocr::MangaOcr;
use serde_json::{Map, Value, json};
use translator::catalog::DownloadPlan;
#[cfg(feature = "ppocr")]
use translator::coords::Quadrant;
#[cfg(feature = "ppocr")]
use translator::ocr::{DetectedTextBox, OrientedRect, Rect};
#[cfg(feature = "ppocr")]
use translator::ppocr::{PpocrEngine, PpocrProfile, PpocrRecognizerSpec};
use translator::tesseract::{DetectedWord, PageSegMode, TesseractWrapper};
use translator::{Feature, FsPackInstallChecker, PpocrScript, TranslatorSession};

pub struct Session {
    inner: TranslatorSession,
}

#[cfg(feature = "ppocr")]
static PPOCR_CACHE: OnceLock<Mutex<HashMap<String, Arc<PpocrEngine>>>> = OnceLock::new();
#[cfg(feature = "manga-ocr")]
static MANGA_OCR_CACHE: OnceLock<Mutex<HashMap<String, Arc<MangaOcr>>>> = OnceLock::new();

fn cstr(ptr: *const c_char) -> Result<String, String> {
    if ptr.is_null() {
        return Err("null string".to_string());
    }
    unsafe { CStr::from_ptr(ptr) }
        .to_str()
        .map(str::to_owned)
        .map_err(|err| err.to_string())
}

fn cstr_opt(ptr: *const c_char) -> Option<String> {
    if ptr.is_null() { None } else { cstr(ptr).ok() }
}

fn into_c_string(value: String) -> *mut c_char {
    match CString::new(value) {
        Ok(s) => s.into_raw(),
        Err(err) => CString::new(err.to_string()).unwrap().into_raw(),
    }
}

fn result_string<T, F>(f: F) -> *mut c_char
where
    F: FnOnce() -> Result<T, String>,
    T: Into<String>,
{
    match std::panic::catch_unwind(std::panic::AssertUnwindSafe(f)) {
        Ok(Ok(value)) => into_c_string(value.into()),
        Ok(Err(err)) => into_c_string(format!("ERROR: {err}")),
        Err(_) => into_c_string("ERROR: native OCR/translation panicked".to_string()),
    }
}

fn plan_to_json(plan: DownloadPlan) -> String {
    let tasks = plan
        .tasks
        .into_iter()
        .map(|task| {
            json!({
                "pack_id": task.pack_id,
                "install_path": task.install_path,
                "url": task.url,
                "size_bytes": task.size_bytes,
                "decompress": task.decompress,
                "archive_format": task.archive_format,
                "extract_to": task.extract_to,
                "delete_after_extract": task.delete_after_extract,
                "install_marker_path": task.install_marker_path,
                "install_marker_version": task.install_marker_version,
            })
        })
        .collect::<Vec<_>>();
    json!({ "total_size": plan.total_size, "tasks": tasks }).to_string()
}

fn basename(path: &str) -> String {
    path.rsplit('/').next().unwrap_or(path).to_string()
}

fn strip_gz(path: &str) -> String {
    path.strip_suffix(".gz").unwrap_or(path).to_string()
}

fn compact_ocr_text(text: &str) -> String {
    text.split_whitespace().collect::<String>()
}

fn vertical_text_from_words(mut words: Vec<DetectedWord>) -> String {
    words.retain(|word| !word.text.trim().is_empty());
    if words.is_empty() {
        return String::new();
    }
    words.sort_by_key(|word| {
        let rect = word.bounding_rect;
        (
            Reverse(rect.left + rect.width() / 2),
            rect.top,
            rect.left,
            rect.bottom,
        )
    });
    let mut columns: Vec<Vec<DetectedWord>> = Vec::new();
    let mut column_centers: Vec<i32> = Vec::new();
    for word in words {
        let rect = word.bounding_rect;
        let center = rect.left + rect.width() / 2;
        let threshold = rect.width().max(12);
        if let Some(index) = column_centers
            .iter()
            .position(|column_center| (center - *column_center).abs() <= threshold)
        {
            let len = columns[index].len() as i32;
            column_centers[index] = (column_centers[index] * len + center) / (len + 1);
            columns[index].push(word);
        } else {
            column_centers.push(center);
            columns.push(vec![word]);
        }
    }
    let mut indices = (0..columns.len()).collect::<Vec<_>>();
    indices.sort_by_key(|index| Reverse(column_centers[*index]));
    let mut out = String::new();
    for index in indices {
        columns[index].sort_by_key(|word| {
            let rect = word.bounding_rect;
            (rect.top, rect.left, rect.bottom)
        });
        for word in &columns[index] {
            out.push_str(&compact_ocr_text(&word.text));
        }
    }
    out.trim().to_string()
}

fn page_seg_mode_from_name(psm: Option<&str>, is_vertical: bool) -> PageSegMode {
    match psm.unwrap_or("auto") {
        "auto_osd" => PageSegMode::PsmAutoOsd,
        "auto" => {
            if is_vertical {
                PageSegMode::PsmSingleBlockVertText
            } else {
                PageSegMode::PsmAutoOsd
            }
        }
        "auto_only" => PageSegMode::PsmAutoOnly,
        "single_column" => PageSegMode::PsmSingleColumn,
        "single_block_vert" | "vertical" => PageSegMode::PsmSingleBlockVertText,
        "single_block" => PageSegMode::PsmSingleBlock,
        "single_line" => PageSegMode::PsmSingleLine,
        "sparse_text" => PageSegMode::PsmSparseText,
        "sparse_text_osd" => PageSegMode::PsmSparseTextOsd,
        "raw_line" => PageSegMode::PsmRawLine,
        _ => {
            if is_vertical {
                PageSegMode::PsmSingleBlockVertText
            } else {
                PageSegMode::PsmAutoOsd
            }
        }
    }
}

fn ppocr_script_from_name(value: &str) -> Result<PpocrScript, String> {
    PpocrScript::from_slug(value).ok_or_else(|| format!("unsupported ppocr script: {value}"))
}

#[cfg(feature = "ppocr")]
fn first_existing(paths: &[PathBuf]) -> Option<PathBuf> {
    paths.iter().find(|path| path.is_file()).cloned()
}

#[cfg(feature = "ppocr")]
fn ppocr_recognizer_model_paths(base: &Path, script_slug: &str) -> Vec<PathBuf> {
    let current = match script_slug {
        "cj" => "PP-OCRv5_mobile_rec_int8.mnn".to_string(),
        _ => format!("{script_slug}_PP-OCRv5_mobile_rec_infer_int8.mnn"),
    };
    vec![
        base.join(current),
        base.join(format!("{script_slug}_PP-OCRv5_mobile_rec_infer.mnn")),
    ]
}

#[cfg(feature = "ppocr")]
fn ppocr_engine(base_dir: &str, script: PpocrScript) -> Result<Arc<PpocrEngine>, String> {
    let cache_key = format!("{}:{}", base_dir, script.as_slug());
    let cache = PPOCR_CACHE.get_or_init(|| Mutex::new(HashMap::new()));
    if let Some(engine) = cache
        .lock()
        .map_err(|_| "ppocr cache mutex poisoned".to_string())?
        .get(&cache_key)
        .cloned()
    {
        return Ok(engine);
    }

    let base = Path::new(base_dir);
    let det_path = first_existing(&[
        base.join("PP-OCRv5_mobile_det_int8.mnn"),
        base.join("PP-OCRv5_mobile_det.mnn"),
        base.join("PP-OCRv5_mobile_det_fp16.mnn"),
    ])
    .ok_or_else(|| {
        format!(
            "missing PPOCR detector model in {}: expected PP-OCRv5_mobile_det_int8.mnn",
            base.display()
        )
    })?;
    let script_slug = script.as_slug();
    let rec_model = first_existing(&ppocr_recognizer_model_paths(base, script_slug))
        .ok_or_else(|| format!("missing PPOCR recognizer model for script: {script_slug}"))?;
    let rec_keys = base.join(format!("{script_slug}_PP-OCRv5_keys.txt"));
    if !rec_keys.is_file() {
        return Err(format!(
            "missing PPOCR recognizer keys: {}",
            rec_keys.display()
        ));
    }
    let textline_orientation = first_existing(&[
        base.join("textline_ori_x0_25_wq8.mnn"),
        base.join("textline_ori_x1_0_fp32.mnn"),
        base.join("textline_ori_x1_0_wq8.mnn"),
    ]);
    let engine = Arc::new(
        PpocrEngine::load(
            &det_path,
            None,
            textline_orientation.as_deref(),
            vec![PpocrRecognizerSpec {
                script,
                model_path: rec_model,
                keys_path: rec_keys,
            }],
            2,
        )
        .map_err(|err| err.to_string())?,
    );
    cache
        .lock()
        .map_err(|_| "ppocr cache mutex poisoned".to_string())?
        .insert(cache_key, Arc::clone(&engine));
    Ok(engine)
}

#[cfg(feature = "manga-ocr")]
fn manga_ocr_engine(base_dir: &str) -> Result<Arc<MangaOcr>, String> {
    let cache = MANGA_OCR_CACHE.get_or_init(|| Mutex::new(HashMap::new()));
    if let Some(engine) = cache
        .lock()
        .map_err(|_| "manga OCR cache mutex poisoned".to_string())?
        .get(base_dir)
        .cloned()
    {
        return Ok(engine);
    }

    let base = Path::new(base_dir);
    for file in [
        "encoder_model.onnx",
        "decoder_model.onnx",
        "tokenizer.json",
        "generation_config.json",
    ] {
        let path = base.join(file);
        if !path.is_file() {
            return Err(format!("missing Manga OCR model file: {}", path.display()));
        }
    }
    let engine = Arc::new(MangaOcr::new(base).map_err(|err| format!("{err:#}"))?);
    cache
        .lock()
        .map_err(|_| "manga OCR cache mutex poisoned".to_string())?
        .insert(base_dir.to_string(), Arc::clone(&engine));
    Ok(engine)
}

fn rgba_image_from_raw(
    data: *const c_uchar,
    width: usize,
    height: usize,
    stride: usize,
    x: usize,
    y: usize,
    w: usize,
    h: usize,
) -> Result<DynamicImage, String> {
    if data.is_null() {
        return Err("null image data".to_string());
    }
    if x >= width || y >= height || x + w > width || y + h > height {
        return Err("bbox is outside image bounds".to_string());
    }
    if stride < width * 4 {
        return Err("stride is too small for RGBA data".to_string());
    }
    let source_len = stride
        .checked_mul(height)
        .ok_or_else(|| "image size overflow".to_string())?;
    let source = unsafe { std::slice::from_raw_parts(data, source_len) };
    let mut cropped = Vec::with_capacity(w * h * 4);
    for row in y..(y + h) {
        let start = row * stride + x * 4;
        cropped.extend_from_slice(&source[start..start + w * 4]);
    }
    let image = ImageBuffer::<Rgba<u8>, Vec<u8>>::from_raw(w as u32, h as u32, cropped)
        .ok_or_else(|| "failed to create RGBA image".to_string())?;
    Ok(DynamicImage::ImageRgba8(image))
}

#[cfg(feature = "ppocr")]
fn cj_line_text(mut lines: Vec<translator::ocr::RecognizedTextLine>) -> String {
    lines.retain(|line| !line.text.trim().is_empty());
    lines.sort_by_key(|line| {
        let rect = line.rect;
        (
            Reverse((rect.left + rect.right) / 2),
            rect.top,
            rect.left,
            rect.bottom,
        )
    });
    let mut out = String::new();
    for line in lines {
        let text = line.text.trim();
        if !text.is_empty() {
            out.push_str(text);
        }
    }
    out.trim().to_string()
}

#[cfg(feature = "ppocr")]
fn ppocr_cj_projection_boxes(gray: &GrayImage) -> Vec<DetectedTextBox> {
    let w = gray.width();
    let h = gray.height();
    if w < 32 || h < 32 {
        return Vec::new();
    }

    let x_margin = (w / 25).max(3);
    let y_margin = (h / 25).max(3);
    let min_dark_per_x = (h / 70).max(3);
    let max_dark_per_x = h.saturating_mul(4) / 5;
    let max_gap = (w / 35).max(4);
    let min_col_w = (w / 30).max(6);
    let max_col_w = (w / 3).max(min_col_w);
    let min_col_h = (h / 7).max(20);
    let expand_x = (w / 45).max(4);
    let expand_y = (h / 45).max(4);

    let mut runs = Vec::<(u32, u32)>::new();
    let mut start = None::<u32>;
    let mut last_dark = 0u32;
    for x in x_margin..w.saturating_sub(x_margin) {
        let mut dark = 0u32;
        for y in y_margin..h.saturating_sub(y_margin) {
            if gray.get_pixel(x, y)[0] < 170 {
                dark += 1;
            }
        }
        if dark >= min_dark_per_x && dark <= max_dark_per_x {
            if start.is_none() {
                start = Some(x);
            }
            last_dark = x;
        } else if let Some(s) = start {
            if x.saturating_sub(last_dark) > max_gap {
                runs.push((s, last_dark));
                start = None;
            }
        }
    }
    if let Some(s) = start {
        runs.push((s, last_dark));
    }

    let mut boxes = Vec::new();
    for (left, right) in runs {
        let col_w = right.saturating_sub(left) + 1;
        if col_w < min_col_w || col_w > max_col_w {
            continue;
        }
        let l = left.saturating_sub(expand_x);
        let r = (right + expand_x).min(w);
        let mut top = h;
        let mut bottom = 0u32;
        for y in y_margin..h.saturating_sub(y_margin) {
            let mut row_dark = false;
            for x in l..r {
                if gray.get_pixel(x, y)[0] < 170 {
                    row_dark = true;
                    break;
                }
            }
            if row_dark {
                top = top.min(y);
                bottom = bottom.max(y);
            }
        }
        if bottom <= top || bottom.saturating_sub(top) < min_col_h {
            continue;
        }
        let rect = Rect {
            left: l,
            top: top.saturating_sub(expand_y),
            right: r,
            bottom: (bottom + expand_y).min(h),
        };
        let oriented = OrientedRect::axis_aligned(rect);
        boxes.push(DetectedTextBox {
            rect,
            oriented_box: oriented,
            tight_box: oriented,
            contour: Vec::new(),
            score: 1.0,
        });
    }

    boxes.sort_by_key(|b| Reverse((b.rect.left + b.rect.right) / 2));
    boxes
}

#[cfg(feature = "ppocr")]
fn ppocr_cj_projection_text_for_quadrant(
    engine: &PpocrEngine,
    image: &DynamicImage,
    gray: &GrayImage,
    script: PpocrScript,
    quadrant: Quadrant,
) -> Result<String, String> {
    let boxes = ppocr_cj_projection_boxes(gray);
    if boxes.is_empty() {
        return Ok(String::new());
    }
    let scripts = vec![script; boxes.len()];
    let lines = engine
        .recognize_text_in_boxes_image(
            image,
            gray,
            &boxes,
            &scripts,
            PpocrProfile::Still,
            Some(quadrant),
        )
        .map_err(|err| err.to_string())?;
    Ok(cj_line_text(lines))
}

#[cfg(feature = "ppocr")]
fn ppocr_cj_projection_text(
    engine: &PpocrEngine,
    image: &DynamicImage,
    gray: &GrayImage,
    script: PpocrScript,
) -> Result<String, String> {
    let r90 = ppocr_cj_projection_text_for_quadrant(engine, image, gray, script, Quadrant::R90)?;
    let r270 = ppocr_cj_projection_text_for_quadrant(engine, image, gray, script, Quadrant::R270)?;
    if r270.chars().count() > r90.chars().count() {
        Ok(r270)
    } else {
        Ok(r90)
    }
}

fn file_from_mozilla(base_url: &str, file: &Value) -> Option<Value> {
    let path = file.get("path")?.as_str()?;
    let install_path = strip_gz(path);
    Some(json!({
        "name": basename(&install_path),
        "sizeBytes": file.get("uncompressedSize").and_then(Value::as_u64).unwrap_or(0),
        "installPath": install_path,
        "url": format!("{}/{}", base_url.trim_end_matches('/'), path),
        "sourcePath": path,
        "decompress": path.ends_with(".gz"),
    }))
}

fn language_entry(code: &str, translate: Vec<String>) -> Value {
    json!({
        "meta": {
            "code": code,
            "name": code,
            "shortName": code,
            "script": "Latn",
        },
        "assets": {
            "translate": translate,
        },
    })
}

fn mozilla_models_to_language_catalog(json_text: &str) -> Option<String> {
    let value: Value = serde_json::from_str(json_text).ok()?;
    if value.get("formatVersion").is_some() {
        return Some(json_text.to_string());
    }
    let models = value.get("models")?.as_object()?;
    let base_url = value.get("baseUrl").and_then(Value::as_str).unwrap_or(
        "https://storage.googleapis.com/moz-fx-translations-data--303e-prod-translations-data",
    );

    let mut packs = Map::new();
    let mut language_packs: std::collections::HashMap<String, Vec<String>> =
        std::collections::HashMap::new();

    for (pair_key, entries) in models {
        let Some(entries) = entries.as_array() else {
            continue;
        };
        let selected = entries
            .iter()
            .find(|entry| entry.get("releaseStatus").and_then(Value::as_str) == Some("Release"))
            .or_else(|| entries.first());
        let Some(model_entry) = selected else {
            continue;
        };
        let from = model_entry
            .get("sourceLanguage")
            .and_then(Value::as_str)
            .or_else(|| pair_key.split_once('-').map(|(from, _)| from))?;
        let to = model_entry
            .get("targetLanguage")
            .and_then(Value::as_str)
            .or_else(|| pair_key.split_once('-').map(|(_, to)| to))?;
        let files = model_entry.get("files")?.as_object()?;
        let mut pack_files = Vec::new();
        for key in ["model", "vocab", "srcvocab", "trgvocab", "lexicalShortlist"] {
            if let Some(file) = files
                .get(key)
                .and_then(|file| file_from_mozilla(base_url, file))
            {
                pack_files.push(file);
            }
        }
        if pack_files.len() < 3 {
            continue;
        }
        let pack_id = format!("translation-{from}-{to}");
        packs.insert(
            pack_id.clone(),
            json!({
                "feature": "translation",
                "from": from,
                "to": to,
                "files": pack_files,
            }),
        );
        language_packs
            .entry(from.to_string())
            .or_default()
            .push(pack_id.clone());
        language_packs
            .entry(to.to_string())
            .or_default()
            .push(pack_id);
    }

    if packs.is_empty() {
        return None;
    }

    let mut languages = Map::new();
    for (code, translate) in language_packs {
        languages.insert(code.clone(), language_entry(&code, translate));
    }

    Some(
        json!({
            "formatVersion": 3,
            "generatedAt": 0,
            "dictionaryVersion": 0,
            "sources": {
                "languageIndexVersion": 0,
                "languageIndexUpdatedAt": 0,
                "dictionaryIndexVersion": 0,
                "dictionaryIndexUpdatedAt": 0,
            },
            "languages": languages,
            "packs": packs,
        })
        .to_string(),
    )
}

#[unsafe(no_mangle)]
pub extern "C" fn koreader_offlinetranslator_version() -> *mut c_char {
    into_c_string("translator-rs bridge 0.1.0".to_string())
}

#[unsafe(no_mangle)]
pub extern "C" fn koreader_offlinetranslator_string_free(value: *mut c_char) {
    if !value.is_null() {
        unsafe {
            let _ = CString::from_raw(value);
        }
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn koreader_offlinetranslator_session_new(
    catalog_json: *const c_char,
    disk_catalog_json: *const c_char,
    base_dir: *const c_char,
) -> *mut Session {
    let catalog_json = match cstr(catalog_json) {
        Ok(v) => v,
        Err(_) => return ptr::null_mut(),
    };
    let disk_catalog = cstr_opt(disk_catalog_json);
    let base_dir = match cstr(base_dir) {
        Ok(v) => v,
        Err(_) => return ptr::null_mut(),
    };
    let catalog_json = mozilla_models_to_language_catalog(&catalog_json).unwrap_or(catalog_json);
    let disk_catalog = disk_catalog
        .as_deref()
        .and_then(mozilla_models_to_language_catalog);
    let checker = FsPackInstallChecker::new(&base_dir);
    match TranslatorSession::open(&catalog_json, disk_catalog.as_deref(), base_dir, &checker) {
        Ok(inner) => Box::into_raw(Box::new(Session { inner })),
        Err(_) => ptr::null_mut(),
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn koreader_offlinetranslator_session_free(session: *mut Session) {
    if !session.is_null() {
        unsafe {
            let _ = Box::from_raw(session);
        }
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn koreader_offlinetranslator_refresh(session: *mut Session) -> c_int {
    if session.is_null() {
        return 0;
    }
    unsafe { &*session }.inner.refresh_snapshot();
    1
}

#[unsafe(no_mangle)]
pub extern "C" fn koreader_offlinetranslator_translate(
    session: *mut Session,
    from_code: *const c_char,
    to_code: *const c_char,
    text: *const c_char,
) -> *mut c_char {
    result_string(|| {
        if session.is_null() {
            return Err("session is not initialized".to_string());
        }
        let from_code = cstr(from_code)?;
        let to_code = cstr(to_code)?;
        let text = cstr(text)?;
        unsafe { &*session }
            .inner
            .translate_text(&from_code, &to_code, &text)
            .map_err(|err| err.to_string())
    })
}

#[unsafe(no_mangle)]
pub extern "C" fn koreader_offlinetranslator_plan_language_download(
    session: *mut Session,
    language_code: *const c_char,
) -> *mut c_char {
    result_string(|| {
        if session.is_null() {
            return Err("session is not initialized".to_string());
        }
        let language_code = cstr(language_code)?;
        let plan = unsafe { &*session }
            .inner
            .plan_download(&language_code, Feature::Core, None)
            .ok_or_else(|| format!("no download plan for {language_code}"))?;
        Ok(plan_to_json(plan))
    })
}

fn ocr_rgba_impl(
    tessdata_path: *const c_char,
    language: *const c_char,
    psm: *const c_char,
    data: *const c_uchar,
    width: c_uint,
    height: c_uint,
    stride: c_uint,
    bbox_x: c_uint,
    bbox_y: c_uint,
    bbox_w: c_uint,
    bbox_h: c_uint,
) -> *mut c_char {
    result_string(|| {
        if data.is_null() {
            return Err("null image data".to_string());
        }
        let tessdata_path = cstr(tessdata_path)?;
        let language = cstr(language)?;
        let psm = cstr_opt(psm);
        let width = width as usize;
        let height = height as usize;
        let stride = stride as usize;
        let x = bbox_x as usize;
        let y = bbox_y as usize;
        let w = if bbox_w == 0 { width } else { bbox_w as usize };
        let h = if bbox_h == 0 { height } else { bbox_h as usize };
        if x >= width || y >= height || x + w > width || y + h > height {
            return Err("bbox is outside image bounds".to_string());
        }
        if stride < width * 4 {
            return Err("stride is too small for RGBA data".to_string());
        }
        let source_len = stride
            .checked_mul(height)
            .ok_or_else(|| "image size overflow".to_string())?;
        let source = unsafe { std::slice::from_raw_parts(data, source_len) };
        let mut cropped = Vec::with_capacity(w * h * 4);
        for row in y..(y + h) {
            let start = row * stride + x * 4;
            cropped.extend_from_slice(&source[start..start + w * 4]);
        }
        let is_vertical = language
            .split('+')
            .any(|code| code == "jpn_vert" || code.ends_with("_vert"));
        let join_without_spaces = language
            .split('+')
            .any(|code| code == "jpn" || code == "jpn_vert" || code == "ja");
        let mut ocr = TesseractWrapper::new(Some(&tessdata_path), Some(&language))
            .map_err(|err| err.to_string())?;
        let page_seg_mode = page_seg_mode_from_name(psm.as_deref(), is_vertical);
        ocr.set_page_seg_mode(page_seg_mode);
        ocr.set_frame(&cropped, w as i32, h as i32, 4, (w * 4) as i32)
            .map_err(|err| err.to_string())?;
        if is_vertical {
            let words = ocr.get_word_boxes().map_err(|err| err.to_string())?;
            let text = vertical_text_from_words(words);
            if text.chars().count() >= 6 || psm.as_deref() != Some("auto") {
                return Ok(text);
            }
            let mut sparse_ocr = TesseractWrapper::new(Some(&tessdata_path), Some(&language))
                .map_err(|err| err.to_string())?;
            sparse_ocr.set_page_seg_mode(PageSegMode::PsmSparseText);
            sparse_ocr
                .set_frame(&cropped, w as i32, h as i32, 4, (w * 4) as i32)
                .map_err(|err| err.to_string())?;
            let sparse_words = sparse_ocr.get_word_boxes().map_err(|err| err.to_string())?;
            let sparse_text = vertical_text_from_words(sparse_words);
            if sparse_text.chars().count() > text.chars().count() {
                return Ok(sparse_text);
            }
            return Ok(text);
        }
        if join_without_spaces {
            let text = ocr.get_text().map_err(|err| err.to_string())?;
            let compact = compact_ocr_text(&text);
            if !compact.trim().is_empty() {
                return Ok(compact.trim().to_string());
            }
        }
        let words = ocr.get_word_boxes().map_err(|err| err.to_string())?;
        let mut out = String::new();
        for word in words {
            if !out.is_empty() && !join_without_spaces {
                out.push(' ');
            }
            out.push_str(word.text.trim());
            if word.end_line && !join_without_spaces {
                out.push('\n');
            }
        }
        Ok(out.trim().to_string())
    })
}

#[unsafe(no_mangle)]
pub extern "C" fn koreader_offlinetranslator_ocr_rgba(
    tessdata_path: *const c_char,
    language: *const c_char,
    psm: *const c_char,
    data: *const c_uchar,
    width: c_uint,
    height: c_uint,
    stride: c_uint,
    bbox_x: c_uint,
    bbox_y: c_uint,
    bbox_w: c_uint,
    bbox_h: c_uint,
) -> *mut c_char {
    ocr_rgba_impl(
        tessdata_path,
        language,
        psm,
        data,
        width,
        height,
        stride,
        bbox_x,
        bbox_y,
        bbox_w,
        bbox_h,
    )
}

#[unsafe(no_mangle)]
pub extern "C" fn koreader_offlinetranslator_ocr_ppocr_rgba(
    ppocr_path: *const c_char,
    script: *const c_char,
    data: *const c_uchar,
    width: c_uint,
    height: c_uint,
    stride: c_uint,
    bbox_x: c_uint,
    bbox_y: c_uint,
    bbox_w: c_uint,
    bbox_h: c_uint,
) -> *mut c_char {
    #[cfg(not(feature = "ppocr"))]
    {
        let _ = (
            ppocr_path,
            script,
            data,
            width,
            height,
            stride,
            bbox_x,
            bbox_y,
            bbox_w,
            bbox_h,
        );
        return into_c_string("ERROR: PPOCR is not available in this native build".to_string());
    }
    #[cfg(feature = "ppocr")]
    result_string(|| {
        let ppocr_path = cstr(ppocr_path)?;
        let script = ppocr_script_from_name(&cstr(script)?)?;
        let width = width as usize;
        let height = height as usize;
        let stride = stride as usize;
        let x = bbox_x as usize;
        let y = bbox_y as usize;
        let w = if bbox_w == 0 { width } else { bbox_w as usize };
        let h = if bbox_h == 0 { height } else { bbox_h as usize };
        let image = rgba_image_from_raw(data, width, height, stride, x, y, w, h)?;
        let gray = image.to_luma8();
        let engine = ppocr_engine(&ppocr_path, script)?;
        let boxes = engine
            .detect_only_image(&image, PpocrProfile::Still)
            .map_err(|err| err.to_string())?;
        let scripts = vec![script; boxes.len()];
        let mut lines = engine
            .recognize_text_in_boxes_image(
                &image,
                &gray,
                &boxes,
                &scripts,
                PpocrProfile::Still,
                None,
            )
            .map_err(|err| err.to_string())?;
        if script == PpocrScript::Cj {
            let detected_text = cj_line_text(lines);
            let projection_text = ppocr_cj_projection_text(&engine, &image, &gray, script)?;
            let detected_len = detected_text.chars().count();
            let projection_len = projection_text.chars().count();
            if projection_len > detected_len {
                return Ok(projection_text);
            }
            return Ok(detected_text);
        } else {
            lines.retain(|line| !line.text.trim().is_empty());
            lines.sort_by_key(|line| {
                let rect = line.rect;
                (rect.top, rect.left, rect.bottom, rect.right)
            });
        }
        let mut out = String::new();
        for line in lines {
            let text = line.text.trim();
            if text.is_empty() {
                continue;
            }
            if !out.is_empty() && script != PpocrScript::Cj {
                out.push('\n');
            }
            out.push_str(text);
        }
        Ok(out.trim().to_string())
    })
}

#[unsafe(no_mangle)]
pub extern "C" fn koreader_offlinetranslator_ocr_manga_rgba(
    manga_ocr_path: *const c_char,
    data: *const c_uchar,
    width: c_uint,
    height: c_uint,
    stride: c_uint,
    bbox_x: c_uint,
    bbox_y: c_uint,
    bbox_w: c_uint,
    bbox_h: c_uint,
) -> *mut c_char {
    #[cfg(not(feature = "manga-ocr"))]
    {
        let _ = (
            manga_ocr_path,
            data,
            width,
            height,
            stride,
            bbox_x,
            bbox_y,
            bbox_w,
            bbox_h,
        );
        return into_c_string("ERROR: Manga OCR is not available in this native build".to_string());
    }
    #[cfg(feature = "manga-ocr")]
    result_string(|| {
        let manga_ocr_path = cstr(manga_ocr_path)?;
        let width = width as usize;
        let height = height as usize;
        let stride = stride as usize;
        let x = bbox_x as usize;
        let y = bbox_y as usize;
        let w = if bbox_w == 0 { width } else { bbox_w as usize };
        let h = if bbox_h == 0 { height } else { bbox_h as usize };
        let image = rgba_image_from_raw(data, width, height, stride, x, y, w, h)?;
        if image.width() < 16 || image.height() < 16 {
            return Err("Manga OCR image crop is too small".to_string());
        }
        let engine = manga_ocr_engine(&manga_ocr_path)?;
        engine.recognize(&image).map_err(|err| format!("{err:#}"))
    })
}
