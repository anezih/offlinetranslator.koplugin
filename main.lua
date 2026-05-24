local DataStorage = require("datastorage")
local Device = require("device")
local Dispatcher = require("dispatcher")
local InfoMessage = require("ui/widget/infomessage")
local Notification = require("ui/widget/notification")
local PluginShare = require("pluginshare")
local TextViewer = require("ui/widget/textviewer")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local ffi = require("ffi")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local util = require("ffi/util")
local JSON = require("json")
local _ = require("gettext")
local T = util.template

local android = ffi.os == "Linux" and os.getenv("IS_ANDROID") and require("android") or nil

ffi.cdef[[
typedef struct Session Session;
char *koreader_offlinetranslator_version(void);
void koreader_offlinetranslator_string_free(char *value);
Session *koreader_offlinetranslator_session_new(
    const char *catalog_json,
    const char *disk_catalog_json,
    const char *base_dir
);
void koreader_offlinetranslator_session_free(Session *session);
int koreader_offlinetranslator_refresh(Session *session);
char *koreader_offlinetranslator_translate(
    Session *session,
    const char *from_code,
    const char *to_code,
    const char *text
);
char *koreader_offlinetranslator_plan_language_download(
    Session *session,
    const char *language_code
);
char *koreader_offlinetranslator_ocr_rgba(
    const char *tessdata_path,
    const char *language,
    const char *psm,
    const uint8_t *data,
    unsigned int width,
    unsigned int height,
    unsigned int stride,
    unsigned int bbox_x,
    unsigned int bbox_y,
    unsigned int bbox_w,
    unsigned int bbox_h
);
char *koreader_offlinetranslator_ocr_ppocr_rgba(
    const char *ppocr_path,
    const char *script,
    const uint8_t *data,
    unsigned int width,
    unsigned int height,
    unsigned int stride,
    unsigned int bbox_x,
    unsigned int bbox_y,
    unsigned int bbox_w,
    unsigned int bbox_h
);
char *koreader_offlinetranslator_ocr_manga_rgba(
    const char *manga_ocr_path,
    const uint8_t *data,
    unsigned int width,
    unsigned int height,
    unsigned int stride,
    unsigned int bbox_x,
    unsigned int bbox_y,
    unsigned int bbox_w,
    unsigned int bbox_h
);
]]

local OfflineTranslator = WidgetContainer:extend{
    name = "offlinetranslator",
    is_doc_only = false,
}

local SETTINGS_PREFIX = "offlinetranslator_"
local SETTING_FROM = SETTINGS_PREFIX .. "from"
local SETTING_TO = SETTINGS_PREFIX .. "to"
local SETTING_CATALOG_JSON = SETTINGS_PREFIX .. "catalog_json"
local SETTING_CATALOG_TS = SETTINGS_PREFIX .. "catalog_ts"
local SETTING_TESS_LANG = SETTINGS_PREFIX .. "tess_lang"
local SETTING_OCR_PSM = SETTINGS_PREFIX .. "ocr_psm"
local SETTING_OCR_ENGINE = SETTINGS_PREFIX .. "ocr_engine"
local SETTING_PPOCR_SCRIPT = SETTINGS_PREFIX .. "ppocr_script"
local SETTING_AUTO_HIGHLIGHT_POPUP = SETTINGS_PREFIX .. "auto_highlight_popup"
local SETTING_POPUP_SHOW_ORIGINAL = SETTINGS_PREFIX .. "popup_show_original"
local SETTING_USE_WINDOW_VIEWER = SETTINGS_PREFIX .. "use_window_viewer"

local MODEL_CATALOG_URL = "https://storage.googleapis.com/moz-fx-translations-data--303e-prod-translations-data/db/models.json"
local DEFAULT_FROM = "en"
local DEFAULT_TO = "tr"
local DEFAULT_TESS_LANG = "eng"
local DEFAULT_OCR_PSM = "auto"
local DEFAULT_OCR_ENGINE = "tesseract"
local DEFAULT_PPOCR_SCRIPT = "cj"
local MANGA_OCR_MODEL_FILES = {
    "encoder_model.onnx",
    "decoder_model.onnx",
    "tokenizer.json",
    "generation_config.json",
}
local MANGA_OCR_RUNTIME_FILES = {
    "libonnxruntime.so.1.26.0",
    "libonnxruntime.so.1.22.0",
    "libonnxruntime.so",
}

local OCR_ENGINES = {
    {
        id = "tesseract",
        label = _("Tesseract"),
        help = _("Uses KOReader's tessdata files. Good fallback and small footprint, but vertical Japanese manga text can be fragile."),
    },
    {
        id = "ppocr",
        label = _("PPOCR"),
        help = _("Uses PaddleOCR PP-OCRv5 MNN models. Recommended for Japanese and Chinese speech bubbles when the required PPOCR model files are installed."),
    },
    {
        id = "manga_ocr",
        label = _("Manga OCR"),
        help = _("Uses manga-ocr ONNX models for Japanese manga bubbles. It is Japanese-only and requires encoder_model.onnx, decoder_model.onnx, tokenizer.json, generation_config.json, and the bundled ONNX Runtime library."),
    },
}

local PPOCR_SCRIPTS = {
    { id = "cj", label = _("Chinese/Japanese") },
    { id = "latin", label = _("Latin") },
    { id = "korean", label = _("Korean") },
    { id = "cyrillic", label = _("Cyrillic") },
    { id = "eslav", label = _("East Slavic Cyrillic") },
    { id = "el", label = _("Greek") },
    { id = "arabic", label = _("Arabic") },
    { id = "devanagari", label = _("Devanagari") },
    { id = "ta", label = _("Tamil") },
    { id = "te", label = _("Telugu") },
    { id = "th", label = _("Thai") },
}

local OCR_PSM_MODES = {
    {
        id = "auto",
        label = _("Auto"),
        help = _("Default mode. Uses vertical block mode for vertical tessdata and automatic orientation/script detection otherwise."),
    },
    {
        id = "auto_osd",
        label = _("Auto + orientation"),
        help = _("Best for normal horizontal page text when orientation or script may vary. Often weaker for tight manga speech bubbles."),
    },
    {
        id = "single_block_vert",
        label = _("Single vertical block"),
        help = _("Best first choice for Japanese vertical speech bubbles with one compact block of text."),
    },
    {
        id = "single_column",
        label = _("Single column"),
        help = _("Useful when text is one regular column. Can miss side-by-side vertical columns."),
    },
    {
        id = "single_block",
        label = _("Single block"),
        help = _("Useful for horizontal speech bubbles or rectangular OCR crops containing one block."),
    },
    {
        id = "single_line",
        label = _("Single line"),
        help = _("Useful for one short horizontal line. Usually poor for multi-line bubbles."),
    },
    {
        id = "sparse_text",
        label = _("Sparse text"),
        help = _("Tries to find scattered text without a strict layout. Useful when vertical columns are skipped, but reading order may be noisy."),
    },
    {
        id = "sparse_text_osd",
        label = _("Sparse + orientation"),
        help = _("Sparse text with orientation detection. Useful for mixed or rotated text, slower and sometimes less stable."),
    },
    {
        id = "raw_line",
        label = _("Raw line"),
        help = _("Low-level single-line mode. Mainly useful for debugging or very narrow crops."),
    },
}

local plugin_path = debug.getinfo(1, "S").source:sub(2):match("(.*/)")
plugin_path = plugin_path and plugin_path:gsub("/$", "") or "."

local native_lib
local native_load_attempted
local session
local catalog_cache
local translation_pairs_cache

local function isNull(ptr)
    return ptr == nil or ptr == ffi.NULL
end

local function fileExists(path)
    local attr = lfs.attributes(path)
    return attr and attr.mode == "file"
end

local function htmlEscape(text)
    text = tostring(text or "")
    text = text:gsub("&", "&amp;")
        :gsub("<", "&lt;")
        :gsub(">", "&gt;")
        :gsub('"', "&quot;")
    return text
end

local function htmlParagraph(text)
    return htmlEscape(text):gsub("\r\n", "\n"):gsub("\r", "\n"):gsub("\n", "<br/>")
end

local function filesDiffer(source_path, target_path)
    local src_attr = lfs.attributes(source_path)
    local dst_attr = lfs.attributes(target_path)
    if not src_attr or not dst_attr then
        return true
    end
    if src_attr.size ~= dst_attr.size or src_attr.modification ~= dst_attr.modification then
        return true
    end
    local src_hash = util.partialMD5(source_path)
    local dst_hash = util.partialMD5(target_path)
    if not src_hash or not dst_hash then
        return true
    end
    return src_hash ~= dst_hash
end

local function ensureDir(path)
    local current = path:sub(1, 1) == "/" and "/" or ""
    for part in path:gmatch("[^/]+") do
        if part ~= "." then
            if current == "" or current == "/" then
                current = current .. part
            else
                current = current .. "/" .. part
            end
            lfs.mkdir(current)
        end
    end
end

local function readFile(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local data = f:read("*a")
    f:close()
    return data
end

local function writeFile(path, data)
    ensureDir(path:match("(.+)/[^/]+$") or ".")
    local f = io.open(path, "wb")
    if not f then return false end
    f:write(data)
    f:close()
    return true
end

local function getAndroidAbiDir()
    if not android or not android.nativeLibraryDir then
        return nil
    end
    if android.nativeLibraryDir:find("/arm64") then
        return "arm64-v8a"
    end
end

local function stageAndroidLibrary(source_path, library_name)
    local abi_dir = getAndroidAbiDir()
    if not abi_dir or not source_path or not fileExists(source_path) then
        return nil
    end
    library_name = library_name or "libofflinetranslator.so"
    local target_dir = android.dir .. "/plugins/offlinetranslator.koplugin/libs/android/" .. abi_dir
    local target_path = target_dir .. "/" .. library_name
    ensureDir(target_dir)
    if filesDiffer(source_path, target_path) then
        local err = util.copyFile(source_path, target_path)
        if err then
            logger.warn("OfflineTranslator: failed staging Android library", err)
            return nil
        end
    end
    return target_path
end

local function loadAndroidLocalDependency(source_path, library_name)
    local staged = stageAndroidLibrary(source_path, library_name)
    if not staged then
        return nil
    end
    local ok, lib_or_err = pcall(ffi.load, staged)
    if not ok then
        logger.warn("OfflineTranslator: failed loading Android dependency", staged, lib_or_err)
        return nil
    end
    return lib_or_err
end

local function loadNative()
    if native_load_attempted then
        return native_lib
    end
    native_load_attempted = true
    local candidates
    if android then
        local abi_dir = getAndroidAbiDir()
        if abi_dir then
            loadAndroidLocalDependency(plugin_path .. "/libs/android/" .. abi_dir .. "/libc++_shared.so", "libc++_shared.so")
            loadAndroidLocalDependency(plugin_path .. "/libs/android/" .. abi_dir .. "/libonnxruntime.so", "libonnxruntime.so")
        end
        local staged = abi_dir and stageAndroidLibrary(plugin_path .. "/libs/android/" .. abi_dir .. "/libofflinetranslator.so", "libofflinetranslator.so")
        candidates = {
            staged,
            "offlinetranslator",
        }
    else
        candidates = {
            "offlinetranslator",
            plugin_path .. "/libs/libofflinetranslator.so",
            plugin_path .. "/libs/linux/x86_64/libofflinetranslator.so",
            plugin_path .. "/libs/android/arm64-v8a/libofflinetranslator.so",
        }
    end
    for __, name in ipairs(candidates) do
        if name then
            local ok, lib = pcall(ffi.load, name)
            if ok and lib then
                native_lib = lib
                logger.info("OfflineTranslator: loaded native library", name)
                return native_lib
            end
            if not ok then
                logger.warn("OfflineTranslator: failed loading native library", name, lib)
            end
        end
    end
    logger.warn("OfflineTranslator: native library not found")
end

local function takeCString(ptr)
    if isNull(ptr) then
        return nil
    end
    local lib = loadNative()
    local text = ffi.string(ptr)
    lib.koreader_offlinetranslator_string_free(ptr)
    if text:sub(1, 7) == "ERROR: " then
        return nil, text:sub(8)
    end
    return text
end

local function dataRootDir()
    if DataStorage.getFullDataDir then
        return DataStorage:getFullDataDir()
    end
    return DataStorage:getDataDir()
end

local function modelsDir()
    return dataRootDir() .. "/offlinetranslator/models"
end

local function ppocrRootDir()
    return dataRootDir() .. "/offlinetranslator/ppocr"
end

local function mangaOcrRootDir()
    return dataRootDir() .. "/offlinetranslator/manga-ocr"
end

local function mangaOcrCandidateDirs()
    local root = mangaOcrRootDir()
    return {
        root,
        dataRootDir() .. "/offlinetranslator/models/manga-ocr",
    }
end

local function ppocrCandidateDirs()
    local root = ppocrRootDir()
    return {
        root,
        root .. "/PP-OCRv5",
        dataRootDir() .. "/offlinetranslator/models/ppocr/PP-OCRv5",
        dataRootDir() .. "/offlinetranslator/models/ppocr",
    }
end

local function hasPpocrDetector(dir)
    return fileExists(dir .. "/PP-OCRv5_mobile_det_int8.mnn")
        or fileExists(dir .. "/PP-OCRv5_mobile_det.mnn")
        or fileExists(dir .. "/PP-OCRv5_mobile_det_fp16.mnn")
end

local function hasPpocrRecognizer(dir, script)
    local has_recognizer = fileExists(dir .. "/" .. script .. "_PP-OCRv5_mobile_rec_infer_int8.mnn")
        or fileExists(dir .. "/" .. script .. "_PP-OCRv5_mobile_rec_infer.mnn")
    if script == "cj" then
        has_recognizer = has_recognizer or fileExists(dir .. "/PP-OCRv5_mobile_rec_int8.mnn")
    end
    return has_recognizer and fileExists(dir .. "/" .. script .. "_PP-OCRv5_keys.txt")
end

local function ppocrDir(script)
    script = script or DEFAULT_PPOCR_SCRIPT
    local detector_dir
    for __, dir in ipairs(ppocrCandidateDirs()) do
        local has_detector = hasPpocrDetector(dir)
        if has_detector and not detector_dir then
            detector_dir = dir
        end
        if has_detector and hasPpocrRecognizer(dir, script) then
            return dir
        end
    end
    return detector_dir or ppocrRootDir()
end

local function hasMangaOcrModels(dir)
    for __, file in ipairs(MANGA_OCR_MODEL_FILES) do
        if not fileExists(dir .. "/" .. file) then
            return false
        end
    end
    return true
end

local function hasMangaOcrRuntime(dir)
    for __, file in ipairs(MANGA_OCR_RUNTIME_FILES) do
        if fileExists(dir .. "/" .. file) then
            return true
        end
    end
    return false
end

local function bundledMangaOcrRuntimePath()
    local candidates
    if android then
        local abi_dir = getAndroidAbiDir()
        candidates = abi_dir and {
            plugin_path .. "/libs/android/" .. abi_dir .. "/libonnxruntime.so",
        } or {}
    else
        candidates = {
            plugin_path .. "/libs/linux/x86_64/libonnxruntime.so.1.26.0",
            plugin_path .. "/libs/linux/x86_64/libonnxruntime.so.1.22.0",
            plugin_path .. "/libs/linux/x86_64/libonnxruntime.so",
        }
    end
    for __, path in ipairs(candidates) do
        if fileExists(path) then
            return path
        end
    end
end

local function ensureMangaOcrRuntime(dir)
    if android then
        return bundledMangaOcrRuntimePath() ~= nil
    end
    if hasMangaOcrRuntime(dir) then
        return true
    end
    local source = bundledMangaOcrRuntimePath()
    if not source then
        return false
    end
    local target = dir .. "/" .. source:match("([^/]+)$")
    ensureDir(dir)
    if filesDiffer(source, target) then
        local err = util.copyFile(source, target)
        if err then
            logger.warn("OfflineTranslator: failed copying bundled ONNX Runtime", err)
            return false
        end
    end
    return true
end

local function mangaOcrDir()
    for __, dir in ipairs(mangaOcrCandidateDirs()) do
        if hasMangaOcrModels(dir) and ensureMangaOcrRuntime(dir) then
            return dir
        end
    end
    return mangaOcrRootDir()
end

local function tessdataDir()
    return require("document/koptinterface").tessocr_data
        or os.getenv("TESSDATA_PREFIX")
        or (DataStorage:getDataDir() .. "/data/tessdata")
end

local function stripGz(path)
    return path and path:gsub("%.gz$", "")
end

local function selectMozillaModel(models)
    if type(models) ~= "table" then
        return nil
    end
    for __, model in ipairs(models) do
        if model.releaseStatus == "Release" then
            return model
        end
    end
    return models[1]
end

local function httpGet(url, filepath)
    local socket = require("socket")
    local socketutil = require("socketutil")
    local http = require("socket.http")
    local ltn12 = require("ltn12")
    local sink = {}
    local request = { url = url, method = "GET" }
    if filepath then
        ensureDir(filepath:match("(.+)/[^/]+$") or ".")
        local file = io.open(filepath, "wb")
        if not file then
            return nil, _("Cannot create download file.")
        end
        request.sink = ltn12.sink.file(file)
    else
        request.sink = ltn12.sink.table(sink)
    end
    socketutil:set_timeout()
    local code, headers, status = socket.skip(1, http.request(request))
    socketutil:reset_timeout()
    if headers == nil or code ~= 200 then
        return nil, status or code or _("Network error")
    end
    if filepath then
        return true
    end
    return table.concat(sink)
end

local function decodeJSON(text)
    local ok, value = pcall(JSON.decode, text, JSON.decode.simple)
    if ok then
        return value
    end
end

local function shellQuote(value)
    return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

local function gunzipFile(input_path, output_path)
    local command = "gzip -dc " .. shellQuote(input_path) .. " > " .. shellQuote(output_path)
    local ok = os.execute(command)
    if ok == true or ok == 0 then
        return true
    end
    return nil, _("Cannot decompress downloaded model file.")
end

function OfflineTranslator:getCatalogJSON()
    local cached = G_reader_settings:readSetting(SETTING_CATALOG_JSON)
    if cached and cached ~= "" then
        return cached
    end
    local path = modelsDir() .. "/models.json"
    return readFile(path)
end

function OfflineTranslator:loadCatalog()
    local json_text = self:getCatalogJSON()
    if not json_text then
        return nil
    end
    if catalog_cache and catalog_cache._json == json_text then
        return catalog_cache
    end
    local catalog = decodeJSON(json_text)
    if catalog then
        catalog._json = json_text
        catalog_cache = catalog
    end
    return catalog
end

function OfflineTranslator:fetchCatalog()
    local content, err = httpGet(MODEL_CATALOG_URL)
    if not content then
        UIManager:show(InfoMessage:new{ text = T(_("Catalog download failed: %1"), err) })
        return
    end
    G_reader_settings:saveSetting(SETTING_CATALOG_JSON, content)
    G_reader_settings:saveSetting(SETTING_CATALOG_TS, os.time())
    writeFile(modelsDir() .. "/models.json", content)
    catalog_cache = nil
    translation_pairs_cache = nil
    if session then
        session = nil
    end
    UIManager:show(Notification:new{ text = _("Offline translation catalog updated.") })
end

function OfflineTranslator:getSession()
    local lib = loadNative()
    if not lib then
        return nil, _("Native library is not available.")
    end
    if session then
        return session
    end
    local catalog_json = self:getCatalogJSON()
    if not catalog_json then
        return nil, _("Download the model catalog first.")
    end
    session = lib.koreader_offlinetranslator_session_new(catalog_json, nil, modelsDir())
    if isNull(session) then
        return nil, _("Cannot initialize translator session.")
    end
    return session
end

function OfflineTranslator:getPairs()
    if translation_pairs_cache then
        return translation_pairs_cache
    end
    local catalog = self:loadCatalog()
    local translation_pairs = {}
    local seen = {}
    local function addPair(from_code, to_code, files)
        if not from_code or not to_code then
            return
        end
        local key = from_code .. "\0" .. to_code
        if seen[key] then
            return
        end
        seen[key] = true
        table.insert(translation_pairs, {
            from = from_code,
            to = to_code,
            label = from_code .. " → " .. to_code,
            files = files or {},
        })
    end
    if catalog and catalog.packs then
        for __, pack in pairs(catalog.packs) do
            if pack.feature == "translation" and pack.from and pack.to then
                local files = {}
                for __, file in ipairs(pack.files or {}) do
                    local install_path = file.install_path or file.installPath
                    if install_path then
                        table.insert(files, install_path)
                    end
                end
                addPair(pack.from, pack.to, files)
            end
        end
    end
    if catalog and catalog.models then
        for pair_key, models in pairs(catalog.models) do
            local first_model = selectMozillaModel(models)
            local files = {}
            if first_model and first_model.sourceLanguage and first_model.targetLanguage then
                local model_files = first_model.files or {}
                for __, key in ipairs({ "model", "vocab", "srcvocab", "trgvocab", "lexicalShortlist" }) do
                    local path = model_files[key] and model_files[key].path
                    if path then
                        table.insert(files, stripGz(path))
                    end
                end
                addPair(first_model.sourceLanguage, first_model.targetLanguage, files)
            else
                local from_code, to_code = tostring(pair_key):match("^([^-]+)%-([^-]+)$")
                addPair(from_code, to_code, files)
            end
        end
    end
    table.sort(translation_pairs, function(a, b) return a.label < b.label end)
    translation_pairs_cache = translation_pairs
    return translation_pairs
end

function OfflineTranslator:isPairInstalled(pair)
    if pair.from == pair.to then
        return true
    end
    if not pair.files or #pair.files == 0 then
        return false
    end
    for __, path in ipairs(pair.files) do
        if not fileExists(modelsDir() .. "/" .. path) then
            return false
        end
    end
    return true
end

function OfflineTranslator:getInstalledPairs()
    local installed = {}
    for __, pair in ipairs(self:getPairs()) do
        if self:isPairInstalled(pair) then
            table.insert(installed, {
                from = pair.from,
                to = pair.to,
                label = pair.label,
            })
        end
    end
    table.sort(installed, function(a, b) return a.label < b.label end)
    return installed
end

function OfflineTranslator:getDirection()
    return G_reader_settings:readSetting(SETTING_FROM) or DEFAULT_FROM,
        G_reader_settings:readSetting(SETTING_TO) or DEFAULT_TO
end

function OfflineTranslator:setDirection(from_code, to_code)
    G_reader_settings:saveSetting(SETTING_FROM, from_code)
    G_reader_settings:saveSetting(SETTING_TO, to_code)
end

function OfflineTranslator:getTessdataLanguage()
    return G_reader_settings:readSetting(SETTING_TESS_LANG) or DEFAULT_TESS_LANG
end

function OfflineTranslator:setTessdataLanguage(language)
    if language and language ~= "" then
        G_reader_settings:saveSetting(SETTING_TESS_LANG, language)
    end
end

function OfflineTranslator:getOcrEngines()
    return OCR_ENGINES
end

function OfflineTranslator:getOcrEngine()
    return G_reader_settings:readSetting(SETTING_OCR_ENGINE) or DEFAULT_OCR_ENGINE
end

function OfflineTranslator:setOcrEngine(engine)
    if engine and engine ~= "" then
        G_reader_settings:saveSetting(SETTING_OCR_ENGINE, engine)
    end
end

function OfflineTranslator:getOcrEngineLabel(engine)
    engine = engine or self:getOcrEngine()
    for __, item in ipairs(OCR_ENGINES) do
        if item.id == engine then
            return item.label
        end
    end
    return engine
end

function OfflineTranslator:getPpocrScripts()
    return PPOCR_SCRIPTS
end

function OfflineTranslator:getPpocrScript()
    return G_reader_settings:readSetting(SETTING_PPOCR_SCRIPT) or DEFAULT_PPOCR_SCRIPT
end

function OfflineTranslator:setPpocrScript(script)
    if script and script ~= "" then
        G_reader_settings:saveSetting(SETTING_PPOCR_SCRIPT, script)
    end
end

function OfflineTranslator:getPpocrScriptLabel(script)
    script = script or self:getPpocrScript()
    for __, item in ipairs(PPOCR_SCRIPTS) do
        if item.id == script then
            return item.label
        end
    end
    return script
end

function OfflineTranslator:isPpocrScriptInstalled(script)
    script = script or self:getPpocrScript()
    for __, dir in ipairs(ppocrCandidateDirs()) do
        if hasPpocrDetector(dir) and hasPpocrRecognizer(dir, script) then
            return true
        end
    end
    return false
end

function OfflineTranslator:isMangaOcrInstalled()
    for __, dir in ipairs(mangaOcrCandidateDirs()) do
        if hasMangaOcrModels(dir) and ensureMangaOcrRuntime(dir) then
            return true
        end
    end
    return false
end

function OfflineTranslator:getMangaOcrDir()
    return mangaOcrDir()
end

function OfflineTranslator:getOcrPsmModes()
    return OCR_PSM_MODES
end

function OfflineTranslator:getOcrPsmMode()
    return G_reader_settings:readSetting(SETTING_OCR_PSM) or DEFAULT_OCR_PSM
end

function OfflineTranslator:setOcrPsmMode(mode)
    if mode and mode ~= "" then
        G_reader_settings:saveSetting(SETTING_OCR_PSM, mode)
    end
end

function OfflineTranslator:getOcrPsmLabel(mode)
    mode = mode or self:getOcrPsmMode()
    for __, item in ipairs(OCR_PSM_MODES) do
        if item.id == mode then
            return item.label
        end
    end
    return mode
end

function OfflineTranslator:getInstalledTessdataLanguages()
    local languages = {}
    local ok, iter, dir_obj = pcall(lfs.dir, tessdataDir())
    if not ok then
        return languages
    end
    for filename in iter, dir_obj do
        local lang = filename:match("^(.+)%.traineddata$")
        if lang then
            table.insert(languages, lang)
        end
    end
    table.sort(languages)
    return languages
end

function OfflineTranslator:translate(text, from_code, to_code)
    local s, err = self:getSession()
    if not s then
        return nil, err
    end
    local lib = loadNative()
    return takeCString(lib.koreader_offlinetranslator_translate(s, from_code, to_code, text))
end

function OfflineTranslator:isAutoHighlightPopupEnabled()
    return G_reader_settings:isTrue(SETTING_AUTO_HIGHLIGHT_POPUP)
end

function OfflineTranslator:setAutoHighlightPopupEnabled(enabled)
    G_reader_settings:saveSetting(SETTING_AUTO_HIGHLIGHT_POPUP, enabled and true or false)
end

function OfflineTranslator:isPopupOriginalShown()
    local value = G_reader_settings:readSetting(SETTING_POPUP_SHOW_ORIGINAL)
    if value == nil then
        return true
    end
    return value == true
end

function OfflineTranslator:setPopupOriginalShown(enabled)
    G_reader_settings:saveSetting(SETTING_POPUP_SHOW_ORIGINAL, enabled and true or false)
end

function OfflineTranslator:isWindowViewerEnabled()
    return G_reader_settings:isTrue(SETTING_USE_WINDOW_VIEWER)
end

function OfflineTranslator:setWindowViewerEnabled(enabled)
    G_reader_settings:saveSetting(SETTING_USE_WINDOW_VIEWER, enabled and true or false)
end

function OfflineTranslator:onDispatcherRegisterActions()
    Dispatcher:registerAction("offlinetranslator_auto_highlight",
        { category = "string", event = "OfflineTranslatorSetAutoHighlight", title = _("Offline Translator: translate highlights immediately"),
          reader = true, args = { true, false }, toggle = { _("enable"), _("disable") }, arg = true })
    Dispatcher:registerAction("offlinetranslator_auto_highlight_toggle",
        { category = "none", event = "OfflineTranslatorToggleAutoHighlight", title = _("Offline Translator: toggle immediate highlight translation"),
          reader = true })
end

function OfflineTranslator:onOfflineTranslatorSetAutoHighlight(arg)
    local enabled = arg
    if type(arg) == "table" then
        enabled = arg[2]
    end
    self:setAutoHighlightPopupEnabled(enabled == true)
    Notification:notify(enabled == true
        and _("Immediate highlight translation enabled")
        or _("Immediate highlight translation disabled"))
    return true
end

function OfflineTranslator:onOfflineTranslatorToggleAutoHighlight()
    return self:onOfflineTranslatorSetAutoHighlight(not self:isAutoHighlightPopupEnabled())
end

function OfflineTranslator:showTranslationResult(original, translated, from_code, to_code, show_original)
    if show_original == nil then
        show_original = self:isPopupOriginalShown()
    end
    local FootnoteWidget = require("ui/widget/footnotewidget")
    local Screen = Device.screen
    local title = T(_("Offline Translation %1 → %2"), from_code, to_code)
    local html = T(
        [[<div><p><b>%1</b></p><p><b>%2</b><br/>%3</p><p><b>%4</b><br/>%5</p></div>]],
        htmlEscape(title),
        htmlEscape(_("Original")),
        htmlParagraph(original),
        htmlEscape(_("Translation")),
        htmlParagraph(translated)
    )
    if not show_original then
        html = T(
            [[<div><p><b>%1</b></p><p>%2</p></div>]],
            htmlEscape(title),
            htmlParagraph(translated)
        )
    end
    if not self:isWindowViewerEnabled() and self.ui and self.ui.document and self.ui.highlight then
        local highlight = self.ui.highlight
        local popup = FootnoteWidget:new{
            html = html,
            doc_font_name = self.ui.font and self.ui.font.font_face,
            doc_font_size = self.ui.document.configurable
                and self.ui.document.configurable.font_size
                and Screen:scaleBySize(self.ui.document.configurable.font_size)
                or nil,
            doc_margins = self.ui.document.getPageMargins and self.ui.document:getPageMargins() or nil,
            dialog = self.ui.highlight.dialog,
            close_callback = function()
                if highlight and highlight.selected_text then
                    highlight:clear()
                end
            end,
        }
        UIManager:show(popup)
        return
    end
    local viewer_text = show_original
        and T(_("Original:\n%1\n\nTranslation:\n%2"), original, translated)
        or translated
    local viewer
    viewer = TextViewer:new{
        title = title,
        title_multilines = true,
        text = viewer_text,
        text_type = "lookup",
        add_default_buttons = true,
        close_callback = function()
            local highlight = self.ui and self.ui.highlight
            if highlight and highlight.selected_text then
                highlight:clear()
            end
        end,
        buttons_table = {
            {
                {
                    text = show_original and _("Hide original") or _("Show original"),
                    callback = function()
                        UIManager:close(viewer)
                        self:showTranslationResult(original, translated, from_code, to_code, not show_original)
                    end,
                },
                {
                    text = _("Direction"),
                    callback = function()
                        self:showDirectionMenu(function(new_from, new_to)
                            UIManager:close(viewer)
                            self:showTranslation(original, new_from, new_to)
                        end)
                    end,
                },
            },
        },
    }
    UIManager:show(viewer)
end

function OfflineTranslator:showTranslation(text, from_code, to_code)
    from_code = from_code or G_reader_settings:readSetting(SETTING_FROM) or DEFAULT_FROM
    to_code = to_code or G_reader_settings:readSetting(SETTING_TO) or DEFAULT_TO
    local translated, err = self:translate(text, from_code, to_code)
    if not translated then
        UIManager:show(InfoMessage:new{ text = err or _("Translation failed.") })
        return
    end
    self:showTranslationResult(text, translated, from_code, to_code)
end

function OfflineTranslator:showDirectionMenu(callback)
    local pairs = self:getInstalledPairs()
    if #pairs == 0 then
        UIManager:show(InfoMessage:new{ text = _("No installed translation directions.") })
        return
    end
    local Menu = require("ui/widget/menu")
    local item_table = {}
    local menu
    for __, pair in ipairs(pairs) do
        table.insert(item_table, {
            text = pair.label,
            callback = function()
                UIManager:close(menu)
                self:setDirection(pair.from, pair.to)
                if callback then
                    callback(pair.from, pair.to)
                end
            end,
        })
    end
    menu = Menu:new{
        title = _("Offline translation direction"),
        item_table = item_table,
    }
    UIManager:show(menu)
end

function OfflineTranslator:showTessdataMenu(callback)
    local languages = self:getInstalledTessdataLanguages()
    if #languages == 0 then
        UIManager:show(InfoMessage:new{ text = _("No tessdata files found.") })
        return
    end
    local Menu = require("ui/widget/menu")
    local item_table = {}
    local menu
    for __, lang in ipairs(languages) do
        table.insert(item_table, {
            text = lang,
            checked_func = function()
                return self:getTessdataLanguage() == lang
            end,
            radio = true,
            callback = function()
                self:setTessdataLanguage(lang)
                if callback then
                    callback(lang)
                end
                UIManager:close(menu)
            end,
        })
    end
    menu = Menu:new{
        title = _("Tesseract OCR language"),
        item_table = item_table,
    }
    UIManager:show(menu)
end

function OfflineTranslator:showOcrPsmMenu(callback)
    local Menu = require("ui/widget/menu")
    local current = self:getOcrPsmMode()
    local item_table = {}
    local menu
    for __, mode in ipairs(OCR_PSM_MODES) do
        table.insert(item_table, {
            text_func = function()
                local selected = self:getOcrPsmMode() == mode.id
                return selected and ("✔ " .. mode.label) or mode.label
            end,
            help_text = mode.help,
            callback = function()
                self:setOcrPsmMode(mode.id)
                if callback then
                    callback(mode.id)
                end
                if menu then
                    menu:updateItems(nil, true)
                end
            end,
        })
    end
    menu = Menu:new{
        title = _("Tesseract page segmentation"),
        item_table = item_table,
    }
    function menu:onMenuHold(item)
        if item.help_text then
            UIManager:show(InfoMessage:new{ text = item.help_text })
            return true
        end
        return true
    end
    UIManager:show(menu)
end

function OfflineTranslator:showOcrEngineMenu(callback)
    local Menu = require("ui/widget/menu")
    local item_table = {}
    local menu
    for __, engine in ipairs(self:getOcrEngines()) do
        table.insert(item_table, {
            text_func = function()
                local selected = self:getOcrEngine() == engine.id
                local suffix = ""
                if engine.id == "manga_ocr" and not self:isMangaOcrInstalled() then
                    suffix = " (" .. _("missing files") .. ")"
                end
                return (selected and "✔ " or "") .. engine.label .. suffix
            end,
            help_text = engine.help,
            callback = function()
                self:setOcrEngine(engine.id)
                if callback then
                    callback(engine.id)
                end
                if menu then
                    menu:updateItems(nil, true)
                end
            end,
        })
    end
    menu = Menu:new{
        title = _("OCR engine"),
        item_table = item_table,
    }
    function menu:onMenuHold(item)
        if item.help_text then
            UIManager:show(InfoMessage:new{ text = item.help_text })
        end
        return true
    end
    UIManager:show(menu)
end

function OfflineTranslator:showPpocrScriptMenu(callback)
    local Menu = require("ui/widget/menu")
    local item_table = {}
    local menu
    for __, script in ipairs(PPOCR_SCRIPTS) do
        table.insert(item_table, {
            text_func = function()
                local installed = self:isPpocrScriptInstalled(script.id)
                local selected = self:getPpocrScript() == script.id
                return (selected and "✔ " or "") .. script.label .. (installed and "" or " (" .. _("missing files") .. ")")
            end,
            callback = function()
                self:setPpocrScript(script.id)
                if callback then
                    callback(script.id)
                end
                if menu then
                    menu:updateItems(nil, true)
                end
            end,
        })
    end
    menu = Menu:new{
        title = _("PPOCR recognizer script"),
        item_table = item_table,
    }
    UIManager:show(menu)
end

function OfflineTranslator:downloadLanguage(language_code)
    local s, err = self:getSession()
    if not s then
        UIManager:show(InfoMessage:new{ text = err })
        return
    end
    local lib = loadNative()
    local plan_text, plan_err = takeCString(lib.koreader_offlinetranslator_plan_language_download(s, language_code))
    if not plan_text then
        UIManager:show(InfoMessage:new{ text = plan_err })
        return
    end
    local plan = decodeJSON(plan_text)
    if not plan or not plan.tasks or #plan.tasks == 0 then
        UIManager:show(Notification:new{ text = _("Language files already installed.") })
        return
    end
    for __, task in ipairs(plan.tasks) do
        local target = modelsDir() .. "/" .. task.install_path
        local download_target = task.decompress and (target .. ".gz") or target
        local ok, download_err = httpGet(task.url, download_target)
        if not ok then
            UIManager:show(InfoMessage:new{ text = tostring(download_err) })
            return
        end
        if task.decompress then
            local decompress_err
            ok, decompress_err = gunzipFile(download_target, target)
            os.remove(download_target)
            if not ok then
                UIManager:show(InfoMessage:new{ text = tostring(decompress_err) })
                return
            end
        end
        if task.archive_format == "zip" and task.extract_to then
            os.execute(string.format("unzip -o %q -d %q", target, modelsDir() .. "/" .. task.extract_to))
            if task.delete_after_extract then
                os.remove(target)
            end
        end
    end
    lib.koreader_offlinetranslator_refresh(s)
    UIManager:show(Notification:new{ text = _("Offline translation files downloaded.") })
end

function OfflineTranslator:showDownloadMenu()
    if not self:loadCatalog() then
        UIManager:show(InfoMessage:new{ text = _("Download the model catalog first.") })
        return
    end
    local pairs = self:getPairs()
    local any_missing = false
    for __, pair in ipairs(self:getPairs()) do
        if not self:isPairInstalled(pair) then
            any_missing = true
            break
        end
    end
    table.sort(pairs, function(a, b) return a.label < b.label end)
    if #pairs == 0 then
        UIManager:show(InfoMessage:new{ text = _("No downloadable language files in catalog.") })
        return
    end
    local Menu = require("ui/widget/menu")
    local item_table = {}
    local menu
    for __, pair in ipairs(pairs) do
        local installed = self:isPairInstalled(pair)
        table.insert(item_table, {
            text = installed and ("✔ " .. pair.label) or pair.label,
            callback = function()
                UIManager:close(menu)
                local language_code = pair.from ~= "en" and pair.from or pair.to
                self:downloadLanguage(language_code)
            end,
        })
    end
    menu = Menu:new{
        title = any_missing and _("Download offline language files") or _("Offline language files"),
        item_table = item_table,
    }
    UIManager:show(menu)
end

function OfflineTranslator:ocrImageRgba(image, bbox, language, psm, engine, ppocr_script)
    local lib = loadNative()
    if not lib then
        return nil, _("Native library is not available.")
    end
    engine = engine or self:getOcrEngine()
    bbox = bbox or {}
    if engine == "ppocr" then
        ppocr_script = ppocr_script or self:getPpocrScript()
        local ptr = lib.koreader_offlinetranslator_ocr_ppocr_rgba(
            ppocrDir(ppocr_script),
            ppocr_script,
            ffi.cast("const uint8_t *", image.data),
            image.w,
            image.h,
            image.stride,
            bbox.x or 0,
            bbox.y or 0,
            bbox.w or 0,
            bbox.h or 0
        )
        return takeCString(ptr)
    end
    if engine == "manga_ocr" then
        local ptr = lib.koreader_offlinetranslator_ocr_manga_rgba(
            mangaOcrDir(),
            ffi.cast("const uint8_t *", image.data),
            image.w,
            image.h,
            image.stride,
            bbox.x or 0,
            bbox.y or 0,
            bbox.w or 0,
            bbox.h or 0
        )
        return takeCString(ptr)
    end
    language = language or self:getTessdataLanguage()
    psm = psm or self:getOcrPsmMode()
    local ptr = lib.koreader_offlinetranslator_ocr_rgba(
        tessdataDir(),
        language,
        psm,
        ffi.cast("const uint8_t *", image.data),
        image.w,
        image.h,
        image.stride,
        bbox.x or 0,
        bbox.y or 0,
        bbox.w or 0,
        bbox.h or 0
    )
    return takeCString(ptr)
end

function OfflineTranslator:addToHighlightDialog()
    if not self.ui or not self.ui.highlight then
        return
    end
    self.ui.highlight:addToHighlightDialog("99_offline_translation", function(this)
        return {
            text = _("Offline Translation"),
            callback = function()
                local text = this.selected_text and this.selected_text.text
                if not text or text == "" then
                    UIManager:show(InfoMessage:new{ text = _("No selected text.") })
                    return
                end
                this:onClose(true)
                local from_code, to_code = self:getDirection()
                self:showTranslation(text, from_code, to_code)
            end,
        }
    end)
end

function OfflineTranslator:patchHighlightMenu()
    local highlight = self.ui and self.ui.highlight
    if not highlight or highlight._offlinetranslator_onShowHighlightMenu then
        return
    end
    local plugin = self
    highlight._offlinetranslator_onShowHighlightMenu = highlight.onShowHighlightMenu
    highlight.onShowHighlightMenu = function(this, index, ...)
        local text = this.selected_text and this.selected_text.text
        if plugin:isAutoHighlightPopupEnabled() and not index and text and text ~= "" then
            local from_code, to_code = plugin:getDirection()
            plugin:showTranslation(text, from_code, to_code)
            return true
        end
        return this._offlinetranslator_onShowHighlightMenu(this, index, ...)
    end
end

function OfflineTranslator:init()
    if self.ui and self.ui.menu then
        self.ui.menu:registerToMainMenu(self)
    end
    self:onDispatcherRegisterActions()
    self:addToHighlightDialog()
    self:patchHighlightMenu()
    PluginShare.offlinetranslator = {
        translate = function(text, from_code, to_code)
            return self:translate(text, from_code, to_code)
        end,
        getInstalledPairs = function()
            return self:getInstalledPairs()
        end,
        getDirection = function()
            local from_code, to_code = self:getDirection()
            return { from = from_code, to = to_code, label = from_code .. " → " .. to_code }
        end,
        setDirection = function(from_code, to_code)
            return self:setDirection(from_code, to_code)
        end,
        getInstalledTessdataLanguages = function()
            return self:getInstalledTessdataLanguages()
        end,
        getTessdataLanguage = function()
            return self:getTessdataLanguage()
        end,
        setTessdataLanguage = function(language)
            return self:setTessdataLanguage(language)
        end,
        getOcrEngines = function()
            return self:getOcrEngines()
        end,
        getOcrEngine = function()
            return self:getOcrEngine()
        end,
        setOcrEngine = function(engine)
            return self:setOcrEngine(engine)
        end,
        getOcrPsmModes = function()
            return self:getOcrPsmModes()
        end,
        getOcrPsmMode = function()
            return self:getOcrPsmMode()
        end,
        setOcrPsmMode = function(mode)
            return self:setOcrPsmMode(mode)
        end,
        getPpocrScripts = function()
            return self:getPpocrScripts()
        end,
        getPpocrScript = function()
            return self:getPpocrScript()
        end,
        setPpocrScript = function(script)
            return self:setPpocrScript(script)
        end,
        isPpocrScriptInstalled = function(script)
            return self:isPpocrScriptInstalled(script)
        end,
        isMangaOcrInstalled = function()
            return self:isMangaOcrInstalled()
        end,
        getMangaOcrDir = function()
            return self:getMangaOcrDir()
        end,
        ocrImageRgba = function(image, bbox, language, psm, engine, ppocr_script)
            return self:ocrImageRgba(image, bbox, language, psm, engine, ppocr_script)
        end,
    }
end

function OfflineTranslator:addToMainMenu(menu_items)
    local function refreshMenu(menu)
        if menu and menu.updateItems then
            menu:updateItems()
        end
    end

    menu_items.offlinetranslator = {
        text = _("Offline Translator"),
        help_text = _("Download Firefox translation models, set the default offline translation direction, and configure the OCR engines used by this plugin and its Lua API."),
        sorting_hint = "search_settings",
        sub_item_table = {
            {
                text = _("Update model catalog"),
                callback = function()
                    self:fetchCatalog()
                end,
            },
            {
                text = _("Download language files"),
                keep_menu_open = true,
                callback = function()
                    self:showDownloadMenu()
                end,
            },
            {
                text_func = function()
                    local from_code, to_code = self:getDirection()
                    return T(_("Default direction: %1 → %2"), from_code, to_code)
                end,
                separator = true,
                keep_menu_open = true,
                callback = function(menu)
                    self:showDirectionMenu(function()
                        refreshMenu(menu)
                    end)
                end,
            },
            {
                text = _("Translate highlights immediately"),
                checked_func = function()
                    return self:isAutoHighlightPopupEnabled()
                end,
                callback = function()
                    self:setAutoHighlightPopupEnabled(not self:isAutoHighlightPopupEnabled())
                    refreshMenu()
                end,
                help_text = _("When enabled, releasing a text highlight opens Offline Translation directly instead of showing the highlight action menu."),
            },
            {
                text = _("Show original in footnote popup"),
                checked_func = function()
                    return self:isPopupOriginalShown()
                end,
                callback = function()
                    self:setPopupOriginalShown(not self:isPopupOriginalShown())
                    refreshMenu()
                end,
                help_text = _("When enabled, the footnote-style Offline Translation popup shows both selected original text and translated text. When disabled, it shows only the translation."),
            },
            {
                text = _("Use window translation viewer"),
                checked_func = function()
                    return self:isWindowViewerEnabled()
                end,
                separator = true,
                callback = function()
                    self:setWindowViewerEnabled(not self:isWindowViewerEnabled())
                    refreshMenu()
                end,
                help_text = _("Use the older window-based translation viewer instead of the footnote-style popup."),
            },
            {
                text_func = function()
                    return T(_("OCR engine: %1"), self:getOcrEngineLabel())
                end,
                help_text = _("Choose which OCR backend is used by Offline Translator and by plugins that call its OCR API. Tesseract uses KOReader's tessdata files and is the smallest fallback; it works for many languages, but Japanese vertical manga text may need jpn_vert and can still miss columns. PPOCR uses PP-OCRv5 MNN detector, orientation, recognizer, and keys files; it is useful for speech bubbles and mixed page text, especially Chinese/Japanese with the cj script, but the detector pack and selected script files must be installed. Manga OCR uses encoder_model.onnx, decoder_model.onnx, tokenizer.json, generation_config.json, and the bundled ONNX Runtime library; it is Japanese-only and tuned for manga bubbles, including vertical and multi-line text, but it is larger and only appears as installed when those files are present."),
                keep_menu_open = true,
                callback = function(menu)
                    self:showOcrEngineMenu(function()
                        refreshMenu(menu)
                    end)
                end,
            },
            {
                text_func = function()
                    return T(_("Tesseract OCR language: %1"), self:getTessdataLanguage())
                end,
                keep_menu_open = true,
                callback = function(menu)
                    self:showTessdataMenu(function()
                        refreshMenu(menu)
                    end)
                end,
            },
            {
                text_func = function()
                    return T(_("OCR segmentation: %1"), self:getOcrPsmLabel())
                end,
                keep_menu_open = true,
                callback = function(menu)
                    self:showOcrPsmMenu(function()
                        refreshMenu(menu)
                    end)
                end,
            },
            {
                text_func = function()
                    return T(_("PPOCR script: %1"), self:getPpocrScriptLabel())
                end,
                keep_menu_open = true,
                callback = function(menu)
                    self:showPpocrScriptMenu(function()
                        refreshMenu(menu)
                    end)
                end,
            },
            {
                text = _("Translate clipboard/selection"),
                separator = true,
                callback = function()
                    local text = Device:hasClipboard() and Device.input.getClipboardText() or nil
                    if not text or text == "" then
                        UIManager:show(InfoMessage:new{ text = _("Clipboard is empty.") })
                        return
                    end
                    local from_code, to_code = self:getDirection()
                    self:showTranslation(text, from_code, to_code)
                end,
            },
            {
                text = _("About"),
                callback = function()
                    UIManager:show(InfoMessage:new{
                        text = _("Offline Translator KOPlugin\nhttps://github.com/anezih/offlinetranslator.koplugin"),
                    })
                end,
            },
        },
    }
end

function OfflineTranslator:onClose()
    if session then
        local lib = loadNative()
        if lib then
            lib.koreader_offlinetranslator_session_free(session)
        end
        session = nil
    end
end

return OfflineTranslator
