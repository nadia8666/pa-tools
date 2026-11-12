use std::{
    collections::{BTreeMap, BTreeSet, HashMap, HashSet, VecDeque},
    fs,
    path::{Path as FsPath, PathBuf},
    time::{Duration, Instant, SystemTime},
};

use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::{diffops, sourcemap};

pub type InstancePath = Vec<String>;

type Attrs = BTreeMap<String, Value>;

#[derive(Serialize, Deserialize)]
pub struct AttrEntry {
    pub name: String,
    pub value: Value,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AttrReport {
    pub path: InstancePath,
    #[serde(default)]
    pub attributes: Vec<AttrEntry>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct AttrCommand {
    pub path: InstancePath,
    pub set: Vec<AttrEntry>,
    pub remove: Vec<String>,
}

const MAX_BULK_DELETE: usize = 15;
const DELETE_GRACE: Duration = Duration::from_millis(1500);
const REVERT_WINDOW: Duration = Duration::from_secs(10);
const MAX_REVERTS: u8 = 3;
const SCAN_INTERVAL: Duration = Duration::from_secs(1);
// A changed file is only believed once it reads the same on two polls this far apart, so a
// half-written save or a git checkout caught in the middle of a file isn't pushed to Studio.
const DISK_SETTLE: Duration = Duration::from_millis(200);
// An editor truncating a file before writing it reads as an empty file for a moment.
const EMPTY_SETTLE: Duration = Duration::from_millis(1500);
// While git holds the index lock (checkout, pull, rebase, stash...) nothing is pushed, and for a
// moment after it lets go.
const GIT_SETTLE: Duration = Duration::from_millis(800);
// A lock file left behind by a crashed git must not stop syncing for good.
const GIT_MAX_HOLD: Duration = Duration::from_secs(30);
// Scripts made or moved in Studio wait this long for the scripts above them to exist.
const DEFER_TTL: Duration = Duration::from_secs(15);
// Texts remembered per script that went to Studio through this backend. Studio showing one of
// them is not a Studio edit.
const PUSHED_KEEP: usize = 16;

#[derive(Deserialize)]
pub struct Report {
    pub path: InstancePath,
    pub source: String,
}

#[derive(Deserialize)]
pub struct Ack {
    pub id: u64,
    pub ok: bool,
    #[serde(default)]
    pub halt: bool,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Created {
    pub path: InstancePath,
    #[serde(default)]
    pub classes: Vec<String>,
    pub class_name: String,
    #[serde(default)]
    pub run_context: String,
    pub source: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Moved {
    pub from: InstancePath,
    pub path: InstancePath,
    #[serde(default)]
    pub classes: Vec<String>,
    pub class_name: String,
    #[serde(default)]
    pub run_context: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SyncRequest {
    #[serde(default)]
    pub hello: bool,
    #[serde(default, rename = "placeId")]
    pub place_id: Option<u64>,
    #[serde(default)]
    pub reports: Vec<Report>,
    #[serde(default)]
    pub acks: Vec<Ack>,
    #[serde(default)]
    pub resume: bool,
    #[serde(default)]
    pub created: Vec<Created>,
    #[serde(default)]
    pub deleted: Vec<InstancePath>,
    #[serde(default)]
    pub moved: Vec<Moved>,
    #[serde(default)]
    pub missing: Vec<InstancePath>,
    #[serde(default)]
    pub attr_reports: Vec<AttrReport>,
    #[serde(default)]
    pub refused: Vec<Refused>,
}

#[derive(Serialize, Clone)]
pub struct Edit {
    pub start: usize,
    pub end: usize,
    pub removed: String,
    pub text: String,
}

#[derive(Serialize)]
pub struct Event {
    pub path: InstancePath,
    pub edits: Vec<Edit>,
}

#[derive(Serialize, Clone)]
#[serde(rename_all = "camelCase")]
pub struct Command {
    pub id: u64,
    pub path: InstancePath,
    pub expect_hash: u32,
    pub target_hash: u32,
    pub edits: Vec<Edit>,
}

// What Studio should make an instance above a new script as: the sourcemap's class, an entry in
// psync.overrides.json, or the synced script that sits there. Folder only as the last resort.
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ParentSpec {
    pub class_name: String,
    pub run_context: String,
}

// A create Studio could not carry out (a script it won't hold); it stops being tracked.
#[derive(Deserialize)]
pub struct Refused {
    pub path: InstancePath,
    #[serde(default)]
    pub reason: String,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Create {
    pub path: InstancePath,
    pub parents: Vec<ParentSpec>,
    pub class_name: String,
    pub run_context: String,
    pub file: String,
    pub source: String,
}

#[derive(Serialize)]
pub struct Deleted {
    pub path: InstancePath,
    pub file: String,
}

#[derive(Serialize)]
pub struct Notice {
    pub origin: &'static str,
    pub path: InstancePath,
    pub kind: &'static str,
    pub file: String,
    pub text: String,
    pub detail: String,
}

#[derive(Serialize)]
pub struct SyncResponse {
    pub rev: u64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub tracked: Option<Vec<InstancePath>>,
    pub commands: Vec<Command>,
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub events: Vec<Event>,
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub creates: Vec<Create>,
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub deletes: Vec<Deleted>,
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub notices: Vec<Notice>,
    #[serde(rename = "attrCommands", skip_serializing_if = "Vec::is_empty")]
    pub attr_commands: Vec<AttrCommand>,
    pub paused: bool,
    pub ignored: bool,
    pub message: String,
}

#[derive(Default)]
pub struct Client {
    rev: u64,
    message: String,
    ignored: bool,
    ignored_message: String,
}

struct Pending {
    command: Command,
    target: String,
    old: String,
    sent: bool,
}

struct Recent {
    old: String,
    target: String,
    at: Instant,
    tries: u8,
}

// Something made or moved in Studio that has to wait for the scripts above it.
enum Item {
    Create(Created),
    Move(Moved),
}

struct Deferred {
    first_seen: Instant,
    item: Item,
}

struct Script {
    path: InstancePath,
    class: String,
    run_context: String,
    missing_since: Option<Instant>,
    file: PathBuf,
    base_file: PathBuf,
    base: Option<String>,
    disk: String,
    studio: Option<String>,
    pending: Option<Pending>,
    conflict: Option<String>,
    attr_disk: Attrs,
    attr_studio: Option<Attrs>,
    attr_base: Attrs,
    attr_pending: Option<Attrs>,
    recent: Option<Recent>,
    // Texts this backend pushed to Studio or replaced there (length and hash).
    pushed: VecDeque<(usize, u32)>,
    // What a changed file read as last poll, and since when. It becomes `disk` once it holds still.
    settling: Option<(String, Instant)>,
    // The command that was out when the connection dropped. Studio may have applied it unheard.
    lost: Option<(usize, u32)>,
}

fn read(file: &FsPath) -> Option<String> {
    fs::read_to_string(file).ok().map(|s| s.replace("\r\n", "\n"))
}

fn fingerprint(text: &str) -> (usize, u32) {
    (text.len(), diffops::hash(text))
}

// The git directory of the repository around `start`, if there is one.
fn find_git_dir(start: &FsPath) -> Option<PathBuf> {
    let start = fs::canonicalize(start).unwrap_or_else(|_| start.to_path_buf());
    for dir in start.ancestors() {
        let dot = dir.join(".git");
        if dot.is_dir() {
            return Some(dot);
        }
        if dot.is_file() {
            // A worktree or submodule: ".git" is a file pointing at the real directory.
            let text = fs::read_to_string(&dot).ok()?;
            let target = PathBuf::from(text.trim().strip_prefix("gitdir:")?.trim());
            return Some(if target.is_absolute() { target } else { dir.join(target) });
        }
    }
    None
}

fn has_markers(text: &str) -> bool {
    text.lines()
        .any(|l| l.starts_with("<<<<<<<") || l.starts_with(">>>>>>>"))
}

fn normalize(v: &Value) -> Value {
    match v {
        Value::Number(n) => n.as_f64().map_or_else(|| v.clone(), |f| serde_json::json!(f)),
        Value::Array(a) => Value::Array(a.iter().map(normalize).collect()),
        Value::Object(o) => Value::Object(o.iter().map(|(k, v)| (k.clone(), normalize(v))).collect()),
        _ => v.clone(),
    }
}

fn tidy(v: &Value) -> Value {
    match v {
        Value::Number(n) => match n.as_f64() {
            Some(f) if f.fract() == 0.0 && f.abs() < 9.0e15 => serde_json::json!(f as i64),
            _ => v.clone(),
        },
        Value::Array(a) => Value::Array(a.iter().map(tidy).collect()),
        Value::Object(o) => Value::Object(o.iter().map(|(k, v)| (k.clone(), tidy(v))).collect()),
        _ => v.clone(),
    }
}

fn valid_value(v: &Value) -> bool {
    match v {
        Value::Bool(_) | Value::String(_) | Value::Number(_) => true,
        Value::Object(o) if o.len() == 1 => {
            let Some((kind, inner)) = o.iter().next() else {
                return false;
            };
            let want = match kind.as_str() {
                "Vector3" | "Color3" => 3,
                "Vector2" => 2,
                _ => return false,
            };
            matches!(inner, Value::Array(a) if a.len() == want && a.iter().all(Value::is_number))
        }
        _ => false,
    }
}

fn attrs_from(entries: &[AttrEntry]) -> Attrs {
    let mut out = Attrs::new();
    for entry in entries {
        if valid_value(&entry.value) {
            out.insert(entry.name.clone(), normalize(&entry.value));
        } else {
            println!("ignored unsupported attribute {}", entry.name);
        }
    }
    out
}

fn read_meta(path: &FsPath) -> Option<Attrs> {
    let text = match fs::read_to_string(path) {
        Ok(text) => text,
        Err(_) if !path.exists() => return Some(Attrs::new()),
        Err(_) => return None,
    };
    let value: Value = serde_json::from_str(&text).ok()?;
    let mut out = Attrs::new();
    match value.get("attributes") {
        None | Some(Value::Null) => {}
        Some(Value::Object(entries)) => {
            for (name, v) in entries {
                if valid_value(v) {
                    out.insert(name.clone(), normalize(v));
                } else {
                    println!("ignored unsupported attribute {name} in {}", path.display());
                }
            }
        }
        Some(_) => return None,
    }
    Some(out)
}

fn write_meta(path: &FsPath, attrs: &Attrs) -> std::io::Result<()> {
    if attrs.is_empty() {
        return match fs::remove_file(path) {
            Err(e) if e.kind() != std::io::ErrorKind::NotFound => Err(e),
            _ => Ok(()),
        };
    }
    let tidied: Attrs = attrs.iter().map(|(k, v)| (k.clone(), tidy(v))).collect();
    let text = serde_json::to_string_pretty(&serde_json::json!({ "attributes": tidied }))
        .map_err(std::io::Error::other)?;
    fs::write(path, text + "\n")
}

fn read_attrs(path: &FsPath) -> Option<Attrs> {
    serde_json::from_str(&fs::read_to_string(path).ok()?).ok()
}

fn write_attrs(path: &FsPath, attrs: &Attrs) {
    if let Some(parent) = path.parent() {
        let _ = fs::create_dir_all(parent);
    }
    if let Ok(text) = serde_json::to_string(attrs) {
        let _ = fs::write(path, text);
    }
}

fn meta_path(file: &FsPath) -> Option<PathBuf> {
    let name = file.file_name()?.to_string_lossy().to_string();
    let (stem, _, _) = parse_script_file(&name)?;
    Some(file.with_file_name(format!("{stem}.meta.json")))
}

fn merge_attrs(base: &Attrs, disk: &Attrs, studio: &Attrs) -> (Attrs, Vec<String>) {
    let mut keys: BTreeSet<&String> = BTreeSet::new();
    keys.extend(base.keys());
    keys.extend(disk.keys());
    keys.extend(studio.keys());
    let mut out = Attrs::new();
    let mut conflicts = Vec::new();
    for k in keys {
        let (b, d, s) = (base.get(k), disk.get(k), studio.get(k));
        let pick: Option<&Value> = if d == s {
            d
        } else if s == b {
            d
        } else if d == b {
            s
        } else {
            conflicts.push(k.clone());
            d
        };
        if let Some(v) = pick {
            out.insert(k.clone(), v.clone());
        }
    }
    (out, conflicts)
}

fn signed(sign: char, text: &str) -> String {
    text.lines()
        .map(|l| format!("{sign} {l}"))
        .collect::<Vec<_>>()
        .join("\n")
}

fn attr_diff(old: &Attrs, new: &Attrs) -> String {
    let mut keys: BTreeSet<&String> = BTreeSet::new();
    keys.extend(old.keys());
    keys.extend(new.keys());
    let mut lines = Vec::new();
    for k in keys {
        match (old.get(k), new.get(k)) {
            (None, Some(n)) => lines.push(format!("+ {k}: {n}")),
            (Some(o), None) => lines.push(format!("- {k}: {o}")),
            (Some(o), Some(n)) if o != n => lines.push(format!("~ {k}: {o} -> {n}")),
            _ => {}
        }
    }
    lines.join("\n")
}

fn key(path: &[String]) -> String {
    path.join("\u{1f}")
}

fn parse_script_file(name: &str) -> Option<(String, &'static str, &'static str)> {
    const SUFFIXES: [(&str, &str, &str); 12] = [
        (".server.luau", "Script", "Server"),
        (".server.lua", "Script", "Server"),
        (".client.luau", "Script", "Client"),
        (".client.lua", "Script", "Client"),
        (".local.luau", "LocalScript", ""),
        (".local.lua", "LocalScript", ""),
        (".legacy.luau", "Script", "Legacy"),
        (".legacy.lua", "Script", "Legacy"),
        (".plugin.luau", "Script", "Plugin"),
        (".plugin.lua", "Script", "Plugin"),
        (".luau", "ModuleScript", ""),
        (".lua", "ModuleScript", ""),
    ];
    for (suffix, class, run_context) in SUFFIXES {
        if let Some(stem) = name.strip_suffix(suffix) {
            if stem.is_empty() {
                return None;
            }
            return Some((stem.to_string(), class, run_context));
        }
    }
    None
}

fn suffix(class: &str, run_context: &str) -> Result<&'static str, String> {
    match (class, run_context) {
        ("ModuleScript", _) => Ok(".luau"),
        ("LocalScript", _) => Ok(".local.luau"),
        ("Script", "Client") => Ok(".client.luau"),
        ("Script", "Legacy") => Ok(".legacy.luau"),
        ("Script", "Plugin") => Ok(".plugin.luau"),
        ("Script", _) => Ok(".server.luau"),
        (other, _) => Err(format!("unsupported class {other}")),
    }
}

fn find_init(dir: &FsPath) -> Option<(PathBuf, &'static str, &'static str)> {
    for entry in fs::read_dir(dir).ok()?.flatten() {
        let name = entry.file_name().to_string_lossy().to_string();
        if let Some((stem, class, run_context)) = parse_script_file(&name) {
            if stem == "init" {
                return Some((entry.path(), class, run_context));
            }
        }
    }
    None
}

fn valid_name(name: &str) -> bool {
    !name.is_empty()
        && !name.starts_with('.')
        && !name.ends_with(' ')
        && !name.chars().any(|c| "/\\:*?\"<>|".contains(c) || c.is_control())
}

impl Script {
    fn set_base(&mut self, text: String) {
        if self.base.as_deref() == Some(text.as_str()) {
            return;
        }
        if let Some(parent) = self.base_file.parent() {
            let _ = fs::create_dir_all(parent);
        }
        let _ = fs::write(&self.base_file, &text);
        self.base = Some(text);
    }

    fn write_disk(&mut self, text: &str) {
        if fs::write(&self.file, text).is_ok() {
            self.disk = text.to_string();
        }
    }

    // Remembers a text that went to or was replaced in Studio through this backend.
    fn remember(&mut self, text: &str) {
        let print = fingerprint(text);
        if let Some(i) = self.pushed.iter().position(|p| *p == print) {
            self.pushed.remove(i);
        }
        self.pushed.push_back(print);
        while self.pushed.len() > PUSHED_KEEP {
            self.pushed.pop_front();
        }
    }

    fn is_ours(&self, text: &str) -> bool {
        self.pushed.contains(&fingerprint(text))
    }

    // One line for the console when a conflict happens, so the cause can be read off it.
    fn describe(&self) -> String {
        fn show(label: &str, text: Option<&str>) -> String {
            match text {
                Some(t) => format!("{label} {}b/{:08x}", t.len(), diffops::hash(t)),
                None => format!("{label} none"),
            }
        }
        let recent = match &self.recent {
            Some(r) => format!("{}s ago, {} reverts", r.at.elapsed().as_secs(), r.tries),
            None => "none".to_string(),
        };
        format!(
            "{}, {}, {}, studio is a text we pushed: {}, last ack: {recent}",
            show("base", self.base.as_deref()),
            show("disk", Some(self.disk.as_str())),
            show("studio", self.studio.as_deref()),
            self.studio.as_deref().map_or(false, |s| self.is_ours(s)),
        )
    }

    // The three texts of the last conflict per script, in <project>/.sync/conflicts/.
    fn dump_conflict(&self, base: &str, studio: &str) {
        let Some(sync) = self.base_file.parent().and_then(|p| p.parent()) else {
            return;
        };
        let dir = sync.join("conflicts");
        if fs::create_dir_all(&dir).is_err() {
            return;
        }
        let Some(name) = self.base_file.file_name().map(|n| n.to_string_lossy().to_string()) else {
            return;
        };
        let _ = fs::write(dir.join(format!("{name}.base")), base);
        let _ = fs::write(dir.join(format!("{name}.disk")), &self.disk);
        let _ = fs::write(dir.join(format!("{name}.studio")), studio);
    }

    fn push(&mut self, current: &str, target: String, next_id: &mut u64) {
        self.remember(current);
        self.remember(&target);
        let id = *next_id;
        *next_id += 1;
        let command = Command {
            id,
            path: self.path.clone(),
            expect_hash: diffops::hash(current),
            target_hash: diffops::hash(&target),
            edits: diffops::edits(current, &target),
        };
        self.pending = Some(Pending { command, target, old: current.to_string(), sent: false });
    }

    fn reconcile(&mut self, next_id: &mut u64, events: &mut Vec<Event>) -> bool {
        if self.pending.is_some() {
            return false;
        }
        let Some(studio) = self.studio.clone() else {
            return false;
        };
        // The connection dropped with a command out: Studio may have applied it without us hearing.
        // What Studio shows is then what was last synced.
        if let Some(lost) = self.lost.take() {
            if fingerprint(&studio) == lost {
                self.set_base(studio.clone());
            }
        }
        let base = match self.base.clone() {
            Some(base) => base,
            None => {
                self.set_base(studio.clone());
                studio.clone()
            }
        };

        if self.disk == studio {
            self.set_base(studio);
            return false;
        }
        if studio == base {
            let target = self.disk.clone();
            self.push(&studio, target, next_id);
            return false;
        }
        if self.disk == base {
            events.push(Event {
                path: self.path.clone(),
                edits: diffops::edits(&self.disk, &studio),
            });
            self.write_disk(&studio);
            self.set_base(studio);
            return false;
        }

        // Both sides moved. If Studio only shows a text this backend pushed earlier (a report that
        // overtook an ack), Studio was never edited: disk is simply the newer side.
        if self.is_ours(&studio) {
            let target = self.disk.clone();
            self.push(&studio, target, next_id);
            return false;
        }

        match diffy::merge(&base, &self.disk, &studio) {
            Ok(merged) => {
                events.push(Event {
                    path: self.path.clone(),
                    edits: diffops::edits(&self.disk, &merged),
                });
                self.write_disk(&merged);
                self.push(&studio, merged, next_id);
                false
            }
            Err(marked) => {
                println!("conflict details {}: {}", self.path.join("/"), self.describe());
                self.dump_conflict(&base, &studio);
                self.write_disk(&marked);
                self.conflict = Some(studio);
                true
            }
        }
    }
}

pub struct State {
    root: PathBuf,
    sourcemap: PathBuf,
    sourcemap_stamp: Option<SystemTime>,
    scripts: HashMap<String, Script>,
    rev: u64,
    next_id: u64,
    paused: bool,
    halt: Option<String>,
    events: Vec<Event>,
    active: u64,
    attr_cmds: Vec<AttrCommand>,
    last_meta: Instant,
    dirs: HashMap<String, (InstancePath, PathBuf)>,
    seen_new: HashMap<PathBuf, u8>,
    ignored: HashSet<PathBuf>,
    last_scan: Instant,
    mass_warned: bool,
    creates: Vec<Create>,
    deletes: Vec<Deleted>,
    notices: Vec<Notice>,
    git_dir: Option<PathBuf>,
    git_busy_since: Option<Instant>,
    git_hold_until: Option<Instant>,
    reconcile_dirty: bool,
    deferred: Vec<Deferred>,
    node_classes: HashMap<String, String>,
    overrides: HashMap<String, (String, String)>,
    overrides_stamp: Option<SystemTime>,
    authorized: bool,
    place_id: Option<u64>,
}

impl State {
    pub fn new(root: PathBuf, sourcemap: PathBuf) -> State {
        let git_dir = find_git_dir(&root);
        let mut state = State {
            root,
            sourcemap,
            sourcemap_stamp: None,
            scripts: HashMap::new(),
            rev: 0,
            next_id: 1,
            paused: false,
            halt: None,
            events: Vec::new(),
            active: 0,
            attr_cmds: Vec::new(),
            last_meta: Instant::now(),
            dirs: HashMap::new(),
            seen_new: HashMap::new(),
            ignored: HashSet::new(),
            last_scan: Instant::now(),
            mass_warned: false,
            creates: Vec::new(),
            deletes: Vec::new(),
            notices: Vec::new(),
            git_dir,
            git_busy_since: None,
            git_hold_until: None,
            reconcile_dirty: false,
            deferred: Vec::new(),
            node_classes: HashMap::new(),
            overrides: HashMap::new(),
            overrides_stamp: None,
            authorized: false,
            place_id: None,
        };
        state.refresh_sourcemap();
        state
    }

    fn base_file(&self, file: &FsPath) -> PathBuf {
        let name: String = file
            .strip_prefix(&self.root)
            .unwrap_or(file)
            .to_string_lossy()
            .chars()
            .map(|c| if c.is_alphanumeric() || c == '.' { c } else { '_' })
            .collect();
        self.root.join(".sync").join("base").join(name)
    }

    fn make_script(
        &self,
        path: InstancePath,
        class: &str,
        run_context: &str,
        file: PathBuf,
        disk: String,
        studio: Option<String>,
    ) -> Script {
        let base_file = self.base_file(&file);
        let attr_base_file = self.attr_base_file(&file);
        let attr_disk = meta_path(&file).and_then(|m| read_meta(&m)).unwrap_or_default();
        let attr_base = read_attrs(&attr_base_file).unwrap_or_default();
        Script {
            path,
            class: class.to_string(),
            run_context: run_context.to_string(),
            missing_since: None,
            base: fs::read_to_string(&base_file).ok(),
            base_file,
            file,
            disk,
            studio,
            pending: None,
            conflict: None,
            attr_disk,
            attr_studio: None,
            attr_base,
            attr_pending: None,
            recent: None,
            pushed: VecDeque::new(),
            settling: None,
            lost: None,
        }
    }

    // True while git is rewriting the working tree (it holds index.lock for the whole checkout,
    // pull, rebase or stash) and for a moment after: files change one after another and half of
    // them aren't in their final state yet.
    fn git_holding(&mut self) -> bool {
        let Some(dir) = self.git_dir.clone() else {
            return false;
        };
        let now = Instant::now();
        if dir.join("index.lock").exists() {
            let since = *self.git_busy_since.get_or_insert(now);
            if now.duration_since(since) >= GIT_MAX_HOLD {
                // A lock left behind by a crashed git must not stop syncing for good.
                return false;
            }
            self.git_hold_until = Some(now + GIT_SETTLE);
            return true;
        }
        self.git_busy_since = None;
        self.git_hold_until.map_or(false, |until| now < until)
    }

    // Whether a script above `path` that isn't synced yet is still to come: a tree made in Studio
    // arrives in whatever order Studio listed it, and a script can only go inside its parent.
    fn ancestor_pending(&self, path: &[String], classes: &[String]) -> bool {
        let parent_len = path.len().saturating_sub(1);
        let mut start = parent_len;
        while start > 0 && !self.dirs.contains_key(&key(&path[..start])) {
            start -= 1;
        }
        if start == 0 {
            return false;
        }
        (start..parent_len).any(|j| {
            matches!(classes.get(j).map(String::as_str), Some("Script" | "LocalScript" | "ModuleScript"))
                && !self.scripts.contains_key(&key(&path[..=j]))
        })
    }

    fn retry_deferred(&mut self) {
        if self.deferred.is_empty() {
            return;
        }
        let mut waiting = std::mem::take(&mut self.deferred);
        waiting.sort_by_key(|d| match &d.item {
            Item::Create(c) => c.path.len(),
            Item::Move(m) => m.path.len(),
        });
        for entry in waiting {
            match entry.item {
                Item::Create(created) => self.create_from_studio(created, entry.first_seen),
                Item::Move(moved) => self.move_from_studio(moved, entry.first_seen),
            }
        }
    }

    // psync.overrides.json in the project root: instance path -> class, for the instances above
    // scripts that the sourcemap and the files can't tell the class of. Either
    //   "ReplicatedStorage/DevExplorer": "ModuleScript"
    // or
    //   "ServerScriptService/Admin": { "class": "Script", "runContext": "Legacy" }
    fn refresh_overrides(&mut self) {
        let file = self.root.join("psync.overrides.json");
        let stamp = fs::metadata(&file).and_then(|m| m.modified()).ok();
        if stamp == self.overrides_stamp {
            return;
        }
        self.overrides_stamp = stamp;
        self.overrides.clear();
        let Ok(text) = fs::read_to_string(&file) else {
            return;
        };
        let Ok(Value::Object(entries)) = serde_json::from_str::<Value>(&text) else {
            println!("psync.overrides.json is not a JSON object, ignored");
            return;
        };
        for (path, spec) in entries {
            let (class, run_context) = match &spec {
                Value::String(class) => (class.clone(), String::new()),
                Value::Object(o) => (
                    o.get("class").and_then(Value::as_str).unwrap_or("").to_string(),
                    o.get("runContext").and_then(Value::as_str).unwrap_or("").to_string(),
                ),
                _ => continue,
            };
            if class.is_empty() {
                continue;
            }
            let parts: Vec<String> = path.split('/').filter(|p| !p.is_empty()).map(String::from).collect();
            self.overrides.insert(key(&parts), (class, run_context));
        }
        println!("overrides: {} entries", self.overrides.len());
    }

    // The class of every instance above `path`, so Studio makes the ones that don't exist yet as
    // what they are instead of guessing Folder. Element n of the result is `path[n]`, counting from 0.
    fn parent_specs(&self, path: &[String]) -> Vec<ParentSpec> {
        (1..path.len())
            .map(|n| {
                let k = key(&path[..n]);
                let (class, run_context) = if let Some((class, rc)) = self.overrides.get(&k) {
                    (class.clone(), rc.clone())
                } else if let Some(script) = self.scripts.get(&k) {
                    (script.class.clone(), script.run_context.clone())
                } else if let Some(class) = self.node_classes.get(&k) {
                    (class.clone(), String::new())
                } else {
                    ("Folder".to_string(), String::new())
                };
                ParentSpec { class_name: class, run_context }
            })
            .collect()
    }

    fn refused_by_studio(&mut self, refused: Refused) {
        let Some(script) = self.scripts.remove(&key(&refused.path)) else {
            return;
        };
        let rel = self.rel(&script.file);
        println!("not synced, Studio refused {rel}: {}", refused.reason);
        self.ignored.insert(script.file.clone());
        let _ = fs::remove_file(&script.base_file);
        self.rev += 1;
        let text = format!("Not synced, Studio refused it: {}", refused.reason);
        self.notice("ERR", &refused.path, "err", String::new(), text);
    }

    fn rel(&self, file: &FsPath) -> String {
        file.strip_prefix(&self.root)
            .unwrap_or(file)
            .to_string_lossy()
            .replace('\\', "/")
    }

    fn notice(
        &mut self,
        origin: &'static str,
        path: &[String],
        kind: &'static str,
        file: String,
        text: String,
    ) {
        self.notices.push(Notice { origin, path: path.to_vec(), kind, file, text, detail: String::new() });
    }

    fn set_detail(&mut self, detail: String) {
        if let Some(n) = self.notices.last_mut() {
            n.detail = detail;
        }
    }

    fn refresh_sourcemap(&mut self) {
        let stamp = fs::metadata(&self.sourcemap).and_then(|m| m.modified()).ok();
        if stamp.is_none() || stamp == self.sourcemap_stamp {
            return;
        }
        let Some(map) = sourcemap::load(&self.root, &self.sourcemap) else {
            return;
        };
        self.sourcemap_stamp = stamp;

        for (path, class) in map.classes {
            self.node_classes.insert(key(&path), class);
        }
        for (path, dir) in map.dirs {
            self.dirs.entry(key(&path)).or_insert((path, dir));
        }

        let mut counts: HashMap<String, usize> = HashMap::new();
        for entry in &map.scripts {
            *counts.entry(key(&entry.path)).or_default() += 1;
        }

        for entry in map.scripts {
            let k = key(&entry.path);
            if counts[&k] > 1 {
                println!("skipped (duplicate instance path): {}", entry.path.join("/"));
                continue;
            }
            if self.scripts.contains_key(&k) || self.ignored.contains(&entry.file) {
                continue;
            }
            let Some(disk) = read(&entry.file) else {
                println!("skipped (unreadable or not UTF-8): {}", entry.file.display());
                continue;
            };
            let (class, run_context) = entry
                .file
                .file_name()
                .and_then(|n| parse_script_file(&n.to_string_lossy()))
                .map_or((entry.class.as_str(), ""), |(_, class, rc)| (class, rc));
            let script = self.make_script(entry.path.clone(), class, run_context, entry.file.clone(), disk, None);
            self.scripts.insert(k, script);
        }
        self.rev += 1;
        println!("tracking {} scripts", self.scripts.len());
    }

    fn attr_base_file(&self, file: &FsPath) -> PathBuf {
        let mut name = self.base_file(file).into_os_string();
        name.push(".attrs");
        PathBuf::from(name)
    }

    fn remove_sidecars(&self, file: &FsPath) {
        if let Some(meta) = meta_path(file) {
            let _ = fs::remove_file(meta);
        }
        let _ = fs::remove_file(self.attr_base_file(file));
    }

    fn reconcile_attrs(&mut self, key: &str) {
        let Some(script) = self.scripts.get(key) else {
            return;
        };
        let Some(studio) = script.attr_studio.clone() else {
            return;
        };
        let disk = script.attr_disk.clone();
        let base = script.attr_base.clone();
        let path = script.path.clone();
        let file = script.file.clone();

        let (result, conflicts) = merge_attrs(&base, &disk, &studio);
        let attr_base_path = self.attr_base_file(&file);
        let meta = meta_path(&file);
        let meta_rel = meta.as_ref().map(|m| self.rel(m)).unwrap_or_default();

        if !conflicts.is_empty() {
            let text = format!("attribute conflict on {}, kept the file value", conflicts.join(", "));
            self.notice("ERR", &path, "err", String::new(), text);
        }

        let mut disk_now = disk.clone();
        if result != disk {
            let Some(meta_file) = &meta else {
                return;
            };
            if let Err(e) = write_meta(meta_file, &result) {
                let text = format!("could not write {meta_rel}: {e}");
                self.notice("ERR", &path, "err", String::new(), text);
                return;
            }
            if result == studio {
                let text = format!("~ attributes saved to {meta_rel}");
                self.notice("RBX", &path, "attr", meta_rel.clone(), text);
                self.set_detail(attr_diff(&disk, &result));
            }
            disk_now = result.clone();
            if let Some(script) = self.scripts.get_mut(key) {
                script.attr_disk = result.clone();
            }
        }

        let mut outgoing: Option<AttrCommand> = None;
        if let Some(script) = self.scripts.get_mut(key) {
            if result == studio && result == disk_now {
                script.attr_pending = None;
                if script.attr_base != result {
                    script.attr_base = result.clone();
                    write_attrs(&attr_base_path, &result);
                }
            } else if result != studio && script.attr_pending.as_ref() != Some(&result) {
                script.attr_pending = Some(result.clone());
                let set: Vec<AttrEntry> = result
                    .iter()
                    .filter(|(k, v)| studio.get(k.as_str()) != Some(*v))
                    .map(|(k, v)| AttrEntry {
                        name: k.clone(),
                        value: v.clone(),
                    })
                    .collect();
                let remove: Vec<String> = studio
                    .keys()
                    .filter(|k| !result.contains_key(k.as_str()))
                    .cloned()
                    .collect();
                outgoing = Some(AttrCommand {
                    path: path.clone(),
                    set,
                    remove,
                });
            }
        }
        if let Some(cmd) = outgoing {
            let text = format!("~ attributes pushed to Studio ({meta_rel})");
            self.notice("VSC", &path, "attr", meta_rel.clone(), text);
            self.set_detail(attr_diff(&studio, &result));
            self.attr_cmds.push(cmd);
        }
    }

    pub fn poll(&mut self) {
        if !self.authorized || !self.project_matches() {
            return;
        }
        self.refresh_sourcemap();
        self.refresh_overrides();

        let now = Instant::now();
        let holding = self.git_holding();
        let mut changed = false;
        let mut gone = Vec::new();
        for (k, script) in self.scripts.iter_mut() {
            match read(&script.file) {
                Some(text) => {
                    script.missing_since = None;
                    if text == script.disk {
                        script.settling = None;
                    } else if matches!(&script.settling, Some((seen, _)) if *seen == text) {
                        let since = script.settling.as_ref().map_or(now, |s| s.1);
                        let wait = if text.is_empty() && !script.disk.is_empty() {
                            EMPTY_SETTLE
                        } else {
                            DISK_SETTLE
                        };
                        if now.duration_since(since) >= wait {
                            script.disk = text;
                            script.settling = None;
                            changed = true;
                        }
                    } else {
                        script.settling = Some((text, now));
                    }
                }
                None if !script.file.exists() => {
                    let since = *script.missing_since.get_or_insert(now);
                    if now.duration_since(since) >= DELETE_GRACE {
                        gone.push(k.clone());
                    }
                }
                None => {}
            }
        }
        if !holding {
            self.remove_gone(gone);
        }

        if !holding && now.duration_since(self.last_scan) >= SCAN_INTERVAL {
            self.last_scan = now;
            self.scan_new();
        }
        if now.duration_since(self.last_meta) >= SCAN_INTERVAL {
            self.last_meta = now;
            let mut changed_attrs = Vec::new();
            for (k, script) in self.scripts.iter_mut() {
                let Some(meta) = meta_path(&script.file) else {
                    continue;
                };
                let Some(disk) = read_meta(&meta) else {
                    continue;
                };
                if disk != script.attr_disk {
                    script.attr_disk = disk;
                    changed_attrs.push(k.clone());
                }
            }
            for k in changed_attrs {
                self.reconcile_attrs(&k);
            }
        }
        self.retry_deferred();
        if changed || self.reconcile_dirty {
            self.reconcile_all();
        }
    }

    fn remove_gone(&mut self, gone: Vec<String>) {
        if gone.is_empty() {
            self.mass_warned = false;
            return;
        }
        if gone.len() > MAX_BULK_DELETE {
            if !self.mass_warned {
                println!("{} script files vanished at once, not deleting them from Studio", gone.len());
                self.mass_warned = true;
            }
            return;
        }
        self.mass_warned = false;
        for k in gone {
            if let Some(script) = self.scripts.remove(&k) {
                let _ = fs::remove_file(&script.base_file);
                self.remove_sidecars(&script.file);
                println!("deleted: {}", script.path.join("/"));
                let file = self.rel(&script.file);
                self.deletes.push(Deleted { path: script.path, file });
                self.rev += 1;
            }
        }
    }

    fn scan_new(&mut self) {
        let known_files: HashSet<PathBuf> = self.scripts.values().map(|s| s.file.clone()).collect();
        let mut known_dirs: HashSet<PathBuf> = self.dirs.values().map(|(_, d)| d.clone()).collect();
        let mut queue: Vec<(InstancePath, PathBuf)> = self.dirs.values().cloned().collect();
        let mut found: Vec<(PathBuf, InstancePath, &'static str, &'static str)> = Vec::new();

        let mut index = 0;
        while index < queue.len() {
            let (ipath, dir) = queue[index].clone();
            index += 1;
            let Ok(entries) = fs::read_dir(&dir) else {
                continue;
            };
            for entry in entries.flatten() {
                let name = entry.file_name().to_string_lossy().to_string();
                if name.starts_with('.') || name == "node_modules" || name == "target" {
                    continue;
                }
                let path = entry.path();
                let Ok(kind) = entry.file_type() else {
                    continue;
                };
                if kind.is_dir() {
                    if known_dirs.contains(&path) || !valid_name(&name) {
                        continue;
                    }
                    let mut sub = ipath.clone();
                    sub.push(name);
                    known_dirs.insert(path.clone());
                    self.dirs.insert(key(&sub), (sub.clone(), path.clone()));
                    if let Some((init, class, run_context)) = find_init(&path) {
                        if !known_files.contains(&init) {
                            found.push((init, sub.clone(), class, run_context));
                        }
                    }
                    queue.push((sub, path));
                } else if kind.is_file() && !known_files.contains(&path) {
                    if let Some((stem, class, run_context)) = parse_script_file(&name) {
                        if stem != "init" {
                            let mut sub = ipath.clone();
                            sub.push(stem);
                            found.push((path, sub, class, run_context));
                        }
                    }
                }
            }
        }

        let current: HashSet<PathBuf> = found.iter().map(|f| f.0.clone()).collect();
        self.seen_new.retain(|p, _| current.contains(p));

        for (file, path, class, run_context) in found {
            if self.ignored.contains(&file) {
                continue;
            }
            let seen = self.seen_new.entry(file.clone()).or_insert(0);
            *seen += 1;
            if *seen < 2 {
                continue;
            }
            self.seen_new.remove(&file);

            let k = key(&path);
            if self.scripts.contains_key(&k) {
                println!("skipped (instance name already used): {}", file.display());
                self.ignored.insert(file);
                continue;
            }
            let Some(disk) = read(&file) else {
                println!("skipped (unreadable or not UTF-8): {}", file.display());
                self.ignored.insert(file);
                continue;
            };
            println!("new file: {}", self.rel(&file));
            let script = self.make_script(path, class, run_context, file, disk, None);
            self.scripts.insert(k, script);
            self.rev += 1;
        }
    }

    fn prune_dirs(&mut self, start: &FsPath) {
        let mut dir = start.to_path_buf();
        loop {
            let entry = self
                .dirs
                .iter()
                .find(|(_, (_, d))| *d == dir)
                .map(|(k, (p, _))| (k.clone(), p.len()));
            let Some((k, depth)) = entry else {
                return;
            };
            let empty = fs::read_dir(&dir).map_or(false, |mut e| e.next().is_none());
            if depth < 2 || !empty || fs::remove_dir(&dir).is_err() {
                return;
            }
            self.dirs.remove(&k);
            let Some(parent) = dir.parent() else {
                return;
            };
            dir = parent.to_path_buf();
        }
    }

    fn resolve_file(
        &mut self,
        path: &[String],
        classes: &[String],
        class: &str,
        run_context: &str,
    ) -> Result<PathBuf, String> {
        let name = path.last().ok_or("empty path")?;
        if !valid_name(name) {
            return Err(format!("{name:?} can't be used as a file name"));
        }
        let suffix = suffix(class, run_context)?;

        let parent_len = path.len() - 1;
        let mut start = parent_len;
        let mut dir = loop {
            if start == 0 {
                return Err("no mapped directory above this script".to_string());
            }
            if let Some((_, dir)) = self.dirs.get(&key(&path[..start])) {
                break dir.clone();
            }
            start -= 1;
        };

        for j in start..parent_len {
            if !valid_name(&path[j]) {
                return Err(format!("{:?} can't be used as a directory name", path[j]));
            }
            let sub = dir.join(&path[j]);
            let parent_key = key(&path[..=j]);
            if classes.get(j).map(String::as_str) == Some("Folder") {
                fs::create_dir_all(&sub).map_err(|e| e.to_string())?;
            } else if self.scripts.contains_key(&parent_key) {
                self.convert_to_init(&parent_key, &sub)?;
            } else {
                return Err(format!("{} is not a Folder and is not a synced script", path[j]));
            }
            self.dirs.insert(parent_key, (path[..=j].to_vec(), sub.clone()));
            dir = sub;
        }

        let file = dir.join(format!("{name}{suffix}"));
        if file.exists() {
            return Err(format!("{} already exists", self.rel(&file)));
        }
        fs::create_dir_all(&dir).map_err(|e| e.to_string())?;
        Ok(file)
    }

    fn convert_to_init(&mut self, script_key: &str, dir: &FsPath) -> Result<(), String> {
        let (class, run_context, old_file) = {
            let script = &self.scripts[script_key];
            (script.class.clone(), script.run_context.clone(), script.file.clone())
        };
        fs::create_dir_all(dir).map_err(|e| e.to_string())?;
        let new_file = dir.join(format!("init{}", suffix(&class, &run_context)?));
        fs::rename(&old_file, &new_file).map_err(|e| e.to_string())?;
        if let Some(old_meta) = meta_path(&old_file) {
            if let Some(new_meta) = meta_path(&new_file) {
                if old_meta.exists() {
                    let _ = fs::rename(&old_meta, &new_meta);
                }
            }
        }
        let old_attr = self.attr_base_file(&old_file);
        if old_attr.exists() {
            let _ = fs::rename(&old_attr, self.attr_base_file(&new_file));
        }
        let base_file = self.base_file(&new_file);
        let script = self.scripts.get_mut(script_key).unwrap();
        if script.base_file.exists() {
            let _ = fs::rename(&script.base_file, &base_file);
        }
        script.file = new_file;
        script.base_file = base_file;
        Ok(())
    }

    fn create_from_studio(&mut self, created: Created, first_seen: Instant) {
        let k = key(&created.path);
        if self.scripts.contains_key(&k) {
            return;
        }
        // A script inside another new script waits for it to be synced first.
        if first_seen.elapsed() < DEFER_TTL && self.ancestor_pending(&created.path, &created.classes) {
            self.deferred.push(Deferred { first_seen, item: Item::Create(created) });
            return;
        }
        let file = match self.resolve_file(
            &created.path,
            &created.classes,
            &created.class_name,
            &created.run_context,
        ) {
            Ok(file) => file,
            Err(e) => {
                let text = format!("Not synced: {e}");
                self.notice("ERR", &created.path, "err", String::new(), text);
                return;
            }
        };
        if let Err(e) = fs::write(&file, &created.source) {
            let text = format!("Could not write file: {e}");
            self.notice("ERR", &created.path, "err", String::new(), text);
            return;
        }
        let mut script = self.make_script(
            created.path.clone(),
            &created.class_name,
            &created.run_context,
            file.clone(),
            created.source.clone(),
            Some(created.source.clone()),
        );
        script.set_base(created.source.clone());
        let rel = self.rel(&file);
        println!("+ created {rel}");
        self.scripts.insert(k, script);
        self.rev += 1;
        self.notice("RBX", &created.path, "add", rel.clone(), format!("+ created {rel}"));
        self.set_detail(signed('+', &created.source));
    }

    fn delete_from_studio(&mut self, path: InstancePath) {
        let Some(script) = self.scripts.remove(&key(&path)) else {
            return;
        };
        let rel = self.rel(&script.file);
        let _ = fs::remove_file(&script.file);
        let _ = fs::remove_file(&script.base_file);
        self.remove_sidecars(&script.file);
        if let Some(parent) = script.file.parent() {
            self.prune_dirs(parent);
        }
        self.rev += 1;
        println!("- deleted {rel}");
        self.notice("RBX", &path, "del", rel.clone(), format!("- deleted {rel}"));
        self.set_detail(signed('-', &script.disk));
    }

    fn move_from_studio(&mut self, moved: Moved, first_seen: Instant) {
        if !self.scripts.contains_key(&key(&moved.from)) {
            return;
        }
        // Moved into a script that has not been moved itself yet: wait for it, or this script
        // would be dropped from sync.
        if first_seen.elapsed() < DEFER_TTL && self.ancestor_pending(&moved.path, &moved.classes) {
            self.deferred.push(Deferred { first_seen, item: Item::Move(moved) });
            return;
        }
        let Some(mut script) = self.scripts.remove(&key(&moved.from)) else {
            return;
        };
        self.rev += 1;
        let file = match self.resolve_file(
            &moved.path,
            &moved.classes,
            &moved.class_name,
            &moved.run_context,
        ) {
            Ok(file) => file,
            Err(e) => {
                let text = format!("Moved out of the mapped tree ({e}); file left in place, no longer synced");
                self.notice("ERR", &moved.path, "err", String::new(), text);
                return;
            }
        };
        if let Err(e) = fs::rename(&script.file, &file) {
            let text = format!("Could not move file: {e}");
            self.notice("ERR", &moved.path, "err", String::new(), text);
            return;
        }
        let old_dir = script.file.parent().map(|p| p.to_path_buf());
        let base_file = self.base_file(&file);
        if script.base_file.exists() {
            let _ = fs::rename(&script.base_file, &base_file);
        }
        if let Some(old_meta) = meta_path(&script.file) {
            if let Some(new_meta) = meta_path(&file) {
                if old_meta.exists() {
                    let _ = fs::rename(&old_meta, &new_meta);
                }
            }
        }
        let old_attr = self.attr_base_file(&script.file);
        if old_attr.exists() {
            let _ = fs::rename(&old_attr, self.attr_base_file(&file));
        }
        let rel = self.rel(&file);
        println!("moved to {rel}");
        script.path = moved.path.clone();
        script.class = moved.class_name;
        script.run_context = moved.run_context;
        script.file = file;
        script.base_file = base_file;
        script.pending = None;
        self.scripts.insert(key(&moved.path), script);
        // The folder the script left may be empty now.
        if let Some(dir) = old_dir {
            self.prune_dirs(&dir);
        }
        self.notice("RBX", &moved.path, "move", rel.clone(), format!("~ moved to {rel}"));
        self.set_detail(format!("~ from {}\n~ to {}", moved.from.join("/"), moved.path.join("/")));
    }

    fn reconcile_all(&mut self) {
        // A halt (edits that wouldn't apply, Studio reverting) stops everything. A conflict only
        // stops its own script; the rest keep syncing while it is being resolved.
        if self.halt.is_some() {
            return;
        }
        // git rewrites files one after the other; push when it is done, not the states between.
        if self.git_holding() {
            self.reconcile_dirty = true;
            return;
        }
        self.reconcile_dirty = false;
        let mut conflicted = false;
        for script in self.scripts.values_mut() {
            if script.conflict.is_some() {
                continue;
            }
            if script.reconcile(&mut self.next_id, &mut self.events) {
                println!("conflict: {}", script.path.join("/"));
                conflicted = true;
            }
        }
        if conflicted {
            self.paused = true;
        }
    }

    fn ack(&mut self, id: u64, ok: bool, halt: bool) {
        for script in self.scripts.values_mut() {
            if script.pending.as_ref().map(|p| p.command.id) != Some(id) {
                continue;
            }
            let pending = script.pending.take().unwrap();
            if ok {
                let tries = script
                    .recent
                    .as_ref()
                    .filter(|r| r.target == pending.target)
                    .map_or(0, |r| r.tries);
                script.recent = Some(Recent {
                    old: pending.old,
                    target: pending.target.clone(),
                    at: Instant::now(),
                    tries,
                });
                script.studio = Some(pending.target.clone());
                script.set_base(pending.target);
            } else {
                script.studio = None;
                if halt {
                    println!("edits did not apply: {}", script.path.join("/"));
                    self.paused = true;
                    self.halt = Some(format!(
                        "Paused. Edits to {} did not apply, press Resume to retry",
                        script.path.join("/")
                    ));
                }
            }
        }
    }

    fn report(&mut self, report: Report) {
        let Some(script) = self.scripts.get_mut(&key(&report.path)) else {
            return;
        };
        // While a command for this script is out, a report only shows what Studio looks like right
        // now. The ack settles it, and revert detection would misfire on echoes of the last push.
        if script.pending.is_some() {
            script.studio = Some(report.source);
            return;
        }
        let verdict = match script.recent.as_mut() {
            Some(r) if r.at.elapsed() > REVERT_WINDOW || report.source == r.target => 1,
            Some(r) if report.source == r.old => {
                r.tries += 1;
                r.at = Instant::now();
                if r.tries > MAX_REVERTS {
                    3
                } else {
                    2
                }
            }
            _ => 0,
        };
        let name = script.path.join("/");
        let path = script.path.clone();
        match verdict {
            1 => script.recent = None,
            2 | 3 => {
                if let Some(recent) = script.recent.take() {
                    script.set_base(recent.old);
                }
            }
            _ => {}
        }
        script.studio = Some(report.source);
        match verdict {
            2 => {
                println!("studio reverted a pushed change, retrying: {name}");
                self.notice("ERR", &path, "err", String::new(), "Studio reverted a pushed change, retrying".to_string());
            }
            3 => {
                println!("studio keeps reverting: {name}");
                self.paused = true;
                self.halt = Some(format!("Paused. Studio keeps reverting {name}, press Resume to retry"));
            }
            _ => {}
        }
    }

    fn resume(&mut self) {
        if !self.paused {
            return;
        }
        let unresolved = self.scripts.values().any(|s| {
            s.conflict.is_some() && read(&s.file).map_or(true, |t| has_markers(&t))
        });
        if unresolved {
            return;
        }
        self.halt = None;
        for script in self.scripts.values_mut() {
            if let Some(studio) = script.conflict.take() {
                if let Some(text) = read(&script.file) {
                    script.disk = text;
                }
                script.set_base(studio);
            }
        }
        self.paused = false;
    }

    fn message(&self) -> String {
        if !self.paused {
            return format!("Synced, tracking {} scripts", self.scripts.len());
        }
        if let Some(halt) = &self.halt {
            return halt.clone();
        }
        let mut names: Vec<String> = self
            .scripts
            .values()
            .filter(|s| s.conflict.is_some())
            .map(|s| s.path.join("/"))
            .collect();
        names.sort();
        format!("Paused. Resolve conflicts in {}, then press Resume", names.join(", "))
    }

    fn project_matches(&self) -> bool {
        let Some(place_id) = self.place_id else {
            return false;
        };
        fs::read_to_string(self.root.join(".psync"))
            .ok()
            .and_then(|text| text.trim().parse::<u64>().ok())
            == Some(place_id)
    }

    pub fn handle(&mut self, req: SyncRequest, client: &mut Client) {
        if req.hello {
            self.disconnect();
            client.rev = 0;
            client.message.clear();
            let expected = fs::read_to_string(self.root.join(".psync"))
                .ok()
                .and_then(|text| text.trim().parse::<u64>().ok());
            self.place_id = req.place_id;
            self.authorized = expected.is_some() && expected == req.place_id;
            client.ignored = !self.authorized;
            client.ignored_message = match (expected, req.place_id) {
                (None, _) => "Sync ignored: .psync is missing or does not contain a valid PlaceId".to_string(),
                (Some(expected), Some(actual)) if expected != actual => {
                    format!("Sync ignored: this project is for PlaceId {expected}, but Studio is open to {actual}")
                }
                (Some(expected), None) => {
                    format!("Sync ignored: .psync requires PlaceId {expected}, but Studio did not provide one")
                }
                _ => format!("Project verified: PlaceId {}", req.place_id.unwrap()),
            };
            if self.authorized {
                let sync_dir = self.root.join(".sync");
                let _ = fs::create_dir_all(&sync_dir);
                let _ = fs::write(sync_dir.join(".gitignore"), "*\n");
            }
        }
        if client.ignored || !self.authorized || !self.project_matches() {
            return;
        }
        for ack in req.acks {
            self.ack(ack.id, ack.ok, ack.halt);
        }
        for report in req.reports {
            self.report(report);
        }
        let mut attr_keys = Vec::new();
        for report in req.attr_reports {
            let k = key(&report.path);
            if let Some(script) = self.scripts.get_mut(&k) {
                script.attr_studio = Some(attrs_from(&report.attributes));
                attr_keys.push(k);
            }
        }
        for k in attr_keys {
            self.reconcile_attrs(&k);
        }
        // Parents before the scripts inside them, whatever order Studio listed them in.
        let now = Instant::now();
        let mut created = req.created;
        created.sort_by_key(|c| c.path.len());
        for created in created {
            self.create_from_studio(created, now);
        }
        let mut moved = req.moved;
        moved.sort_by_key(|m| m.path.len());
        for moved in moved {
            self.move_from_studio(moved, now);
        }
        if req.deleted.len() > MAX_BULK_DELETE {
            // Deleting a folder that holds a wrongly built tree, or a Studio hiccup, must not take
            // the files with it. Studio gets the scripts back instead.
            let count = req.deleted.len();
            println!("{count} scripts deleted in Studio at once, keeping their files");
            let first = req.deleted[0].clone();
            let text = format!(
                "{count} scripts were deleted in Studio at once. Their files were kept and Studio will get them back; delete them in VS Code if you meant it"
            );
            self.notice("ERR", &first, "err", String::new(), text);
            self.rev += 1;
        } else {
            for path in req.deleted {
                self.delete_from_studio(path);
            }
        }
        for refused in req.refused {
            self.refused_by_studio(refused);
        }
        for path in req.missing {
            let parents = self.parent_specs(&path);
            if let Some(script) = self.scripts.get(&key(&path)) {
                self.creates.push(Create {
                    path,
                    parents,
                    class_name: script.class.clone(),
                    run_context: script.run_context.clone(),
                    file: self.rel(&script.file),
                    source: script.disk.clone(),
                });
            }
        }
        if req.resume {
            self.resume();
        }
        self.reconcile_all();
    }

    pub fn begin_connection(&mut self) -> u64 {
        self.active += 1;
        self.authorized = false;
        self.place_id = None;
        self.disconnect();
        self.active
    }

    pub fn is_active(&self, id: u64) -> bool {
        self.active == id
    }

    pub fn end_connection(&mut self, id: u64) {
        if self.active == id {
            self.authorized = false;
            self.place_id = None;
            self.disconnect();
        }
    }

    pub fn disconnect(&mut self) {
        for script in self.scripts.values_mut() {
            script.studio = None;
            if let Some(p) = script.pending.take() {
                script.lost = Some(fingerprint(&p.target));
            }
            script.pending = None;
            script.attr_studio = None;
            script.attr_pending = None;
            script.recent = None;
        }
        self.attr_cmds.clear();
        self.events.clear();
        self.creates.clear();
        self.deletes.clear();
        self.notices.clear();
    }

    pub fn outgoing(&mut self, client: &mut Client) -> Option<SyncResponse> {
        if !client.ignored && (!self.authorized || !self.project_matches()) {
            client.ignored = true;
            client.ignored_message = if self.root.join(".psync").exists() {
                "Sync ignored: .psync no longer matches the open place".to_string()
            } else {
                "Sync ignored: .psync is missing".to_string()
            };
            client.message.clear();
        }
        if client.ignored {
            if client.message == client.ignored_message {
                return None;
            }
            client.message = client.ignored_message.clone();
            return Some(SyncResponse {
                rev: 0,
                tracked: None,
                commands: Vec::new(),
                events: Vec::new(),
                creates: Vec::new(),
                deletes: Vec::new(),
                notices: Vec::new(),
                attr_commands: Vec::new(),
                paused: false,
                ignored: true,
                message: client.message.clone(),
            });
        }
        if !self.authorized || !self.project_matches() {
            return None;
        }
        let tracked = (client.rev != self.rev)
            .then(|| self.scripts.values().map(|s| s.path.clone()).collect());
        let commands: Vec<Command> = self
            .scripts
            .values_mut()
            .filter_map(|s| s.pending.as_mut())
            .filter(|p| !p.sent)
            .map(|p| {
                p.sent = true;
                p.command.clone()
            })
            .collect();
        let events = std::mem::take(&mut self.events);
        let mut creates = std::mem::take(&mut self.creates);
        // Parents before the scripts inside them, or Studio makes a Folder where a script belongs.
        creates.sort_by_key(|c| c.path.len());
        let deletes = std::mem::take(&mut self.deletes);
        let notices = std::mem::take(&mut self.notices);
        let attr_commands = std::mem::take(&mut self.attr_cmds);
        let message = self.message();

        if tracked.is_none()
            && commands.is_empty()
            && events.is_empty()
            && creates.is_empty()
            && deletes.is_empty()
            && notices.is_empty()
            && attr_commands.is_empty()
            && message == client.message
        {
            return None;
        }
        client.rev = self.rev;
        client.message = message.clone();
        Some(SyncResponse {
            rev: self.rev,
            tracked,
            commands,
            events,
            creates,
            deletes,
            notices,
            attr_commands,
            paused: self.paused,
            ignored: false,
            message,
        })
    }
}
