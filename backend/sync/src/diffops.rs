use similar::{DiffOp, TextDiff};

use crate::state::Edit;

pub fn hash(text: &str) -> u32 {
    let mut h: u32 = 2166136261;
    for b in text.bytes() {
        h ^= b as u32;
        h = h.wrapping_mul(16777619);
    }
    h
}

fn line_starts(text: &str) -> Vec<usize> {
    let mut starts = vec![0];
    for (i, b) in text.bytes().enumerate() {
        if b == b'\n' {
            starts.push(i + 1);
        }
    }
    if starts.last() == Some(&text.len()) && starts.len() > 1 {
        starts.pop();
    }
    starts
}

fn offset(starts: &[usize], text: &str, line: usize) -> usize {
    starts.get(line).copied().unwrap_or(text.len())
}

pub fn edits(old: &str, new: &str) -> Vec<Edit> {
    let diff = TextDiff::from_lines(old, new);
    let old_starts = line_starts(old);
    let new_starts = line_starts(new);
    let mut out = Vec::new();

    for op in diff.ops() {
        let ((old_from, old_to), (new_from, new_to)) = match *op {
            DiffOp::Equal { .. } => continue,
            DiffOp::Delete { old_index, old_len, new_index } => {
                ((old_index, old_index + old_len), (new_index, new_index))
            }
            DiffOp::Insert { old_index, new_index, new_len } => {
                ((old_index, old_index), (new_index, new_index + new_len))
            }
            DiffOp::Replace { old_index, old_len, new_index, new_len } => {
                ((old_index, old_index + old_len), (new_index, new_index + new_len))
            }
        };
        let text_from = offset(&new_starts, new, new_from);
        let text_to = offset(&new_starts, new, new_to);
        let start = offset(&old_starts, old, old_from);
        let end = offset(&old_starts, old, old_to);
        out.push(Edit {
            start,
            end,
            removed: old[start..end].to_string(),
            text: new[text_from..text_to].to_string(),
        });
    }

    out.reverse();
    out
}
