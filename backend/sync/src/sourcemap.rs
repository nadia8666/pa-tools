use std::{
    fs,
    path::{Path, PathBuf},
};

use serde::Deserialize;

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Node {
    name: String,
    class_name: String,
    #[serde(default)]
    file_paths: Vec<String>,
    #[serde(default)]
    children: Vec<Node>,
}

pub struct Entry {
    pub path: Vec<String>,
    pub class: String,
    pub file: PathBuf,
}

#[derive(Default)]
pub struct Map {
    pub classes: Vec<(Vec<String>, String)>,
    pub scripts: Vec<Entry>,
    pub dirs: Vec<(Vec<String>, PathBuf)>,
}

pub fn load(root: &Path, sourcemap: &Path) -> Option<Map> {
    let text = fs::read_to_string(sourcemap).ok()?;
    let node: Node = serde_json::from_str(&text).ok()?;
    let mut map = Map::default();
    for child in &node.children {
        walk(child, &mut Vec::new(), root, &mut map);
    }
    Some(map)
}

fn walk(node: &Node, prefix: &mut Vec<String>, root: &Path, map: &mut Map) {
    prefix.push(node.name.clone());
    map.classes.push((prefix.clone(), node.class_name.clone()));
    let mut has_dir = false;

    if matches!(node.class_name.as_str(), "Script" | "LocalScript" | "ModuleScript") {
        let file = node
            .file_paths
            .iter()
            .find(|p| p.ends_with(".luau") || p.ends_with(".lua"));
        if let Some(file) = file {
            let full = root.join(file);
            let is_init = full
                .file_name()
                .map_or(false, |n| n.to_string_lossy().starts_with("init."));
            if is_init {
                if let Some(parent) = full.parent() {
                    map.dirs.push((prefix.clone(), parent.to_path_buf()));
                    has_dir = true;
                }
            }
            map.scripts.push(Entry {
                path: prefix.clone(),
                class: node.class_name.clone(),
                file: full,
            });
        }
    }

    if let Some(dir) = node
        .file_paths
        .iter()
        .map(|p| root.join(p))
        .find(|p| p.is_dir())
    {
        map.dirs.push((prefix.clone(), dir));
        has_dir = true;
    }

    for child in &node.children {
        walk(child, prefix, root, map);
    }

    // A Folder made from a directory has no filePaths of its own in the sourcemap, so its
    // directory is read off its children instead.
    if !has_dir && node.class_name == "Folder" {
        if let Some(dir) = derive_dir(prefix, map) {
            map.dirs.push((prefix.clone(), dir));
        }
    }
    prefix.pop();
}

// The directory a Folder maps to, from what is inside it: a plain script file sits directly in it,
// and a child directory (an init script's or another Folder's) has it as its parent.
fn derive_dir(prefix: &[String], map: &Map) -> Option<PathBuf> {
    let is_child = |path: &Vec<String>| path.len() == prefix.len() + 1 && path.starts_with(prefix);
    for entry in &map.scripts {
        let init = entry
            .file
            .file_name()
            .map_or(false, |n| n.to_string_lossy().starts_with("init."));
        if is_child(&entry.path) && !init {
            return entry.file.parent().map(Path::to_path_buf);
        }
    }
    for (path, dir) in &map.dirs {
        if is_child(path) {
            return dir.parent().map(Path::to_path_buf);
        }
    }
    None
}
