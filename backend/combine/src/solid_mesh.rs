use std::error::Error;

type Result<T> = std::result::Result<T, Box<dyn Error + Send + Sync>>;

const MODEL_HEADER: &[u8] = b"<roblox!\x89\xff\r\n\x1a\n";
const SOLID_MESH_HEADER: &[u8] = b"SolidMesh\0\0\0\0";
const CSG_MDL_V5_HEADER: &[u8] = b"\x15\x7d\x29\x15\x75\x6c\x35\x04\x34\x69";

#[derive(Debug, PartialEq, serde::Serialize)]
pub struct SolidMesh {
    pub positions: Vec<[f32; 3]>,
    pub normals: Vec<[f32; 3]>,
    pub colors: Vec<[f32; 3]>,
    pub faces: Vec<u32>,
    pub face_normals: Vec<u32>,
    pub face_colors: Vec<u32>,
}

#[derive(Debug, PartialEq, serde::Serialize)]
pub struct CsgMdlV5 {
    pub positions: Vec<[f32; 3]>,
    pub normals: Vec<[f32; 3]>,
    pub colors: Vec<[u8; 4]>,
    pub normal_ids: Vec<u8>,
    pub uvs: Vec<[f32; 2]>,
    pub tangents: Vec<[f32; 3]>,
    pub faces: Vec<u32>,
}

#[derive(Debug, PartialEq, serde::Serialize)]
#[serde(tag = "format", content = "data")]
pub enum UnionMesh {
    SolidMesh(SolidMesh),
    CsgMdlV5(CsgMdlV5),
}

struct Reader<'a> {
    bytes: &'a [u8],
    offset: usize,
}

impl<'a> Reader<'a> {
    fn new(bytes: &'a [u8]) -> Self {
        Self { bytes, offset: 0 }
    }

    fn read(&mut self, length: usize) -> Result<&'a [u8]> {
        let end = self.offset.checked_add(length).ok_or("buffer offset overflow")?;
        let value = self.bytes.get(self.offset..end).ok_or_else(|| {
            format!(
                "unexpected end of buffer at byte {}: requested {} bytes from a {}-byte buffer",
                self.offset,
                length,
                self.bytes.len()
            )
        })?;
        self.offset = end;
        Ok(value)
    }

    fn skip(&mut self, length: usize) -> Result<()> {
        self.read(length).map(|_| ())
    }

    fn u8(&mut self) -> Result<u8> {
        Ok(self.read(1)?[0])
    }

    fn u16(&mut self) -> Result<u16> {
        Ok(u16::from_le_bytes(self.read(2)?.try_into()?))
    }

    fn u32(&mut self) -> Result<u32> {
        Ok(u32::from_le_bytes(self.read(4)?.try_into()?))
    }

    fn f32(&mut self) -> Result<f32> {
        Ok(f32::from_le_bytes(self.read(4)?.try_into()?))
    }
}

fn decompress_chunk(compressed: &[u8], expected_length: usize) -> Result<Vec<u8>> {
    let output = if compressed.starts_with(b"\x28\xb5\x2f\xfd") {
        zstd::stream::decode_all(compressed)?
    } else {
        let mut output = vec![0; expected_length];
        let written = lz4_flex::block::decompress_into(compressed, &mut output)?;
        if written != expected_length {
            return Err("LZ4 chunk decompressed to an unexpected length".into());
        }
        output
    };
    if output.len() != expected_length {
        return Err("compressed chunk decompressed to an unexpected length".into());
    }
    Ok(output)
}

fn shared_strings(serialized_model: &[u8]) -> Result<Vec<Vec<u8>>> {
    let mut reader = Reader::new(serialized_model);
    if reader.read(MODEL_HEADER.len())? != MODEL_HEADER {
        return Err("serialized instance data has an invalid RBXM header".into());
    }
    if reader.u16()? != 0 {
        return Err("unsupported RBXM model version".into());
    }
    reader.skip(16)?;

    let mut values = Vec::new();
    loop {
        let chunk_type: [u8; 4] = reader.read(4)?.try_into()?;
        let compressed_length = reader.u32()? as usize;
        let uncompressed_length = reader.u32()? as usize;
        reader.skip(4)?;
        if chunk_type == *b"END\0" {
            break;
        }
        let payload = reader.read(if compressed_length == 0 {
            uncompressed_length
        } else {
            compressed_length
        })?;
        let decoded = if compressed_length == 0 {
            payload.to_vec()
        } else {
            decompress_chunk(payload, uncompressed_length)?
        };
        if &chunk_type != b"SSTR" {
            continue;
        }
        let mut strings = Reader::new(&decoded);
        strings.u32()?;
        let count = strings.u32()? as usize;
        for _ in 0..count {
            strings.skip(16)?;
            let length = strings.u32()? as usize;
            values.push(strings.read(length)?.to_vec());
        }
    }
    Ok(values)
}

fn read_state_machine(reader: &mut Reader<'_>, count: usize) -> Result<Vec<u32>> {
    let mut index = 0i64;
    let mut indices = Vec::with_capacity(count);
    for _ in 0..count {
        let first = reader.u8()?;
        let delta = if first & 0x80 == 0 {
            if first & 0x40 == 0 {
                first as i64
            } else {
                ((first | 0x80) as i8) as i64
            }
        } else {
            let second = reader.u8()?;
            let third = reader.u8()?;
            (((first & 0x7f) as i64) << 16) | ((second as i64) << 8) | third as i64
        };
        index += delta;
        indices.push((index as u32) & 0x7fffff);
    }
    Ok(indices)
}

fn read_vectors(reader: &mut Reader<'_>, count: usize) -> Result<Vec<[f32; 3]>> {
    (0..count)
        .map(|_| Ok([reader.f32()?, reader.f32()?, reader.f32()?]))
        .collect()
}

fn read_quantized_vectors(reader: &mut Reader<'_>, count: usize) -> Result<Vec<[f32; 3]>> {
    let quantize = |value: i16| {
        let maximum = 32767.0f32;
        let range = 65536.0f32;
        let wrapped = ((value as f32 - maximum + 32768.0) % range + range) % range - 32768.0;
        wrapped / maximum
    };
    (0..count)
        .map(|_| {
            Ok([
                quantize(i16::from_le_bytes(reader.read(2)?.try_into()?)),
                quantize(i16::from_le_bytes(reader.read(2)?.try_into()?)),
                quantize(i16::from_le_bytes(reader.read(2)?.try_into()?)),
            ])
        })
        .collect()
}

fn read_csg_mdl_v5(bytes: &[u8]) -> Result<CsgMdlV5> {
    let mut reader = Reader::new(bytes);
    if reader.read(CSG_MDL_V5_HEADER.len())? != CSG_MDL_V5_HEADER {
        return Err("shared string is not a CSGMDLV5 buffer".into());
    }

    let position_count = reader.u16()? as usize;
    let positions = read_vectors(&mut reader, position_count)?;

    let normal_count = reader.u16()? as usize;
    let normal_bytes = reader.u32()? as usize;
    let normals = read_quantized_vectors(&mut reader, normal_count)?;
    if normal_bytes != normal_count * 6 {
        return Err("CSGMDLV5 normal data length is inconsistent".into());
    }

    let color_count = reader.u16()? as usize;
    let mut colors = Vec::with_capacity(color_count);
    for _ in 0..color_count {
        colors.push([reader.u8()?, reader.u8()?, reader.u8()?, reader.u8()?]);
    }

    let normal_id_count = reader.u16()? as usize;
    let mut normal_ids = Vec::with_capacity(normal_id_count);
    for _ in 0..normal_id_count {
        normal_ids.push(reader.u8()?);
    }

    let uv_count = reader.u16()? as usize;
    let mut uvs = Vec::with_capacity(uv_count);
    for _ in 0..uv_count {
        uvs.push([reader.f32()?, reader.f32()?]);
    }

    let tangent_count = reader.u16()? as usize;
    let tangent_bytes = reader.u32()? as usize;
    let tangents = read_quantized_vectors(&mut reader, tangent_count)?;
    if tangent_bytes != tangent_count * 6 {
        return Err("CSGMDLV5 tangent data length is inconsistent".into());
    }

    let vertex_count = reader.u32()? as usize;
    let vertex_data_length = reader.u32()? as usize;
    let vertex_data = reader.read(vertex_data_length)?;
    let mut encoded_indices = Reader::new(vertex_data);
    let mut faces = read_state_machine(&mut encoded_indices, vertex_count)?;

    let marker_count = reader.u8()? as usize;
    let mut markers = Vec::with_capacity(marker_count);
    for _ in 0..marker_count {
        markers.push(reader.u32()? as usize);
    }
    let marker_start = *markers.first().ok_or("CSGMDLV5 is missing its first range marker")?;
    let marker_end = *markers.get(1).ok_or("CSGMDLV5 is missing its second range marker")?;
    let has_collision_range = markers.get(2).is_some();

    if marker_start > faces.len() || marker_end > faces.len() || marker_start > marker_end {
        return Err("CSGMDLV5 contains invalid face range markers".into());
    }
    if marker_start != 0 {
        let original = faces.clone();
        for index in 0..original.len() - marker_start {
            faces[index] = original[index + marker_start];
        }
    }
    if !has_collision_range {
        let trim_count = marker_end - marker_start;
        if trim_count > faces.len() {
            return Err("CSGMDLV5 face range markers exceed the index data".into());
        }
        faces.truncate(faces.len() - trim_count);
    }
    if faces.len() % 3 != 0 || faces.iter().any(|index| *index as usize >= positions.len()) {
        return Err("CSGMDLV5 contains invalid triangle indices".into());
    }

    Ok(CsgMdlV5 {
        positions,
        normals,
        colors,
        normal_ids,
        uvs,
        tangents,
        faces,
    })
}

fn read_state_section(reader: &mut Reader<'_>) -> Result<Vec<u32>> {
    let count = reader.u32()? as usize;
    reader.u32()?;
    read_state_machine(reader, count)
}

pub fn parse_solid_mesh(bytes: &[u8]) -> Result<SolidMesh> {
    let mut reader = Reader::new(bytes);
    reader.skip(14)?;
    if reader.read(SOLID_MESH_HEADER.len())? != SOLID_MESH_HEADER {
        return Err("shared string is not a SolidMesh buffer".into());
    }

    let position_count = reader.u32()? as usize;
    reader.u32()?;
    let positions = read_vectors(&mut reader, position_count)?;

    let normal_count = reader.u32()? as usize;
    reader.u32()?;
    let normals = read_vectors(&mut reader, normal_count)?;

    let uv_count = reader.u32()? as usize;
    reader.u32()?;
    reader.skip(uv_count.checked_mul(8).ok_or("uv count overflow")?)?;

    let color_count = reader.u32()? as usize;
    reader.u32()?;
    let colors = read_vectors(&mut reader, color_count)?;

    let faces = read_state_section(&mut reader)?;
    let face_normals = read_state_section(&mut reader)?;
    let unknown_count = reader.u32()? as usize;
    reader.u32()?;
    if unknown_count != 0 {
        read_state_machine(&mut reader, unknown_count)?;
        return Err("SolidMesh contains an unrecognized per-face data channel".into());
    }
    let face_colors = read_state_section(&mut reader)?;

    if faces.len() % 3 != 0 {
        return Err("SolidMesh face index count is not divisible by three".into());
    }
    if faces.iter().any(|index| *index as usize >= positions.len()) {
        return Err("SolidMesh contains an out-of-range vertex index".into());
    }
    if face_normals.len() != faces.len() || face_colors.len() != faces.len() {
        return Err("SolidMesh corner attribute counts do not match its indices".into());
    }

    Ok(SolidMesh {
        positions,
        normals,
        colors,
        faces,
        face_normals,
        face_colors,
    })
}

pub fn extract_union_mesh(serialized_model: &[u8]) -> Result<UnionMesh> {
    let values = shared_strings(serialized_model)
        .map_err(|error| format!("could not read serialized union shared strings: {error}"))?;
    for value in values {
        if value.len() >= 14 + SOLID_MESH_HEADER.len()
            && value.get(14..14 + SOLID_MESH_HEADER.len()) == Some(SOLID_MESH_HEADER)
        {
            return parse_solid_mesh(&value)
                .map(UnionMesh::SolidMesh)
                .map_err(|error| format!("could not parse serialized SolidMesh union: {error}").into());
        }
        if value.starts_with(CSG_MDL_V5_HEADER) {
            return read_csg_mdl_v5(&value)
                .map(UnionMesh::CsgMdlV5)
                .map_err(|error| format!("could not parse serialized CSGMDLV5 union: {error}").into());
        }
    }
    Err("serialized union did not contain a recognized SolidMesh or CSGMDLV5 shared string".into())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn decodes_signed_delta_indices() {
        let bytes = [1, 1, 0x7f, 0x80, 0, 1];
        let mut reader = Reader::new(&bytes);
        assert_eq!(read_state_machine(&mut reader, 4).unwrap(), vec![1, 2, 1, 2]);
    }

    #[test]
    fn reads_state_sections_from_the_parent_stream() {
        let mut bytes = Vec::new();
        bytes.extend_from_slice(&3u32.to_le_bytes());
        bytes.extend_from_slice(&0u32.to_le_bytes());
        bytes.extend_from_slice(&[1, 1, 1]);
        let mut reader = Reader::new(&bytes);
        assert_eq!(read_state_section(&mut reader).unwrap(), vec![1, 2, 3]);
        assert_eq!(reader.offset, bytes.len());
    }

    #[test]
    fn rejects_invalid_solid_mesh_header() {
        assert!(parse_solid_mesh(&[0; 64]).is_err());
    }
}
