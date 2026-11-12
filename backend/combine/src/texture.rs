use image::{codecs::png::{CompressionType, FilterType, PngEncoder}, imageops, DynamicImage, ExtendedColorType, ImageEncoder, Rgba, RgbaImage};
use serde::{Deserialize, Serialize};
use std::{collections::BTreeMap, env, fs, hash::{Hash, Hasher}, io::{Cursor, Read}, sync::atomic::{AtomicBool, Ordering}};

const MAX_SOURCE_BYTES: usize = 100_000_000;
const MAP_SLOTS: [&str; 5] = ["color", "metalness", "normal", "roughness", "emissive"];

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TextureInput {
    pub name: String,
    pub slot: String,
    pub uri: String,
    #[serde(default)]
    pub tint: Option<[f32; 3]>,
    #[serde(default)]
    pub transparency: Option<f32>,
    #[serde(default)]
    pub alpha_mode: Option<String>,
    #[serde(default)]
    pub resample_mode: Option<String>,
    #[serde(default)]
    pub surface_color: Option<[f32; 3]>,
    #[serde(default)]
    pub base_color: Option<[f32; 3]>,
    #[serde(default)]
    pub part_color_baked: bool,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct TextureSourceError {
    pub name: String,
    pub slot: String,
    pub error: String,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct TextureBindingInfo {
    pub name: String,
    pub slot: String,
    pub has_source: bool,
    pub page: usize,
    pub alpha_mode: Option<String>,
    pub resample_mode: Option<String>,
    pub has_alpha: bool,
    pub skip_part_color: bool,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct TextureImageInfo {
    pub slot: String,
    pub page: usize,
    pub path: String,
    pub width: u32,
    pub height: u32,
}

struct DecodedTexture {
    input: TextureInput,
    path: std::path::PathBuf,
    has_alpha: bool,
}

struct SourceMaps {
    maps: BTreeMap<String, DecodedTexture>,
    width: u32,
    height: u32,
}

#[cfg(test)]
fn resize_premultiplied(source: &RgbaImage, width: u32, height: u32) -> RgbaImage {
    if source.dimensions() == (width, height) {
        return source.clone();
    }
    let mut premultiplied = source.clone();
    for pixel in premultiplied.pixels_mut() {
        let alpha = pixel[3] as f32 / 255.0;
        for channel in 0..3 {
            pixel[channel] = (pixel[channel] as f32 * alpha).round().clamp(0.0, 255.0) as u8;
        }
    }
    let mut resized = imageops::resize(&premultiplied, width, height, imageops::FilterType::Lanczos3);
    for pixel in resized.pixels_mut() {
        let alpha = pixel[3] as f32;
        if alpha > 0.0 {
            for channel in 0..3 {
                pixel[channel] = (pixel[channel] as f32 * 255.0 / alpha).round().clamp(0.0, 255.0) as u8;
            }
        } else {
            pixel[0] = 0;
            pixel[1] = 0;
            pixel[2] = 0;
        }
    }
    resized
}

#[cfg(test)]
fn resize_normal_map(source: &RgbaImage, width: u32, height: u32) -> RgbaImage {
    let mut fitted = imageops::resize(source, width, height, imageops::FilterType::Lanczos3);
    for pixel in fitted.pixels_mut() {
        let normal = [
            pixel[0] as f32 / 127.5 - 1.0,
            pixel[1] as f32 / 127.5 - 1.0,
            pixel[2] as f32 / 127.5 - 1.0,
        ];
        let length = (normal[0] * normal[0] + normal[1] * normal[1] + normal[2] * normal[2]).sqrt();
        if length > f32::EPSILON {
            for channel in 0..3 {
                pixel[channel] = ((normal[channel] / length + 1.0) * 127.5).round().clamp(0.0, 255.0) as u8;
            }
        }
    }
    fitted
}

fn is_roblox_host(host: &str) -> bool {
    host == "roblox.com"
        || host.ends_with(".roblox.com")
        || host == "rbxcdn.com"
        || host.ends_with(".rbxcdn.com")
        || host == "robloxusercontent.com"
        || host.ends_with(".robloxusercontent.com")
}

fn asset_url(uri: &str) -> Result<String, String> {
    let value = uri.trim();
    if let Some(id) = value.strip_prefix("rbxassetid://") {
        if id.is_empty() || !id.bytes().all(|byte| byte.is_ascii_digit()) {
            return Err("asset URI contains an invalid asset ID".to_string());
        }
        return Ok(format!("https://assetdelivery.roblox.com/v1/asset/?id={id}"));
    }
    if value.starts_with("https://") {
        let parsed = reqwest::Url::parse(value).map_err(|error| error.to_string())?;
        if parsed.scheme() != "https" || !parsed.host_str().is_some_and(is_roblox_host) {
            return Err("image URL must use an HTTPS Roblox asset host".to_string());
        }
        return Ok(parsed.to_string());
    }
    if !value.is_empty() && value.bytes().all(|byte| byte.is_ascii_digit()) {
        return Ok(format!("https://assetdelivery.roblox.com/v1/asset/?id={value}"));
    }
    Err(format!("unsupported image URI: {value}"))
}

fn studio_cookie() -> Option<String> {
    if let Ok(value) = env::var("ROBLOSECURITY") {
        if !value.is_empty() {
            return Some(value);
        }
    }
    #[cfg(windows)] {
        if let Some(user) = read_credential("https://www.roblox.com:RobloxStudioAuthuserid") {
            if let Some(cookie) = read_credential(&format!("https://www.roblox.com:RobloxStudioAuth.ROBLOSECURITY{user}")) {
                return Some(cookie);
            }
        }
        if let Some(cookie) = read_credential("https://www.roblox.com:RobloxStudioAuth.ROBLOSECURITY") {
            return Some(cookie);
        }
    }
    None
}

#[cfg(windows)]
#[repr(C)]
struct FileTime {
    low: u32,
    high: u32,
}

#[cfg(windows)]
#[repr(C)]
struct Credential {
    flags: u32,
    kind: u32,
    target: *mut u16,
    comment: *mut u16,
    written: FileTime,
    blob_size: u32,
    blob: *mut u8,
    persist: u32,
    attribute_count: u32,
    attributes: *mut std::ffi::c_void,
    alias: *mut u16,
    username: *mut u16,
}

#[cfg(windows)]
#[link(name = "Advapi32")]
unsafe extern "system" {
    fn CredReadW(target: *const u16, kind: u32, flags: u32, output: *mut *mut Credential) -> i32;
    fn CredFree(buffer: *mut std::ffi::c_void);
}

#[cfg(windows)]
fn read_credential(target: &str) -> Option<String> {
    let target: Vec<u16> = target.encode_utf16().chain(Some(0)).collect();
    let mut pointer = std::ptr::null_mut();
    if unsafe { CredReadW(target.as_ptr(), 1, 0, &mut pointer) } == 0 || pointer.is_null() {
        return None;
    }
    let result = unsafe {
        let value = &*pointer;
        if value.blob.is_null() || value.blob_size == 0 {
            None
        } else {
            let bytes = std::slice::from_raw_parts(value.blob, value.blob_size as usize);
            std::str::from_utf8(bytes).ok().map(str::to_owned).or_else(|| {
                String::from_utf16(&bytes.chunks_exact(2).map(|value| u16::from_le_bytes([value[0], value[1]])).collect::<Vec<_>>()).ok()
            }).map(|value| value.trim_end_matches('\0').to_owned())
        }
    };
    unsafe { CredFree(pointer.cast()); }
    result.filter(|value| !value.is_empty())
}

async fn response_bytes(response: reqwest::Response, cancelled: &AtomicBool) -> Result<Vec<u8>, String> {
    if !response.status().is_success() {
        return Err(format!("image request returned HTTP {}", response.status()));
    }
    if response.content_length().is_some_and(|length| length > MAX_SOURCE_BYTES as u64) {
        return Err("source image exceeds the 100 MB download limit".to_string());
    }
    let bytes = tokio::select! {
        result = response.bytes() => result.map_err(|error| error.to_string())?,
        _ = wait_for_cancel(cancelled) => return Err("texture download cancelled".to_string()),
    };
    if bytes.len() > MAX_SOURCE_BYTES {
        return Err("source image exceeds the 100 MB download limit".to_string());
    }
    if bytes.starts_with(&[0x1f, 0x8b]) {
        let decoder = flate2::read::MultiGzDecoder::new(bytes.as_ref());
        let mut decoded = Vec::new();
        decoder.take(MAX_SOURCE_BYTES as u64 + 1).read_to_end(&mut decoded)
            .map_err(|error| format!("could not decompress gzip asset response: {error}"))?;
        if decoded.len() > MAX_SOURCE_BYTES {
            return Err("decompressed source image exceeds the 100 MB download limit".to_string());
        }
        return Ok(decoded);
    }
    Ok(bytes.to_vec())
}

async fn download_bytes(url: &str, client: &reqwest::Client, cookie: Option<&str>, cancelled: &AtomicBool) -> Result<Vec<u8>, String> {
    let parsed = reqwest::Url::parse(url).map_err(|error| error.to_string())?;
    let authenticated_asset_delivery = parsed.host_str() == Some("assetdelivery.roblox.com");
    let mut request = client.get(parsed);
    if authenticated_asset_delivery {
        if let Some(cookie) = cookie {
            request = request.header(reqwest::header::COOKIE, format!(".ROBLOSECURITY={cookie}"));
        }
    }
    let response = tokio::select! {
        result = request.send() => result.map_err(|error| error.to_string())?,
        _ = wait_for_cancel(cancelled) => return Err("texture download cancelled".to_string()),
    };
    if response.status().is_redirection() {
        let location = response.headers().get(reqwest::header::LOCATION)
            .ok_or_else(|| "asset delivery redirect omitted its location".to_string())?
            .to_str().map_err(|error| error.to_string())?.to_owned();
        let target = reqwest::Url::parse(&location).map_err(|error| error.to_string())?;
        if target.scheme() != "https" || !target.host_str().is_some_and(is_roblox_host) {
            return Err("asset delivery returned an unsupported download host".to_string());
        }
        let redirected = tokio::select! {
            result = client.get(target).send() => result.map_err(|error| error.to_string())?,
            _ = wait_for_cancel(cancelled) => return Err("texture download cancelled".to_string()),
        };
        return response_bytes(redirected, cancelled).await;
    }
    if response.status().is_success()
        && response.headers().get(reqwest::header::CONTENT_TYPE).and_then(|value| value.to_str().ok()).is_some_and(|value| value.contains("json"))
    {
        let payload = response.json::<serde_json::Value>().await.map_err(|error| format!("invalid asset delivery response: {error}"))?;
        let location = payload["locations"].as_array()
            .and_then(|locations| locations.iter().find_map(|entry| entry["location"].as_str()))
            .ok_or_else(|| "asset delivery response omitted its download location".to_string())?;
        let target = reqwest::Url::parse(location).map_err(|error| error.to_string())?;
        if target.scheme() != "https" || !target.host_str().is_some_and(is_roblox_host) {
            return Err("asset delivery returned an unsupported download host".to_string());
        }
        let redirected = tokio::select! {
            result = client.get(target).send() => result.map_err(|error| error.to_string())?,
            _ = wait_for_cancel(cancelled) => return Err("texture download cancelled".to_string()),
        };
        return response_bytes(redirected, cancelled).await;
    }
    response_bytes(response, cancelled).await
}

async fn wait_for_cancel(cancelled: &AtomicBool) {
    while !cancelled.load(Ordering::Relaxed) {
        tokio::time::sleep(std::time::Duration::from_millis(50)).await;
    }
}

async fn download_source(input: &TextureInput, client: &reqwest::Client, cookie: Option<&str>, cancelled: &AtomicBool) -> Result<RgbaImage, String> {
    if !MAP_SLOTS.contains(&input.slot.as_str()) {
        return Err(format!("unsupported texture map slot: {}", input.slot));
    }
    let url = asset_url(&input.uri)?;
    let mut last_error = String::new();
    for attempt in 0..3 {
        let bytes = if attempt == 0 {
            download_bytes(&url, client, cookie, cancelled).await?
        } else {
            tokio::time::sleep(std::time::Duration::from_millis(250 * attempt)).await;
            download_bytes(&url, client, cookie, cancelled).await?
        };
        let decoded = (|| {
            let mut reader = image::ImageReader::new(Cursor::new(bytes.as_slice()))
                .with_guessed_format()
                .map_err(|error| {
                    let signature = bytes.iter().take(16).map(|byte| format!("{byte:02x}")).collect::<Vec<_>>().join(" ");
                    format!("could not identify source image format: {error} ({} bytes; signature: {signature})", bytes.len())
                })?;
            let mut limits = image::Limits::default();
            limits.max_image_width = Some(16_384);
            limits.max_image_height = Some(16_384);
            limits.max_alloc = Some(256 * 1024 * 1024);
            reader.limits(limits);
            reader.decode().map_err(|error| {
                let signature = bytes.iter().take(16).map(|byte| format!("{byte:02x}")).collect::<Vec<_>>().join(" ");
                format!("could not decode source image: {error} ({} bytes; signature: {signature})", bytes.len())
            })
        })();
        match decoded {
            Ok(decoded) => {
                let pixel_count = (decoded.width() as u64).checked_mul(decoded.height() as u64)
                    .ok_or("source image dimensions overflow")?;
                if pixel_count > 64 * 1024 * 1024 {
                    return Err("source image exceeds the 64-megapixel decode limit".to_string());
                }
                return fit_source(decoded, &input.slot);
            }
            Err(error) => last_error = error,
        }
        if cancelled.load(Ordering::Relaxed) {
            return Err("texture download cancelled".to_string());
        }
    }
    Err(format!("failed to decode source image after 3 downloads: {last_error}"))
}


fn resolved_alpha_mode(input: &TextureInput, has_alpha: bool) -> Option<String> {
    input.alpha_mode.as_ref().map(|mode| {
        if mode == "Transparency" && !has_alpha {
            "Opaque".to_string()
        } else {
            mode.clone()
        }
    })
}

fn prepare_texture(input: &TextureInput, mut image: RgbaImage) -> Result<RgbaImage, String> {
    apply_modifiers(&mut image, input.tint, input.transparency)?;
    if input.slot == "color" && input.alpha_mode.is_some() {
        apply_alpha_mode(&mut image, input.alpha_mode.as_deref(), input.surface_color, input.base_color)?;
    }
    Ok(image)
}

fn apply_modifiers(image: &mut RgbaImage, tint: Option<[f32; 3]>, transparency: Option<f32>) -> Result<(), String> {
    let tint = tint.unwrap_or([1.0; 3]);
    let transparency = transparency.unwrap_or(0.0);
    if tint.iter().any(|value| !value.is_finite() || !(0.0..=1.0).contains(value))
        || !transparency.is_finite()
        || !(0.0..=1.0).contains(&transparency)
    {
        return Err("texture tint and transparency must be finite values between 0 and 1".to_string());
    }
    let alpha_scale = 1.0 - transparency;
    for pixel in image.pixels_mut() {
        for channel in 0..3 {
            pixel[channel] = (pixel[channel] as f32 * tint[channel]).round().clamp(0.0, 255.0) as u8;
        }
        pixel[3] = (pixel[3] as f32 * alpha_scale).round().clamp(0.0, 255.0) as u8;
    }
    Ok(())
}

fn apply_alpha_mode(
    image: &mut RgbaImage,
    alpha_mode: Option<&str>,
    surface_color: Option<[f32; 3]>,
    base_color: Option<[f32; 3]>,
) -> Result<(), String> {
    let mode = alpha_mode.unwrap_or("Overlay");
    let tint = surface_color.unwrap_or([1.0; 3]);
    let base = base_color.unwrap_or([1.0; 3]);
    if tint.iter().chain(base.iter()).any(|value| !value.is_finite() || !(0.0..=1.0).contains(value)) {
        return Err("source appearance colors must contain finite values between 0 and 1".to_string());
    }
    if !["Overlay", "Transparency", "TintMask", "Opaque"].contains(&mode) {
        return Err(format!("unsupported SurfaceAppearance AlphaMode: {mode}"));
    }
    for pixel in image.pixels_mut() {
        let alpha = pixel[3] as f32 / 255.0;
        for channel in 0..3 {
            let source = pixel[channel] as f32 / 255.0;
            let tinted = source * tint[channel];
            let output = match mode {
                "Overlay" => tinted * alpha + base[channel] * (1.0 - alpha),
                "TintMask" => source * (1.0 + (tint[channel] - 1.0) * alpha),
                _ => tinted,
            };
            pixel[channel] = (output * 255.0).round().clamp(0.0, 255.0) as u8;
        }
        if mode == "Overlay" || mode == "Opaque" {
            pixel[3] = 255;
        }
    }
    Ok(())
}

fn fit_source(source: DynamicImage, _slot: &str) -> Result<RgbaImage, String> {
    let source = source.to_rgba8();
    if source.width() == 0 || source.height() == 0 {
        return Err("source image has empty dimensions".to_string());
    }
    Ok(source)
}

fn map_channel(pixel: Rgba<u8>) -> u8 {
    pixel[0]
}

#[cfg(test)]
fn grayscale_map(source: &RgbaImage, width: u32, height: u32) -> RgbaImage {
    let fitted = imageops::resize(source, width, height, imageops::FilterType::Lanczos3);
    let mut grayscale = RgbaImage::new(width, height);
    for (target, pixel) in grayscale.pixels_mut().zip(fitted.pixels()) {
        let value = map_channel(*pixel);
        *target = Rgba([value, value, value, 255]);
    }
    grayscale
}

fn pack_metallic_roughness(source: &SourceMaps) -> Result<RgbaImage, String> {
    let metalness = source.maps.get("metalness").map(|map| {
        image::open(&map.path).map(|image| image.to_rgba8()).map_err(|error| error.to_string())
    }).transpose()?.map(|image| {
        if image.dimensions() == (source.width, source.height) {
            image
        } else {
            imageops::resize(&image, source.width, source.height, imageops::FilterType::Lanczos3)
        }
    });
    let roughness = source.maps.get("roughness").map(|map| {
        image::open(&map.path).map(|image| image.to_rgba8()).map_err(|error| error.to_string())
    }).transpose()?.map(|image| {
        if image.dimensions() == (source.width, source.height) {
            image
        } else {
            imageops::resize(&image, source.width, source.height, imageops::FilterType::Lanczos3)
        }
    });
    let mut packed = RgbaImage::from_pixel(source.width, source.height, Rgba([0, 255, 0, 255]));
    for y in 0..source.height {
        for x in 0..source.width {
            let metal = metalness.as_ref().map(|image| map_channel(*image.get_pixel(x, y))).unwrap_or(0);
            let rough = roughness.as_ref().map(|image| map_channel(*image.get_pixel(x, y))).unwrap_or(255);
            packed.put_pixel(x, y, Rgba([0, rough, metal, 255]));
        }
    }
    Ok(packed)
}

fn write_texture_png(path: &std::path::Path, image: &RgbaImage) -> Result<(), String> {
    let file = fs::File::create(path).map_err(|error| error.to_string())?;
    PngEncoder::new_with_quality(file, CompressionType::Best, FilterType::Adaptive)
        .write_image(image.as_raw(), image.width(), image.height(), ExtendedColorType::Rgba8)
        .map_err(|error| error.to_string())
}

fn write_texture_image(request_id: u64, page: usize, slot: String, image: &RgbaImage) -> Result<TextureImageInfo, String> {
    let path = env::temp_dir().join(format!(
        "pa-combine-{}-{request_id}-{slot}-{page}.png",
        std::process::id()
    ));
    write_texture_png(&path, image)?;
    Ok(TextureImageInfo {
        slot,
        page,
        path: path.to_string_lossy().into_owned(),
        width: image.width(),
        height: image.height(),
    })
}

#[cfg(test)]
fn release_source_cache_entry(
    cache_key: &(String, String),
    remaining_source_uses: &mut BTreeMap<(String, String), usize>,
    source_cache: &mut BTreeMap<(String, String), Result<RgbaImage, String>>,
    source_cache_sizes: &mut BTreeMap<(String, String), usize>,
    resident_source_bytes: &mut usize,
) {
    let should_remove = if let Some(remaining) = remaining_source_uses.get_mut(cache_key) {
        *remaining -= 1;
        *remaining == 0
    } else {
        false
    };
    if should_remove {
        remaining_source_uses.remove(cache_key);
        source_cache.remove(cache_key);
        if let Some(size) = source_cache_sizes.remove(cache_key) {
            *resident_source_bytes = resident_source_bytes.saturating_sub(size);
        }
    }
}

pub async fn build_texture_images(
    inputs: &[TextureInput],
    request_id: u64,
    cancelled: &AtomicBool,
) -> (Vec<TextureImageInfo>, Vec<TextureBindingInfo>, Vec<TextureSourceError>) {
    let client = match reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(60))
        .redirect(reqwest::redirect::Policy::none())
        .build() {
        Ok(client) => client,
        Err(error) => {
            let errors = inputs.iter().map(|input| TextureSourceError {
                name: input.name.clone(),
                slot: input.slot.clone(),
                error: error.to_string(),
            }).collect();
            return (Vec::new(), Vec::new(), errors);
        }
    };
    let cookie = studio_cookie();
    let mut inputs_by_name = BTreeMap::<String, Vec<&TextureInput>>::new();
    for input in inputs {
        inputs_by_name.entry(input.name.clone()).or_default().push(input);
    }
    let mut source_cache = BTreeMap::<(String, String), std::path::PathBuf>::new();
    let mut source_cache_paths = Vec::new();
    let mut prepared_map_paths = Vec::new();
    let mut source_signatures = BTreeMap::<u64, usize>::new();
    let mut canonical_page_bindings = BTreeMap::<usize, Vec<TextureBindingInfo>>::new();
    let mut texture_images = Vec::new();
    let mut tiles: Vec<TextureBindingInfo> = Vec::new();
    let mut errors = Vec::new();
    let mut next_source_cache_id = 0usize;
    let mut next_page = 0usize;

    for (name, named_inputs) in inputs_by_name {
        if cancelled.load(Ordering::Relaxed) {
            break;
        }
        let mut ordered_inputs = named_inputs;
        ordered_inputs.sort_by(|a, b| a.slot.cmp(&b.slot));
        let mut signature_hasher = std::collections::hash_map::DefaultHasher::new();
        for input in &ordered_inputs {
            input.slot.hash(&mut signature_hasher);
            input.uri.hash(&mut signature_hasher);
            input.tint.map(|value| value.map(f32::to_bits)).hash(&mut signature_hasher);
            input.transparency.map(f32::to_bits).hash(&mut signature_hasher);
            input.alpha_mode.hash(&mut signature_hasher);
            input.resample_mode.hash(&mut signature_hasher);
            input.surface_color.map(|value| value.map(f32::to_bits)).hash(&mut signature_hasher);
            input.base_color.map(|value| value.map(f32::to_bits)).hash(&mut signature_hasher);
            input.part_color_baked.hash(&mut signature_hasher);
        }
        let signature = signature_hasher.finish();

        if let Some(page) = source_signatures.get(&signature).copied() {
            if let Some(bindings) = canonical_page_bindings.get(&page) {
                tiles.extend(bindings.iter().cloned().map(|mut binding| {
                    binding.name = name.clone();
                    binding
                }));
            }
            continue;
        }

        let mut source = SourceMaps {
            maps: BTreeMap::new(),
            width: 1,
            height: 1,
        };
        for input in ordered_inputs {
            if cancelled.load(Ordering::Relaxed) {
                break;
            }
            let cache_key = match asset_url(&input.uri) {
                Ok(url) => (input.slot.clone(), url),
                Err(error) => {
                    errors.push(TextureSourceError { name: name.clone(), slot: input.slot.clone(), error });
                    continue;
                }
            };
            if !source_cache.contains_key(&cache_key) {
                let downloaded = match download_source(input, &client, cookie.as_deref(), cancelled).await {
                    Ok(image) => image,
                    Err(error) => {
                        errors.push(TextureSourceError {
                            name: name.clone(),
                            slot: input.slot.clone(),
                            error: if error.contains("HTTP 401") && cookie.is_none() {
                                "image request returned HTTP 401 Unauthorized; sign in to Roblox Studio or set ROBLOSECURITY for the Combine worker".to_string()
                            } else {
                                error
                            },
                        });
                        continue;
                    }
                };
                let cache_path = env::temp_dir().join(format!(
                    "pa-combine-{}-{request_id}-source-{next_source_cache_id}.png",
                    std::process::id()
                ));
                next_source_cache_id += 1;
                if let Err(error) = write_texture_png(&cache_path, &downloaded) {
                    errors.push(TextureSourceError { name: name.clone(), slot: input.slot.clone(), error });
                    let _ = fs::remove_file(cache_path);
                    continue;
                }
                source_cache_paths.push(cache_path.clone());
                source_cache.insert(cache_key.clone(), cache_path);
                drop(downloaded);
            }
            let cache_path = source_cache.get(&cache_key).unwrap();
            let source_image = match image::open(cache_path) {
                Ok(image) => image.to_rgba8(),
                Err(error) => {
                    errors.push(TextureSourceError {
                        name: name.clone(),
                        slot: input.slot.clone(),
                        error: format!("could not read cached source texture: {error}"),
                    });
                    continue;
                }
            };
            match prepare_texture(input, source_image) {
                Ok(image) => {
                    let path = env::temp_dir().join(format!(
                        "pa-combine-{}-{request_id}-prepared-{next_source_cache_id}-{}.png",
                        std::process::id(),
                        input.slot
                    ));
                    next_source_cache_id += 1;
                    if let Err(error) = write_texture_png(&path, &image) {
                        errors.push(TextureSourceError { name: name.clone(), slot: input.slot.clone(), error });
                        let _ = fs::remove_file(path);
                        continue;
                    }
                    let (width, height) = image.dimensions();
                    let has_alpha = input.slot == "color" && image.pixels().any(|pixel| pixel[3] < 255);
                    source.width = source.width.max(width);
                    source.height = source.height.max(height);
                    prepared_map_paths.push(path.clone());
                    source.maps.insert(input.slot.clone(), DecodedTexture {
                        input: input.clone(),
                        path,
                        has_alpha,
                    });
                }
                Err(error) => errors.push(TextureSourceError { name: name.clone(), slot: input.slot.clone(), error }),
            }
        }
        if cancelled.load(Ordering::Relaxed) {
            break;
        }

        let page = next_page;
        let mut page_bindings = Vec::new();
        for slot in MAP_SLOTS {
            let map = source.maps.get(slot);
            page_bindings.push(TextureBindingInfo {
                name: name.clone(),
                slot: slot.to_string(),
                has_source: map.is_some_and(|map| !map.input.uri.is_empty()),
                page,
                alpha_mode: source.maps.get("color").and_then(|map| resolved_alpha_mode(&map.input, map.has_alpha)),
                resample_mode: source.maps.values().find_map(|map| map.input.resample_mode.clone()),
                has_alpha: source.maps.get("color").is_some_and(|map| map.has_alpha),
                skip_part_color: source.maps.get("color").is_some_and(|map| map.input.part_color_baked || map.input.alpha_mode.as_deref() == Some("Overlay")),
            });
        }

        let mut page_errors = false;
        let mut page_images = Vec::new();
        if source.maps.contains_key("metalness") || source.maps.contains_key("roughness") {
            match pack_metallic_roughness(&source) {
                Ok(image) => match write_texture_image(request_id, page, "metallicRoughness".to_string(), &image) {
                    Ok(texture_image) => page_images.push(texture_image),
                    Err(error) => {
                        errors.push(TextureSourceError { name: name.clone(), slot: "metallicRoughness".to_string(), error });
                        page_errors = true;
                    }
                },
                Err(error) => {
                    errors.push(TextureSourceError { name: name.clone(), slot: "metallicRoughness".to_string(), error });
                    page_errors = true;
                }
            }
        }
        for (slot, decoded) in source.maps {
            let mut image = match image::open(&decoded.path) {
                Ok(image) => image.to_rgba8(),
                Err(error) => {
                    errors.push(TextureSourceError { name: name.clone(), slot: slot.clone(), error: format!("could not read prepared texture: {error}") });
                    page_errors = true;
                    continue;
                }
            };
            match slot.as_str() {
                "normal" | "emissive" => {
                    for pixel in image.pixels_mut() {
                        pixel[3] = 255;
                    }
                }
                "metalness" | "roughness" => {
                    for pixel in image.pixels_mut() {
                        let value = pixel[0];
                        *pixel = Rgba([value, value, value, 255]);
                    }
                }
                _ => {}
            }
            match write_texture_image(request_id, page, slot.clone(), &image) {
                Ok(texture_image) => page_images.push(texture_image),
                Err(error) => {
                    errors.push(TextureSourceError { name: name.clone(), slot, error });
                    page_errors = true;
                }
            }
        }
        if page_errors {
            for image in page_images {
                let _ = fs::remove_file(image.path);
            }
            continue;
        }
        texture_images.extend(page_images);
        tiles.extend(page_bindings.iter().cloned());
        canonical_page_bindings.insert(page, page_bindings);
        source_signatures.insert(signature, page);
        next_page += 1;
    }

    for path in source_cache_paths.into_iter().chain(prepared_map_paths) {
        let _ = fs::remove_file(path);
    }
    (texture_images, tiles, errors)
}

#[cfg(test)]
mod tests {
    use super::*;


    #[test]
    fn opaque_transparency_mode_resolves_to_opaque() {
        let input = TextureInput {
            name: "surface".to_string(),
            slot: "color".to_string(),
            uri: "1".to_string(),
            tint: None,
            transparency: None,
            alpha_mode: Some("Transparency".to_string()),
            resample_mode: None,
            surface_color: None,
            base_color: None,
            part_color_baked: false,
        };
        assert_eq!(resolved_alpha_mode(&input, false).as_deref(), Some("Opaque"));
        assert_eq!(resolved_alpha_mode(&input, true).as_deref(), Some("Transparency"));
    }

    #[test]
    fn prepare_texture_preserves_source_dimensions() {
        let input = TextureInput {
            name: "surface".to_string(),
            slot: "color".to_string(),
            uri: "1".to_string(),
            tint: None,
            transparency: None,
            alpha_mode: None,
            resample_mode: None,
            surface_color: None,
            base_color: None,
            part_color_baked: false,
        };
        let source = RgbaImage::from_pixel(16, 8, Rgba([10, 20, 30, 255]));
        let prepared = prepare_texture(&input, source.clone()).unwrap();
        assert_eq!(prepared.dimensions(), source.dimensions());
        assert_eq!(prepared, source);
    }

    #[test]
    fn premultiplied_resize_prevents_transparent_rgb_bleed() {
        let source = RgbaImage::from_fn(2, 1, |x, _| {
            if x == 0 { Rgba([255, 0, 0, 255]) } else { Rgba([0, 0, 255, 0]) }
        });
        let resized = resize_premultiplied(&source, 3, 1);
        let middle = resized.get_pixel(1, 0);
        assert!(middle[0] > 240);
        assert!(middle[2] < 10);
    }

    #[test]
    fn resized_normal_maps_are_renormalized() {
        let source = RgbaImage::from_pixel(2, 2, Rgba([255, 128, 128, 255]));
        let resized = resize_normal_map(&source, 2, 2);
        let pixel = resized.get_pixel(0, 0);
        let normal = [
            pixel[0] as f32 / 127.5 - 1.0,
            pixel[1] as f32 / 127.5 - 1.0,
            pixel[2] as f32 / 127.5 - 1.0,
        ];
        let length = (normal[0] * normal[0] + normal[1] * normal[1] + normal[2] * normal[2]).sqrt();
        assert!((length - 1.0).abs() < 0.02);
    }

    #[test]
    fn source_images_keep_their_original_dimensions() {
        let source = DynamicImage::ImageRgba8(RgbaImage::new(8192, 4096));
        let fitted = fit_source(source, "color").unwrap();
        assert_eq!((fitted.width(), fitted.height()), (8192, 4096));
    }

    #[test]
    fn pbr_maps_use_the_red_channel() {
        assert_eq!(map_channel(Rgba([40, 180, 220, 255])), 40);
        let source = RgbaImage::from_pixel(1, 1, Rgba([40, 180, 220, 255]));
        assert_eq!(grayscale_map(&source, 1, 1).get_pixel(0, 0), &Rgba([40, 40, 40, 255]));
    }

    #[test]
    fn packs_roughness_into_green_and_metalness_into_blue() {
        let mut source = SourceMaps {
            maps: BTreeMap::new(),
            width: 1,
            height: 1,
        };
        let directory = env::temp_dir();
        let metalness_path = directory.join(format!("pa-combine-metal-test-{}.png", std::process::id()));
        let roughness_path = directory.join(format!("pa-combine-rough-test-{}.png", std::process::id()));
        RgbaImage::from_pixel(1, 1, Rgba([90, 90, 90, 255])).save(&metalness_path).unwrap();
        RgbaImage::from_pixel(1, 1, Rgba([180, 180, 180, 255])).save(&roughness_path).unwrap();
        let input = |slot: &str, uri: &str| TextureInput { name: "surface".to_string(), slot: slot.to_string(), uri: uri.to_string(), tint: None, transparency: None, alpha_mode: None, resample_mode: None, surface_color: None, base_color: None, part_color_baked: false };
        source.maps.insert("metalness".to_string(), DecodedTexture {
            input: input("metalness", "metal"),
            path: metalness_path.clone(),
            has_alpha: false,
        });
        source.maps.insert("roughness".to_string(), DecodedTexture {
            input: input("roughness", "rough"),
            path: roughness_path.clone(),
            has_alpha: false,
        });
        let packed = pack_metallic_roughness(&source).unwrap();
        assert_eq!(packed.get_pixel(0, 0), &Rgba([0, 180, 90, 255]));
        let _ = fs::remove_file(metalness_path);
        let _ = fs::remove_file(roughness_path);
    }

    #[test]
    fn applies_overlay_tint_and_instance_transparency() {
        let mut image = RgbaImage::from_pixel(1, 1, Rgba([200, 100, 50, 255]));
        apply_modifiers(&mut image, Some([0.5, 1.0, 0.25]), Some(0.2)).unwrap();
        assert_eq!(image.get_pixel(0, 0), &Rgba([100, 100, 13, 204]));
    }

    #[test]
    fn rejects_invalid_overlay_modifiers() {
        let mut image = RgbaImage::new(1, 1);
        assert!(apply_modifiers(&mut image, Some([1.0, 2.0, 1.0]), None).is_err());
    }

    #[test]
    fn composites_surfaceappearance_overlay_over_part_color() {
        let mut image = RgbaImage::from_pixel(1, 1, Rgba([200, 100, 50, 128]));
        apply_alpha_mode(&mut image, Some("Overlay"), Some([0.5, 1.0, 1.0]), Some([0.0, 0.0, 1.0])).unwrap();
        assert_eq!(image.get_pixel(0, 0), &Rgba([50, 50, 153, 255]));
    }

    #[test]
    fn preserves_surfaceappearance_transparency_alpha() {
        let mut image = RgbaImage::from_pixel(1, 1, Rgba([200, 100, 50, 128]));
        apply_alpha_mode(&mut image, Some("Transparency"), Some([0.5, 1.0, 1.0]), None).unwrap();
        assert_eq!(image.get_pixel(0, 0), &Rgba([100, 100, 50, 128]));
    }

    #[test]
    fn applies_tintmask_proportionally_to_color_map_alpha() {
        let mut image = RgbaImage::from_pixel(1, 1, Rgba([200, 100, 50, 128]));
        apply_alpha_mode(&mut image, Some("TintMask"), Some([0.5, 1.0, 0.0]), None).unwrap();
        assert_eq!(image.get_pixel(0, 0), &Rgba([150, 100, 25, 128]));
    }

    #[test]
    fn opaque_alpha_mode_discards_color_map_alpha() {
        let mut image = RgbaImage::from_pixel(1, 1, Rgba([200, 100, 50, 128]));
        apply_alpha_mode(&mut image, Some("Opaque"), None, None).unwrap();
        assert_eq!(image.get_pixel(0, 0), &Rgba([200, 100, 50, 255]));
    }

    #[test]
    fn parses_roblox_asset_uris() {
        assert_eq!(asset_url("rbxassetid://12345").unwrap(), "https://assetdelivery.roblox.com/v1/asset/?id=12345");
        assert!(asset_url("rbxthumb://type=Asset&id=123").is_err());
        assert!(asset_url("https://127.0.0.1/private.png").is_err());
    }

    #[test]
    fn releases_cached_source_after_its_final_use() {
        let key = ("color".to_string(), "https://assetdelivery.roblox.com/v1/asset/?id=123".to_string());
        let mut remaining = BTreeMap::from([(key.clone(), 2)]);
        let mut cache = BTreeMap::from([(key.clone(), Err("cached failure".to_string()))]);

        let mut sizes = BTreeMap::from([(key.clone(), 16)]);
        let mut resident_bytes = 16;

        release_source_cache_entry(&key, &mut remaining, &mut cache, &mut sizes, &mut resident_bytes);
        assert_eq!(remaining.get(&key), Some(&1));
        assert!(cache.contains_key(&key));
        assert_eq!(resident_bytes, 16);

        release_source_cache_entry(&key, &mut remaining, &mut cache, &mut sizes, &mut resident_bytes);
        assert!(!remaining.contains_key(&key));
        assert!(!cache.contains_key(&key));
        assert_eq!(resident_bytes, 0);
    }
}
