use draco_core::{DecoderBuffer, FaceIndex, Mesh, MeshDecoder};
use std::convert::TryInto;

#[derive(Clone)]
pub struct FileMeshData {
    pub positions: Vec<[f32; 3]>,
    pub normals: Vec<[f32; 3]>,
    pub uvs: Vec<[f32; 2]>,
    pub colors: Vec<[f32; 4]>,
}

struct Reader<'a> {
    bytes: &'a [u8],
    offset: usize,
}

impl<'a> Reader<'a> {
    fn new(bytes: &'a [u8]) -> Self {
        Self { bytes, offset: 0 }
    }

    fn take(&mut self, length: usize) -> Result<&'a [u8], String> {
        let end = self.offset.checked_add(length).ok_or("FileMesh offset overflow")?;
        let value = self.bytes.get(self.offset..end).ok_or("FileMesh ended before its declared data")?;
        self.offset = end;
        Ok(value)
    }

    fn u8(&mut self) -> Result<u8, String> {
        Ok(self.take(1)?[0])
    }

    fn u16(&mut self) -> Result<u16, String> {
        Ok(u16::from_le_bytes(self.take(2)?.try_into().unwrap()))
    }

    fn u32(&mut self) -> Result<u32, String> {
        Ok(u32::from_le_bytes(self.take(4)?.try_into().unwrap()))
    }

    fn f32(&mut self) -> Result<f32, String> {
        Ok(f32::from_le_bytes(self.take(4)?.try_into().unwrap()))
    }

    fn count(&mut self, maximum: usize) -> Result<usize, String> {
        let count = self.u32()? as usize;
        if count > maximum {
            return Err(format!("FileMesh count {count} exceeds the supported limit"));
        }
        Ok(count)
    }
}

fn expand_geometry(vertices: &[[f32; 12]], faces: &[[u32; 3]], face_limit: usize) -> Result<FileMeshData, String> {
    let face_count = faces.len().min(face_limit);
    let mut output = FileMeshData {
        positions: Vec::with_capacity(face_count * 3),
        normals: Vec::with_capacity(face_count * 3),
        uvs: Vec::with_capacity(face_count * 3),
        colors: Vec::with_capacity(face_count * 3),
    };
    for face in faces.iter().take(face_count) {
        for index in face {
            let vertex = vertices.get(*index as usize).ok_or("FileMesh face references a missing vertex")?;
            output.positions.push([vertex[0], vertex[1], vertex[2]]);
            output.normals.push([vertex[3], vertex[4], vertex[5]]);
            output.uvs.push([vertex[6], vertex[7]]);
            output.colors.push([vertex[8], vertex[9], vertex[10], vertex[11]]);
        }
    }
    if output.positions.is_empty() {
        return Err("FileMesh contains no triangles in its highest-detail mesh".to_string());
    }
    Ok(output)
}

fn read_vertices(reader: &mut Reader<'_>, count: usize, stride: usize) -> Result<Vec<[f32; 12]>, String> {
    if !matches!(stride, 36 | 40) {
        return Err(format!("Unsupported FileMesh vertex stride: {stride}"));
    }
    let mut vertices = Vec::with_capacity(count);
    for _ in 0..count {
        let position = [reader.f32()?, reader.f32()?, reader.f32()?];
        let normal = [reader.f32()?, reader.f32()?, reader.f32()?];
        let uv = [reader.f32()?, reader.f32()?];
        reader.take(4)?;
        let color = if stride == 40 {
            let bytes = reader.take(4)?;
            [bytes[0] as f32 / 255.0, bytes[1] as f32 / 255.0, bytes[2] as f32 / 255.0, bytes[3] as f32 / 255.0]
        } else {
            [1.0; 4]
        };
        vertices.push([position[0], position[1], position[2], normal[0], normal[1], normal[2], uv[0], uv[1], color[0], color[1], color[2], color[3]]);
    }
    Ok(vertices)
}

fn read_faces(reader: &mut Reader<'_>, count: usize) -> Result<Vec<[u32; 3]>, String> {
    let mut faces = Vec::with_capacity(count);
    for _ in 0..count {
        faces.push([reader.u32()?, reader.u32()?, reader.u32()?]);
    }
    Ok(faces)
}

fn decode_ascii(bytes: &[u8], version: &str) -> Result<FileMeshData, String> {
    let text = std::str::from_utf8(bytes).map_err(|error| error.to_string())?;
    let mut lines = text.lines();
    lines.next();
    let face_count: usize = lines.next().ok_or("Missing FileMesh face count")?.trim().parse().map_err(|_| "Invalid FileMesh face count")?;
    if face_count == 0 || face_count > 2_000_000 {
        return Err("FileMesh face count is outside the supported range".to_string());
    }
    let data = lines.collect::<String>();
    let mut values = Vec::with_capacity(face_count * 27);
    let mut token = String::new();
    let mut inside = false;
    for character in data.chars() {
        match character {
            '[' => { token.clear(); inside = true; }
            ']' if inside => {
                let components = token.split(',').map(|value| value.trim().parse::<f32>().map_err(|_| "Invalid ASCII FileMesh coordinate")).collect::<Result<Vec<_>, _>>()?;
                if components.len() != 3 { return Err("Invalid ASCII FileMesh vector".to_string()); }
                values.extend(components);
                inside = false;
            }
            _ if inside => token.push(character),
            _ => {}
        }
    }
    if values.len() != face_count * 27 {
        return Err("ASCII FileMesh vertex data length does not match its face count".to_string());
    }
    let scale = if version == "version 1.00" { 0.5 } else { 1.0 };
    let mut output = FileMeshData { positions: Vec::with_capacity(face_count * 3), normals: Vec::with_capacity(face_count * 3), uvs: Vec::with_capacity(face_count * 3), colors: vec![[1.0; 4]; face_count * 3] };
    for vertex in values.chunks_exact(9) {
        output.positions.push([vertex[0] * scale, vertex[1] * scale, vertex[2] * scale]);
        output.normals.push([vertex[3], vertex[4], vertex[5]]);
        output.uvs.push([vertex[6], 1.0 - vertex[7]]);
    }
    Ok(output)
}

fn decode_v2_v3(bytes: &[u8], version3: bool) -> Result<FileMeshData, String> {
    let mut reader = Reader::new(bytes);
    let header_size = reader.u16()? as usize;
    let vertex_stride = reader.u8()? as usize;
    let face_stride = reader.u8()? as usize;
    let lod_count = if version3 { let _ = reader.u16()?; reader.u16()? as usize } else { 0 };
    let vertex_count = reader.count(5_000_000)?;
    let face_count = reader.count(5_000_000)?;
    if header_size < if version3 { 16 } else { 12 } || face_stride != 12 {
        return Err("Invalid FileMesh v2/v3 header".to_string());
    }
    reader.offset = header_size;
    let vertices = read_vertices(&mut reader, vertex_count, vertex_stride)?;
    let faces = read_faces(&mut reader, face_count)?;
    let mut face_limit = face_count;
    if version3 && lod_count > 0 {
        let mut offsets = Vec::with_capacity(lod_count);
        for _ in 0..lod_count {
            offsets.push(reader.u32()? as usize);
        }
        if offsets.first().copied() != Some(0) {
            return Err("Invalid FileMesh LOD face offsets".to_string());
        }
        if let Some(main_mesh_end) = offsets.get(1) {
            if *main_mesh_end > face_count { return Err("Invalid FileMesh main LOD face offset".to_string()); }
            face_limit = *main_mesh_end;
        }
    }
    expand_geometry(&vertices, &faces, face_limit)
}

fn decode_v4_v5(bytes: &[u8], version5: bool) -> Result<FileMeshData, String> {
    let mut reader = Reader::new(bytes);
    let header_size = reader.u16()? as usize;
    reader.u16()?;
    let vertex_count = reader.count(5_000_000)?;
    let face_count = reader.count(5_000_000)?;
    let lod_count = reader.u16()? as usize;
    let bone_count = reader.u16()? as usize;
    let bone_names_size = reader.u32()? as usize;
    let subset_count = reader.u16()? as usize;
    reader.take(2)?;
    let facs_data_size = if version5 {
        reader.take(4)?;
        reader.u32()? as usize
    } else {
        0
    };
    if header_size < if version5 { 32 } else { 24 } {
        return Err("Invalid FileMesh v4/v5 header".to_string());
    }
    if bone_count > 0 {
        return Err("Skinned FileMesh assets cannot be merged as static geometry".to_string());
    }
    let skinning_size = if bone_count > 0 {
        vertex_count.checked_mul(8).ok_or("FileMesh skinning size overflow")?
    } else {
        0
    };
    let fixed_size = skinning_size
        .checked_add(face_count.checked_mul(12).ok_or("FileMesh face size overflow")?)
        .and_then(|size| size.checked_add(lod_count.checked_mul(4)?))
        .and_then(|size| size.checked_add(bone_count.checked_mul(60)?))
        .and_then(|size| size.checked_add(bone_names_size))
        .and_then(|size| size.checked_add(subset_count.checked_mul(72)?))
        .and_then(|size| size.checked_add(facs_data_size))
        .ok_or("FileMesh v4/v5 data size overflow")?;
    let vertex_data_size = bytes.len().checked_sub(header_size)
        .and_then(|size| size.checked_sub(fixed_size))
        .ok_or("FileMesh v4/v5 vertex data exceeds the file size")?;
    if vertex_count == 0 || vertex_data_size % vertex_count != 0 {
        return Err("Invalid FileMesh v4/v5 vertex data size".to_string());
    }
    let vertex_stride = vertex_data_size / vertex_count;
    reader.offset = header_size;
    let vertices = read_vertices(&mut reader, vertex_count, vertex_stride)?;
    if bone_count > 0 { reader.take(skinning_size)?; }
    let faces = read_faces(&mut reader, face_count)?;
    let mut face_limit = face_count;
    if lod_count > 0 {
        let mut offsets = Vec::with_capacity(lod_count);
        for _ in 0..lod_count {
            offsets.push(reader.u32()? as usize);
        }
        if offsets.first().copied() != Some(0) {
            return Err("Invalid FileMesh LOD face offsets".to_string());
        }
        if let Some(main_mesh_end) = offsets.get(1) {
            if *main_mesh_end > face_count { return Err("Invalid FileMesh main LOD face offset".to_string()); }
            face_limit = *main_mesh_end;
        }
    }
    reader.take(bone_count.checked_mul(60).ok_or("FileMesh bone data size overflow")?)?;
    reader.take(bone_names_size)?;
    for _ in 0..subset_count {
        reader.take(4 * 5 + 2 * 26)?;
    }
    expand_geometry(&vertices, &faces, face_limit)
}

fn decode_draco(bytes: &[u8], face_limit: Option<usize>) -> Result<FileMeshData, String> {
    let mut decoder = MeshDecoder::new();
    let mut mesh = Mesh::new();
    decoder.decode(&mut DecoderBuffer::new(bytes), &mut mesh).map_err(|error| format!("Draco decode failed: {error}"))?;
    let attribute = |unique_id| (0..mesh.num_attributes()).find_map(|index| {
        let candidate = mesh.attribute(index);
        (candidate.unique_id() == unique_id).then_some(candidate)
    });
    let position = attribute(0).ok_or("Draco FileMesh is missing position attribute")?.read_f32s(mesh.num_points(), 3);
    let normal = attribute(1).map(|value| value.read_f32s(mesh.num_points(), 3));
    let uv = attribute(2).map(|value| value.read_f32s(mesh.num_points(), 2));
    let color = attribute(4).map(|value| value.read_f32s(mesh.num_points(), 4));
    let mut output = FileMeshData { positions: Vec::new(), normals: Vec::new(), uvs: Vec::new(), colors: Vec::new() };
    let limit = face_limit.unwrap_or(mesh.num_faces()).min(mesh.num_faces());
    for face_index in 0..limit {
        let face = mesh.face(FaceIndex(face_index as u32));
        for point in face {
            let index = point.0 as usize;
            let p = index * 3;
            output.positions.push([position[p], position[p + 1], position[p + 2]]);
            output.normals.push(normal.as_ref().map(|v| [v[p], v[p + 1], v[p + 2]]).unwrap_or([0.0, 1.0, 0.0]));
            let uv_index = index * 2;
            output.uvs.push(uv.as_ref().map(|v| [v[uv_index], v[uv_index + 1]]).unwrap_or([0.0, 0.0]));
            let color_index = index * 4;
            let rgba = color.as_ref().map(|v| [v[color_index] / 255.0, v[color_index + 1] / 255.0, v[color_index + 2] / 255.0, v[color_index + 3] / 255.0]).unwrap_or([1.0; 4]);
            output.colors.push(rgba);
        }
    }
    if output.positions.is_empty() { return Err("Draco FileMesh contains no triangles".to_string()); }
    Ok(output)
}

fn decode_chunked(bytes: &[u8], version7: bool) -> Result<FileMeshData, String> {
    let mut reader = Reader::new(bytes);
    let mut core = None;
    let mut face_limit = None;
    while reader.offset < bytes.len() {
        let name = reader.take(8)?;
        let chunk_version = reader.u32()?;
        let chunk_size = reader.u32()? as usize;
        let data = reader.take(chunk_size)?;
        let name = std::str::from_utf8(name).unwrap_or("").trim_matches(char::from(0));
        if name == "SKINNING" {
            return Err("Skinned FileMesh assets cannot be merged as static geometry".to_string());
        }
        if name == "COREMESH" {
            if (version7 && chunk_version != 2) || (!version7 && chunk_version != 1) {
                return Err(format!("Unsupported COREMESH chunk version {chunk_version}"));
            }
            core = Some(data);
        } else if name == "LODS" && chunk_version == 1 {
            let mut lods = Reader::new(data);
            lods.take(3)?;
            let count = lods.count(1024)?;
            let mut offsets = Vec::with_capacity(count);
            for _ in 0..count {
                offsets.push(lods.u32()? as usize);
            }
            if !offsets.is_empty() && offsets.first().copied() != Some(0) {
                return Err("Invalid FileMesh LOD face offsets".to_string());
            }
            if let Some(main_mesh_end) = offsets.get(1) {
                face_limit = Some(*main_mesh_end);
            }
        }
    }
    let core = core.ok_or("FileMesh is missing its COREMESH chunk")?;
    if version7 {
        let mut core_reader = Reader::new(core);
        let stream_size = core_reader.count(20_000_000)?;
        decode_draco(core_reader.take(stream_size)?, face_limit)
    } else {
        let mut core_reader = Reader::new(core);
        let vertex_count = core_reader.count(5_000_000)?;
        let mut vertex_stride = None;
        for stride in [40usize, 36] {
            let Some(face_count_offset) = vertex_count.checked_mul(stride).and_then(|size| size.checked_add(4)) else { continue; };
            let Some(face_count_end) = face_count_offset.checked_add(4) else { continue; };
            let Some(face_count_bytes) = core.get(face_count_offset..face_count_end) else { continue; };
            let face_count = u32::from_le_bytes(face_count_bytes.try_into().unwrap()) as usize;
            let Some(expected_size) = face_count.checked_mul(12).and_then(|size| face_count_end.checked_add(size)) else { continue; };
            if face_count <= 5_000_000 && expected_size == core.len() {
                vertex_stride = Some(stride);
                break;
            }
        }
        let vertex_stride = vertex_stride.ok_or("Invalid FileMesh v6 COREMESH vertex stride or face data")?;
        let vertices = read_vertices(&mut core_reader, vertex_count, vertex_stride)?;
        let face_count = core_reader.count(5_000_000)?;
        let faces = read_faces(&mut core_reader, face_count)?;
        expand_geometry(&vertices, &faces, face_limit.unwrap_or(face_count))
    }
}

pub fn parse(bytes: &[u8]) -> Result<FileMeshData, String> {
    if bytes.len() < 13 || bytes.len() > 20_000_000 {
        return Err("FileMesh size is outside the supported range".to_string());
    }
    let header = std::str::from_utf8(&bytes[..12]).map_err(|error| error.to_string())?;
    if bytes[12] != b'\n' { return Err("Invalid FileMesh version header".to_string()); }
    let data = &bytes[13..];
    match header {
        "version 1.00" | "version 1.01" => decode_ascii(bytes, header),
        "version 2.00" => decode_v2_v3(data, false),
        "version 3.00" | "version 3.01" => decode_v2_v3(data, true),
        "version 4.00" | "version 4.01" => decode_v4_v5(data, false),
        "version 5.00" => decode_v4_v5(data, true),
        "version 6.00" => decode_chunked(data, false),
        "version 7.00" => decode_chunked(data, true),
        _ => Err(format!("Unsupported FileMesh version: {header}")),
    }
}


#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_ascii_filemesh_versions() {
        let data = "[0,0,0][0,0,1][0,0,0][1,0,0][0,0,1][1,0,0][0,1,0][0,0,1][0,1,0]";
        let version100 = format!("version 1.00\n1\n{data}");
        let version101 = format!("version 1.01\n1\n{data}");
        let first = parse(version100.as_bytes()).unwrap();
        let second = parse(version101.as_bytes()).unwrap();
        assert_eq!(first.positions[1], [0.5, 0.0, 0.0]);
        assert_eq!(second.positions[1], [1.0, 0.0, 0.0]);
        assert_eq!(second.uvs[2], [0.0, 0.0]);
    }

    #[test]
    fn parses_binary_filemesh_without_vertex_colors() {
        let mut bytes = b"version 2.00\n".to_vec();
        bytes.extend_from_slice(&12u16.to_le_bytes());
        bytes.extend_from_slice(&[36, 12]);
        bytes.extend_from_slice(&3u32.to_le_bytes());
        bytes.extend_from_slice(&1u32.to_le_bytes());
        for position in [[0.0f32, 0.0, 0.0], [1.0, 0.0, 0.0], [0.0, 1.0, 0.0]] {
            for value in [position[0], position[1], position[2], 0.0, 0.0, 1.0, 0.0, 0.0] {
                bytes.extend_from_slice(&value.to_le_bytes());
            }
            bytes.extend_from_slice(&[0; 4]);
        }
        for index in [0u32, 1, 2] {
            bytes.extend_from_slice(&index.to_le_bytes());
        }
        let mesh = parse(&bytes).unwrap();
        assert_eq!(mesh.positions.len(), 3);
        assert_eq!(mesh.positions[1], [1.0, 0.0, 0.0]);
        assert_eq!(mesh.colors, vec![[1.0; 4]; 3]);
    }
}


#[cfg(test)]
mod lod_tests {
    use super::*;

    fn vertex_bytes() -> Vec<u8> {
        let mut bytes = Vec::new();
        for position in [[0.0f32, 0.0, 0.0], [1.0, 0.0, 0.0], [0.0, 1.0, 0.0]] {
            for value in [position[0], position[1], position[2], 0.0, 0.0, 1.0, 0.0, 0.0] {
                bytes.extend_from_slice(&value.to_le_bytes());
            }
            bytes.extend_from_slice(&[0; 4]);
        }
        bytes
    }

    #[test]
    fn v3_uses_the_second_lod_offset_as_the_main_mesh_end() {
        let mut bytes = b"version 3.00\n".to_vec();
        bytes.extend_from_slice(&16u16.to_le_bytes());
        bytes.extend_from_slice(&[36, 12]);
        bytes.extend_from_slice(&4u16.to_le_bytes());
        bytes.extend_from_slice(&2u16.to_le_bytes());
        bytes.extend_from_slice(&3u32.to_le_bytes());
        bytes.extend_from_slice(&2u32.to_le_bytes());
        bytes.extend_from_slice(&vertex_bytes());
        for face in [[0u32, 1, 2], [0, 2, 1]] {
            for index in face {
                bytes.extend_from_slice(&index.to_le_bytes());
            }
        }
        bytes.extend_from_slice(&0u32.to_le_bytes());
        bytes.extend_from_slice(&1u32.to_le_bytes());
        let mesh = parse(&bytes).unwrap();
        assert_eq!(mesh.positions.len(), 3);
    }

    #[test]
    fn v4_infers_the_optional_color_vertex_stride() {
        let mut bytes = b"version 4.00\n".to_vec();
        bytes.extend_from_slice(&24u16.to_le_bytes());
        bytes.extend_from_slice(&0u16.to_le_bytes());
        bytes.extend_from_slice(&3u32.to_le_bytes());
        bytes.extend_from_slice(&1u32.to_le_bytes());
        bytes.extend_from_slice(&0u16.to_le_bytes());
        bytes.extend_from_slice(&0u16.to_le_bytes());
        bytes.extend_from_slice(&0u32.to_le_bytes());
        bytes.extend_from_slice(&0u16.to_le_bytes());
        bytes.extend_from_slice(&[0, 0]);
        bytes.extend_from_slice(&vertex_bytes());
        for index in [0u32, 1, 2] {
            bytes.extend_from_slice(&index.to_le_bytes());
        }
        let mesh = parse(&bytes).unwrap();
        assert_eq!(mesh.positions.len(), 3);
        assert_eq!(mesh.colors, vec![[1.0; 4]; 3]);
    }
}
