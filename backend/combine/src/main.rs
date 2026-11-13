mod filemesh;
mod glb;
mod mesh;
mod overlay;
mod primitive;
mod solid_mesh;
mod texture;

use base64::{engine::general_purpose::STANDARD, Engine};
use futures_util::{stream::FuturesUnordered, SinkExt, StreamExt};
use serde::{Deserialize, Serialize};
use std::io::{self, Write};
use std::{collections::{BTreeMap, BTreeSet, HashMap, VecDeque}, error::Error, fs, net::SocketAddr, path::PathBuf, sync::{atomic::{AtomicBool, AtomicU64, Ordering}, Arc}, time::Duration};
use tokio::{net::TcpListener, sync::{mpsc, Semaphore}};
use tokio_tungstenite::{accept_async_with_config, tungstenite::{protocol::WebSocketConfig, Message}};

type Result<T> = std::result::Result<T, Box<dyn Error + Send + Sync>>;
#[derive(Clone, Debug, Eq, PartialEq, Ord, PartialOrd)]
struct GroupKey {
    material: String,
    material_variant: String,
    double_sided: bool,
    cast_shadow: bool,
    base_color_page: Option<usize>,
    metallic_roughness_page: Option<usize>,
    has_metalness: bool,
    has_roughness: bool,
    normal_page: Option<usize>,
    emissive_page: Option<usize>,
    emissive_tint: Option<[u32; 3]>,
    emissive_strength: Option<u32>,
    reflectance: u32,
    assembly_id: String,
    alpha_mode: Option<mesh::AlphaMode>,
    resample_mode: Option<mesh::ResampleMode>,
    has_color_alpha: bool,
    transparency: u32,
    surface_overlay: bool,
}

fn group_key(mesh: &mesh::MeshData) -> GroupKey {
    GroupKey {
        material: mesh.material.clone(),
        material_variant: mesh.material_variant.clone(),
        double_sided: mesh.double_sided,
        cast_shadow: mesh.cast_shadow,
        base_color_page: mesh.base_color_page,
        metallic_roughness_page: mesh.metallic_roughness_page,
        has_metalness: mesh.has_metalness,
        has_roughness: mesh.has_roughness,
        normal_page: mesh.normal_page,
        emissive_page: mesh.emissive_page,
        emissive_tint: mesh.emissive_tint.map(|value| value.map(f32::to_bits)),
        emissive_strength: mesh.emissive_strength.map(f32::to_bits),
        reflectance: mesh.reflectance.to_bits(),
        assembly_id: mesh.assembly_id.clone(),
        alpha_mode: mesh.alpha_mode,
        resample_mode: mesh.resample_mode,
        has_color_alpha: mesh.has_color_alpha,
        transparency: mesh.transparency.to_bits(),
        surface_overlay: mesh.surface_overlay,
    }
}

const ADDRESS: &str = "127.0.0.1:34873";
static FILE_SEQUENCE: AtomicU64 = AtomicU64::new(1);
static PROGRESS_SEQUENCE: AtomicU64 = AtomicU64::new(1);
const MAX_ASSET_BYTES: usize = 20_000_000;

struct TemporaryTextureFiles(Vec<PathBuf>);

impl Drop for TemporaryTextureFiles {
    fn drop(&mut self) {
        for path in &self.0 {
            let _ = fs::remove_file(path);
        }
    }
}

struct TemporaryOutputFiles {
    paths: Vec<PathBuf>,
    keep: bool,
}

impl Drop for TemporaryOutputFiles {
    fn drop(&mut self) {
        if !self.keep {
            for path in &self.paths {
                let _ = fs::remove_file(path);
            }
        }
    }
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct SerializedUnion {
    name: String,
    #[serde(default)]
    assembly_id: String,
    #[serde(default)]
    cast_shadow: bool,
    serialized_union: String,
    transform: [f32; 12],
    size: [f32; 3],
    overlay_transform: Option<[f32; 12]>,
    material: String,
    material_variant: String,
    color: [f32; 3],
    transparency: f32,
    local_transparency_modifier: f32,
    reflectance: f32,
    emissive_tint: Option<[f32; 3]>,
    emissive_strength: Option<f32>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct MeshInput {
    name: String,
    #[serde(default)]
    mesh_asset_id: Option<String>,
    #[serde(default)]
    assembly_id: String,
    #[serde(default)]
    cast_shadow: bool,
    positions: Vec<[f32; 3]>,
    normals: Vec<[f32; 3]>,
    uvs: Vec<[f32; 2]>,
    colors: Vec<[f32; 4]>,
    transform: [f32; 12],
    scale: [f32; 3],
    double_sided: bool,
    material: String,
    material_variant: String,
    color: [f32; 3],
    transparency: f32,
    local_transparency_modifier: f32,
    reflectance: f32,
    emissive_tint: Option<[f32; 3]>,
    emissive_strength: Option<f32>,
}

#[derive(Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
struct Creator {
    kind: String,
    id: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Request {
    id: u64,
    #[serde(rename = "type")]
    request_type: String,
    selection_count: Option<usize>,
    geometry_count: Option<usize>,
    descendant_count: Option<usize>,
    union_inputs: Option<Vec<SerializedUnion>>,
    mesh_inputs: Option<Vec<MeshInput>>,
    primitive_inputs: Option<Vec<primitive::PrimitiveInput>>,
    texture_inputs: Option<Vec<texture::TextureInput>>,
    surface_overlays: Option<Vec<overlay::SurfaceOverlayInput>>,
    creator: Option<Creator>,
    publish: Option<bool>,
    max_triangles_per_chunk: Option<usize>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct Progress {
    id: u64,
    event: &'static str,
    sequence: u64,
    stage: String,
    progress: f32,
    message: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ControlMessage {
    id: u64,
    #[serde(rename = "type")]
    message_type: String,
}

fn send_progress(sender: &mpsc::UnboundedSender<Progress>, id: u64, stage: &str, progress: f32, message: &str) {
    let _ = sender.send(Progress {
        id,
        event: "progress",
        sequence: PROGRESS_SEQUENCE.fetch_add(1, Ordering::Relaxed),
        stage: stage.to_string(),
        progress: progress.clamp(0.0, 1.0),
        message: message.to_string(),
    });
}

fn cancelled_response(id: u64) -> Response {
    empty_response(id, "Bake cancelled. No further geometry or asset uploads will be started.")
}

struct ByteCounter(usize);

impl Write for ByteCounter {
    fn write(&mut self, bytes: &[u8]) -> io::Result<usize> {
        self.0 += bytes.len();
        Ok(bytes.len())
    }

    fn flush(&mut self) -> io::Result<()> {
        Ok(())
    }
}

fn serialized_size<T: Serialize>(value: &T) -> Result<usize> {
    let mut counter = ByteCounter(0);
    serde_json::to_writer(&mut counter, value)?;
    Ok(counter.0)
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct SourceError {
    name: String,
    error: String,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct MaterialBinding {
    material: String,
    material_variant: String,
    double_sided: bool,
    cast_shadow: bool,
    reflectance: f32,
    base_color_page: Option<usize>,
    metallic_roughness_page: Option<usize>,
    has_metalness: bool,
    has_roughness: bool,
    normal_page: Option<usize>,
    emissive_page: Option<usize>,
    emissive_tint: Option<[f32; 3]>,
    emissive_strength: Option<f32>,
    alpha_mode: Option<String>,
    resample_mode: Option<String>,
    transparency: f32,
    surface_overlay: bool,
    has_color_alpha: bool,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct TextureAssetBinding {
    slot: String,
    page: usize,
    asset_id: String,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct GeometryAsset {
    positions: Vec<[f32; 3]>,
    normals: Vec<[f32; 3]>,
    uvs: Vec<[f32; 2]>,
    colors: Vec<[f32; 4]>,
    indices: Vec<u32>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct Response {
    id: u64,
    ok: bool,
    message: Option<String>,
    error: Option<String>,
    selection_count: Option<usize>,
    geometry_count: Option<usize>,
    descendant_count: Option<usize>,
    mesh_count: Option<usize>,
    union_count: Option<usize>,
    primitive_count: Option<usize>,
    merged_vertex_count: Option<usize>,
    merged_triangle_count: Option<usize>,
    double_sided_group_count: Option<usize>,
    glb_path: Option<String>,
    glb_bytes: Option<usize>,
    asset_id: Option<String>,
    asset_ids: Option<Vec<String>>,
    asset_materials: Option<Vec<MaterialBinding>>,
    asset_sources: Option<Vec<Vec<String>>>,
    geometry_assets: Option<Vec<GeometryAsset>>,
    source_errors: Option<Vec<SourceError>>,
    texture_images: Option<Vec<texture::TextureImageInfo>>,
    texture_bindings: Option<Vec<texture::TextureBindingInfo>>,
    texture_assets: Option<Vec<TextureAssetBinding>>,
    texture_errors: Option<Vec<texture::TextureSourceError>>,
    overlay_count: Option<usize>,
    overlay_errors: Option<Vec<overlay::OverlayError>>,
    recovered_mesh_names: Option<Vec<String>>,
    failed_mesh_names: Option<Vec<String>>,
}

fn empty_response(id: u64, error: impl Into<String>) -> Response {
    Response {
        id,
        ok: false,
        message: None,
        error: Some(error.into()),
        selection_count: None,
        geometry_count: None,
        descendant_count: None,
        mesh_count: None,
        union_count: None,
        primitive_count: None,
        merged_vertex_count: None,
        merged_triangle_count: None,
        double_sided_group_count: None,
        glb_path: None,
        glb_bytes: None,
        asset_id: None,
        asset_ids: None,
        asset_materials: None,
        asset_sources: None,
        geometry_assets: None,
        source_errors: None,
        texture_images: None,
        texture_bindings: None,
        texture_assets: None,
        texture_errors: None,
        overlay_count: None,
        overlay_errors: None,
        recovered_mesh_names: None,
        failed_mesh_names: None,
    }
}

fn inspect(request: &Request) -> Response {
    let selection_count = request.selection_count.unwrap_or_default();
    let geometry_count = request.geometry_count.unwrap_or_default();
    let descendant_count = request.descendant_count.unwrap_or_default();
    Response {
        id: request.id,
        ok: true,
        message: Some(format!("Selection analyzed: {selection_count} roots, {geometry_count} geometry parts, {descendant_count} descendants.")),
        error: None,
        selection_count: Some(selection_count),
        geometry_count: Some(geometry_count),
        descendant_count: Some(descendant_count),
        mesh_count: None,
        union_count: None,
        primitive_count: None,
        merged_vertex_count: None,
        merged_triangle_count: None,
        double_sided_group_count: None,
        glb_path: None,
        glb_bytes: None,
        asset_id: None,
        asset_ids: None,
        asset_materials: None,
        asset_sources: None,
        geometry_assets: None,
        source_errors: None,
        texture_images: None,
        texture_bindings: None,
        texture_assets: None,
        texture_errors: None,
        overlay_count: None,
        overlay_errors: None,
        recovered_mesh_names: None,
        failed_mesh_names: None,
    }
}

fn texture_binding(name: &str, tiles: &[texture::TextureBindingInfo]) -> Option<mesh::TextureBinding> {
    let color = tiles.iter().find(|tile| tile.name == name && tile.slot == "color")?;
    let uri_for = |slot: &str| tiles.iter().find(|tile| tile.name == name && tile.slot == slot).is_some_and(|tile| tile.has_source);
    let binding = mesh::TextureBinding {
        page: color.page,
        has_color: uri_for("color"),
        has_metalness: uri_for("metalness"),
        has_roughness: uri_for("roughness"),
        has_normal: uri_for("normal"),
        has_emissive: uri_for("emissive"),
        skip_part_color: color.skip_part_color,
        alpha_mode: color.alpha_mode.as_deref().and_then(mesh::AlphaMode::from_name),
        resample_mode: color.resample_mode.as_deref().and_then(mesh::ResampleMode::from_name),
        has_color_alpha: color.has_alpha,
    };
    (binding.has_color || binding.has_metalness || binding.has_roughness || binding.has_normal || binding.has_emissive).then_some(binding)
}

struct GeometryResult {
    groups: BTreeMap<GroupKey, mesh::MeshData>,
    mesh_count: usize,
    union_count: usize,
    primitive_count: usize,
    errors: Vec<SourceError>,
    recovered_mesh_names: Vec<String>,
    failed_mesh_names: Vec<String>,
}

async fn process_geometry(request: &Request, texture_bindings: &[texture::TextureBindingInfo], cancelled: &AtomicBool) -> GeometryResult {
    let mesh_inputs = request.mesh_inputs.as_deref().unwrap_or_default();
    let union_inputs = request.union_inputs.as_deref().unwrap_or_default();
    let primitive_inputs = request.primitive_inputs.as_deref().unwrap_or_default();
    let mut groups = BTreeMap::<GroupKey, mesh::MeshData>::new();
    let mut errors = Vec::new();
    let mut mesh_count = 0;
    let mut union_count = 0;
    let mut primitive_count = 0;

    let client = reqwest::Client::builder().user_agent("PA Combine").timeout(Duration::from_secs(20)).redirect(reqwest::redirect::Policy::limited(5)).build().unwrap_or_default();
    let mut asset_mesh_cache = HashMap::<String, std::result::Result<filemesh::FileMeshData, String>>::new();
    let mut recovered_mesh_names = Vec::new();
    let mut failed_mesh_names = Vec::new();
    let fallback_asset_ids: BTreeSet<String> = mesh_inputs.iter()
        .filter(|input| input.positions.is_empty())
        .filter_map(|input| input.mesh_asset_id.as_deref())
        .filter_map(asset_id_from_uri)
        .collect();

    for input in mesh_inputs {
        tokio::task::yield_now().await;
        if cancelled.load(Ordering::Relaxed) { break; }
        let fallback = if let Some(asset_uri) = input.mesh_asset_id.as_deref().filter(|uri| asset_id_from_uri(uri).is_some_and(|id| fallback_asset_ids.contains(&id))) {
            let Some(asset_id) = asset_id_from_uri(asset_uri) else { continue; };
            if !asset_mesh_cache.contains_key(&asset_id) {
                let url = format!("https://assetdelivery.roblox.com/v1/asset/?id={asset_id}");
                let downloaded = async {
                    let response = client.get(url).send().await.map_err(|error| error.to_string())?;
                    if !response.status().is_success() {
                        return Err(format!("AssetDelivery returned HTTP {}", response.status()));
                    }
                    let bytes = response.bytes().await.map_err(|error| error.to_string())?;
                    filemesh::parse(&bytes)
                }.await;
                asset_mesh_cache.insert(asset_id.to_string(), downloaded);
            }
            match asset_mesh_cache.get(&asset_id) {
                Some(Ok(data)) => {
                    recovered_mesh_names.push(input.name.clone());
                    Some(data.clone())
                }
                _ => {
                    failed_mesh_names.push(input.name.clone());
                    continue;
                }
            }
        } else {
            None
        };
        let positions = fallback.as_ref().map(|data| &data.positions).unwrap_or(&input.positions);
        let normals = fallback.as_ref().map(|data| &data.normals).unwrap_or(&input.normals);
        let uvs = fallback.as_ref().map(|data| &data.uvs).unwrap_or(&input.uvs);
        let colors = fallback.as_ref().map(|data| &data.colors).unwrap_or(&input.colors);
        let binding = texture_binding(&input.name, texture_bindings);
        let skip_part_color = binding.is_some_and(|binding| binding.skip_part_color);
        let result = mesh::MeshData::from_mesh_part(
            positions, normals, uvs, colors, &input.transform, &input.scale, input.double_sided, binding,
        ).and_then(|mut mesh| {
            mesh.cast_shadow = input.cast_shadow;
            mesh.apply_color_multiplier(if skip_part_color { [1.0; 3] } else { input.color }, input.transparency, input.local_transparency_modifier)?;
            mesh.transparency = 1.0 - effective_alpha(input.transparency, input.local_transparency_modifier).ok_or("source transparency is invalid")?;
            mesh.reflectance = input.reflectance;
            mesh.emissive_tint = input.emissive_tint;
            mesh.emissive_strength = input.emissive_strength;
            mesh.validate()?;
            mesh.material = input.material.clone();
            mesh.material_variant = input.material_variant.clone();
            mesh.assembly_id = input.assembly_id.clone();
            mesh.source_names.push(input.name.clone());
            mesh.triangle_sources = vec![input.name.clone(); mesh.indices.len() / 3];
            let key = group_key(&mesh);
            groups.entry(key).or_default().append(mesh)
        });
        match result {
            Ok(()) => mesh_count += 1,
            Err(error) => errors.push(SourceError { name: input.name.clone(), error }),
        }
    }

    for input in union_inputs {
        tokio::task::yield_now().await;
        if cancelled.load(Ordering::Relaxed) { break; }
        let binding = texture_binding(&input.name, texture_bindings);
        let skip_part_color = binding.is_some_and(|binding| binding.skip_part_color);
        let result = if input.serialized_union.is_empty() {
            Err("serialized union base64 payload is empty".to_string())
        } else {
            STANDARD.decode(&input.serialized_union)
                .map_err(|error| format!("invalid serialized union base64 ({} encoded bytes): {error}", input.serialized_union.len()))
                .and_then(|bytes| {
                    if bytes.is_empty() {
                        Err(format!("serialized union decoded to an empty buffer ({} encoded bytes)", input.serialized_union.len()))
                    } else {
                        solid_mesh::extract_union_mesh(&bytes)
                            .map_err(|error| format!("could not parse serialized union ({} decoded bytes): {error}", bytes.len()))
                    }
                })
        }
            .and_then(|source| mesh::MeshData::from_union(source, &input.transform, &input.size, binding))
            .and_then(|mut mesh| {
                mesh.cast_shadow = input.cast_shadow;
                mesh.apply_color_multiplier(if skip_part_color { [1.0; 3] } else { input.color }, input.transparency, input.local_transparency_modifier)?;
                mesh.transparency = 1.0 - effective_alpha(input.transparency, input.local_transparency_modifier).ok_or("source transparency is invalid")?;
                mesh.reflectance = input.reflectance;
                mesh.emissive_tint = input.emissive_tint;
                mesh.emissive_strength = input.emissive_strength;
                mesh.validate()?;
                mesh.material = input.material.clone();
                mesh.material_variant = input.material_variant.clone();
                mesh.assembly_id = input.assembly_id.clone();
                mesh.source_names.push(input.name.clone());
                mesh.triangle_sources = vec![input.name.clone(); mesh.indices.len() / 3];
                let key = group_key(&mesh);
                groups.entry(key).or_default().append(mesh)
            });
        match result {
            Ok(()) => union_count += 1,
            Err(error) => {
                eprintln!("[PA Combine] union source failed: {}: {}", input.name, error);
                errors.push(SourceError { name: input.name.clone(), error });
            }
        }
    }

    for input in primitive_inputs {
        tokio::task::yield_now().await;
        if cancelled.load(Ordering::Relaxed) { break; }
        let binding = texture_binding(&input.name, texture_bindings);
        let skip_part_color = binding.is_some_and(|binding| binding.skip_part_color);
        let result = primitive::build(input).and_then(|source| mesh::MeshData::from_primitive(source, binding)).and_then(|mut mesh| {
            mesh.cast_shadow = input.cast_shadow;
            mesh.apply_color_multiplier(if skip_part_color { [1.0; 3] } else { input.color }, input.transparency, input.local_transparency_modifier)?;
            mesh.transparency = 1.0 - effective_alpha(input.transparency, input.local_transparency_modifier).ok_or("source transparency is invalid")?;
            mesh.reflectance = input.reflectance;
            mesh.emissive_tint = input.emissive_tint;
            mesh.emissive_strength = input.emissive_strength;
            mesh.validate()?;
            mesh.material = input.material.clone();
            mesh.material_variant = input.material_variant.clone();
            mesh.assembly_id = input.assembly_id.clone();
            mesh.source_names.push(input.name.clone());
            mesh.triangle_sources = vec![input.name.clone(); mesh.indices.len() / 3];
            let key = group_key(&mesh);
            groups.entry(key).or_default().append(mesh)
        });
        match result {
            Ok(()) => primitive_count += 1,
            Err(error) => errors.push(SourceError { name: input.name.clone(), error }),
        }
    }

    GeometryResult {
        groups: groups.into_iter().filter(|(_, group)| !group.positions.is_empty()).collect(),
        mesh_count,
        union_count,
        primitive_count,
        errors,
        recovered_mesh_names,
        failed_mesh_names,
    }
}

fn asset_id_from_uri(uri: &str) -> Option<String> {
    let digits = uri.rsplit(|character: char| !character.is_ascii_digit()).find(|value| !value.is_empty())?;
    Some(digits.to_string())
}

fn transform_overlay_point(point: [f32; 3], transform: &[f32; 12]) -> [f32; 3] {
    [
        transform[0] + transform[3] * point[0] + transform[4] * point[1] + transform[5] * point[2],
        transform[1] + transform[6] * point[0] + transform[7] * point[1] + transform[8] * point[2],
        transform[2] + transform[9] * point[0] + transform[10] * point[1] + transform[11] * point[2],
    ]
}

fn transform_overlay_normal(normal: [f32; 3], transform: &[f32; 12]) -> [f32; 3] {
    let value = [
        transform[3] * normal[0] + transform[4] * normal[1] + transform[5] * normal[2],
        transform[6] * normal[0] + transform[7] * normal[1] + transform[8] * normal[2],
        transform[9] * normal[0] + transform[10] * normal[1] + transform[11] * normal[2],
    ];
    let length = (value[0] * value[0] + value[1] * value[1] + value[2] * value[2]).sqrt();
    if length > 0.0 { [value[0] / length, value[1] / length, value[2] / length] } else { [0.0, 1.0, 0.0] }
}

fn normalize_overlay_normal(normal: [f32; 3]) -> [f32; 3] {
    let length = (normal[0] * normal[0] + normal[1] * normal[1] + normal[2] * normal[2]).sqrt();
    if length > 0.0 { [normal[0] / length, normal[1] / length, normal[2] / length] } else { [0.0, 1.0, 0.0] }
}

fn inverse_overlay_normal(normal: [f32; 3], transform: &[f32; 12]) -> [f32; 3] {
    let value = [
        transform[3] * normal[0] + transform[6] * normal[1] + transform[9] * normal[2],
        transform[4] * normal[0] + transform[7] * normal[1] + transform[10] * normal[2],
        transform[5] * normal[0] + transform[8] * normal[1] + transform[11] * normal[2],
    ];
    normalize_overlay_normal(value)
}

fn triangle_face_normal(positions: [[f32; 3]; 3]) -> [f32; 3] {
    let edge_a = [positions[1][0] - positions[0][0], positions[1][1] - positions[0][1], positions[1][2] - positions[0][2]];
    let edge_b = [positions[2][0] - positions[0][0], positions[2][1] - positions[0][1], positions[2][2] - positions[0][2]];
    let normal = [edge_a[1] * edge_b[2] - edge_a[2] * edge_b[1], edge_a[2] * edge_b[0] - edge_a[0] * edge_b[2], edge_a[0] * edge_b[1] - edge_a[1] * edge_b[0]];
    let length = (normal[0] * normal[0] + normal[1] * normal[1] + normal[2] * normal[2]).sqrt();
    if length > 0.0 { [normal[0] / length, normal[1] / length, normal[2] / length] } else { [0.0, 1.0, 0.0] }
}

fn effective_alpha(transparency: f32, local_transparency_modifier: f32) -> Option<f32> {
    if !transparency.is_finite()
        || !(0.0..=1.0).contains(&transparency)
        || !local_transparency_modifier.is_finite()
        || !(0.0..=1.0).contains(&local_transparency_modifier)
    {
        return None;
    }
    Some((1.0 - transparency) * (1.0 - local_transparency_modifier))
}



async fn append_meshpart_overlays(
    request: &Request,
    tiles: &[texture::TextureBindingInfo],
    groups: &mut BTreeMap<GroupKey, mesh::MeshData>,
    cancelled: &AtomicBool) -> (usize, Vec<overlay::OverlayError>) {
    let overlays = request.surface_overlays.as_deref().unwrap_or_default();
    let mut applied = 0;
    let mut errors = overlay::validate_inputs(overlays);
    let mut ordered_overlays = overlays.iter().collect::<Vec<_>>();
    ordered_overlays.sort_by_key(|surface| surface.layer);
    for surface in ordered_overlays {
        tokio::task::yield_now().await;
        if cancelled.load(Ordering::Relaxed) { return (applied, errors); }
        if errors.iter().any(|error| error.name == surface.name) {
            continue;
        }
        let Some(source) = request.mesh_inputs.as_deref().unwrap_or_default().iter().find(|input| input.name == surface.owner_name) else {
            if request.primitive_inputs.as_deref().unwrap_or_default().iter().any(|input| input.name == surface.owner_name)
                || request.union_inputs.as_deref().unwrap_or_default().iter().any(|input| input.name == surface.owner_name)
            {
                continue;
            }
            errors.push(overlay::OverlayError {
                name: surface.name.clone(),
                error: "overlay projection requires an extracted MeshPart or supported primitive source".to_string(),
            });
            continue;
        };
        if !tiles.iter().any(|tile| tile.name == surface.name && tile.slot == "color" && !!tile.has_source) {
            errors.push(overlay::OverlayError {
                name: surface.name.clone(),
                error: "overlay source image could not be prepared".to_string(),
            });
            continue;
        }
        let face = match overlay::Face::parse(&surface.face) {
            Ok(face) => face,
            Err(error) => {
                errors.push(overlay::OverlayError { name: surface.name.clone(), error });
                continue;
            }
        };
        if source.positions.len() != source.normals.len() || source.positions.len() % 3 != 0
            || source.scale.iter().any(|value| !value.is_finite() || *value == 0.0)
        {
            errors.push(overlay::OverlayError {
                name: surface.name.clone(),
                error: "source MeshPart geometry has invalid triangle attributes or scale".to_string(),
            });
            continue;
        }
        let scale = source.scale;
        let source_triangles = source.positions.chunks_exact(3).map(|triangle| {
            [
                [triangle[0][0] * scale[0], triangle[0][1] * scale[1], triangle[0][2] * scale[2]],
                [triangle[1][0] * scale[0], triangle[1][1] * scale[1], triangle[1][2] * scale[2]],
                [triangle[2][0] * scale[0], triangle[2][1] * scale[1], triangle[2][2] * scale[2]],
            ]
        }).collect::<Vec<_>>();
        let occlusion = overlay::OcclusionMap::new(&source_triangles, surface.size, face);
        let binding = texture_binding(&surface.name, tiles);
        let mut projected_mesh = mesh::MeshData {
            base_color_page: binding.filter(|binding| binding.has_color).map(|binding| binding.page),
            metallic_roughness_page: binding.filter(|binding| binding.has_metalness || binding.has_roughness).map(|binding| binding.page),
            has_metalness: binding.is_some_and(|binding| binding.has_metalness),
            has_roughness: binding.is_some_and(|binding| binding.has_roughness),
            normal_page: binding.filter(|binding| binding.has_normal).map(|binding| binding.page),
            emissive_page: binding.filter(|binding| binding.has_emissive).map(|binding| binding.page),
            alpha_mode: binding.and_then(|binding| binding.alpha_mode),
            resample_mode: binding.and_then(|binding| binding.resample_mode),
            has_color_alpha: binding.is_some_and(|binding| binding.has_color_alpha),
            transparency: 0.0,
            surface_overlay: true,
            emissive_tint: surface.emissive_tint,
            emissive_strength: surface.emissive_strength,
            source_names: vec![surface.owner_name.clone()],
            cast_shadow: source.cast_shadow,
            reflectance: source.reflectance,
            ..mesh::MeshData::default()
        };
        for triangle in (0..source.positions.len()).step_by(3) {
            tokio::task::yield_now().await;
            if cancelled.load(Ordering::Relaxed) { return (applied, errors); }
            if triangle + 2 >= source.positions.len() {
                break;
            }
            let positions = [
                [source.positions[triangle][0] * scale[0], source.positions[triangle][1] * scale[1], source.positions[triangle][2] * scale[2]],
                [source.positions[triangle + 1][0] * scale[0], source.positions[triangle + 1][1] * scale[1], source.positions[triangle + 1][2] * scale[2]],
                [source.positions[triangle + 2][0] * scale[0], source.positions[triangle + 2][1] * scale[1], source.positions[triangle + 2][2] * scale[2]],
            ];
            let normals = [
                normalize_overlay_normal([
                    source.normals[triangle][0] / scale[0],
                    source.normals[triangle][1] / scale[1],
                    source.normals[triangle][2] / scale[2],
                ]),
                normalize_overlay_normal([
                    source.normals[triangle + 1][0] / scale[0],
                    source.normals[triangle + 1][1] / scale[1],
                    source.normals[triangle + 1][2] / scale[2],
                ]),
                normalize_overlay_normal([
                    source.normals[triangle + 2][0] / scale[0],
                    source.normals[triangle + 2][1] / scale[1],
                    source.normals[triangle + 2][2] / scale[2],
                ]),
            ];
            let fragments = if surface.class_name == "Texture" {
                overlay::project_texture_triangle(positions, normals, surface.size, face, surface.studs_per_tile, surface.offset)
            } else {
                overlay::project_decal_triangle(positions, normals, surface.size, face, surface.studs_per_tile, surface.offset)
            };
            let fragments = occlusion.filter_visible_fragments(fragments);
            for fragment in fragments {
                let rotated = fragment.map(|mut vertex| {
                    vertex.uv = if surface.class_name == "Texture" {
                        overlay::rotate_tiled_uv(vertex.uv, surface.rotation)
                    } else {
                        overlay::rotate_uv(vertex.uv, surface.rotation)
                    };
                    vertex
                });
                let clipped_fragments = if surface.class_name == "Texture" {
                    vec![rotated]
                } else {
                    overlay::clip_unit_uv(rotated)
                };
                for clipped in clipped_fragments {
                    for mut vertex in clipped {
                        let layer_bias = surface.layer.min(1000) as f32 * 0.00001;
                        for axis in 0..3 {
                            vertex.position[axis] += vertex.normal[axis] * layer_bias;
                        }
                        projected_mesh.positions.push(transform_overlay_point(vertex.position, &source.transform));
                        projected_mesh.normals.push(transform_overlay_normal(vertex.normal, &source.transform));
                        projected_mesh.uvs.push(vertex.uv);
                        projected_mesh.colors.push([1.0, 1.0, 1.0, 1.0]);
                        let index = projected_mesh.indices.len() as u32;
                        projected_mesh.indices.push(index);
                    }
                }
            }
        }
        projected_mesh.triangle_sources = vec![surface.owner_name.clone(); projected_mesh.indices.len() / 3];
        if projected_mesh.indices.is_empty() {
            errors.push(overlay::OverlayError {
                name: surface.name.clone(),
                error: "no source triangles intersect the selected face and projection region".to_string(),
            });
            continue;
        }
        projected_mesh.material = "Plastic".to_string();
        projected_mesh.assembly_id = source.assembly_id.clone();
        let key = group_key(&projected_mesh);
        match groups.entry(key).or_default().append(projected_mesh) {
            Ok(()) => applied += 1,
            Err(error) => errors.push(overlay::OverlayError { name: surface.name.clone(), error }),
        }
    }
    (applied, errors)
}

fn inverse_overlay_point(point: [f32; 3], transform: &[f32; 12]) -> [f32; 3] {
    let relative = [point[0] - transform[0], point[1] - transform[1], point[2] - transform[2]];
    [
        transform[3] * relative[0] + transform[6] * relative[1] + transform[9] * relative[2],
        transform[4] * relative[0] + transform[7] * relative[1] + transform[10] * relative[2],
        transform[5] * relative[0] + transform[8] * relative[1] + transform[11] * relative[2],
    ]
}

async fn append_primitive_overlays(
    request: &Request,
    tiles: &[texture::TextureBindingInfo],
    groups: &mut BTreeMap<GroupKey, mesh::MeshData>,
    cancelled: &AtomicBool) -> (usize, Vec<overlay::OverlayError>) {
    let primitives = request.primitive_inputs.as_deref().unwrap_or_default();
    let overlays = request.surface_overlays.as_deref().unwrap_or_default();
    let mut applied = 0;
    let mut errors = Vec::new();
    let mut ordered_overlays = overlays.iter().collect::<Vec<_>>();
    ordered_overlays.sort_by_key(|surface| surface.layer);
    for surface in ordered_overlays {
        tokio::task::yield_now().await;
        if cancelled.load(Ordering::Relaxed) { return (applied, errors); }
        if overlay::validate_inputs(std::slice::from_ref(surface)).len() > 0
            || request.mesh_inputs.as_deref().unwrap_or_default().iter().any(|input| input.name == surface.owner_name)
            || request.union_inputs.as_deref().unwrap_or_default().iter().any(|input| input.name == surface.owner_name)
        {
            continue;
        }
        let Some(source) = primitives.iter().find(|input| input.name == surface.owner_name) else {
            continue;
        };
        if !tiles.iter().any(|tile| tile.name == surface.name && tile.slot == "color" && !!tile.has_source) {
            errors.push(overlay::OverlayError {
                name: surface.name.clone(),
                error: "overlay source image could not be prepared".to_string(),
            });
            continue;
        }
        let face = match overlay::Face::parse(&surface.face) {
            Ok(face) => face,
            Err(error) => {
                errors.push(overlay::OverlayError { name: surface.name.clone(), error });
                continue;
            }
        };
        let source_mesh = match primitive::build(source) {
            Ok(mesh) => mesh,
            Err(error) => {
                errors.push(overlay::OverlayError { name: surface.name.clone(), error });
                continue;
            }
        };
        let source_triangles = source_mesh.positions.chunks_exact(3).map(|triangle| {
            [
                inverse_overlay_point(triangle[0], &source.transform),
                inverse_overlay_point(triangle[1], &source.transform),
                inverse_overlay_point(triangle[2], &source.transform),
            ]
        }).collect::<Vec<_>>();
        let occlusion = overlay::OcclusionMap::new(&source_triangles, surface.size, face);
        let binding = texture_binding(&surface.name, tiles);
        let mut projected_mesh = mesh::MeshData {
            base_color_page: binding.filter(|binding| binding.has_color).map(|binding| binding.page),
            metallic_roughness_page: binding.filter(|binding| binding.has_metalness || binding.has_roughness).map(|binding| binding.page),
            has_metalness: binding.is_some_and(|binding| binding.has_metalness),
            has_roughness: binding.is_some_and(|binding| binding.has_roughness),
            normal_page: binding.filter(|binding| binding.has_normal).map(|binding| binding.page),
            emissive_page: binding.filter(|binding| binding.has_emissive).map(|binding| binding.page),
            alpha_mode: binding.and_then(|binding| binding.alpha_mode),
            resample_mode: binding.and_then(|binding| binding.resample_mode),
            has_color_alpha: binding.is_some_and(|binding| binding.has_color_alpha),
            transparency: 0.0,
            surface_overlay: true,
            emissive_tint: surface.emissive_tint,
            emissive_strength: surface.emissive_strength,
            source_names: vec![surface.owner_name.clone()],
            cast_shadow: source.cast_shadow,
            reflectance: source.reflectance,
            ..mesh::MeshData::default()
        };
        for triangle in (0..(if source.shape == "block" { 0 } else { source_mesh.positions.len() })).step_by(3) {
            tokio::task::yield_now().await;
            if cancelled.load(Ordering::Relaxed) { return (applied, errors); }
            if triangle + 2 >= source_mesh.positions.len() {
                break;
            }
            let positions = [
                inverse_overlay_point(source_mesh.positions[triangle], &source.transform),
                inverse_overlay_point(source_mesh.positions[triangle + 1], &source.transform),
                inverse_overlay_point(source_mesh.positions[triangle + 2], &source.transform),
            ];
            let normals = [triangle_face_normal(positions); 3];
            let fragments = if surface.class_name == "Texture" {
                overlay::project_texture_triangle(positions, normals, surface.size, face, surface.studs_per_tile, surface.offset)
            } else {
                overlay::project_decal_triangle(positions, normals, surface.size, face, surface.studs_per_tile, surface.offset)
            };
            let fragments = occlusion.filter_visible_fragments(fragments);
            for fragment in fragments {
                let rotated = fragment.map(|mut vertex| {
                    vertex.uv = if surface.class_name == "Texture" {
                        overlay::rotate_tiled_uv(vertex.uv, surface.rotation)
                    } else {
                        overlay::rotate_uv(vertex.uv, surface.rotation)
                    };
                    vertex
                });
                let clipped_fragments = if surface.class_name == "Texture" {
                    vec![rotated]
                } else {
                    overlay::clip_unit_uv(rotated)
                };
                for clipped in clipped_fragments {
                    for mut vertex in clipped {
                        let layer_bias = surface.layer.min(1000) as f32 * 0.00001;
                        for axis in 0..3 {
                            vertex.position[axis] += vertex.normal[axis] * layer_bias;
                        }
                        projected_mesh.positions.push(transform_overlay_point(vertex.position, &source.transform));
                        projected_mesh.normals.push(transform_overlay_normal(vertex.normal, &source.transform));
                        projected_mesh.uvs.push(vertex.uv);
                        projected_mesh.colors.push([1.0, 1.0, 1.0, 1.0]);
                        projected_mesh.indices.push(projected_mesh.indices.len() as u32);
                    }
                }
            }
        }
        if projected_mesh.indices.is_empty() && source.shape == "block" {
            for fragment in overlay::project_face_overlay(surface.size, face, surface.studs_per_tile, surface.offset, surface.class_name == "Texture") {
                let rotated = fragment.map(|mut vertex| {
                    vertex.uv = if surface.class_name == "Texture" { overlay::rotate_tiled_uv(vertex.uv, surface.rotation) } else { overlay::rotate_uv(vertex.uv, surface.rotation) };
                    vertex
                });
                let clipped_fragments = if surface.class_name == "Texture" { vec![rotated] } else { overlay::clip_unit_uv(rotated) };
                for clipped in clipped_fragments {
                    for mut vertex in clipped {
                        let layer_bias = surface.layer.min(1000) as f32 * 0.00001;
                        for axis in 0..3 { vertex.position[axis] += vertex.normal[axis] * layer_bias; }
                        projected_mesh.positions.push(transform_overlay_point(vertex.position, &source.transform));
                        projected_mesh.normals.push(transform_overlay_normal(vertex.normal, &source.transform));
                        projected_mesh.uvs.push(vertex.uv);
                        projected_mesh.colors.push([1.0, 1.0, 1.0, 1.0]);
                        projected_mesh.indices.push(projected_mesh.indices.len() as u32);
                    }
                }
            }
        }
        projected_mesh.triangle_sources = vec![surface.owner_name.clone(); projected_mesh.indices.len() / 3];
        if projected_mesh.indices.is_empty() {
            errors.push(overlay::OverlayError {
                name: surface.name.clone(),
                error: "no primitive triangles intersect the selected face and projection region".to_string(),
            });
            continue;
        }
        projected_mesh.material = "Plastic".to_string();
        projected_mesh.assembly_id = source.assembly_id.clone();
        let key = group_key(&projected_mesh);
        match groups.entry(key).or_default().append(projected_mesh) {
            Ok(()) => applied += 1,
            Err(error) => errors.push(overlay::OverlayError { name: surface.name.clone(), error }),
        }
    }
    (applied, errors)
}

async fn append_union_overlays(
    request: &Request,
    tiles: &[texture::TextureBindingInfo],
    groups: &mut BTreeMap<GroupKey, mesh::MeshData>,
    cancelled: &AtomicBool) -> (usize, Vec<overlay::OverlayError>) {
    let unions = request.union_inputs.as_deref().unwrap_or_default();
    let overlays = request.surface_overlays.as_deref().unwrap_or_default();
    let mut applied = 0;
    let mut errors = Vec::new();
    let mut ordered_overlays = overlays.iter().collect::<Vec<_>>();
    ordered_overlays.sort_by_key(|surface| surface.layer);
    for surface in ordered_overlays {
        tokio::task::yield_now().await;
        if cancelled.load(Ordering::Relaxed) { return (applied, errors); }
        if overlay::validate_inputs(std::slice::from_ref(surface)).len() > 0
            || request.mesh_inputs.as_deref().unwrap_or_default().iter().any(|input| input.name == surface.owner_name)
            || request.primitive_inputs.as_deref().unwrap_or_default().iter().any(|input| input.name == surface.owner_name)
        {
            continue;
        }
        let Some(source) = unions.iter().find(|input| input.name == surface.owner_name) else {
            continue;
        };
        if !tiles.iter().any(|tile| tile.name == surface.name && tile.slot == "color" && !!tile.has_source) {
            errors.push(overlay::OverlayError {
                name: surface.name.clone(),
                error: "overlay source image could not be prepared".to_string(),
            });
            continue;
        }
        let face = match overlay::Face::parse(&surface.face) {
            Ok(face) => face,
            Err(error) => {
                errors.push(overlay::OverlayError { name: surface.name.clone(), error });
                continue;
            }
        };
        let serialized = match STANDARD.decode(&source.serialized_union) {
            Ok(bytes) => bytes,
            Err(error) => {
                errors.push(overlay::OverlayError { name: surface.name.clone(), error: error.to_string() });
                continue;
            }
        };
        let union_mesh = match solid_mesh::extract_union_mesh(&serialized)
            .map_err(|error| error.to_string())
            .and_then(|source_mesh| mesh::MeshData::from_union(source_mesh, &source.transform, &source.size, None))
            .and_then(|mesh| {
                mesh.validate()?;
                Ok(mesh)
            })
        {
            Ok(mesh) => mesh,
            Err(error) => {
                errors.push(overlay::OverlayError { name: surface.name.clone(), error });
                continue;
            }
        };
        let overlay_transform = source.overlay_transform.as_ref().unwrap_or(&source.transform);
        let source_triangles = union_mesh.indices.chunks_exact(3).map(|triangle| {
            [
                inverse_overlay_point(union_mesh.positions[triangle[0] as usize], overlay_transform),
                inverse_overlay_point(union_mesh.positions[triangle[1] as usize], overlay_transform),
                inverse_overlay_point(union_mesh.positions[triangle[2] as usize], overlay_transform),
            ]
        }).collect::<Vec<_>>();
        let occlusion = overlay::OcclusionMap::new(&source_triangles, surface.size, face);
        let binding = texture_binding(&surface.name, tiles);
        let mut projected_mesh = mesh::MeshData {
            base_color_page: binding.filter(|binding| binding.has_color).map(|binding| binding.page),
            metallic_roughness_page: binding.filter(|binding| binding.has_metalness || binding.has_roughness).map(|binding| binding.page),
            has_metalness: binding.is_some_and(|binding| binding.has_metalness),
            has_roughness: binding.is_some_and(|binding| binding.has_roughness),
            normal_page: binding.filter(|binding| binding.has_normal).map(|binding| binding.page),
            emissive_page: binding.filter(|binding| binding.has_emissive).map(|binding| binding.page),
            alpha_mode: binding.and_then(|binding| binding.alpha_mode),
            resample_mode: binding.and_then(|binding| binding.resample_mode),
            has_color_alpha: binding.is_some_and(|binding| binding.has_color_alpha),
            transparency: 0.0,
            surface_overlay: true,
            emissive_tint: surface.emissive_tint,
            emissive_strength: surface.emissive_strength,
            source_names: vec![surface.owner_name.clone()],
            cast_shadow: source.cast_shadow,
            reflectance: source.reflectance,
            ..mesh::MeshData::default()
        };
        for triangle in union_mesh.indices.chunks_exact(3) {
            tokio::task::yield_now().await;
            if cancelled.load(Ordering::Relaxed) { return (applied, errors); }
            let positions = [
                inverse_overlay_point(union_mesh.positions[triangle[0] as usize], overlay_transform),
                inverse_overlay_point(union_mesh.positions[triangle[1] as usize], overlay_transform),
                inverse_overlay_point(union_mesh.positions[triangle[2] as usize], overlay_transform),
            ];
            let normals = [
                inverse_overlay_normal(union_mesh.normals[triangle[0] as usize], overlay_transform),
                inverse_overlay_normal(union_mesh.normals[triangle[1] as usize], overlay_transform),
                inverse_overlay_normal(union_mesh.normals[triangle[2] as usize], overlay_transform),
            ];
            let fragments = if surface.class_name == "Texture" {
                overlay::project_texture_triangle(positions, normals, surface.size, face, surface.studs_per_tile, surface.offset)
            } else {
                overlay::project_decal_triangle(positions, normals, surface.size, face, surface.studs_per_tile, surface.offset)
            };
            let fragments = occlusion.filter_visible_fragments(fragments);
            for fragment in fragments {
                let rotated = fragment.map(|mut vertex| {
                    vertex.uv = if surface.class_name == "Texture" {
                        overlay::rotate_tiled_uv(vertex.uv, surface.rotation)
                    } else {
                        overlay::rotate_uv(vertex.uv, surface.rotation)
                    };
                    vertex
                });
                let clipped_fragments = if surface.class_name == "Texture" {
                    vec![rotated]
                } else {
                    overlay::clip_unit_uv(rotated)
                };
                for clipped in clipped_fragments {
                    for mut vertex in clipped {
                        let layer_bias = surface.layer.min(1000) as f32 * 0.00001;
                        for axis in 0..3 {
                            vertex.position[axis] += vertex.normal[axis] * layer_bias;
                        }
                        projected_mesh.positions.push(transform_overlay_point(vertex.position, &source.transform));
                        projected_mesh.normals.push(transform_overlay_normal(vertex.normal, &source.transform));
                        projected_mesh.uvs.push(vertex.uv);
                        projected_mesh.colors.push([1.0, 1.0, 1.0, 1.0]);
                        projected_mesh.indices.push(projected_mesh.indices.len() as u32);
                    }
                }
            }
        }
        projected_mesh.triangle_sources = vec![surface.owner_name.clone(); projected_mesh.indices.len() / 3];
        if projected_mesh.indices.is_empty() {
            errors.push(overlay::OverlayError {
                name: surface.name.clone(),
                error: "no union triangles intersect the selected face and projection region".to_string(),
            });
            continue;
        }
        projected_mesh.material = "Plastic".to_string();
        projected_mesh.assembly_id = source.assembly_id.clone();
        let key = group_key(&projected_mesh);
        match groups.entry(key).or_default().append(projected_mesh) {
            Ok(()) => applied += 1,
            Err(error) => errors.push(overlay::OverlayError { name: surface.name.clone(), error }),
        }
    }
    (applied, errors)
}

fn split_mesh(mesh: &mesh::MeshData, max_triangles: usize) -> std::result::Result<Vec<mesh::MeshData>, String> {
    if max_triangles == 0 {
        return Err("mesh chunk triangle limit must be greater than zero".to_string());
    }
    mesh.validate()?;
    let mut chunks = Vec::new();
    for (chunk_index, triangles) in mesh.indices.chunks(max_triangles * 3).enumerate() {
        let mut chunk = mesh.empty_like();
        let triangle_start = chunk_index * max_triangles;
        let triangle_end = triangle_start + triangles.len() / 3;
        chunk.source_names = mesh.triangle_sources.get(triangle_start..triangle_end)
            .map(|sources| {
                let mut names = sources.to_vec();
                names.sort();
                names.dedup();
                names
            })
            .filter(|names| !names.is_empty())
            .unwrap_or_else(|| mesh.source_names.clone());
        if !mesh.triangle_sources.is_empty() {
            chunk.triangle_sources.extend_from_slice(&mesh.triangle_sources[triangle_start..triangle_end]);
        }
        let mut remapped = BTreeMap::<u32, u32>::new();
        for source_index in triangles {
            let target_index = if let Some(index) = remapped.get(source_index) {
                *index
            } else {
                let source = *source_index as usize;
                let target = u32::try_from(chunk.positions.len()).map_err(|_| "mesh chunk exceeds the 32-bit vertex limit")?;
                chunk.positions.push(mesh.positions[source]);
                chunk.normals.push(mesh.normals[source]);
                chunk.uvs.push(mesh.uvs[source]);
                chunk.colors.push(mesh.colors[source]);
                remapped.insert(*source_index, target);
                target
            };
            chunk.indices.push(target_index);
        }
        chunk.validate()?;
        chunks.push(chunk);
    }
    Ok(chunks)
}

fn creator_payload(creator: &Creator) -> Result<serde_json::Value> {
    let id = creator.id.parse::<u64>()?;
    let creator = match creator.kind.as_str() {
        "User" => serde_json::json!({ "userId": id }),
        "Group" => serde_json::json!({ "groupId": id }),
        other => return Err(format!("unsupported creator type: {other}").into()),
    };
    Ok(creator)
}

async fn wait_for_cancellation(cancelled: &AtomicBool) {
    while !cancelled.load(Ordering::Relaxed) {
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
}

async fn upload_asset(
    path: &PathBuf,
    key: &str,
    creator: &Creator,
    name: &str,
    asset_type: &str,
    file_name: &str,
    mime_type: &str,
    description: &str,
    cancelled: &AtomicBool,
) -> Result<String> {
    let started = tokio::time::Instant::now();
    let bytes = fs::read(path)?;
    eprintln!("[PA Combine] texture upload started: {name} ({:.2} MB)", bytes.len() as f64 / 1_000_000.0);
    if cancelled.load(Ordering::Relaxed) {
        return Err("upload cancelled before submission".into());
    }
    let metadata = serde_json::json!({
        "assetType": asset_type,
        "displayName": name,
        "description": description,
        "creationContext": {
            "creator": creator_payload(creator)?
        }
    });
    if bytes.len() > MAX_ASSET_BYTES {
        return Err(format!(
            "{asset_type} asset is {:.2} MB; Open Cloud asset uploads are limited to 20 MB per file.",
            bytes.len() as f64 / 1_000_000.0
        ).into());
    }
    let file = reqwest::multipart::Part::bytes(bytes)
        .file_name(file_name.to_owned())
        .mime_str(mime_type)?;
    let form = reqwest::multipart::Form::new()
        .text("request", serde_json::to_string(&metadata)?)
        .part("fileContent", file);
    let client = reqwest::Client::builder().timeout(Duration::from_secs(30)).build()?;
    eprintln!("[PA Combine] texture upload submitting: {name}");
    let response = tokio::select! {
        result = client.post("https://apis.roblox.com/assets/v1/assets")
            .header("x-api-key", key)
            .multipart(form)
            .send() => result?,
        _ = wait_for_cancellation(cancelled) => {
            return Err("upload cancelled during submission; the asset may still be accepted by Open Cloud".into());
        }
    };
    let status = response.status();
    let body = tokio::select! {
        result = response.text() => result?,
        _ = wait_for_cancellation(cancelled) => {
            return Err("upload cancelled while reading the submission response; the submitted asset may still complete".into());
        }
    };
    if !status.is_success() {
        return Err(format!("asset upload returned HTTP {status}: {body}").into());
    }
    let operation: serde_json::Value = serde_json::from_str(&body)?;
    let operation_path = operation["path"].as_str()
        .ok_or_else(|| format!("asset upload response omitted operation path: {body}"))?;
    let operation_id = operation_path.strip_prefix("operations/")
        .ok_or_else(|| format!("unexpected asset operation path: {operation_path}"))?;
    eprintln!("[PA Combine] texture upload accepted: {name}, operation {operation_id}, HTTP {status}");
    let deadline = tokio::time::Instant::now() + Duration::from_secs(180);
    let mut poll_count = 0usize;
    loop {
        if cancelled.load(Ordering::Relaxed) {
            return Err("upload cancelled while waiting for asset processing; the submitted operation may still complete".into());
        }
        if tokio::time::Instant::now() >= deadline {
            eprintln!("[PA Combine] texture upload timed out: {name}, operation {operation_id}, {poll_count} poll(s), {:.1}s elapsed", started.elapsed().as_secs_f64());
            return Err(format!("asset upload operation {operation_id} did not complete within 180 seconds").into());
        }
        poll_count += 1;
        let response = tokio::select! {
            result = client.get(format!("https://apis.roblox.com/assets/v1/operations/{operation_id}"))
                .header("x-api-key", key)
                .send() => result?,
            _ = wait_for_cancellation(cancelled) => {
                return Err("upload cancelled while checking asset processing; the submitted operation may still complete".into());
            }
        };
        let status = response.status();
        let body = tokio::select! {
            result = response.text() => result?,
            _ = wait_for_cancellation(cancelled) => {
                return Err("upload cancelled while reading asset processing status; the submitted operation may still complete".into());
            }
        };
        if !status.is_success() {
            return Err(format!("asset operation poll returned HTTP {status}: {body}").into());
        }
        let operation: serde_json::Value = serde_json::from_str(&body)?;
        if !operation["error"].is_null() {
            return Err(format!("asset creation failed: {}", operation["error"]).into());
        }
        if let Some(asset_id) = operation["response"]["assetId"].as_str()
            .map(str::to_owned)
            .or_else(|| operation["response"]["assetId"].as_u64().map(|value| value.to_string()))
        {
            eprintln!("[PA Combine] texture upload completed: {name}, asset {asset_id}, {poll_count} poll(s), {:.1}s", started.elapsed().as_secs_f64());
            return Ok(asset_id);
        }
        if poll_count == 1 || poll_count % 5 == 0 {
            eprintln!("[PA Combine] texture upload pending: {name}, operation {operation_id}, poll {poll_count}, {:.1}s elapsed", started.elapsed().as_secs_f64());
        }
        if operation["done"].as_bool() == Some(true) {
            return Err(format!("completed asset operation omitted assetId: {body}").into());
        }
        tokio::select! {
            _ = tokio::time::sleep(Duration::from_secs(2)) => {}
            _ = wait_for_cancellation(cancelled) => {
                return Err("upload cancelled while waiting for asset processing; the submitted operation may still complete".into());
            }
        }
    }
}

async fn upload_image(path: &PathBuf, key: &str, creator: &Creator, name: &str, cancelled: &AtomicBool) -> Result<String> {
    upload_asset(path, key, creator, name, "Image", "texture.png", "image/png", "Source texture image generated by PA Combine.", cancelled).await
}

async fn process_request(request: &mut Request, progress: &mpsc::UnboundedSender<Progress>, cancelled: Arc<AtomicBool>) -> Response {
    match request.request_type.as_str() {
        "inspect" => inspect(request),
        "geometry" => {
            let overlays = request.surface_overlays.as_deref().unwrap_or_default();
            let mut texture_inputs = std::mem::take(&mut request.texture_inputs).unwrap_or_default();
            for overlay in overlays {
                for (slot, uri) in [
                    ("color", Some(&overlay.uri)),
                    ("metalness", overlay.metalness_uri.as_ref()),
                    ("normal", overlay.normal_uri.as_ref()),
                    ("roughness", overlay.roughness_uri.as_ref()),
                    ("emissive", overlay.emissive_uri.as_ref()),
                ] {
                    if let Some(uri) = uri {
                        texture_inputs.push(texture::TextureInput {
                            name: overlay.name.clone(),
                            slot: slot.to_string(),
                            uri: uri.clone(),
                            tint: (slot == "color").then_some(overlay.color),
                            transparency: (slot == "color").then_some(overlay.transparency),
                            alpha_mode: None,
                            resample_mode: None,
                            surface_color: None,
                            base_color: None,
                            part_color_baked: false,
                        });
                    }
                }
            }
            let file_id = FILE_SEQUENCE.fetch_add(1, Ordering::Relaxed);
            send_progress(progress, request.id, "textures", 0.08, "Downloading and decoding texture sources.");
            if cancelled.load(Ordering::Relaxed) { return cancelled_response(request.id); }
            let unique_texture_sources = texture_inputs.iter()
                .map(|input| (input.slot.as_str(), input.uri.trim()))
                .collect::<std::collections::BTreeSet<_>>()
                .len();
            eprintln!("[PA Combine] request {} received {} texture input(s) across {} unique source map(s), {} surface overlay(s), {} union(s), {} MeshPart(s), and {} primitive(s)", request.id, texture_inputs.len(), unique_texture_sources, overlays.len(), request.union_inputs.as_deref().unwrap_or_default().len(), request.mesh_inputs.as_deref().unwrap_or_default().len(), request.primitive_inputs.as_deref().unwrap_or_default().len());
            let (texture_images, texture_bindings, texture_errors) = texture::build_texture_images(&texture_inputs, file_id, &cancelled).await;
            drop(texture_inputs);
            for issue in &texture_errors {
                eprintln!("[PA Combine] texture error: {} [{}]: {}", issue.name, issue.slot, issue.error);
            }
            let _texture_files = TemporaryTextureFiles(texture_images.iter().map(|texture_image| PathBuf::from(&texture_image.path)).collect());
            if cancelled.load(Ordering::Relaxed) { return cancelled_response(request.id); }
            if let Some(error) = texture_errors.iter().find(|error| error.slot == "texture" || error.name.starts_with("[texture]")) {
                let mut response = empty_response(request.id, format!("texture preparation failed: {}", error.error));
                response.texture_images = Some(texture_images);
                response.texture_bindings = Some(texture_bindings);
                response.texture_errors = Some(texture_errors);
                return response;
            }
            send_progress(progress, request.id, "textures", 0.37, "Independent source textures prepared.");
            send_progress(progress, request.id, "geometry", 0.38, "Reconstructing and merging source geometry.");
            eprintln!("[PA Combine] request {}: starting geometry reconstruction", request.id);
            let geometry_started = tokio::time::Instant::now();
            let mut result = process_geometry(request, &texture_bindings, &cancelled).await;
            let input_vertices: usize = result.groups.values().map(|group| group.positions.len()).sum();
            let input_triangles: usize = result.groups.values().map(|group| group.indices.len() / 3).sum();
            eprintln!("[PA Combine] request {}: geometry reconstruction produced {} group(s), {} vertices, {} triangles in {:.2}s", request.id, result.groups.len(), input_vertices, input_triangles, geometry_started.elapsed().as_secs_f64());
            if cancelled.load(Ordering::Relaxed) { return cancelled_response(request.id); }
            send_progress(progress, request.id, "overlays", 0.55, "Projecting overlays onto visible MeshPart surfaces.");
            let mesh_overlay_started = tokio::time::Instant::now();
            let (mesh_overlay_count, mut overlay_errors) = append_meshpart_overlays(request, &texture_bindings, &mut result.groups, &cancelled).await;
            eprintln!("[PA Combine] request {}: projected {} MeshPart overlay(s) in {:.2}s", request.id, mesh_overlay_count, mesh_overlay_started.elapsed().as_secs_f64());
            if cancelled.load(Ordering::Relaxed) { return cancelled_response(request.id); }
            send_progress(progress, request.id, "overlays", 0.64, "Projecting overlays onto primitive surfaces.");
            let primitive_overlay_started = tokio::time::Instant::now();
            let (primitive_overlay_count, primitive_overlay_errors) = append_primitive_overlays(request, &texture_bindings, &mut result.groups, &cancelled).await;
            eprintln!("[PA Combine] request {}: projected {} primitive overlay(s) in {:.2}s", request.id, primitive_overlay_count, primitive_overlay_started.elapsed().as_secs_f64());
            if cancelled.load(Ordering::Relaxed) { return cancelled_response(request.id); }
            send_progress(progress, request.id, "overlays", 0.72, "Projecting overlays onto union surfaces.");
            let union_overlay_started = tokio::time::Instant::now();
            let (union_overlay_count, union_overlay_errors) = append_union_overlays(request, &texture_bindings, &mut result.groups, &cancelled).await;
            eprintln!("[PA Combine] request {}: projected {} union overlay(s) in {:.2}s", request.id, union_overlay_count, union_overlay_started.elapsed().as_secs_f64());
            if cancelled.load(Ordering::Relaxed) { return cancelled_response(request.id); }
            overlay_errors.extend(primitive_overlay_errors);
            overlay_errors.extend(union_overlay_errors);
            let overlay_count = mesh_overlay_count + primitive_overlay_count + union_overlay_count;
            request.mesh_inputs = None;
            request.union_inputs = None;
            request.primitive_inputs = None;
            request.surface_overlays = None;
            let mut texture_assets = Vec::new();
            let mut upload_errors = Vec::new();
            if request.publish.unwrap_or(false) {
                let required_texture_slots = texture_bindings.iter()
                    .filter(|tile| tile.has_source)
                    .map(|tile| tile.slot.clone())
                    .collect::<BTreeSet<_>>();
                let publish_texture_images = texture_images.iter()
                    .filter(|texture_image| texture_image.slot != "metallicRoughness" && required_texture_slots.contains(&texture_image.slot))
                    .collect::<Vec<_>>();
                if !publish_texture_images.is_empty() {
                    let key = match std::env::var("ROBLOX_OPEN_CLOUD_API_KEY") {
                        Ok(key) => key,
                        Err(_) => return empty_response(request.id, "set ROBLOX_OPEN_CLOUD_API_KEY in the worker environment to publish texture assets"),
                    };
                    let creator = match request.creator.as_ref() {
                        Some(creator) => creator,
                        None => return empty_response(request.id, "the Studio request did not include a creator identity for texture publishing"),
                    };
                    let total_uploads = publish_texture_images.len();
                    let mut uploads = FuturesUnordered::new();
                    let mut completed_uploads = 0usize;
                    for texture_image in &publish_texture_images {
                        if cancelled.load(Ordering::Relaxed) { return cancelled_response(request.id); }
                        let path = PathBuf::from(&texture_image.path);
                        let slot = texture_image.slot.clone();
                        let page = texture_image.page;
                        let name = format!("PA Combine {} Texture {}", slot, page + 1);
                        let key = key.clone();
                        let creator = creator.clone();
                        let upload_cancelled = cancelled.clone();
                        eprintln!("[PA Combine] texture upload queued: {} page {}", slot, page + 1);
                        uploads.push(async move {
                            let result = upload_image(&path, &key, &creator, &name, &upload_cancelled).await;
                            (slot, page, result)
                        });
                        if uploads.len() >= 4 {
                            if let Some((slot, page, result)) = tokio::select! {
                                result = uploads.next() => result,
                                _ = wait_for_cancellation(&cancelled) => return cancelled_response(request.id),
                            } {
                                completed_uploads += 1;
                                match result {
                                    Ok(asset_id) => {
                                        eprintln!("[PA Combine] texture upload recorded: {} page {}, asset {}", slot, page + 1, asset_id);
                                        texture_assets.push(TextureAssetBinding { slot, page, asset_id });
                                    }
                                    Err(error) => {
                                        eprintln!("[PA Combine] texture upload failed: {} page {}: {error}", slot, page + 1);
                                        upload_errors.push(format!("could not publish {} source texture {}: {error}", slot, page + 1));
                                    },
                                }
                                let fraction = completed_uploads as f32 / total_uploads.max(1) as f32;
                                send_progress(progress, request.id, "texture_assets", 0.73 + fraction * 0.04, &format!("Published {completed_uploads} of {} source texture assets.", total_uploads));
                            }
                        }
                    }
                    while let Some((slot, page, result)) = tokio::select! {
                        result = uploads.next() => result,
                        _ = wait_for_cancellation(&cancelled) => return cancelled_response(request.id),
                    } {
                        completed_uploads += 1;
                        match result {
                            Ok(asset_id) => {
                                eprintln!("[PA Combine] texture upload recorded: {} page {}, asset {}", slot, page + 1, asset_id);
                                texture_assets.push(TextureAssetBinding { slot, page, asset_id });
                            }
                            Err(error) => {
                                eprintln!("[PA Combine] texture upload failed: {} page {}: {error}", slot, page + 1);
                                upload_errors.push(format!("could not publish {} source texture {}: {error}", slot, page + 1));
                            },
                        }
                        let fraction = completed_uploads as f32 / publish_texture_images.len().max(1) as f32;
                        send_progress(progress, request.id, "texture_assets", 0.73 + fraction * 0.04, &format!("Published {completed_uploads} of {} source texture assets.", publish_texture_images.len()));
                    }
    
                }
                texture_assets.sort_by(|a, b| (a.page, &a.slot).cmp(&(b.page, &b.slot)));
                if let Some(failure) = upload_errors.first() {
                    let mut response = empty_response(request.id, failure.clone());
                    response.texture_images = Some(texture_images);
                    response.texture_bindings = Some(texture_bindings);
                    response.texture_assets = Some(texture_assets);
                    response.texture_errors = Some(texture_errors);
                    return response;
                }
            }
            if cancelled.load(Ordering::Relaxed) { return cancelled_response(request.id); }
            for issue in &result.errors {
                eprintln!("[PA Combine] source error: {}: {}", issue.name, issue.error);
            }
            for issue in &overlay_errors {
                eprintln!("[PA Combine] overlay error: {}: {}", issue.name, issue.error);
            }
            let success_count = result.mesh_count + result.union_count + result.primitive_count;
            if result.groups.is_empty() {
                let mut response = empty_response(request.id, "No selected geometry could be merged.");
                response.source_errors = Some(result.errors);
                response.texture_images = Some(texture_images);
                response.texture_bindings = Some(texture_bindings);
                response.texture_assets = Some(texture_assets);
                response.texture_errors = Some(texture_errors);
                response.overlay_count = Some(overlay_count);
                response.overlay_errors = Some(overlay_errors);
                return response;
            }
            let merged_vertex_count = result.groups.values().map(|group| group.positions.len()).sum();
            let merged_triangle_count: usize = result.groups.values().map(|group| group.indices.len() / 3).sum();
            let double_sided_group_count = result.groups.values().filter(|group| group.double_sided).count();
            eprintln!("[PA Combine] request {}: final merged geometry has {} group(s), {} vertices, {} triangles; {} double-sided group(s)", request.id, result.groups.len(), merged_vertex_count, merged_triangle_count, double_sided_group_count);
            send_progress(progress, request.id, "splitting", 0.78, "Splitting geometry to fit asset limits.");
            let max_triangles_per_chunk = request.max_triangles_per_chunk.unwrap_or(20_000).clamp(1_000, 20_000);
            let asset_ids = Vec::new();
            let mut asset_materials = Vec::new();
            let mut asset_sources = Vec::new();
            let mut output_paths = Vec::new();
            let mut output_files = TemporaryOutputFiles {
                paths: Vec::new(),
                keep: !request.publish.unwrap_or(false),
            };
            let mut output_bytes = Vec::new();
            let mut prepared_chunks = Vec::new();
            let mut error = None;
            let mut index = 0usize;
            let mut processed_triangles = 0usize;
            let progress_stage = if request.publish.unwrap_or(false) { "geometry_preparation" } else { "publishing" };
            let groups = std::mem::take(&mut result.groups);
            for group in groups.into_values() {
                if cancelled.load(Ordering::Relaxed) {
                    error = Some("Bake cancelled. Previously uploaded assets were retained; replacement was skipped.".to_string());
                    break;
                }
                send_progress(progress, request.id, progress_stage, 0.8 + processed_triangles as f32 / merged_triangle_count.max(1) as f32 * 0.18, "Preparing geometry chunks.");
                tokio::task::yield_now().await;
                let group_chunks = match split_mesh(&group, max_triangles_per_chunk) {
                    Ok(group_chunks) => group_chunks,
                    Err(failure) => {
                        error = Some(failure);
                        break;
                    }
                };
                let mut chunks = VecDeque::from(group_chunks);
                while let Some(chunk) = chunks.pop_front() {
                    tokio::task::yield_now().await;
                    if cancelled.load(Ordering::Relaxed) {
                        error = Some("Bake cancelled. Previously uploaded assets were retained; replacement was skipped.".to_string());
                        break;
                    }
                    index += 1;
                    eprintln!("[PA Combine] request {}: prepared geometry chunk {} with {} vertices and {} triangles", request.id, index, chunk.positions.len(), chunk.indices.len() / 3);
                    let fraction = processed_triangles as f32 / merged_triangle_count.max(1) as f32;
                    send_progress(progress, request.id, progress_stage, 0.8 + fraction * 0.18, &format!("Building output asset {} ({} queued).", index, chunks.len()));
                    tokio::task::yield_now().await;
                    let path = std::env::temp_dir().join(format!("pa-combine-{}-{file_id}-{index}.glb", std::process::id()));
                    let bytes = if request.publish.unwrap_or(false) {
                        0
                    } else {
                        match glb::write(&path, std::slice::from_ref(&chunk), &texture_images, true) {
                            Ok(bytes) => bytes,
                            Err(failure) => {
                                let _ = fs::remove_file(&path);
                                error = Some(failure);
                                break;
                            }
                        }
                    };
                    if !request.publish.unwrap_or(false) && bytes > MAX_ASSET_BYTES {
                        let triangle_count = chunk.indices.len() / 3;
                        let _ = fs::remove_file(&path);
                        if triangle_count <= 1 {
                            error = Some(format!("a single output triangle requires {:.2} MB with its referenced source texture images, exceeding the 20 MB Open Cloud upload limit. Reduce source texture complexity or split the source appearance.", bytes as f64 / 1_000_000.0));
                            break;
                        }
                        let reduced_limit = triangle_count.div_ceil(2);
                        match split_mesh(&chunk, reduced_limit) {
                            Ok(smaller_chunks) if smaller_chunks.len() > 1 => {
                                for smaller_chunk in smaller_chunks.into_iter().rev() {
                                    chunks.push_front(smaller_chunk);
                                }
                                index -= 1;
                                continue;
                            }
                            Ok(_) => {
                                error = Some("unable to reduce an oversized output asset further".to_string());
                                break;
                            }
                            Err(failure) => {
                                error = Some(failure);
                                break;
                            }
                        }
                    }
                    if !request.publish.unwrap_or(false) {
                        output_paths.push(path.clone());
                        output_files.paths.push(path.clone());
                        output_bytes.push(bytes);
                    }
                    processed_triangles = processed_triangles.saturating_add(chunk.indices.len() / 3);
                    if request.publish.unwrap_or(false) {
                        asset_materials.push(MaterialBinding {
                            material: chunk.material.clone(),
                            material_variant: chunk.material_variant.clone(),
                            double_sided: chunk.double_sided,
                            cast_shadow: chunk.cast_shadow,
                            reflectance: chunk.reflectance,
                            base_color_page: chunk.base_color_page,
                            metallic_roughness_page: chunk.metallic_roughness_page,
                            has_metalness: chunk.has_metalness,
                            has_roughness: chunk.has_roughness,
                            normal_page: chunk.normal_page,
                            emissive_page: chunk.emissive_page,
                            emissive_tint: chunk.emissive_tint,
                            emissive_strength: chunk.emissive_strength,
                            alpha_mode: chunk.alpha_mode.map(|mode| mode.as_name().to_string()),
                            resample_mode: chunk.resample_mode.map(|mode| mode.as_name().to_string()),
                            transparency: chunk.transparency,
                            surface_overlay: chunk.surface_overlay,
                            has_color_alpha: chunk.has_color_alpha,
                        });
                        asset_sources.push(chunk.source_names.clone());
                    }
                    prepared_chunks.push((index, if request.publish.unwrap_or(false) { chunk } else { chunk.empty_like() }, path));
                    let completed_fraction = processed_triangles as f32 / merged_triangle_count.max(1) as f32;
                    send_progress(progress, request.id, progress_stage, 0.8 + completed_fraction * 0.18, &format!("Prepared {} of {} geometry triangles for upload.", processed_triangles, merged_triangle_count));
                }
                if error.is_some() {
                    break;
                }
            }
            let mut geometry_assets = None;
            if request.publish.unwrap_or(false) && error.is_none() {
                let mut assets = Vec::with_capacity(prepared_chunks.len());
                for (_, chunk, _) in prepared_chunks {
                    tokio::task::yield_now().await;
                    if cancelled.load(Ordering::Relaxed) {
                        error = Some("Bake cancelled. Previously uploaded assets were retained; replacement was skipped.".to_string());
                        break;
                    }
                    assets.push(GeometryAsset {
                        positions: chunk.positions,
                        normals: chunk.normals,
                        uvs: chunk.uvs,
                        colors: chunk.colors,
                        indices: chunk.indices,
                    });
                }
                if error.is_none() {
                    geometry_assets = Some(assets);
                }
            }
            if request.publish.unwrap_or(false) && error.is_none() {
                send_progress(progress, request.id, "geometry_upload", 0.99, "Uploading geometry assets in Studio.");
            }
            if cancelled.load(Ordering::Relaxed) && error.is_none() {
                error = Some("Bake cancelled. Previously uploaded assets were retained; replacement was skipped.".to_string());
            }
            let path = output_paths.first().cloned().unwrap_or_default();
            let glb_bytes = output_bytes.iter().sum();
            let source_errors = result.errors;
            let recovered_mesh_names = result.recovered_mesh_names;
            let failed_mesh_names = result.failed_mesh_names;
            let ok = error.is_none();
            let message = if geometry_assets.is_some() {
                format!("Merged {success_count} sources into {} independently uploadable mesh assets.", geometry_assets.as_ref().map_or(0, Vec::len))
            } else if !asset_ids.is_empty() {
                format!("Merged {success_count} sources into {} independently uploadable Model assets.", asset_ids.len())
            } else {
                format!("Merged {success_count} sources into {} GLB chunk(s).", output_paths.len())
            };
            if !request.publish.unwrap_or(false) || error.is_some() {
                send_progress(progress, request.id, "complete", 1.0, "Geometry processing finished.");
            }
            if let Some(assets) = &geometry_assets {
                let vertex_count: usize = assets.iter().map(|asset| asset.positions.len()).sum();
                let triangle_count: usize = assets.iter().map(|asset| asset.indices.len() / 3).sum();
                eprintln!("[PA Combine] request {}: handing {} geometry asset(s), {} vertices, {} triangles to Studio", request.id, assets.len(), vertex_count, triangle_count);
            }
            Response {
                id: request.id,
                ok,
                message: Some(message),
                error,
                selection_count: None,
                geometry_count: None,
                descendant_count: None,
                mesh_count: Some(result.mesh_count),
                union_count: Some(result.union_count),
                primitive_count: Some(result.primitive_count),
                merged_vertex_count: Some(merged_vertex_count),
                merged_triangle_count: Some(merged_triangle_count),
                double_sided_group_count: Some(double_sided_group_count),
                glb_path: Some(path.to_string_lossy().into_owned()),
                glb_bytes: Some(glb_bytes),
                asset_id: asset_ids.first().cloned(),
                asset_ids: Some(asset_ids),
                asset_materials: Some(asset_materials),
                asset_sources: Some(asset_sources),
                geometry_assets,
                source_errors: Some(source_errors),
                texture_images: if request.publish.unwrap_or(false) { None } else { Some(texture_images) },
                texture_bindings: Some(texture_bindings),
                texture_assets: Some(texture_assets),
                texture_errors: Some(texture_errors),
                overlay_count: Some(overlay_count),
                overlay_errors: Some(overlay_errors),
                recovered_mesh_names: Some(recovered_mesh_names),
                failed_mesh_names: Some(failed_mesh_names),
            }
        }
        _ => empty_response(request.id, format!("Unsupported request type: {}", request.request_type)),
    }
}

async fn handle_connection(stream: tokio::net::TcpStream, address: SocketAddr, processing_semaphore: Arc<Semaphore>) -> Result<()> {
    let mut config = WebSocketConfig::default();
    config.max_message_size = Some(256 * 1024 * 1024);
    config.max_frame_size = Some(256 * 1024 * 1024);
    let websocket = accept_async_with_config(stream, Some(config)).await?;
    let (mut writer, mut reader) = websocket.split();
    println!("studio connected: {address}");
    while let Some(message) = reader.next().await {
        let message = message?;
        if !message.is_text() {
            continue;
        }
        let mut request: Request = match serde_json::from_str(message.to_text()?) {
            Ok(request) => request,
            Err(error) => {
                eprintln!("invalid request from {address}: {error}");
                continue;
            }
        };
        if request.request_type == "cancel" {
            continue;
        }
        let cancelled = Arc::new(AtomicBool::new(false));
        let (progress_sender, mut progress_receiver) = mpsc::unbounded_channel();
        let semaphore = processing_semaphore.clone();
        let request_id = request.id;
        let request_ref = &mut request;
        let progress_ref = &progress_sender;
        let processing_cancelled = cancelled.clone();
        let mut processing = Box::pin(async move {
            let _permit = semaphore.acquire_owned().await.expect("worker processing semaphore was closed");
            if processing_cancelled.load(Ordering::Relaxed) {
                cancelled_response(request_ref.id)
            } else {
                process_request(request_ref, progress_ref, processing_cancelled).await
            }
        });
        let mut finished = false;
        while !finished {
            tokio::select! {
                biased;
                progress = progress_receiver.recv() => {
                    if let Some(progress) = progress {
                        let message = serde_json::to_string(&progress)?;
                        writer.send(Message::Text(message.into())).await?;
                    }
                }
                result = &mut processing => {
                    eprintln!("[PA Combine] request {}: serializing final response", request_id);
                    eprintln!(
                        "[PA Combine] request {}: response field sizes: geometryAssets={} bytes, assetSources={} bytes, assetMaterials={} bytes, textureBindings={} bytes, textureAssets={} bytes, textureErrors={} bytes, sourceErrors={} bytes, overlayErrors={} bytes",
                        request_id,
                        serialized_size(&result.geometry_assets)?,
                        serialized_size(&result.asset_sources)?,
                        serialized_size(&result.asset_materials)?,
                        serialized_size(&result.texture_bindings)?,
                        serialized_size(&result.texture_assets)?,
                        serialized_size(&result.texture_errors)?,
                        serialized_size(&result.source_errors)?,
                        serialized_size(&result.overlay_errors)?,
                    );
                    let serialization_started = std::time::Instant::now();
                    let response = serde_json::to_string(&result)?;
                    eprintln!("[PA Combine] request {}: serialized {} response bytes in {:.3}s", request_id, response.len(), serialization_started.elapsed().as_secs_f32());
                    writer.send(Message::Text(response.into())).await?;
                    eprintln!("[PA Combine] request {}: final response sent to Studio", request_id);
                    finished = true;
                }
                incoming = reader.next() => {
                    match incoming {
                        Some(Ok(message)) if message.is_text() => {
                            if let Ok(control) = serde_json::from_str::<ControlMessage>(message.to_text()?) {
                                if control.message_type == "cancel" && control.id == request_id {
                                    cancelled.store(true, Ordering::Relaxed);
                                    send_progress(&progress_sender, request_id, "cancelling", 0.0, "Cancellation requested; finishing the current processing step.");
                                }
                            }
                        }
                        Some(Ok(Message::Ping(payload))) => {
                            writer.send(Message::Pong(payload)).await?;
                        }
                        Some(Ok(Message::Close(_))) | None => {
                            cancelled.store(true, Ordering::Relaxed);
                            return Ok(());
                        }
                        Some(Ok(_)) => {}
                        Some(Err(error)) => return Err(error.into()),
                    }
                }
            }
        }
    }
    println!("studio disconnected: {address}");
    Ok(())
}

#[tokio::main]
async fn main() -> Result<()> {
    let listener = TcpListener::bind(ADDRESS).await?;
    let processing_semaphore = Arc::new(Semaphore::new(1));
    println!("PA Combine worker listening on ws://{ADDRESS}");
    println!("Set ROBLOX_OPEN_CLOUD_API_KEY with asset:read and asset:write permissions to publish models.");
    loop {
        let (stream, address) = listener.accept().await?;
        let processing_semaphore = processing_semaphore.clone();
        tokio::spawn(async move {
            if let Err(error) = handle_connection(stream, address, processing_semaphore).await {
                eprintln!("connection {address} failed: {error}");
            }
        });
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn calculates_effective_alpha_from_part_transparency() {
        assert_eq!(effective_alpha(0.0, 0.0), Some(1.0));
        assert_eq!(effective_alpha(0.5, 0.0), Some(0.5));
        assert_eq!(effective_alpha(1.0, 0.25), Some(0.0));
        assert_eq!(effective_alpha(-0.1, 0.0), None);
        assert_eq!(effective_alpha(0.0, 1.1), None);
        assert_eq!(effective_alpha(f32::NAN, 0.0), None);
    }

    #[test]
    fn splits_meshes_without_losing_triangle_attributes() {
        let mesh = mesh::MeshData {
            positions: vec![[0.0, 0.0, 0.0], [1.0, 0.0, 0.0], [0.0, 1.0, 0.0], [2.0, 0.0, 0.0], [2.0, 1.0, 0.0]],
            normals: vec![[0.0, 0.0, 1.0]; 5],
            uvs: vec![[0.0, 0.0]; 5],
            colors: vec![[1.0, 1.0, 1.0, 1.0]; 5],
            indices: vec![0, 1, 2, 1, 3, 4],
            source_names: vec!["Workspace.Part".to_string(), "Workspace.Other".to_string()],
            triangle_sources: vec!["Workspace.Part".to_string(), "Workspace.Other".to_string()],
            ..mesh::MeshData::default()
        };
        let chunks = split_mesh(&mesh, 1).unwrap();
        assert_eq!(chunks.len(), 2);
        assert!(chunks.iter().all(|chunk| chunk.indices.len() == 3));
        assert!(chunks.iter().all(|chunk| chunk.positions.len() == 3));
        assert!(chunks.iter().all(|chunk| chunk.positions.len() == chunk.normals.len()));
        assert!(chunks.iter().all(|chunk| chunk.positions.len() == chunk.uvs.len()));
        assert!(chunks.iter().all(|chunk| chunk.positions.len() == chunk.colors.len()));
        assert_eq!(chunks[0].material, mesh.material);
        assert_eq!(chunks[1].material_variant, mesh.material_variant);
        assert_eq!(chunks[0].source_names, vec!["Workspace.Part".to_string()]);
        assert_eq!(chunks[1].source_names, vec!["Workspace.Other".to_string()]);
    }
}
