#[derive(Clone, Copy, Debug, Eq, PartialEq, Ord, PartialOrd)]
pub enum AlphaMode {
    Opaque,
    Transparency,
    TintMask,
    Overlay,
}

impl AlphaMode {
    pub fn from_name(name: &str) -> Option<Self> {
        match name {
            "Opaque" => Some(Self::Opaque),
            "Transparency" => Some(Self::Transparency),
            "TintMask" => Some(Self::TintMask),
            "Overlay" => Some(Self::Overlay),
            _ => None,
        }
    }

    pub fn as_name(self) -> &'static str {
        match self {
            Self::Opaque => "Opaque",
            Self::Transparency => "Transparency",
            Self::TintMask => "TintMask",
            Self::Overlay => "Overlay",
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Ord, PartialOrd)]
pub enum ResampleMode {
    Default,
    Pixelated,
}

impl ResampleMode {
    pub fn from_name(name: &str) -> Option<Self> {
        match name {
            "Default" => Some(Self::Default),
            "Pixelated" => Some(Self::Pixelated),
            _ => None,
        }
    }

    pub fn as_name(self) -> &'static str {
        match self {
            Self::Default => "Default",
            Self::Pixelated => "Pixelated",
        }
    }
}

#[derive(Clone, Debug, Default)]
pub struct MeshData {
    pub positions: Vec<[f32; 3]>,
    pub normals: Vec<[f32; 3]>,
    pub uvs: Vec<[f32; 2]>,
    pub colors: Vec<[f32; 4]>,
    pub indices: Vec<u32>,
    pub source_names: Vec<String>,
    pub triangle_sources: Vec<String>,
    pub assembly_id: String,
    pub double_sided: bool,
    pub cast_shadow: bool,
    pub base_color_page: Option<usize>,
    pub metallic_roughness_page: Option<usize>,
    pub has_metalness: bool,
    pub has_roughness: bool,
    pub normal_page: Option<usize>,
    pub emissive_page: Option<usize>,
    pub emissive_tint: Option<[f32; 3]>,
    pub emissive_strength: Option<f32>,
    pub reflectance: f32,
    pub material: String,
    pub material_variant: String,
    pub alpha_mode: Option<AlphaMode>,
    pub resample_mode: Option<ResampleMode>,
    pub has_color_alpha: bool,
    pub transparency: f32,
    pub surface_overlay: bool,
}

#[derive(Clone, Copy, Debug)]
pub struct TextureBinding {
    pub page: usize,
    pub has_color: bool,
    pub has_metalness: bool,
    pub has_roughness: bool,
    pub has_normal: bool,
    pub has_emissive: bool,
    pub skip_part_color: bool,
    pub alpha_mode: Option<AlphaMode>,
    pub resample_mode: Option<ResampleMode>,
    pub has_color_alpha: bool,
}

impl TextureBinding {
    fn metallic_roughness_page(self) -> Option<usize> {
        (self.has_metalness || self.has_roughness).then_some(self.page)
    }
}

fn boxmap_uv(position: [f32; 3], normal: [f32; 3], minimum: [f32; 3], maximum: [f32; 3]) -> [f32; 2] {
    let extent = [
        (maximum[0] - minimum[0]).max(f32::EPSILON),
        (maximum[1] - minimum[1]).max(f32::EPSILON),
        (maximum[2] - minimum[2]).max(f32::EPSILON),
    ];
    let absolute = normal.map(f32::abs);
    if absolute[0] >= absolute[1] && absolute[0] >= absolute[2] {
        let u = if normal[0] >= 0.0 {
            (maximum[2] - position[2]) / extent[2]
        } else {
            (position[2] - minimum[2]) / extent[2]
        };
        [u, (position[1] - minimum[1]) / extent[1]]
    } else if absolute[1] >= absolute[2] {
        let v = if normal[1] >= 0.0 {
            (maximum[2] - position[2]) / extent[2]
        } else {
            (position[2] - minimum[2]) / extent[2]
        };
        [(position[0] - minimum[0]) / extent[0], v]
    } else {
        let u = if normal[2] >= 0.0 {
            (maximum[0] - position[0]) / extent[0]
        } else {
            (position[0] - minimum[0]) / extent[0]
        };
        [u, (position[1] - minimum[1]) / extent[1]]
    }
}

impl MeshData {
    pub fn empty_like(&self) -> Self {
        Self {
            source_names: self.source_names.clone(),
            assembly_id: self.assembly_id.clone(),
            double_sided: self.double_sided,
            cast_shadow: self.cast_shadow,
            base_color_page: self.base_color_page,
            metallic_roughness_page: self.metallic_roughness_page,
            has_metalness: self.has_metalness,
            has_roughness: self.has_roughness,
            normal_page: self.normal_page,
            emissive_page: self.emissive_page,
            emissive_tint: self.emissive_tint,
            emissive_strength: self.emissive_strength,
            reflectance: self.reflectance,
            material: self.material.clone(),
            material_variant: self.material_variant.clone(),
            alpha_mode: self.alpha_mode,
            resample_mode: self.resample_mode,
            has_color_alpha: self.has_color_alpha,
            transparency: self.transparency,
            surface_overlay: self.surface_overlay,
            ..Self::default()
        }
    }

    pub fn append(&mut self, other: Self) -> Result<(), String> {
        if self.positions.is_empty() {
            self.assembly_id = other.assembly_id;
            self.double_sided = other.double_sided;
            self.cast_shadow = other.cast_shadow;
            self.base_color_page = other.base_color_page;
            self.metallic_roughness_page = other.metallic_roughness_page;
            self.has_metalness = other.has_metalness;
            self.has_roughness = other.has_roughness;
            self.normal_page = other.normal_page;
            self.emissive_page = other.emissive_page;
            self.emissive_tint = other.emissive_tint;
            self.emissive_strength = other.emissive_strength;
            self.reflectance = other.reflectance;
            self.material = other.material;
            self.material_variant = other.material_variant;
            self.alpha_mode = other.alpha_mode;
            self.resample_mode = other.resample_mode;
            self.has_color_alpha = other.has_color_alpha;
            self.transparency = other.transparency;
            self.surface_overlay = other.surface_overlay;
        } else if self.assembly_id != other.assembly_id
            || self.double_sided != other.double_sided
            || self.cast_shadow != other.cast_shadow
            || self.base_color_page != other.base_color_page
            || self.metallic_roughness_page != other.metallic_roughness_page
            || self.has_metalness != other.has_metalness
            || self.has_roughness != other.has_roughness
            || self.normal_page != other.normal_page
            || self.emissive_page != other.emissive_page
            || self.emissive_tint != other.emissive_tint
            || self.emissive_strength != other.emissive_strength
            || self.reflectance != other.reflectance
            || self.material != other.material
            || self.material_variant != other.material_variant
            || self.alpha_mode != other.alpha_mode
            || self.resample_mode != other.resample_mode
            || self.has_color_alpha != other.has_color_alpha
            || self.transparency != other.transparency
            || self.surface_overlay != other.surface_overlay
        {
            return Err("mesh material settings differ between groups".to_string());
        }
        let offset = u32::try_from(self.positions.len()).map_err(|_| "combined mesh exceeds the index limit")?;
        let vertex_count = self.positions.len().checked_add(other.positions.len()).ok_or("combined vertex count overflow")?;
        if vertex_count > u32::MAX as usize {
            return Err("combined mesh exceeds the 32-bit index limit".to_string());
        }
        if other.positions.len() != other.normals.len()
            || other.positions.len() != other.uvs.len()
            || other.positions.len() != other.colors.len()
            || (!other.triangle_sources.is_empty() && other.triangle_sources.len() != other.indices.len() / 3)
            || other.indices.len() % 3 != 0
            || other.indices.iter().any(|index| *index as usize >= other.positions.len())
        {
            return Err("mesh attributes or indices are inconsistent".to_string());
        }
        self.positions.extend(other.positions);
        self.normals.extend(other.normals);
        self.uvs.extend(other.uvs);
        self.colors.extend(other.colors);
        self.indices.extend(other.indices.into_iter().map(|index| index + offset));
        self.source_names.extend(other.source_names);
        self.source_names.sort();
        self.source_names.dedup();
        self.triangle_sources.extend(other.triangle_sources);
        Ok(())
    }

    pub fn from_mesh_part(
        positions: &[[f32; 3]],
        normals: &[[f32; 3]],
        uvs: &[[f32; 2]],
        colors: &[[f32; 4]],
        transform: &[f32; 12],
        scale: &[f32; 3],
        double_sided: bool,
        texture: Option<TextureBinding>,
    ) -> Result<Self, String> {
        if positions.is_empty() || positions.len() % 3 != 0
            || positions.len() != normals.len()
            || positions.len() != uvs.len()
            || positions.len() != colors.len()
            || scale.iter().any(|value| !value.is_finite() || *value == 0.0)
        {
            return Err("MeshPart corner attributes or scale have inconsistent values".to_string());
        }
        let mut mesh = Self {
            double_sided,
            base_color_page: texture.filter(|binding| binding.has_color).map(|binding| binding.page),
            metallic_roughness_page: texture.and_then(TextureBinding::metallic_roughness_page),
            has_metalness: texture.is_some_and(|binding| binding.has_metalness),
            has_roughness: texture.is_some_and(|binding| binding.has_roughness),
            normal_page: texture.filter(|binding| binding.has_normal).map(|binding| binding.page),
            emissive_page: texture.filter(|binding| binding.has_emissive).map(|binding| binding.page),
            alpha_mode: texture.and_then(|binding| binding.alpha_mode),
            resample_mode: texture.and_then(|binding| binding.resample_mode),
            has_color_alpha: texture.is_some_and(|binding| binding.has_color_alpha),
            ..Self::default()
        };
        for index in 0..positions.len() {
            let point = positions[index];
            let scaled = [point[0] * scale[0], point[1] * scale[1], point[2] * scale[2]];
            mesh.positions.push(transform_point(scaled, transform));
            mesh.normals.push(transform_normal(normals[index], scale, transform));
            mesh.uvs.push(uvs[index]);
            mesh.colors.push(colors[index]);
            mesh.indices.push(index as u32);
        }
        if texture.is_some() {
            mesh.validate_texture_uvs()?;
        }
        Ok(mesh)
    }

    pub fn from_primitive(mesh: crate::primitive::PrimitiveMesh, texture: Option<TextureBinding>) -> Result<Self, String> {
        let vertex_count = mesh.positions.len();
        let result = Self {
            positions: mesh.positions,
            normals: mesh.normals,
            uvs: mesh.uvs,
            colors: vec![[1.0, 1.0, 1.0, 1.0]; vertex_count],
            indices: mesh.indices,
            base_color_page: texture.filter(|binding| binding.has_color).map(|binding| binding.page),
            metallic_roughness_page: texture.and_then(TextureBinding::metallic_roughness_page),
            has_metalness: texture.is_some_and(|binding| binding.has_metalness),
            has_roughness: texture.is_some_and(|binding| binding.has_roughness),
            normal_page: texture.filter(|binding| binding.has_normal).map(|binding| binding.page),
            emissive_page: texture.filter(|binding| binding.has_emissive).map(|binding| binding.page),
            alpha_mode: texture.and_then(|binding| binding.alpha_mode),
            resample_mode: texture.and_then(|binding| binding.resample_mode),
            has_color_alpha: texture.is_some_and(|binding| binding.has_color_alpha),
            ..Self::default()
        };
        if texture.is_some() {
            result.validate_texture_uvs()?;
        }
        Ok(result)
    }

    pub fn from_union(mesh: crate::solid_mesh::UnionMesh, transform: &[f32; 12], size: &[f32; 3], texture: Option<TextureBinding>) -> Result<Self, String> {
        let mut result = match mesh {
            crate::solid_mesh::UnionMesh::SolidMesh(source) => {
                let mut result = Self::default();
                let mut minimum = [f32::INFINITY; 3];
                let mut maximum = [f32::NEG_INFINITY; 3];
                for position in &source.positions {
                    for axis in 0..3 {
                        minimum[axis] = minimum[axis].min(position[axis]);
                        maximum[axis] = maximum[axis].max(position[axis]);
                    }
                }
                for (corner, vertex_index) in source.faces.iter().enumerate() {
                    let vertex = *vertex_index as usize;
                    let normal = *source.face_normals.get(corner).ok_or("SolidMesh normal index is missing")? as usize;
                    let color = *source.face_colors.get(corner).ok_or("SolidMesh color index is missing")? as usize;
                    let position = *source.positions.get(vertex).ok_or("SolidMesh position index is invalid")?;
                    let normal_value = *source.normals.get(normal).ok_or("SolidMesh normal index is invalid")?;
                    result.positions.push(position);
                    result.normals.push(normal_value);
                    let _ = source.colors.get(color).ok_or("SolidMesh color index is invalid")?;
                    result.colors.push([1.0, 1.0, 1.0, 1.0]);
                    result.uvs.push(boxmap_uv(position, normal_value, minimum, maximum));
                    result.indices.push(corner as u32);
                }
                result
            }
            crate::solid_mesh::UnionMesh::CsgMdlV5(source) => {
                let mut result = Self::default();
                for vertex_index in &source.faces {
                    let vertex = *vertex_index as usize;
                    let normal_id = *source.normal_ids.get(vertex).ok_or("CSGMDLV5 normal ID is missing")?;
                    let normal_index = normal_id.checked_sub(1).ok_or("CSGMDLV5 normal ID is zero")? as usize;
                    let normal = *source.normals.get(normal_index).ok_or("CSGMDLV5 normal ID is out of range")?;
                    let _color = source.colors.get(vertex).copied().unwrap_or([255, 255, 255, 255]);
                    result.positions.push(*source.positions.get(vertex).ok_or("CSGMDLV5 position index is invalid")?);
                    result.normals.push(normal);
                    result.colors.push([1.0, 1.0, 1.0, 1.0]);
                    result.uvs.push(source.uvs.get(vertex).copied().unwrap_or([0.0, 0.0]));
                    result.indices.push(result.indices.len() as u32);
                }
                result
            }
        };
        result.base_color_page = texture.filter(|binding| binding.has_color).map(|binding| binding.page);
        result.metallic_roughness_page = texture.and_then(TextureBinding::metallic_roughness_page);
        result.has_metalness = texture.is_some_and(|binding| binding.has_metalness);
        result.has_roughness = texture.is_some_and(|binding| binding.has_roughness);
        result.normal_page = texture.filter(|binding| binding.has_normal).map(|binding| binding.page);
        result.emissive_page = texture.filter(|binding| binding.has_emissive).map(|binding| binding.page);
        result.alpha_mode = texture.and_then(|binding| binding.alpha_mode);
        result.resample_mode = texture.and_then(|binding| binding.resample_mode);
        result.has_color_alpha = texture.is_some_and(|binding| binding.has_color_alpha);
        if texture.is_some() {
            result.validate_texture_uvs()?;
        }
        if size.iter().any(|value| !value.is_finite() || *value <= 0.0) {
            return Err("union dimensions must be finite and positive".to_string());
        }
        if result.positions.is_empty() || result.positions.len() != result.normals.len() {
            return Err("union mesh has inconsistent position and normal data".to_string());
        }
        let mut minimum = [f32::INFINITY; 3];
        let mut maximum = [f32::NEG_INFINITY; 3];
        for position in &result.positions {
            for axis in 0..3 {
                minimum[axis] = minimum[axis].min(position[axis]);
                maximum[axis] = maximum[axis].max(position[axis]);
            }
        }
        let extents = [
            maximum[0] - minimum[0],
            maximum[1] - minimum[1],
            maximum[2] - minimum[2],
        ];
        let scale = [
            if extents[0] > f32::EPSILON { size[0] / extents[0] } else { 1.0 },
            if extents[1] > f32::EPSILON { size[1] / extents[1] } else { 1.0 },
            if extents[2] > f32::EPSILON { size[2] / extents[2] } else { 1.0 },
        ];
        for position in &mut result.positions {
            *position = [
                (position[0] - (minimum[0] + maximum[0]) * 0.5) * scale[0],
                (position[1] - (minimum[1] + maximum[1]) * 0.5) * scale[1],
                (position[2] - (minimum[2] + maximum[2]) * 0.5) * scale[2],
            ];
            *position = transform_point(*position, transform);
        }
        for normal in &mut result.normals {
            *normal = transform_direction([
                normal[0] / scale[0],
                normal[1] / scale[1],
                normal[2] / scale[2],
            ], transform);
        }
        Ok(result)
    }

    fn validate_texture_uvs(&self) -> Result<(), String> {
        if self.positions.len() != self.normals.len()
            || self.positions.len() != self.uvs.len()
            || self.positions.len() != self.colors.len()
            || self.uvs.iter().flatten().any(|value| !value.is_finite())
        {
            return Err("texture UV mapping received inconsistent mesh attributes or bounds".to_string());
        }
        Ok(())
    }

    pub fn apply_color_multiplier(&mut self, color: [f32; 3], transparency: f32, local_transparency_modifier: f32) -> Result<(), String> {
        if color.iter().any(|value| !value.is_finite() || !(0.0..=1.0).contains(value))
            || !transparency.is_finite()
            || !(0.0..=1.0).contains(&transparency)
            || !local_transparency_modifier.is_finite()
            || !(0.0..=1.0).contains(&local_transparency_modifier)
        {
            return Err("source color and transparency modifiers must contain valid finite values".to_string());
        }
        let multiplier = [color[0], color[1], color[2], 1.0];
        for vertex_color in &mut self.colors {
            for channel in 0..4 {
                vertex_color[channel] *= multiplier[channel];
            }
        }
        Ok(())
    }

    pub fn validate(&self) -> Result<(), String> {
        if self.positions.len() != self.normals.len()
            || self.positions.len() != self.uvs.len()
            || self.positions.len() != self.colors.len()
            || self.indices.len() % 3 != 0
            || (!self.triangle_sources.is_empty() && self.triangle_sources.len() != self.indices.len() / 3)
            || self.indices.iter().any(|index| *index as usize >= self.positions.len())
        {
            return Err("combined mesh has inconsistent attributes or triangle indices".to_string());
        }
        if self.positions.iter().flatten()
            .chain(self.normals.iter().flatten())
            .chain(self.uvs.iter().flatten())
            .chain(self.colors.iter().flatten())
            .any(|value| !value.is_finite())
            || self.emissive_tint.is_some_and(|tint| tint.iter().any(|value| !value.is_finite()))
            || self.emissive_strength.is_some_and(|strength| !strength.is_finite() || strength < 0.0)
            || !self.reflectance.is_finite()
            || !(0.0..=1.0).contains(&self.reflectance)
        {
            return Err("combined mesh contains non-finite or invalid material attributes".to_string());
        }
        Ok(())
    }
}



fn transform_point(point: [f32; 3], transform: &[f32; 12]) -> [f32; 3] {
    [
        transform[0] + transform[3] * point[0] + transform[4] * point[1] + transform[5] * point[2],
        transform[1] + transform[6] * point[0] + transform[7] * point[1] + transform[8] * point[2],
        transform[2] + transform[9] * point[0] + transform[10] * point[1] + transform[11] * point[2],
    ]
}

fn transform_direction(normal: [f32; 3], transform: &[f32; 12]) -> [f32; 3] {
    normalize([
        transform[3] * normal[0] + transform[4] * normal[1] + transform[5] * normal[2],
        transform[6] * normal[0] + transform[7] * normal[1] + transform[8] * normal[2],
        transform[9] * normal[0] + transform[10] * normal[1] + transform[11] * normal[2],
    ])
}

fn transform_normal(normal: [f32; 3], scale: &[f32; 3], transform: &[f32; 12]) -> [f32; 3] {
    transform_direction([normal[0] / scale[0], normal[1] / scale[1], normal[2] / scale[2]], transform)
}

fn normalize(value: [f32; 3]) -> [f32; 3] {
    let length = (value[0] * value[0] + value[1] * value[1] + value[2] * value[2]).sqrt();
    if length > 0.0 {
        [value[0] / length, value[1] / length, value[2] / length]
    } else {
        [0.0, 1.0, 0.0]
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn scales_union_geometry_to_the_temporary_union_bounds() {
        let source = crate::solid_mesh::SolidMesh {
            positions: vec![[-1.0, -1.0, -1.0], [1.0, -1.0, -1.0], [1.0, 1.0, 1.0], [-1.0, 1.0, 1.0]],
            normals: vec![[0.0, 0.0, 1.0]],
            colors: vec![[1.0, 1.0, 1.0]],
            faces: vec![0, 1, 2],
            face_normals: vec![0, 0, 0],
            face_colors: vec![0, 0, 0],
        };
        let mesh = MeshData::from_union(
            crate::solid_mesh::UnionMesh::SolidMesh(source),
            &[10.0, 20.0, 30.0, 1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0],
            &[4.0, 2.0, 1.0],
            None,
        ).unwrap();
        assert_eq!(mesh.positions[0], [8.0, 19.0, 29.5]);
        assert_eq!(mesh.positions[1], [12.0, 19.0, 29.5]);
        assert_eq!(mesh.positions[2], [12.0, 21.0, 30.5]);
    }

    #[test]
    fn preserves_original_repeating_uvs_without_subdividing_source_triangles() {
        let binding = TextureBinding {
            page: 0,
            has_color: true,
            has_metalness: false,
            has_roughness: false,
            has_normal: false,
            has_emissive: false,
            skip_part_color: false,
            alpha_mode: None,
            resample_mode: None,
            has_color_alpha: false,
        };
        let mut mesh = MeshData {
            positions: vec![[0.0, 0.0, 0.0], [2.0, 0.0, 0.0], [0.0, 1.0, 0.0]],
            normals: vec![[0.0, 0.0, 1.0]; 3],
            uvs: vec![[-2.0, 1.0], [2.0, 1.0], [-2.0, 3.0]],
            colors: vec![[1.0; 4]; 3],
            indices: vec![0, 1, 2],
            ..MeshData::default()
        };
        mesh.validate_texture_uvs().unwrap();
        assert_eq!(mesh.indices, vec![0, 1, 2]);
        assert_eq!(mesh.positions.len(), 3);
        assert_eq!(mesh.uvs, vec![[-2.0, 1.0], [2.0, 1.0], [-2.0, 3.0]]);
    }

    #[test]
    fn applies_translation_rotation_and_scale_to_meshpart_vertices() {
        let transform = [10.0, 20.0, 30.0, 0.0, -1.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 1.0];
        let mesh = MeshData::from_mesh_part(
            &[[1.0, 2.0, 3.0]; 3],
            &[[1.0, 0.0, 0.0]; 3],
            &[[0.0, 0.0]; 3],
            &[[1.0, 1.0, 1.0, 1.0]; 3],
            &transform,
            &[2.0, 1.0, 1.0],
            true,
            None,
        ).unwrap();
        assert_eq!(mesh.positions[0], [8.0, 22.0, 33.0]);
        assert_eq!(mesh.indices, vec![0, 1, 2]);
        assert!(mesh.double_sided);
    }

    #[test]
    fn multiplies_source_color_and_transparency_into_vertex_colors() {
        let mut mesh = MeshData {
            colors: vec![[0.5, 0.25, 1.0, 0.8]],
            ..MeshData::default()
        };
        mesh.apply_color_multiplier([0.4, 0.8, 0.5], 0.25, 0.0).unwrap();
        assert_eq!(mesh.colors[0], [0.2, 0.2, 0.5, 0.6]);
    }

    #[test]
    fn multiplies_local_transparency_modifier_into_vertex_alpha() {
        let mut mesh = MeshData {
            colors: vec![[1.0, 1.0, 1.0, 0.8]],
            ..MeshData::default()
        };
        mesh.apply_color_multiplier([1.0; 3], 0.25, 0.5).unwrap();
        assert_eq!(mesh.colors[0][3], 0.3);
    }

    #[test]
    fn rejects_invalid_source_visual_properties() {
        let mut mesh = MeshData::default();
        assert!(mesh.apply_color_multiplier([1.1, 1.0, 1.0], 0.0, 0.0).is_err());
        assert!(mesh.apply_color_multiplier([1.0, 1.0, 1.0], 1.1, 0.0).is_err());
        mesh.reflectance = 1.1;
        assert!(mesh.validate().is_err());
    }

    #[test]
    fn generates_boxmapped_uvs_for_solidmesh_union_textures() {
        let source = crate::solid_mesh::SolidMesh {
            positions: vec![[-1.0, -1.0, -1.0], [1.0, -1.0, -1.0], [1.0, 1.0, -1.0]],
            normals: vec![[0.0, 0.0, -1.0]],
            colors: vec![[1.0, 1.0, 1.0]],
            faces: vec![0, 1, 2],
            face_normals: vec![0, 0, 0],
            face_colors: vec![0, 0, 0],
        };
        let binding = TextureBinding {
            page: 3,
            has_color: true,
            has_metalness: false,
            has_roughness: false,
            has_normal: false,
            has_emissive: false,
            skip_part_color: false,
            alpha_mode: None,
            resample_mode: None,
            has_color_alpha: false,
        };
        let mesh = MeshData::from_union(
            crate::solid_mesh::UnionMesh::SolidMesh(source),
            &[0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0],
            &[2.0, 2.0, 2.0],
            Some(binding),
        ).unwrap();
        assert_eq!(mesh.base_color_page, Some(3));
        assert!(mesh.uvs.iter().all(|uv| uv.iter().all(|value| (0.0..=1.0).contains(value))));
        assert_ne!(mesh.uvs[0], [0.0, 0.0]);
    }

    #[test]
    fn appends_disconnected_meshes_with_index_offsets() {
        let mut combined = MeshData::default();
        let triangle = MeshData {
            positions: vec![[0.0; 3]; 3],
            normals: vec![[0.0, 1.0, 0.0]; 3],
            uvs: vec![[0.0; 2]; 3],
            colors: vec![[1.0; 4]; 3],
            indices: vec![0, 1, 2],
            source_names: vec!["source".to_string()],
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
        };
        combined.append(triangle.clone()).unwrap();
        combined.append(triangle).unwrap();
        assert_eq!(combined.indices, vec![0, 1, 2, 3, 4, 5]);
        assert_eq!(combined.positions.len(), 6);
    }

    #[test]
    fn rejects_appending_meshes_from_different_assemblies() {
        let mut first = MeshData {
            positions: vec![[0.0; 3]; 3],
            normals: vec![[0.0, 1.0, 0.0]; 3],
            uvs: vec![[0.0; 2]; 3],
            colors: vec![[1.0; 4]; 3],
            indices: vec![0, 1, 2],
            assembly_id: "assembly-a".to_string(),
            ..MeshData::default()
        };
        let second = MeshData {
            positions: vec![[0.0; 3]; 3],
            normals: vec![[0.0, 1.0, 0.0]; 3],
            uvs: vec![[0.0; 2]; 3],
            colors: vec![[1.0; 4]; 3],
            indices: vec![0, 1, 2],
            assembly_id: "assembly-b".to_string(),
            ..MeshData::default()
        };
        assert!(first.append(second).is_err());
    }

    #[test]
    fn rejects_appending_meshes_with_different_pbr_map_channels() {
        let mut first = MeshData {
            positions: vec![[0.0; 3]; 3],
            normals: vec![[0.0, 1.0, 0.0]; 3],
            uvs: vec![[0.0; 2]; 3],
            colors: vec![[1.0; 4]; 3],
            indices: vec![0, 1, 2],
            has_metalness: true,
            ..MeshData::default()
        };
        let second = MeshData {
            positions: vec![[0.0; 3]; 3],
            normals: vec![[0.0, 1.0, 0.0]; 3],
            uvs: vec![[0.0; 2]; 3],
            colors: vec![[1.0; 4]; 3],
            indices: vec![0, 1, 2],
            ..MeshData::default()
        };
        assert!(first.append(second).is_err());
    }

    #[test]
    fn rejects_appending_meshes_with_different_reflectance() {
        let mut first = MeshData {
            positions: vec![[0.0; 3]; 3],
            normals: vec![[0.0, 1.0, 0.0]; 3],
            uvs: vec![[0.0; 2]; 3],
            colors: vec![[1.0; 4]; 3],
            indices: vec![0, 1, 2],
            reflectance: 0.25,
            ..MeshData::default()
        };
        let second = MeshData {
            positions: vec![[0.0; 3]; 3],
            normals: vec![[0.0, 1.0, 0.0]; 3],
            uvs: vec![[0.0; 2]; 3],
            colors: vec![[1.0; 4]; 3],
            indices: vec![0, 1, 2],
            reflectance: 0.5,
            ..MeshData::default()
        };
        assert!(first.append(second).is_err());
    }
    #[test]
    fn rejects_appending_meshes_with_different_cast_shadow() {
        let mut first = MeshData {
            positions: vec![[0.0; 3]; 3],
            normals: vec![[0.0, 1.0, 0.0]; 3],
            uvs: vec![[0.0; 2]; 3],
            colors: vec![[1.0; 4]; 3],
            indices: vec![0, 1, 2],
            cast_shadow: true,
            ..MeshData::default()
        };
        let second = MeshData {
            positions: vec![[0.0; 3]; 3],
            normals: vec![[0.0, 1.0, 0.0]; 3],
            uvs: vec![[0.0; 2]; 3],
            colors: vec![[1.0; 4]; 3],
            indices: vec![0, 1, 2],
            cast_shadow: false,
            ..MeshData::default()
        };
        assert!(first.append(second).is_err());
    }

}
