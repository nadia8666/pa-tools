use crate::mesh::MeshData;
use serde_json::{json, Value};
use std::{collections::BTreeMap, fs, path::PathBuf};

fn align(buffer: &mut Vec<u8>) {
    while buffer.len() % 4 != 0 {
        buffer.push(0);
    }
}

fn append_f32(buffer: &mut Vec<u8>, values: impl IntoIterator<Item = f32>) {
    for value in values {
        buffer.extend_from_slice(&value.to_le_bytes());
    }
}

fn append_u32(buffer: &mut Vec<u8>, values: &[u32]) {
    for value in values {
        buffer.extend_from_slice(&value.to_le_bytes());
    }
}

fn add_view(views: &mut Vec<Value>, offset: usize, length: usize, target: Option<u32>) -> usize {
    let index = views.len();
    let mut view = json!({
        "buffer": 0,
        "byteOffset": offset,
        "byteLength": length
    });
    if let Some(target) = target {
        view["target"] = json!(target);
    }
    views.push(view);
    index
}

fn add_accessor(
    accessors: &mut Vec<Value>,
    view: usize,
    count: usize,
    component_type: u32,
    kind: &str,
    minimum: Option<Value>,
    maximum: Option<Value>,
) -> usize {
    let index = accessors.len();
    let mut accessor = json!({
        "bufferView": view,
        "componentType": component_type,
        "count": count,
        "type": kind
    });
    if let Some(minimum) = minimum {
        accessor["min"] = minimum;
    }
    if let Some(maximum) = maximum {
        accessor["max"] = maximum;
    }
    accessors.push(accessor);
    index
}

fn bounds(values: &[[f32; 3]]) -> (Value, Value) {
    let mut minimum = [f32::INFINITY; 3];
    let mut maximum = [f32::NEG_INFINITY; 3];
    for value in values {
        for axis in 0..3 {
            minimum[axis] = minimum[axis].min(value[axis]);
            maximum[axis] = maximum[axis].max(value[axis]);
        }
    }
    (json!(minimum), json!(maximum))
}

pub fn write(path: &PathBuf, groups: &[MeshData], texture_images: &[crate::texture::TextureImageInfo], embed_textures: bool) -> Result<usize, String> {
    let mut binary = Vec::new();
    let mut views = Vec::new();
    let mut accessors = Vec::new();
    let mut meshes = Vec::new();
    let mut nodes = Vec::new();
    let mut materials = Vec::new();
    let mut images = Vec::new();
    let mut textures = Vec::new();
    let mut texture_indices = BTreeMap::new();
    let mut uses_emissive_strength = false;

    let mut required_textures = BTreeMap::new();
    for mesh in groups {
        for (slot, page) in [
            ("color", mesh.base_color_page),
            ("metallicRoughness", mesh.metallic_roughness_page),
            ("normal", mesh.normal_page),
            ("emissive", mesh.emissive_page),
        ] {
            if let Some(page) = page {
                required_textures.insert((slot, page), ());
            }
        }
    }

    for texture_image in texture_images {
        if !embed_textures || !required_textures.contains_key(&(texture_image.slot.as_str(), texture_image.page)) {
            continue;
        }
        let image_bytes = fs::read(&texture_image.path).map_err(|error| error.to_string())?;
        align(&mut binary);
        let image_offset = binary.len();
        binary.extend_from_slice(&image_bytes);
        let image_view = add_view(&mut views, image_offset, image_bytes.len(), None);
        let image_index = images.len();
        images.push(json!({
            "name": format!("{}_texture_{}", texture_image.slot, texture_image.page),
            "bufferView": image_view,
            "mimeType": "image/png"
        }));
        let texture_index = textures.len();
        textures.push(json!({ "sampler": 0, "source": image_index }));
        texture_indices.insert((texture_image.slot.as_str(), texture_image.page), texture_index);
    }

    for (group_index, mesh) in groups.iter().enumerate() {
        mesh.validate()?;
        if mesh.positions.is_empty() || mesh.indices.is_empty() {
            continue;
        }

        align(&mut binary);
        let position_offset = binary.len();
        append_f32(&mut binary, mesh.positions.iter().flat_map(|value| value.iter().copied()));
        let position_view = add_view(&mut views, position_offset, binary.len() - position_offset, Some(34962));
        let (position_min, position_max) = bounds(&mesh.positions);
        let position_accessor = add_accessor(&mut accessors, position_view, mesh.positions.len(), 5126, "VEC3", Some(position_min), Some(position_max));

        align(&mut binary);
        let normal_offset = binary.len();
        append_f32(&mut binary, mesh.normals.iter().flat_map(|value| value.iter().copied()));
        let normal_view = add_view(&mut views, normal_offset, binary.len() - normal_offset, Some(34962));
        let normal_accessor = add_accessor(&mut accessors, normal_view, mesh.normals.len(), 5126, "VEC3", None, None);

        align(&mut binary);
        let uv_offset = binary.len();
        append_f32(&mut binary, mesh.uvs.iter().flat_map(|value| value.iter().copied()));
        let uv_view = add_view(&mut views, uv_offset, binary.len() - uv_offset, Some(34962));
        let uv_accessor = add_accessor(&mut accessors, uv_view, mesh.uvs.len(), 5126, "VEC2", None, None);

        align(&mut binary);
        let color_offset = binary.len();
        append_f32(&mut binary, mesh.colors.iter().flat_map(|value| value.iter().copied()));
        let color_view = add_view(&mut views, color_offset, binary.len() - color_offset, Some(34962));
        let color_accessor = add_accessor(&mut accessors, color_view, mesh.colors.len(), 5126, "VEC4", None, None);

        align(&mut binary);
        let index_offset = binary.len();
        append_u32(&mut binary, &mesh.indices);
        let index_view = add_view(&mut views, index_offset, binary.len() - index_offset, Some(34963));
        let index_accessor = add_accessor(&mut accessors, index_view, mesh.indices.len(), 5125, "SCALAR", None, None);

        let material_index = materials.len();
        let texture_for = |slot: &str, page: Option<usize>| page.and_then(|page| texture_indices.get(&(slot, page)).copied());
        let base_color_texture = texture_for("color", mesh.base_color_page);
        let metallic_roughness_texture = texture_for("metallicRoughness", mesh.metallic_roughness_page);
        let normal_texture = texture_for("normal", mesh.normal_page);
        let emissive_texture = texture_for("emissive", mesh.emissive_page);
        let mut pbr = json!({
            "baseColorFactor": [1.0, 1.0, 1.0, 1.0],
            "metallicFactor": if metallic_roughness_texture.is_some() { 1.0 } else { 0.0 },
            "roughnessFactor": 1.0
        });
        if let Some(texture_index) = base_color_texture {
            pbr["baseColorTexture"] = json!({ "index": texture_index });
        }
        if let Some(texture_index) = metallic_roughness_texture {
            pbr["metallicRoughnessTexture"] = json!({ "index": texture_index });
        }
        let has_transparency = mesh.colors.iter().any(|color| color[3] < 1.0) || mesh.has_color_alpha;
        let mut material = json!({
            "name": format!("{}_{}", mesh.material, group_index),
            "extras": {
                "robloxMaterial": mesh.material,
                "materialVariant": mesh.material_variant,
                "reflectance": mesh.reflectance,
                "assemblyId": mesh.assembly_id,
                "alphaMode": mesh.alpha_mode.map(|mode| mode.as_name()),
                "texturePages": {
                    "color": mesh.base_color_page,
                    "metalness": mesh.metallic_roughness_page,
                    "roughness": mesh.metallic_roughness_page,
                    "hasMetalness": mesh.has_metalness,
                    "hasRoughness": mesh.has_roughness,
                    "normal": mesh.normal_page,
                    "emissive": mesh.emissive_page
                }
            },
            "pbrMetallicRoughness": pbr,
            "doubleSided": mesh.double_sided,
            "alphaMode": if has_transparency { "BLEND" } else { "OPAQUE" }
        });
        if let Some(texture_index) = normal_texture {
            material["normalTexture"] = json!({ "index": texture_index, "scale": 1.0 });
        }
        if let Some(texture_index) = emissive_texture {
            material["emissiveTexture"] = json!({ "index": texture_index });
            material["emissiveFactor"] = json!(mesh.emissive_tint.unwrap_or([1.0, 1.0, 1.0]));
            let strength = mesh.emissive_strength.unwrap_or(1.0);
            if strength != 1.0 {
                material["extensions"] = json!({
                    "KHR_materials_emissive_strength": {
                        "emissiveStrength": strength
                    }
                });
                uses_emissive_strength = true;
            }
        }
        materials.push(material);
        let mesh_index = meshes.len();
        meshes.push(json!({
            "name": format!("combined_{group_index}"),
            "primitives": [{
                "attributes": {
                    "POSITION": position_accessor,
                    "NORMAL": normal_accessor,
                    "TEXCOORD_0": uv_accessor,
                    "COLOR_0": color_accessor
                },
                "indices": index_accessor,
                "material": material_index,
                "mode": 4
            }]
        }));
        nodes.push(json!({ "name": format!("pa_combine_{}", group_index), "mesh": mesh_index }));
    }

    if meshes.is_empty() {
        return Err("there is no geometry to serialize".to_string());
    }

    let mut document = json!({
        "asset": { "version": "2.0", "generator": "PA Combine" },
        "scene": 0,
        "scenes": [{ "nodes": (0..nodes.len()).collect::<Vec<_>>() }],
        "nodes": nodes,
        "meshes": meshes,
        "materials": materials,
        "images": images,
        "textures": textures,
        "samplers": [{ "magFilter": 9729, "minFilter": 9987, "wrapS": 10497, "wrapT": 10497 }],
        "buffers": [{ "byteLength": binary.len() }],
        "bufferViews": views,
        "accessors": accessors
    });
    if uses_emissive_strength {
        document["extensionsUsed"] = json!(["KHR_materials_emissive_strength"]);
    }
    let mut json_chunk = serde_json::to_vec(&document).map_err(|error| error.to_string())?;
    while json_chunk.len() % 4 != 0 {
        json_chunk.push(b' ');
    }
    align(&mut binary);

    let total_length = 12usize
        .checked_add(8 + json_chunk.len())
        .and_then(|length| length.checked_add(8 + binary.len()))
        .ok_or_else(|| "GLB size overflow".to_string())?;
    let total_length_u32 = u32::try_from(total_length)
        .map_err(|_| "GLB exceeds the 32-bit container size limit".to_string())?;
    let mut glb = Vec::with_capacity(total_length);
    glb.extend_from_slice(&0x46546c67u32.to_le_bytes());
    glb.extend_from_slice(&2u32.to_le_bytes());
    glb.extend_from_slice(&total_length_u32.to_le_bytes());
    glb.extend_from_slice(&(json_chunk.len() as u32).to_le_bytes());
    glb.extend_from_slice(&0x4e4f534au32.to_le_bytes());
    glb.extend_from_slice(&json_chunk);
    glb.extend_from_slice(&(binary.len() as u32).to_le_bytes());
    glb.extend_from_slice(&0x004e4942u32.to_le_bytes());
    glb.extend_from_slice(&binary);
    fs::write(path, &glb).map_err(|error| error.to_string())?;
    Ok(glb.len())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn embeds_pbr_source_textures_and_references_them_from_material() {
        let directory = std::env::temp_dir();
        let path = directory.join(format!("pa-combine-glb-pbr-test-{}.glb", std::process::id()));
        let slots = ["color", "metallicRoughness", "normal", "emissive"];
        let mut texture_images = Vec::new();
        for slot in slots {
            let texture_path = directory.join(format!("pa-combine-{slot}-test-{}.png", std::process::id()));
            image::RgbaImage::from_pixel(2, 2, image::Rgba([255, 255, 255, 255])).save(&texture_path).unwrap();
            texture_images.push(crate::texture::TextureImageInfo {
                slot: slot.to_string(),
                page: 0,
                path: texture_path.to_string_lossy().into_owned(),
                width: 2,
                height: 2,
                            });
        }
        let mesh = MeshData {
            positions: vec![[0.0, 0.0, 0.0], [1.0, 0.0, 0.0], [0.0, 1.0, 0.0]],
            normals: vec![[0.0, 0.0, 1.0]; 3],
            uvs: vec![[0.0, 0.0]; 3],
            colors: vec![[1.0, 1.0, 1.0, 1.0]; 3],
            indices: vec![0, 1, 2],
            source_names: Vec::new(),
            triangle_sources: Vec::new(),
            assembly_id: String::new(),
            double_sided: false,
            cast_shadow: false,
            base_color_page: Some(0),
            metallic_roughness_page: Some(0),
            has_metalness: true,
            has_roughness: true,
            normal_page: Some(0),
            emissive_page: Some(0),
            emissive_tint: Some([0.4, 0.6, 0.8]),
            emissive_strength: Some(2.0),
            reflectance: 0.35,
            material: "Plastic".to_string(),
            material_variant: String::new(),
            alpha_mode: None,
            resample_mode: None,
            has_color_alpha: false,
        };
        write(&path, &[mesh], &texture_images, true).unwrap();
        let bytes = fs::read(&path).unwrap();
        let json_length = u32::from_le_bytes(bytes[12..16].try_into().unwrap()) as usize;
        let document: Value = serde_json::from_slice(&bytes[20..20 + json_length]).unwrap();
        assert_eq!(document["images"].as_array().unwrap().len(), 4);
        assert_eq!(document["textures"].as_array().unwrap().len(), 4);
        let material = &document["materials"][0];
        assert_eq!(material["pbrMetallicRoughness"]["baseColorTexture"]["index"], 0);
        assert!(material["pbrMetallicRoughness"]["metallicRoughnessTexture"].is_object());
        assert!(material["normalTexture"].is_object());
        assert!(material["emissiveTexture"].is_object());
        assert_eq!(material["emissiveFactor"], json!([0.4, 0.6, 0.8]));
        assert_eq!(material["extras"]["robloxMaterial"], "Plastic");
        assert_eq!(material["extras"]["reflectance"], 0.35);
        assert_eq!(material["extensions"]["KHR_materials_emissive_strength"]["emissiveStrength"], 2.0);
        assert_eq!(document["extensionsUsed"][0], "KHR_materials_emissive_strength");
        for texture_image in texture_images {
            let _ = fs::remove_file(texture_image.path);
        }
        let _ = fs::remove_file(path);
    }

    #[test]
    fn opaque_geometry_uses_opaque_material_alpha_mode() {
        let path = std::env::temp_dir().join(format!("pa-combine-glb-alpha-test-{}.glb", std::process::id()));
        let mesh = MeshData {
            positions: vec![[0.0, 0.0, 0.0], [1.0, 0.0, 0.0], [0.0, 1.0, 0.0]],
            normals: vec![[0.0, 0.0, 1.0]; 3],
            uvs: vec![[0.0, 0.0]; 3],
            colors: vec![[1.0, 1.0, 1.0, 1.0]; 3],
            indices: vec![0, 1, 2],
            source_names: Vec::new(),
            triangle_sources: Vec::new(),
            assembly_id: String::new(),
            double_sided: false,
            cast_shadow: false,
            base_color_page: None,
            metallic_roughness_page: None,
            has_metalness: false,
            has_roughness: false,
            normal_page: None,
            emissive_page: None,
            emissive_tint: None,
            emissive_strength: None,
            reflectance: 0.0,
            material: "Plastic".to_string(),
            material_variant: String::new(),
            alpha_mode: None,
            resample_mode: None,
            has_color_alpha: false,
        };
        write(&path, &[mesh], &[], true).unwrap();
        let bytes = fs::read(&path).unwrap();
        let json_length = u32::from_le_bytes(bytes[12..16].try_into().unwrap()) as usize;
        let document: Value = serde_json::from_slice(&bytes[20..20 + json_length]).unwrap();
        assert_eq!(document["materials"][0]["alphaMode"], "OPAQUE");
        let _ = fs::remove_file(path);
    }

    #[test]
    fn transparent_base_color_texture_uses_blended_material_alpha_mode() {
        let directory = std::env::temp_dir();
        let path = directory.join(format!("pa-combine-glb-texture-alpha-test-{}.glb", std::process::id()));
        let texture_path = directory.join(format!("pa-combine-color-alpha-test-{}.png", std::process::id()));
        image::RgbaImage::from_pixel(2, 2, image::Rgba([255, 255, 255, 128])).save(&texture_path).unwrap();
        let texture_image = crate::texture::TextureImageInfo {
            slot: "color".to_string(),
            page: 0,
            path: texture_path.to_string_lossy().into_owned(),
            width: 2,
            height: 2,
                    };
        let mesh = MeshData {
            positions: vec![[0.0, 0.0, 0.0], [1.0, 0.0, 0.0], [0.0, 1.0, 0.0]],
            normals: vec![[0.0, 0.0, 1.0]; 3],
            uvs: vec![[0.0, 0.0]; 3],
            colors: vec![[1.0, 1.0, 1.0, 1.0]; 3],
            indices: vec![0, 1, 2],
            base_color_page: Some(0),
            has_color_alpha: true,
            ..MeshData::default()
        };
        write(&path, &[mesh], &[texture_image], true).unwrap();
        let bytes = fs::read(&path).unwrap();
        let json_length = u32::from_le_bytes(bytes[12..16].try_into().unwrap()) as usize;
        let document: Value = serde_json::from_slice(&bytes[20..20 + json_length]).unwrap();
        assert_eq!(document["materials"][0]["alphaMode"], "BLEND");
        let _ = fs::remove_file(texture_path);
        let _ = fs::remove_file(path);
    }

    #[test]
    fn transparent_geometry_uses_blended_material_alpha_mode() {
        let path = std::env::temp_dir().join(format!("pa-combine-glb-transparent-alpha-test-{}.glb", std::process::id()));
        let mesh = MeshData {
            positions: vec![[0.0, 0.0, 0.0], [1.0, 0.0, 0.0], [0.0, 1.0, 0.0]],
            normals: vec![[0.0, 0.0, 1.0]; 3],
            uvs: vec![[0.0, 0.0]; 3],
            colors: vec![[1.0, 1.0, 1.0, 0.5], [1.0, 1.0, 1.0, 1.0], [1.0, 1.0, 1.0, 1.0]],
            indices: vec![0, 1, 2],
            source_names: Vec::new(),
            triangle_sources: Vec::new(),
            assembly_id: String::new(),
            double_sided: false,
            cast_shadow: false,
            base_color_page: None,
            metallic_roughness_page: None,
            has_metalness: false,
            has_roughness: false,
            normal_page: None,
            emissive_page: None,
            emissive_tint: None,
            emissive_strength: None,
            reflectance: 0.0,
            material: "Plastic".to_string(),
            material_variant: String::new(),
            alpha_mode: None,
            resample_mode: None,
            has_color_alpha: false,
        };
        write(&path, &[mesh], &[], true).unwrap();
        let bytes = fs::read(&path).unwrap();
        let json_length = u32::from_le_bytes(bytes[12..16].try_into().unwrap()) as usize;
        let document: Value = serde_json::from_slice(&bytes[20..20 + json_length]).unwrap();
        assert_eq!(document["materials"][0]["alphaMode"], "BLEND");
        let _ = fs::remove_file(path);
    }

    #[test]
    fn writes_a_valid_glb_header_and_binary_length() {
        let path = std::env::temp_dir().join(format!("pa-combine-glb-test-{}.glb", std::process::id()));
        let mesh = MeshData {
            positions: vec![[0.0, 0.0, 0.0], [1.0, 0.0, 0.0], [0.0, 1.0, 0.0]],
            normals: vec![[0.0, 0.0, 1.0]; 3],
            uvs: vec![[0.0, 0.0]; 3],
            colors: vec![[1.0, 1.0, 1.0, 1.0]; 3],
            indices: vec![0, 1, 2],
            source_names: Vec::new(),
            triangle_sources: Vec::new(),
            assembly_id: String::new(),
            double_sided: false,
            cast_shadow: false,
            base_color_page: None,
            metallic_roughness_page: None,
            has_metalness: false,
            has_roughness: false,
            normal_page: None,
            emissive_page: None,
            emissive_tint: None,
            emissive_strength: None,
            reflectance: 0.0,
            material: "Plastic".to_string(),
            material_variant: String::new(),
            alpha_mode: None,
            resample_mode: None,
            has_color_alpha: false,
        };
        write(&path, &[mesh], &[], true).unwrap();
        let bytes = fs::read(&path).unwrap();
        assert_eq!(&bytes[0..4], &0x46546c67u32.to_le_bytes());
        assert_eq!(u32::from_le_bytes(bytes[8..12].try_into().unwrap()) as usize, bytes.len());
        let _ = fs::remove_file(path);
    }
}
