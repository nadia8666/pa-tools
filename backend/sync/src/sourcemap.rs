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
    }

    for child in &node.children {
        walk(child, prefix, root, map);
    }
    prefix.pop();
}
