use serde::Deserialize;

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PrimitiveInput {
    pub name: String,
    #[serde(default)]
    pub assembly_id: String,
    #[serde(default)]
    pub cast_shadow: bool,
    pub shape: String,
    pub material: String,
    pub material_variant: String,
    pub color: [f32; 3],
    pub transparency: f32,
    pub local_transparency_modifier: f32,
    pub reflectance: f32,
    pub size: [f32; 3],
    pub transform: [f32; 12],
    pub emissive_tint: Option<[f32; 3]>,
    pub emissive_strength: Option<f32>,
}


#[derive(Clone, Debug)]
pub struct PrimitiveMesh {
    pub positions: Vec<[f32; 3]>,
    pub normals: Vec<[f32; 3]>,
    pub uvs: Vec<[f32; 2]>,
    pub indices: Vec<u32>,
}

impl PrimitiveMesh {
    fn new() -> Self {
        Self {
            positions: Vec::new(),
            normals: Vec::new(),
            uvs: Vec::new(),
            indices: Vec::new(),
        }
    }

    fn triangle(&mut self, points: [[f32; 3]; 3], uvs: [[f32; 2]; 3]) {
        let edge_a = subtract(points[1], points[0]);
        let edge_b = subtract(points[2], points[0]);
        let normal = normalize(cross(edge_a, edge_b));
        let start = self.positions.len() as u32;
        for index in 0..3 {
            self.positions.push(points[index]);
            self.normals.push(normal);
            self.uvs.push(uvs[index]);
            self.indices.push(start + index as u32);
        }
    }

    fn quad(&mut self, points: [[f32; 3]; 4], uvs: [[f32; 2]; 4]) {
        self.triangle([points[0], points[1], points[2]], [uvs[0], uvs[1], uvs[2]]);
        self.triangle([points[0], points[2], points[3]], [uvs[0], uvs[2], uvs[3]]);
    }
}

fn subtract(a: [f32; 3], b: [f32; 3]) -> [f32; 3] {
    [a[0] - b[0], a[1] - b[1], a[2] - b[2]]
}

fn cross(a: [f32; 3], b: [f32; 3]) -> [f32; 3] {
    [
        a[1] * b[2] - a[2] * b[1],
        a[2] * b[0] - a[0] * b[2],
        a[0] * b[1] - a[1] * b[0],
    ]
}

#[cfg(test)]
fn dot(a: [f32; 3], b: [f32; 3]) -> f32 {
    a[0] * b[0] + a[1] * b[1] + a[2] * b[2]
}

fn normalize(value: [f32; 3]) -> [f32; 3] {
    let length = (value[0] * value[0] + value[1] * value[1] + value[2] * value[2]).sqrt();
    if length == 0.0 {
        [0.0, 1.0, 0.0]
    } else {
        [value[0] / length, value[1] / length, value[2] / length]
    }
}

fn block(mesh: &mut PrimitiveMesh) {
    let faces = [
        [[-0.5, -0.5, 0.5], [0.5, -0.5, 0.5], [0.5, 0.5, 0.5], [-0.5, 0.5, 0.5]],
        [[0.5, -0.5, -0.5], [-0.5, -0.5, -0.5], [-0.5, 0.5, -0.5], [0.5, 0.5, -0.5]],
        [[0.5, -0.5, 0.5], [0.5, -0.5, -0.5], [0.5, 0.5, -0.5], [0.5, 0.5, 0.5]],
        [[-0.5, -0.5, -0.5], [-0.5, -0.5, 0.5], [-0.5, 0.5, 0.5], [-0.5, 0.5, -0.5]],
        [[-0.5, 0.5, 0.5], [0.5, 0.5, 0.5], [0.5, 0.5, -0.5], [-0.5, 0.5, -0.5]],
        [[-0.5, -0.5, -0.5], [0.5, -0.5, -0.5], [0.5, -0.5, 0.5], [-0.5, -0.5, 0.5]],
    ];
    let uv = [[0.0, 0.0], [1.0, 0.0], [1.0, 1.0], [0.0, 1.0]];
    for face in faces {
        mesh.quad(face, uv);
    }
}

fn cylinder(mesh: &mut PrimitiveMesh, segments: usize) {
    for index in 0..segments {
        let angle_a = std::f32::consts::TAU * index as f32 / segments as f32;
        let angle_b = std::f32::consts::TAU * (index + 1) as f32 / segments as f32;
        let (sin_a, cos_a) = angle_a.sin_cos();
        let (sin_b, cos_b) = angle_b.sin_cos();
        let a = [cos_a * 0.5, -0.5, sin_a * 0.5];
        let b = [cos_b * 0.5, -0.5, sin_b * 0.5];
        let c = [cos_b * 0.5, 0.5, sin_b * 0.5];
        let d = [cos_a * 0.5, 0.5, sin_a * 0.5];
        let u0 = index as f32 / segments as f32;
        let u1 = (index + 1) as f32 / segments as f32;
        mesh.quad([a, d, c, b], [[u0, 1.0], [u0, 0.0], [u1, 0.0], [u1, 1.0]]);
        mesh.triangle([[0.0, -0.5, 0.0], a, b], [[0.5, 0.5], [cos_a * 0.5 + 0.5, sin_a * 0.5 + 0.5], [cos_b * 0.5 + 0.5, sin_b * 0.5 + 0.5]]);
        mesh.triangle([[0.0, 0.5, 0.0], c, d], [[0.5, 0.5], [cos_b * 0.5 + 0.5, sin_b * 0.5 + 0.5], [cos_a * 0.5 + 0.5, sin_a * 0.5 + 0.5]]);
    }
}

fn sphere(mesh: &mut PrimitiveMesh, segments: usize, rings: usize) {
    let point = |latitude: f32, longitude: f32| {
        [
            latitude.cos() * longitude.cos() * 0.5,
            latitude.sin() * 0.5,
            latitude.cos() * longitude.sin() * 0.5,
        ]
    };
    let bottom = [0.0, -0.5, 0.0];
    let top = [0.0, 0.5, 0.0];
    for segment in 0..segments {
        let longitude_a = std::f32::consts::TAU * segment as f32 / segments as f32;
        let longitude_b = std::f32::consts::TAU * (segment + 1) as f32 / segments as f32;
        let u0 = segment as f32 / segments as f32;
        let u1 = (segment + 1) as f32 / segments as f32;
        let first_latitude = -std::f32::consts::FRAC_PI_2 + std::f32::consts::PI / rings as f32;
        let first_a = point(first_latitude, longitude_a);
        let first_b = point(first_latitude, longitude_b);
        mesh.triangle(
            [bottom, first_a, first_b],
            [[(u0 + u1) * 0.5, 0.0], [u0, 1.0 / rings as f32], [u1, 1.0 / rings as f32]],
        );
        for ring in 1..rings - 1 {
            let latitude_a = -std::f32::consts::FRAC_PI_2 + std::f32::consts::PI * ring as f32 / rings as f32;
            let latitude_b = -std::f32::consts::FRAC_PI_2 + std::f32::consts::PI * (ring + 1) as f32 / rings as f32;
            let a = point(latitude_a, longitude_a);
            let b = point(latitude_a, longitude_b);
            let c = point(latitude_b, longitude_b);
            let d = point(latitude_b, longitude_a);
            let v0 = ring as f32 / rings as f32;
            let v1 = (ring + 1) as f32 / rings as f32;
            mesh.quad(
                [a, d, c, b],
                [[u0, v0], [u0, v1], [u1, v1], [u1, v0]],
            );
        }
        let last_latitude = std::f32::consts::FRAC_PI_2 - std::f32::consts::PI / rings as f32;
        let last_a = point(last_latitude, longitude_a);
        let last_b = point(last_latitude, longitude_b);
        mesh.triangle(
            [top, last_b, last_a],
            [[(u0 + u1) * 0.5, 1.0], [u1, 1.0 - 1.0 / rings as f32], [u0, 1.0 - 1.0 / rings as f32]],
        );
    }
}

fn corner_wedge(mesh: &mut PrimitiveMesh) {
    let bottom_left_back = [-0.5, -0.5, -0.5];
    let bottom_right_front = [0.5, -0.5, 0.5];
    let bottom_right_back = [0.5, -0.5, -0.5];
    let top_right_back = [0.5, 0.5, -0.5];
    let bottom_left_front = [-0.5, -0.5, 0.5];
    let uv = [[0.0, 0.0], [1.0, 0.0], [1.0, 1.0], [0.0, 1.0]];
    mesh.quad([bottom_left_back, bottom_right_back, bottom_right_front, bottom_left_front], uv);
    mesh.triangle([bottom_right_front, bottom_right_back, top_right_back], [[0.0, 0.0], [1.0, 0.0], [1.0, 1.0]]);
    mesh.triangle([bottom_left_back, top_right_back, bottom_right_back], [[0.0, 0.0], [1.0, 1.0], [1.0, 0.0]]);
    mesh.triangle([bottom_left_back, bottom_left_front, top_right_back], [[0.0, 0.0], [1.0, 0.0], [1.0, 1.0]]);
    mesh.triangle([bottom_left_front, bottom_right_front, top_right_back], [[0.0, 0.0], [1.0, 0.0], [1.0, 1.0]]);
}

fn wedge(mesh: &mut PrimitiveMesh) {
    let low_left = [-0.5, -0.5, 0.5];
    let low_right = [0.5, -0.5, 0.5];
    let low_back_left = [-0.5, -0.5, -0.5];
    let low_back_right = [0.5, -0.5, -0.5];
    let high_left = [-0.5, 0.5, -0.5];
    let high_right = [0.5, 0.5, -0.5];
    let uv = [[0.0, 0.0], [1.0, 0.0], [1.0, 1.0], [0.0, 1.0]];
    mesh.quad([low_left, low_back_left, low_back_right, low_right], uv);
    mesh.triangle([low_left, high_left, low_back_left], [[0.0, 0.0], [1.0, 1.0], [1.0, 0.0]]);
    mesh.triangle([low_right, low_back_right, high_right], [[0.0, 0.0], [1.0, 0.0], [1.0, 1.0]]);
    mesh.quad([low_back_left, high_left, high_right, low_back_right], uv);
    mesh.quad([low_left, low_right, high_right, high_left], uv);
}

pub fn build(input: &PrimitiveInput) -> Result<PrimitiveMesh, String> {
    if input.size.iter().any(|value| !value.is_finite() || *value <= 0.0)
        || input.transform.iter().any(|value| !value.is_finite())
    {
        return Err("primitive dimensions and transform must contain finite values, with positive dimensions".to_string());
    }
    let mut mesh = PrimitiveMesh::new();
    match input.shape.as_str() {
        "block" => block(&mut mesh),
        "cylinder" => cylinder(&mut mesh, 32),
        "ball" => sphere(&mut mesh, 32, 16),
        "wedge" => wedge(&mut mesh),
        "cornerWedge" => corner_wedge(&mut mesh),
        shape => return Err(format!("unsupported primitive shape: {shape}")),
    }
    for position in &mut mesh.positions {
        if input.shape == "wedge" {
            position[2] = -position[2];
        }
        for axis in 0..3 {
            position[axis] *= input.size[axis];
        }
    }
    if input.shape == "wedge" {
        for triangle in (0..mesh.positions.len()).step_by(3) {
            mesh.positions.swap(triangle + 1, triangle + 2);
            mesh.uvs.swap(triangle + 1, triangle + 2);
        }
    }
    for triangle in (0..mesh.positions.len()).step_by(3) {
        let face_normal = normalize(cross(
            subtract(mesh.positions[triangle + 1], mesh.positions[triangle]),
            subtract(mesh.positions[triangle + 2], mesh.positions[triangle]),
        ));
        let cylinder_side = input.shape == "cylinder" && triangle % 12 < 6;
        for corner in 0..3 {
            let index = triangle + corner;
            let position = mesh.positions[index];
            let normal = if input.shape == "ball" {
                normalize([
                    position[0] / (input.size[0] * input.size[0]),
                    position[1] / (input.size[1] * input.size[1]),
                    position[2] / (input.size[2] * input.size[2]),
                ])
            } else if cylinder_side {
                normalize([
                    position[0] / (input.size[0] * input.size[0]),
                    0.0,
                    position[2] / (input.size[2] * input.size[2]),
                ])
            } else {
                face_normal
            };
            mesh.positions[index] = [
                input.transform[0] + input.transform[3] * position[0] + input.transform[4] * position[1] + input.transform[5] * position[2],
                input.transform[1] + input.transform[6] * position[0] + input.transform[7] * position[1] + input.transform[8] * position[2],
                input.transform[2] + input.transform[9] * position[0] + input.transform[10] * position[1] + input.transform[11] * position[2],
            ];
            mesh.normals[index] = normalize([
                input.transform[3] * normal[0] + input.transform[4] * normal[1] + input.transform[5] * normal[2],
                input.transform[6] * normal[0] + input.transform[7] * normal[1] + input.transform[8] * normal[2],
                input.transform[9] * normal[0] + input.transform[10] * normal[1] + input.transform[11] * normal[2],
            ]);
        }
    }
    Ok(mesh)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn input(shape: &str) -> PrimitiveInput {
        PrimitiveInput {
            name: shape.into(),
            assembly_id: "anchored".to_string(),
            cast_shadow: true,
            shape: shape.into(),
            material: "Plastic".into(),
            material_variant: String::new(),
            color: [1.0; 3],
            transparency: 0.0,
            local_transparency_modifier: 0.0,
            reflectance: 0.0,
            size: [2.0; 3],
            transform: [0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0],
            emissive_tint: None,
            emissive_strength: None,
        }
    }

    #[test]
    fn builds_expected_primitive_topologies() {
        let block_mesh = build(&input("block")).unwrap();
        assert_eq!(block_mesh.indices.len(), 36);

        let cylinder_mesh = build(&input("cylinder")).unwrap();
        assert_eq!(cylinder_mesh.indices.len(), 32 * 12);

        let sphere_mesh = build(&input("ball")).unwrap();
        assert_eq!(sphere_mesh.indices.len(), 32 * (2 + 14 * 2) * 3);
    }

    #[test]
    fn cylinder_and_sphere_faces_have_outward_winding_without_degenerate_triangles() {
        for shape in ["cylinder", "ball"] {
            let mesh = build(&input(shape)).unwrap();
            for triangle in mesh.positions.chunks_exact(3) {
                let normal = cross(subtract(triangle[1], triangle[0]), subtract(triangle[2], triangle[0]));
                let area_squared = normal[0] * normal[0] + normal[1] * normal[1] + normal[2] * normal[2];
                let center = [
                    (triangle[0][0] + triangle[1][0] + triangle[2][0]) / 3.0,
                    (triangle[0][1] + triangle[1][1] + triangle[2][1]) / 3.0,
                    (triangle[0][2] + triangle[1][2] + triangle[2][2]) / 3.0,
                ];
                let outward = normal[0] * center[0] + normal[1] * center[1] + normal[2] * center[2];
                assert!(area_squared > 1e-10);
                assert!(outward > 0.0);
            }
        }
    }

    #[test]
    fn builds_corner_wedge_with_five_faces_and_outward_winding() {
        let mesh = build(&input("cornerWedge")).unwrap();
        assert_eq!(mesh.indices.len(), 18);
        let interior = [0.25, -0.25, -0.25];
        for triangle in mesh.positions.chunks_exact(3) {
            let normal = cross(subtract(triangle[1], triangle[0]), subtract(triangle[2], triangle[0]));
            let center = [
                (triangle[0][0] + triangle[1][0] + triangle[2][0]) / 3.0,
                (triangle[0][1] + triangle[1][1] + triangle[2][1]) / 3.0,
                (triangle[0][2] + triangle[1][2] + triangle[2][2]) / 3.0,
            ];
            let outward = normal[0] * (center[0] - interior[0])
                + normal[1] * (center[1] - interior[1])
                + normal[2] * (center[2] - interior[2]);
            assert!(outward > 0.0);
        }
    }

    #[test]
    fn wedge_faces_have_outward_winding() {
        let mesh = build(&input("wedge")).unwrap();
        for (triangle_index, triangle) in mesh.positions.chunks_exact(3).enumerate() {
            let normal = cross(subtract(triangle[1], triangle[0]), subtract(triangle[2], triangle[0]));
            let center = [
                (triangle[0][0] + triangle[1][0] + triangle[2][0]) / 3.0,
                (triangle[0][1] + triangle[1][1] + triangle[2][1]) / 3.0,
                (triangle[0][2] + triangle[1][2] + triangle[2][2]) / 3.0,
            ];
            let outward = normal[0] * center[0] + normal[1] * center[1] + normal[2] * center[2];
            assert!(outward >= -1e-5);
            assert!(dot(normalize(normal), mesh.normals[triangle_index * 3]) > 0.999);
        }
    }
}
