use std::ffi::CStr;
use std::os::raw::{c_char, c_int, c_void};
use std::path::{Path, PathBuf};
use std::sync::Mutex;

use anyhow::{Context, Result};
use image::{DynamicImage, RgbImage, imageops::FilterType};
use ndarray::{Array4, ArrayD, ArrayView, Slice, s};
use ort::session::{Session, builder::GraphOptimizationLevel};
use ort::value::{Tensor, TensorRef};
use serde::Deserialize;
use tokenizers::Tokenizer;

#[derive(Debug, Deserialize)]
struct GenerationConfig {
    decoder_start_token_id: u32,
    eos_token_id: u32,
    no_repeat_ngram_size: u32,
}

impl GenerationConfig {
    fn from_file(path: &Path) -> Result<Self> {
        let file = std::fs::File::open(path)
            .with_context(|| format!("generation config: open {}", path.display()))?;
        serde_json::from_reader(file)
            .with_context(|| format!("generation config: parse {}", path.display()))
    }
}

struct ModelDir {
    encoder_path: PathBuf,
    decoder_path: PathBuf,
    tokenizer_path: PathBuf,
    generation_config_path: PathBuf,
}

impl ModelDir {
    fn new(base: &Path) -> Result<Self> {
        let out = Self {
            encoder_path: base.join("encoder_model.onnx"),
            decoder_path: base.join("decoder_model.onnx"),
            tokenizer_path: base.join("tokenizer.json"),
            generation_config_path: base.join("generation_config.json"),
        };
        for path in [
            &out.encoder_path,
            &out.decoder_path,
            &out.tokenizer_path,
            &out.generation_config_path,
        ] {
            if !path.is_file() {
                anyhow::bail!("missing Manga OCR model file: {}", path.display());
            }
        }
        Ok(out)
    }
}

fn rgb_to_array(img: &RgbImage) -> Result<Array4<f32>> {
    let (width, height) = img.dimensions();
    let raw_data = img.as_raw();
    let shape = (1, height as usize, width as usize, 3);
    let view: ArrayView<u8, _> = ArrayView::from_shape(shape, raw_data)?.permuted_axes([0, 3, 1, 2]);
    Ok(view.mapv(|x| x as f32).as_standard_layout().into_owned())
}

fn session_from_file(path: &Path) -> Result<Session> {
    let session = Session::builder()
        .map_err(|err| anyhow::anyhow!("model: SessionBuilder: {err}"))?
        .with_optimization_level(GraphOptimizationLevel::Level3)
        .map_err(|err| anyhow::anyhow!("model: optimization level: {err}"))?
        .commit_from_file(path)
        .map_err(|err| anyhow::anyhow!("model: open {}: {err}", path.display()))?;
    Ok(session)
}

struct Encoder {
    session: Mutex<Session>,
}

impl Encoder {
    fn from_path(path: &Path) -> Result<Self> {
        let session = session_from_file(path)?;
        Ok(Self {
            session: Mutex::new(session),
        })
    }

    fn encode(&self, input: &DynamicImage) -> Result<ArrayD<f32>> {
        let resized = input.resize_exact(224, 224, FilterType::Nearest).to_rgb8();
        let arr = (rgb_to_array(&resized)? * 0.003_921_569 - 0.5) / 0.5;
        let mut session = self
            .session
            .lock()
            .map_err(|err| anyhow::anyhow!("encoder lock poisoned: {err}"))?;
        let outputs = session.run(ort::inputs![TensorRef::from_array_view(&arr)?])?;
        Ok(outputs[0].try_extract_array::<f32>()?.to_owned())
    }
}

fn last_token_idx(input: ArrayD<f32>) -> Result<i64> {
    let shape = input.shape();
    if shape.len() != 3 {
        anyhow::bail!("decoder logits must have 3 dimensions");
    }
    let logits = input.slice(s![0, -1, Slice::new(0, None, 1)]);
    let mut best_index = None::<usize>;
    let mut best_value = f32::NEG_INFINITY;
    for (index, value) in logits.iter().enumerate() {
        if best_index.is_none() || *value > best_value {
            best_index = Some(index);
            best_value = *value;
        }
    }
    best_index
        .map(|index| index as i64)
        .ok_or_else(|| anyhow::anyhow!("decoder logits are empty"))
}

struct Decoder {
    session: Mutex<Session>,
    generation_config: GenerationConfig,
}

impl Decoder {
    fn from_path(path: &Path, generation_config: GenerationConfig) -> Result<Self> {
        let session = session_from_file(path)?;
        Ok(Self {
            session: Mutex::new(session),
            generation_config,
        })
    }

    fn stop_decoding(&self, tokens: &[i64]) -> bool {
        let max_repeats = self.generation_config.no_repeat_ngram_size as usize;
        if tokens.len() < max_repeats {
            return false;
        }
        tokens
            .iter()
            .skip(tokens.len() - max_repeats)
            .filter(|token| **token == self.generation_config.eos_token_id as i64)
            .count()
            >= max_repeats
    }

    fn decode(&self, input: ArrayD<f32>, max_tokens: usize) -> Result<Vec<i64>> {
        let mut input_ids = vec![self.generation_config.decoder_start_token_id as i64];
        let mut session = self
            .session
            .lock()
            .map_err(|err| anyhow::anyhow!("decoder lock poisoned: {err}"))?;
        for _ in 0..max_tokens {
            let input_ref = TensorRef::from_array_view(&input)?;
            let input_ids_tensor = Tensor::from_array(([1, input_ids.len()], input_ids.clone()))?;
            let outputs = session.run(ort::inputs! {
                "encoder_hidden_states" => input_ref,
                "input_ids" => input_ids_tensor,
            })?;
            let arr = outputs[0].try_extract_array::<f32>()?.to_owned();
            input_ids.push(last_token_idx(arr)?);
            if self.stop_decoding(&input_ids) {
                break;
            }
        }
        Ok(input_ids)
    }
}

pub struct MangaOcr {
    encoder: Encoder,
    decoder: Decoder,
    tokenizer: Tokenizer,
}

impl MangaOcr {
    pub fn new(model_dir: &Path) -> Result<Self> {
        init_onnxruntime(model_dir)?;
        let model_dir = ModelDir::new(model_dir)?;
        let tokenizer = Tokenizer::from_file(&model_dir.tokenizer_path)
            .map_err(|err| anyhow::anyhow!("tokenizer: open {}: {err}", model_dir.tokenizer_path.display()))?;
        let generation_config = GenerationConfig::from_file(&model_dir.generation_config_path)?;
        Ok(Self {
            encoder: Encoder::from_path(&model_dir.encoder_path)?,
            decoder: Decoder::from_path(&model_dir.decoder_path, generation_config)?,
            tokenizer,
        })
    }

    pub fn recognize(&self, image: &DynamicImage) -> Result<String> {
        let encoded = self.encoder.encode(image)?;
        let token_ids = self.decoder.decode(encoded, 300)?;
        let token_ids = token_ids.iter().map(|id| *id as u32).collect::<Vec<_>>();
        let text = self
            .tokenizer
            .decode(&token_ids, true)
            .map_err(|err| anyhow::anyhow!("tokenizer decode failed: {err}"))?;
        Ok(text.replace(' ', "").trim().to_string())
    }
}

fn init_onnxruntime(model_dir: &Path) -> Result<()> {
    let dylib_path = env_onnxruntime_path()
        .or_else(sibling_onnxruntime_path)
        .or_else(default_android_onnxruntime_name)
        .or_else(|| model_dir_onnxruntime_path(model_dir));

    match dylib_path {
        Some(path) => ort::init_from(path.to_string_lossy())
            .with_name("OfflineTranslatorMangaOcr")
            .commit()
            .map(|_| ())
            .map_err(|err| anyhow::anyhow!("onnxruntime init failed: {err}")),
        None => ort::init()
            .with_name("OfflineTranslatorMangaOcr")
            .commit()
            .map(|_| ())
            .map_err(|err| anyhow::anyhow!("onnxruntime init failed: {err}")),
    }
}

fn env_onnxruntime_path() -> Option<PathBuf> {
    let path = std::env::var("OFFLINETRANSLATOR_ONNXRUNTIME")
        .ok()
        .map(PathBuf::from)?;
    #[cfg(target_os = "android")]
    {
        if !path.starts_with("/data/") {
            return None;
        }
    }
    Some(path)
}

#[cfg(target_os = "android")]
fn default_android_onnxruntime_name() -> Option<PathBuf> {
    Some(PathBuf::from("libonnxruntime.so"))
}

#[cfg(not(target_os = "android"))]
fn default_android_onnxruntime_name() -> Option<PathBuf> {
    None
}

#[cfg(target_os = "android")]
fn model_dir_onnxruntime_path(_model_dir: &Path) -> Option<PathBuf> {
    None
}

#[cfg(not(target_os = "android"))]
fn model_dir_onnxruntime_path(model_dir: &Path) -> Option<PathBuf> {
    [
        "libonnxruntime.so.1.26.0",
        "libonnxruntime.so.1.22.0",
        "libonnxruntime.so",
    ]
    .iter()
    .map(|name| model_dir.join(name))
    .find(|path| path.is_file())
}

#[repr(C)]
struct DlInfo {
    dli_fname: *const c_char,
    dli_fbase: *mut c_void,
    dli_sname: *const c_char,
    dli_saddr: *mut c_void,
}

unsafe extern "C" {
    fn dladdr(addr: *const c_void, info: *mut DlInfo) -> c_int;
}

fn sibling_onnxruntime_path() -> Option<PathBuf> {
    let mut info = DlInfo {
        dli_fname: std::ptr::null(),
        dli_fbase: std::ptr::null_mut(),
        dli_sname: std::ptr::null(),
        dli_saddr: std::ptr::null_mut(),
    };
    let ok = unsafe {
        dladdr(
            init_onnxruntime as *const () as *const c_void,
            &mut info as *mut DlInfo,
        )
    };
    if ok == 0 || info.dli_fname.is_null() {
        return None;
    }
    let self_path = unsafe { CStr::from_ptr(info.dli_fname) }.to_string_lossy();
    let dir = Path::new(self_path.as_ref()).parent()?;
    for name in [
        "libonnxruntime.so",
        "libonnxruntime.so.1.22.0",
        "libonnxruntime.so.1.26.0",
    ] {
        let path = dir.join(name);
        if path.is_file() {
            return Some(path);
        }
    }
    None
}
