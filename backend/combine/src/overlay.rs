use serde::{Deserialize, Serialize};

const SURFACE_BIAS: f32 = 0.001;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Face {
    Right,
    Top,
    Back,
    Left,
    Bottom,
    Front,
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct ProjectedVertex {
    pub position: [f32; 3],
    pub normal: [f32; 3],
    pub uv: [f32; 2],
}

#[derive(Clone, Copy)]
struct Plane {
    normal: [f32; 3],
    horizontal: [f32; 3],
    vertical: [f32; 3],
    half_width: f32,
    half_height: f32,
}

impl Face {
    pub fn parse(value: &str) -> Result<Self, String> {
        match value {
            "Right" => Ok(Self::Right),
            "Top" => Ok(Self::Top),
            "Back" => Ok(Self::Back),
            "Left" => Ok(Self::Left),
            "Bottom" => Ok(Self::Bottom),
            "Front" => Ok(Self::Front),
            _ => Err(format!("unsupported overlay face: {value}")),
        }
    }

    fn plane(self, size: [f32; 3]) -> Plane {
        match self {
            Self::Right => Plane { normal: [1.0, 0.0, 0.0], horizontal: [0.0, 0.0, -1.0], vertical: [0.0, 1.0, 0.0], half_width: size[2] * 0.5, half_height: size[1] * 0.5 },
            Self::Top => Plane { normal: [0.0, 1.0, 0.0], horizontal: [1.0, 0.0, 0.0], vertical: [0.0, 0.0, -1.0], half_width: size[0] * 0.5, half_height: size[2] * 0.5 },
            Self::Back => Plane { normal: [0.0, 0.0, 1.0], horizontal: [-1.0, 0.0, 0.0], vertical: [0.0, 1.0, 0.0], half_width: size[0] * 0.5, half_height: size[1] * 0.5 },
            Self::Left => Plane { normal: [-1.0, 0.0, 0.0], horizontal: [0.0, 0.0, 1.0], vertical: [0.0, 1.0, 0.0], half_width: size[2] * 0.5, half_height: size[1] * 0.5 },
            Self::Bottom => Plane { normal: [0.0, -1.0, 0.0], horizontal: [1.0, 0.0, 0.0], vertical: [0.0, 0.0, 1.0], half_width: size[0] * 0.5, half_height: size[2] * 0.5 },
            Self::Front => Plane { normal: [0.0, 0.0, -1.0], horizontal: [1.0, 0.0, 0.0], vertical: [0.0, 1.0, 0.0], half_width: size[0] * 0.5, half_height: size[1] * 0.5 },
        }
    }
}

fn dot(a: [f32; 3], b: [f32; 3]) -> f32 {
    a[0] * b[0] + a[1] * b[1] + a[2] * b[2]
}

fn normalize(value: [f32; 3]) -> [f32; 3] {
    let length = dot(value, value).sqrt();
    if length > 0.0 {
        [value[0] / length, value[1] / length, value[2] / length]
    } else {
        [0.0, 1.0, 0.0]
    }
}

fn interpolate(a: ProjectedVertex, b: ProjectedVertex, amount: f32) -> ProjectedVertex {
    let mix = |left: f32, right: f32| left + (right - left) * amount;
    ProjectedVertex {
        position: [mix(a.position[0], b.position[0]), mix(a.position[1], b.position[1]), mix(a.position[2], b.position[2])],
        normal: normalize([mix(a.normal[0], b.normal[0]), mix(a.normal[1], b.normal[1]), mix(a.normal[2], b.normal[2])]),
        uv: [mix(a.uv[0], b.uv[0]), mix(a.uv[1], b.uv[1])],
    }
}

fn clip_polygon(
    polygon: &[ProjectedVertex],
    coordinate: fn([f32; 3], Plane) -> f32,
    plane: Plane,
    boundary: f32,
    keep_greater: bool,
) -> Vec<ProjectedVertex> {
    if polygon.is_empty() {
        return Vec::new();
    }
    let mut result = Vec::new();
    let mut previous = *polygon.last().unwrap();
    let mut previous_value = coordinate(previous.position, plane) - boundary;
    let mut previous_inside = if keep_greater { previous_value >= 0.0 } else { previous_value <= 0.0 };
    for current in polygon {
        let current_value = coordinate(current.position, plane) - boundary;
        let current_inside = if keep_greater { current_value >= 0.0 } else { current_value <= 0.0 };
        if current_inside != previous_inside {
            let denominator = previous_value - current_value;
            if denominator.abs() > f32::EPSILON {
                result.push(interpolate(previous, *current, previous_value / denominator));
            }
        }
        if current_inside {
            result.push(*current);
        }
        previous = *current;
        previous_value = current_value;
        previous_inside = current_inside;
    }
    result
}

fn horizontal(position: [f32; 3], plane: Plane) -> f32 {
    dot(position, plane.horizontal)
}

fn vertical(position: [f32; 3], plane: Plane) -> f32 {
    dot(position, plane.vertical)
}

fn project_triangle(
    positions: [[f32; 3]; 3],
    normals: [[f32; 3]; 3],
    size: [f32; 3],
    face: Face,
    tile_size: [f32; 2],
    offsets: [f32; 2],
) -> Vec<[ProjectedVertex; 3]> {
    if size.iter().any(|value| !value.is_finite() || *value <= 0.0)
        || tile_size.iter().any(|value| !value.is_finite() || *value <= 0.0)
        || offsets.iter().any(|value| !value.is_finite())
        || positions.iter().flatten().any(|value| !value.is_finite())
        || normals.iter().flatten().any(|value| !value.is_finite())
        || normals.iter().any(|normal| dot(*normal, face.plane(size).normal) <= 0.0)
    {
        return Vec::new();
    }
    let plane = face.plane(size);
    let mut polygon = positions.into_iter().zip(normals).map(|(position, normal)| {
        let u = (dot(position, plane.horizontal) + plane.half_width - offsets[0]) / tile_size[0];
        let v = 1.0 - (dot(position, plane.vertical) + plane.half_height - offsets[1]) / tile_size[1];
        ProjectedVertex { position, normal: normalize(normal), uv: [u, v] }
    }).collect::<Vec<_>>();
    let horizontal_min = -plane.half_width + offsets[0];
    let vertical_min = -plane.half_height + offsets[1];
    polygon = clip_polygon(&polygon, horizontal, plane, horizontal_min, true);
    polygon = clip_polygon(&polygon, horizontal, plane, horizontal_min + tile_size[0], false);
    polygon = clip_polygon(&polygon, vertical, plane, vertical_min, true);
    polygon = clip_polygon(&polygon, vertical, plane, vertical_min + tile_size[1], false);
    if polygon.len() < 3 {
        return Vec::new();
    }
    (1..polygon.len() - 1).map(|index| {
        let mut triangle = [polygon[0], polygon[index], polygon[index + 1]];
        for vertex in &mut triangle {
            for axis in 0..3 {
                vertex.position[axis] += plane.normal[axis] * SURFACE_BIAS;
            }
        }
        triangle
    }).collect()
}

fn ray_triangle(origin: [f32; 3], direction: [f32; 3], triangle: [[f32; 3]; 3]) -> Option<f32> {
    let edge_a = [
        triangle[1][0] - triangle[0][0],
        triangle[1][1] - triangle[0][1],
        triangle[1][2] - triangle[0][2],
    ];
    let edge_b = [
        triangle[2][0] - triangle[0][0],
        triangle[2][1] - triangle[0][1],
        triangle[2][2] - triangle[0][2],
    ];
    let cross = [
        direction[1] * edge_b[2] - direction[2] * edge_b[1],
        direction[2] * edge_b[0] - direction[0] * edge_b[2],
        direction[0] * edge_b[1] - direction[1] * edge_b[0],
    ];
    let determinant = dot(edge_a, cross);
    if determinant.abs() < 1e-8 {
        return None;
    }
    let inverse = 1.0 / determinant;
    let relative = [
        origin[0] - triangle[0][0],
        origin[1] - triangle[0][1],
        origin[2] - triangle[0][2],
    ];
    let u = dot(relative, cross) * inverse;
    if !(0.0..=1.0).contains(&u) {
        return None;
    }
    let cross_relative = [
        relative[1] * edge_a[2] - relative[2] * edge_a[1],
        relative[2] * edge_a[0] - relative[0] * edge_a[2],
        relative[0] * edge_a[1] - relative[1] * edge_a[0],
    ];
    let v = dot(direction, cross_relative) * inverse;
    if v < 0.0 || u + v > 1.0 {
        return None;
    }
    let distance = dot(edge_b, cross_relative) * inverse;
    (distance >= -0.002 && distance.is_finite()).then_some(distance.max(0.0))
}

pub struct OcclusionMap {
    plane: Plane,
    size: [f32; 3],
    divisions: usize,
    cells: Vec<Vec<[[f32; 3]; 3]>>,
    large_triangles: Vec<[[f32; 3]; 3]>,
}

impl OcclusionMap {
    pub fn new(triangles: &[[[f32; 3]; 3]], size: [f32; 3], face: Face) -> Self {
        let plane = face.plane(size);
        let divisions = 16;
        let mut map = Self {
            plane,
            size,
            divisions,
            cells: vec![Vec::new(); divisions * divisions],
            large_triangles: Vec::new(),
        };
        for triangle in triangles {
            let horizontal_values = triangle.map(|point| dot(point, plane.horizontal));
            let vertical_values = triangle.map(|point| dot(point, plane.vertical));
            let coordinate = |value: f32, half_extent: f32| {
                (((value + half_extent) / (half_extent * 2.0)) * divisions as f32)
                    .floor()
                    .clamp(0.0, (divisions - 1) as f32) as usize
            };
            let min_u = coordinate(horizontal_values.into_iter().fold(f32::INFINITY, f32::min), plane.half_width);
            let max_u = coordinate(horizontal_values.into_iter().fold(f32::NEG_INFINITY, f32::max), plane.half_width);
            let min_v = coordinate(vertical_values.into_iter().fold(f32::INFINITY, f32::min), plane.half_height);
            let max_v = coordinate(vertical_values.into_iter().fold(f32::NEG_INFINITY, f32::max), plane.half_height);
            let covered = (max_u - min_u + 1) * (max_v - min_v + 1);
            if covered > 64 {
                map.large_triangles.push(*triangle);
                continue;
            }
            for y in min_v..=max_v {
                for x in min_u..=max_u {
                    map.cells[y * divisions + x].push(*triangle);
                }
            }
        }
        map
    }

    pub fn filter_visible_fragments(&self, fragments: Vec<[ProjectedVertex; 3]>) -> Vec<[ProjectedVertex; 3]> {
        let tolerance = self.size.iter().copied().fold(0.0, f32::max) * 0.0001 + 0.002;
        let mut output = Vec::new();
        for triangle in fragments {
            subdivide_fragment(triangle, self, tolerance, 0, &mut output);
        }
        output
    }

    fn visible(&self, point: [f32; 3], tolerance: f32) -> bool {
        let horizontal_value = dot(point, self.plane.horizontal);
        let vertical_value = dot(point, self.plane.vertical);
        let normal_extent = (self.plane.normal[0].abs() * self.size[0]
            + self.plane.normal[1].abs() * self.size[1]
            + self.plane.normal[2].abs() * self.size[2]) * 0.5;
        let origin = [
            self.plane.horizontal[0] * horizontal_value + self.plane.vertical[0] * vertical_value + self.plane.normal[0] * normal_extent,
            self.plane.horizontal[1] * horizontal_value + self.plane.vertical[1] * vertical_value + self.plane.normal[1] * normal_extent,
            self.plane.horizontal[2] * horizontal_value + self.plane.vertical[2] * vertical_value + self.plane.normal[2] * normal_extent,
        ];
        let direction = [-self.plane.normal[0], -self.plane.normal[1], -self.plane.normal[2]];
        let candidate_distance = dot([
            origin[0] - point[0],
            origin[1] - point[1],
            origin[2] - point[2],
        ], self.plane.normal).max(0.0);
        let coordinate = |value: f32, half_extent: f32| {
            (((value + half_extent) / (half_extent * 2.0)) * self.divisions as f32)
                .floor()
                .clamp(0.0, (self.divisions - 1) as f32) as usize
        };
        let x = coordinate(horizontal_value, self.plane.half_width);
        let y = coordinate(vertical_value, self.plane.half_height);
        let candidates = &self.cells[y * self.divisions + x];
        let nearest = candidates.iter().chain(self.large_triangles.iter())
            .filter_map(|triangle| ray_triangle(origin, direction, *triangle))
            .fold(f32::INFINITY, f32::min);
        nearest.is_finite() && (nearest - candidate_distance).abs() <= tolerance
    }
}


fn subdivide_fragment(
    triangle: [ProjectedVertex; 3],
    occlusion: &OcclusionMap,
    tolerance: f32,
    depth: usize,
    output: &mut Vec<[ProjectedVertex; 3]>,
) {
    let midpoint = |a: ProjectedVertex, b: ProjectedVertex| interpolate(a, b, 0.5);
    let samples = [
        triangle[0],
        triangle[1],
        triangle[2],
        midpoint(triangle[0], triangle[1]),
        midpoint(triangle[1], triangle[2]),
        midpoint(triangle[2], triangle[0]),
        interpolate(midpoint(triangle[0], triangle[1]), midpoint(triangle[1], triangle[2]), 0.5),
    ];
    let visibility = samples.map(|sample| occlusion.visible(sample.position, tolerance));
    if visibility.iter().all(|visible| *visible) {
        output.push(triangle);
        return;
    }
    if depth >= 4 {
        let center = interpolate(midpoint(triangle[0], triangle[1]), midpoint(triangle[1], triangle[2]), 0.5);
        if occlusion.visible(center.position, tolerance) {
            output.push(triangle);
        }
        return;
    }
    if visibility.iter().all(|visible| !*visible) {
        return;
    }
    let ab = midpoint(triangle[0], triangle[1]);
    let bc = midpoint(triangle[1], triangle[2]);
    let ca = midpoint(triangle[2], triangle[0]);
    subdivide_fragment([triangle[0], ab, ca], occlusion, tolerance, depth + 1, output);
    subdivide_fragment([ab, triangle[1], bc], occlusion, tolerance, depth + 1, output);
    subdivide_fragment([ca, bc, triangle[2]], occlusion, tolerance, depth + 1, output);
    subdivide_fragment([ab, bc, ca], occlusion, tolerance, depth + 1, output);
}

#[cfg(test)]
pub fn filter_visible_fragments(
    fragments: Vec<[ProjectedVertex; 3]>,
    source_triangles: &[[[f32; 3]; 3]],
    size: [f32; 3],
    face: Face,
) -> Vec<[ProjectedVertex; 3]> {
    OcclusionMap::new(source_triangles, size, face).filter_visible_fragments(fragments)
}

pub fn project_decal_triangle(
    positions: [[f32; 3]; 3],
    normals: [[f32; 3]; 3],
    size: [f32; 3],
    face: Face,
    studs_per_tile: [f32; 2],
    offsets: [f32; 2],
) -> Vec<[ProjectedVertex; 3]> {
    project_triangle(positions, normals, size, face, studs_per_tile, offsets)
}

pub fn project_face_overlay(
    size: [f32; 3],
    face: Face,
    tile_size: [f32; 2],
    offsets: [f32; 2],
    tiled: bool,
) -> Vec<[ProjectedVertex; 3]> {
    if size.iter().any(|value| !value.is_finite() || *value <= 0.0) { return Vec::new(); }
    let plane = face.plane(size);
    let normal_extent = (plane.normal[0].abs() * size[0] + plane.normal[1].abs() * size[1] + plane.normal[2].abs() * size[2]) * 0.5;
    let center = [plane.normal[0] * normal_extent, plane.normal[1] * normal_extent, plane.normal[2] * normal_extent];
    let point = |horizontal: f32, vertical: f32| [
        center[0] + plane.horizontal[0] * horizontal + plane.vertical[0] * vertical,
        center[1] + plane.horizontal[1] * horizontal + plane.vertical[1] * vertical,
        center[2] + plane.horizontal[2] * horizontal + plane.vertical[2] * vertical,
    ];
    let bottom_left = point(-plane.half_width, -plane.half_height);
    let bottom_right = point(plane.half_width, -plane.half_height);
    let top_right = point(plane.half_width, plane.half_height);
    let top_left = point(-plane.half_width, plane.half_height);
    let triangles = [[bottom_left, bottom_right, top_right], [bottom_left, top_right, top_left]];
    let mut output = Vec::new();
    for mut positions in triangles {
        let edge_a = [positions[1][0] - positions[0][0], positions[1][1] - positions[0][1], positions[1][2] - positions[0][2]];
        let edge_b = [positions[2][0] - positions[0][0], positions[2][1] - positions[0][1], positions[2][2] - positions[0][2]];
        let winding = [edge_a[1] * edge_b[2] - edge_a[2] * edge_b[1], edge_a[2] * edge_b[0] - edge_a[0] * edge_b[2], edge_a[0] * edge_b[1] - edge_a[1] * edge_b[0]];
        if dot(winding, plane.normal) < 0.0 {
            positions.swap(1, 2);
        }
        let normals = [plane.normal; 3];
        let fragments = if tiled { project_texture_triangle(positions, normals, size, face, tile_size, offsets) } else { project_decal_triangle(positions, normals, size, face, tile_size, offsets) };
        for fragment in fragments {
            if tiled { output.push(fragment); } else { output.extend(clip_unit_uv(fragment)); }
        }
    }
    output
}

pub fn project_texture_triangle(
    positions: [[f32; 3]; 3],
    normals: [[f32; 3]; 3],
    size: [f32; 3],
    face: Face,
    studs_per_tile: [f32; 2],
    offsets: [f32; 2],
) -> Vec<[ProjectedVertex; 3]> {
    if size.iter().any(|value| !value.is_finite() || *value <= 0.0)
        || studs_per_tile.iter().any(|value| !value.is_finite() || *value <= 0.0)
        || offsets.iter().any(|value| !value.is_finite())
        || positions.iter().flatten().any(|value| !value.is_finite())
        || normals.iter().flatten().any(|value| !value.is_finite())
        || normals.iter().any(|normal| dot(*normal, face.plane(size).normal) <= 0.0)
    {
        return Vec::new();
    }
    let plane = face.plane(size);
    let mut polygon = positions.into_iter().zip(normals).map(|(position, normal)| {
        let u = (dot(position, plane.horizontal) + plane.half_width - offsets[0]) / studs_per_tile[0];
        let v = 1.0 - (dot(position, plane.vertical) + plane.half_height - offsets[1]) / studs_per_tile[1];
        ProjectedVertex { position, normal: normalize(normal), uv: [u, v] }
    }).collect::<Vec<_>>();
    polygon = clip_polygon(&polygon, horizontal, plane, -plane.half_width, true);
    polygon = clip_polygon(&polygon, horizontal, plane, plane.half_width, false);
    polygon = clip_polygon(&polygon, vertical, plane, -plane.half_height, true);
    polygon = clip_polygon(&polygon, vertical, plane, plane.half_height, false);
    if polygon.len() < 3 {
        return Vec::new();
    }
    (1..polygon.len() - 1).map(|index| {
        let mut triangle = [polygon[0], polygon[index], polygon[index + 1]];
        for vertex in &mut triangle {
            for axis in 0..3 {
                vertex.position[axis] += plane.normal[axis] * SURFACE_BIAS;
            }
        }
        triangle
    }).collect()
}

fn clip_uv_polygon(
    polygon: Vec<ProjectedVertex>,
    axis: usize,
    boundary: f32,
    keep_greater: bool,
) -> Vec<ProjectedVertex> {
    let Some(mut previous) = polygon.last().copied() else {
        return Vec::new();
    };
    let mut previous_inside = if keep_greater { previous.uv[axis] >= boundary } else { previous.uv[axis] <= boundary };
    let mut output = Vec::new();
    for current in polygon {
        let current_inside = if keep_greater { current.uv[axis] >= boundary } else { current.uv[axis] <= boundary };
        if current_inside != previous_inside {
            let denominator = current.uv[axis] - previous.uv[axis];
            if denominator.abs() > f32::EPSILON {
                let amount = ((boundary - previous.uv[axis]) / denominator).clamp(0.0, 1.0);
                output.push(interpolate(previous, current, amount));
            }
        }
        if current_inside {
            output.push(current);
        }
        previous = current;
        previous_inside = current_inside;
    }
    output
}

pub fn clip_unit_uv(triangle: [ProjectedVertex; 3]) -> Vec<[ProjectedVertex; 3]> {
    let mut polygon = triangle.to_vec();
    polygon = clip_uv_polygon(polygon, 0, 0.0, true);
    polygon = clip_uv_polygon(polygon, 0, 1.0, false);
    polygon = clip_uv_polygon(polygon, 1, 0.0, true);
    polygon = clip_uv_polygon(polygon, 1, 1.0, false);
    if polygon.len() < 3 {
        return Vec::new();
    }
    (1..polygon.len() - 1).map(|index| [polygon[0], polygon[index], polygon[index + 1]]).collect()
}

pub fn rotate_uv(uv: [f32; 2], rotation: f32) -> [f32; 2] {
    let radians = rotation.to_radians();
    let (sine, cosine) = radians.sin_cos();
    let centered = [uv[0] - 0.5, uv[1] - 0.5];
    [
        0.5 + centered[0] * cosine - centered[1] * sine,
        0.5 + centered[0] * sine + centered[1] * cosine,
    ]
}

pub fn rotate_tiled_uv(uv: [f32; 2], rotation: f32) -> [f32; 2] {
    let tile = uv.map(f32::floor);
    let local = [uv[0] - tile[0], uv[1] - tile[1]];
    let rotated = rotate_uv(local, rotation);
    [tile[0] + rotated[0], tile[1] + rotated[1]]
}

#[cfg(test)]
pub fn alpha_over(destination: [u8; 4], source: [u8; 4], transparency: f32) -> [u8; 4] {
    let source_alpha = (source[3] as f32 / 255.0 * (1.0 - transparency.clamp(0.0, 1.0))).clamp(0.0, 1.0);
    let destination_alpha = destination[3] as f32 / 255.0;
    let output_alpha = source_alpha + destination_alpha * (1.0 - source_alpha);
    if output_alpha <= 0.0 {
        return [0, 0, 0, 0];
    }
    let mut output = [0; 4];
    for channel in 0..3 {
        let value = (source[channel] as f32 * source_alpha + destination[channel] as f32 * destination_alpha * (1.0 - source_alpha)) / output_alpha;
        output[channel] = value.round().clamp(0.0, 255.0) as u8;
    }
    output[3] = (output_alpha * 255.0).round().clamp(0.0, 255.0) as u8;
    output
}

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SurfaceOverlayInput {
    pub name: String,
    pub owner_name: String,
    #[serde(default)]
    pub class_name: String,
    pub uri: String,
    pub metalness_uri: Option<String>,
    pub normal_uri: Option<String>,
    pub roughness_uri: Option<String>,
    pub emissive_uri: Option<String>,
    pub emissive_tint: Option<[f32; 3]>,
    pub emissive_strength: Option<f32>,
    pub face: String,
    pub transparency: f32,
    pub color: [f32; 3],
    pub studs_per_tile: [f32; 2],
    pub offset: [f32; 2],
    pub rotation: f32,
    pub size: [f32; 3],
    pub transform: [f32; 12],
    pub layer: usize,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct OverlayError {
    pub name: String,
    pub error: String,
}

pub fn validate_inputs(inputs: &[SurfaceOverlayInput]) -> Vec<OverlayError> {
    inputs.iter().filter_map(|input| {
        let valid_face = matches!(input.face.as_str(), "Right" | "Top" | "Back" | "Left" | "Bottom" | "Front");
        let valid_class = matches!(input.class_name.as_str(), "Decal" | "Texture");
        let valid_uri = !input.uri.trim().is_empty();
        let valid_transparency = input.transparency.is_finite() && (0.0..=1.0).contains(&input.transparency);
        let valid_color = input.color.iter().all(|value| value.is_finite() && (0.0..=1.0).contains(value));
        let valid_tile = input.studs_per_tile.iter().all(|value| value.is_finite() && *value > 0.0);
        let valid_offset = input.offset.iter().all(|value| value.is_finite());
        let valid_rotation = input.rotation.is_finite();
        let valid_size = input.size.iter().all(|value| value.is_finite() && *value > 0.0);
        let valid_transform = input.transform.iter().all(|value| value.is_finite());
        let error = if !valid_class {
            Some("unsupported surface overlay class".to_string())
        } else if !valid_face {
            Some(format!("unsupported face: {}", input.face))
        } else if !valid_uri {
            Some("surface overlay has no image URI".to_string())
        } else if !valid_transparency {
            Some("transparency must be between 0 and 1".to_string())
        } else if !valid_color {
            Some("tint color components must be between 0 and 1".to_string())
        } else if !valid_tile {
            Some("texture tile dimensions must be positive".to_string())
        } else if !valid_offset {
            Some("texture offsets must be finite".to_string())
        } else if !valid_rotation {
            Some("overlay rotation must be finite".to_string())
        } else if !valid_size {
            Some("overlay owner dimensions must be positive".to_string())
        } else if !valid_transform {
            Some("overlay owner transform must be finite".to_string())
        } else {
            None
        };
        error.map(|error| OverlayError { name: input.name.clone(), error })
    }).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn overlay() -> SurfaceOverlayInput {
        SurfaceOverlayInput {
            name: "part.Decal".to_string(),
            owner_name: "part".to_string(),
            class_name: "Decal".to_string(),
            uri: "rbxassetid://123".to_string(),
            metalness_uri: None,
            normal_uri: None,
            roughness_uri: None,
            emissive_uri: None,
            emissive_tint: None,
            emissive_strength: None,
            face: "Front".to_string(),
            transparency: 0.25,
            color: [1.0; 3],
            studs_per_tile: [1.0; 2],
            offset: [0.0; 2],
            rotation: 0.0,
            size: [2.0; 3],
            transform: [0.0; 12],
            layer: 0,
        }
    }

    #[test]
    fn rotates_overlay_uvs_clockwise_around_the_tile_center() {
        let rotated = rotate_uv([0.0, 0.5], 90.0);
        assert!((rotated[0] - 0.5).abs() < 0.0001);
        assert!((rotated[1] - 0.0).abs() < 0.0001);
    }

    #[test]
    fn clips_rotated_overlay_fragments_to_the_source_tile() {
        let triangle = [
            ProjectedVertex { position: [0.0, 0.0, 0.0], normal: [0.0, 0.0, 1.0], uv: [-0.5, 0.5] },
            ProjectedVertex { position: [1.0, 0.0, 0.0], normal: [0.0, 0.0, 1.0], uv: [0.5, 1.5] },
            ProjectedVertex { position: [0.0, 1.0, 0.0], normal: [0.0, 0.0, 1.0], uv: [1.5, 0.5] },
        ];
        let clipped = clip_unit_uv(triangle);
        assert!(!clipped.is_empty());
        assert!(clipped.iter().flatten().all(|vertex| {
            vertex.uv.iter().all(|value| (0.0..=1.0).contains(value))
        }));
    }

    #[test]
    fn maps_front_and_back_to_roblox_face_normals() {
        assert_eq!(Face::Front.plane([1.0; 3]).normal, [0.0, 0.0, -1.0]);
        assert_eq!(Face::Back.plane([1.0; 3]).normal, [0.0, 0.0, 1.0]);
    }

    #[test]
    fn projects_a_front_face_triangle_to_image_uvs() {
        let projected = project_decal_triangle(
            [[-1.0, -1.0, -1.0], [1.0, -1.0, -1.0], [0.0, 1.0, -1.0]],
            [[0.0, 0.0, -1.0]; 3],
            [2.0; 3],
            Face::Front,
            [2.0, 2.0],
            [0.0, 0.0],
        );
        assert_eq!(projected.len(), 1);
        assert_eq!(projected[0][0].uv, [0.0, 1.0]);
        assert_eq!(projected[0][1].uv, [1.0, 1.0]);
        assert_eq!(projected[0][2].uv, [0.5, 0.0]);
        assert!(projected[0].iter().all(|vertex| (vertex.position[2] + 1.001).abs() < 0.00001));
    }

    #[test]
    fn clips_a_decal_to_its_projected_rectangle() {
        let projected = project_decal_triangle(
            [[-1.0, -1.0, -1.0], [1.0, -1.0, -1.0], [0.0, 1.0, -1.0]],
            [[0.0, 0.0, -1.0]; 3],
            [2.0; 3],
            Face::Front,
            [1.0, 1.0],
            [0.5, 0.5],
        );
        assert!(!projected.is_empty());
        assert!(projected.iter().flatten().all(|vertex| vertex.uv.iter().all(|value| *value >= -0.0001 && *value <= 1.0001)));
    }

    #[test]
    fn rejects_overlay_triangles_occluded_by_nearer_concave_surfaces() {
        let face = Face::Front;
        let size = [2.0; 3];
        let hidden = project_decal_triangle(
            [[-0.5, -0.5, 0.0], [0.5, -0.5, 0.0], [0.0, 0.5, 0.0]],
            [[0.0, 0.0, -1.0]; 3],
            size,
            face,
            [2.0, 2.0],
            [0.0, 0.0],
        );
        let source_triangles = vec![
            [[-1.0, -1.0, -1.0], [1.0, -1.0, -1.0], [1.0, 1.0, -1.0]],
            [[-1.0, -1.0, -1.0], [1.0, 1.0, -1.0], [-1.0, 1.0, -1.0]],
            [[-1.0, -1.0, 0.0], [1.0, -1.0, 0.0], [1.0, 1.0, 0.0]],
            [[-1.0, -1.0, 0.0], [1.0, 1.0, 0.0], [-1.0, 1.0, 0.0]],
        ];
        assert!(!hidden.is_empty());
        assert!(filter_visible_fragments(hidden, &source_triangles, size, face).is_empty());
    }

    #[test]
    fn retains_overlay_triangles_on_the_visible_surface() {
        let face = Face::Front;
        let size = [2.0; 3];
        let visible = project_decal_triangle(
            [[-0.5, -0.5, -1.0], [0.5, -0.5, -1.0], [0.0, 0.5, -1.0]],
            [[0.0, 0.0, -1.0]; 3],
            size,
            face,
            [2.0, 2.0],
            [0.0, 0.0],
        );
        let source_triangles = vec![
            [[-1.0, -1.0, -1.0], [1.0, -1.0, -1.0], [1.0, 1.0, -1.0]],
            [[-1.0, -1.0, -1.0], [1.0, 1.0, -1.0], [-1.0, 1.0, -1.0]],
        ];
        assert!(!filter_visible_fragments(visible, &source_triangles, size, face).is_empty());
    }

    #[test]
    fn texture_projection_keeps_one_face_triangle_across_repeated_tiles() {
        let projected = project_texture_triangle(
            [[-2.0, 0.0, -0.5], [2.0, 0.0, -0.5], [2.0, 0.0, 0.5]],
            [[0.0, 1.0, 0.0]; 3],
            [4.0, 2.0, 1.0],
            Face::Top,
            [1.0, 1.0],
            [0.0, 0.0],
        );
        assert_eq!(projected.len(), 1);
        assert_eq!(projected[0].map(|vertex| vertex.uv[0]), [0.0, 4.0, 4.0]);
    }

    #[test]
    fn rotates_each_repeated_texture_tile_independently() {
        assert_eq!(rotate_tiled_uv([2.0, 3.25], 90.0), [2.75, 3.5]);
    }

    #[test]
    fn projects_sloped_triangles_on_the_selected_face() {
        let projected = project_decal_triangle(
            [[-0.5, -0.5, -1.0], [0.5, -0.5, -0.5], [0.0, 0.5, -0.75]],
            [[0.9, 0.0, -0.43589]; 3],
            [2.0; 3],
            Face::Front,
            [2.0; 2],
            [0.0; 2],
        );
        assert!(!projected.is_empty());
    }

    #[test]
    fn rejects_triangles_facing_away_from_the_selected_face() {
        assert!(project_decal_triangle(
            [[0.0; 3]; 3],
            [[0.0, 0.0, 1.0]; 3],
            [2.0; 3],
            Face::Front,
            [1.0; 2],
            [0.0; 2],
        ).is_empty());
    }

    #[test]
    fn composites_transparency_using_alpha_over() {
        assert_eq!(alpha_over([0, 0, 255, 255], [255, 0, 0, 255], 0.5), [128, 0, 128, 255]);
        assert_eq!(alpha_over([0, 0, 0, 0], [255, 255, 255, 255], 1.0), [0, 0, 0, 0]);
    }

    #[test]
    fn accepts_valid_decal_metadata() {
        assert!(validate_inputs(&[overlay()]).is_empty());
    }

    #[test]
    fn rejects_invalid_texture_dimensions() {
        let mut input = overlay();
        input.class_name = "Texture".to_string();
        input.studs_per_tile[0] = 0.0;
        assert_eq!(validate_inputs(&[input])[0].error, "texture tile dimensions must be positive");
    }

    #[test]
    fn rejects_unknown_faces() {
        let mut input = overlay();
        input.face = "Center".to_string();
        assert_eq!(validate_inputs(&[input])[0].error, "unsupported face: Center");
    }
}
