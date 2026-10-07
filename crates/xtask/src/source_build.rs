//! A source checkpoint is captured by the native builder, never accepted from
//! a CLI digest or a bundle's own claim. The app signature seals the receipt.
//! Main-code identity excludes CMS and the Info/CodeResources special slots:
//! those slots change when the outer seal incorporates this receipt. Every
//! executable code page is still checked against its signed SHA-256 page hash.
use crate::distribution::{self, FileEntry, Runner, invalid};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::collections::{BTreeMap, BTreeSet};
use std::fs;
use std::io::{self, Write};
use std::os::unix::fs::{MetadataExt, PermissionsExt};
use std::path::{Component, Path, PathBuf};

pub const RECEIPT_PATH: &str = "Contents/Resources/SourceBuild/receipt.json";
const MAIN_PATH: &str = "Contents/MacOS/Computa";
const OUTER_SEAL: &str = "Contents/_CodeSignature/CodeResources";
const MAX_FILES: usize = 16_384;
const MAX_RECEIPT: u64 = 8 * 1024 * 1024;
const SOURCE_DIRS: &[&str] = &["crates", "Config", ".cargo"];
const SOURCE_FILES: &[&str] = &[
    "Cargo.toml",
    "Cargo.lock",
    "rust-toolchain.toml",
    ".cargo/config.toml",
    "Config/Computa-Info.plist",
    "WebUI/src/styles.css",
    "Runtime/codex-source.lock.json",
    "Runtime/patches/compaction-retention.patch",
    "Scripts/mlx-model.lock.json",
    "Scripts/mlx-model-9b.lock.json",
    "Benchmarks/ReceiptOverflow/native-floor-harness.rs",
    "Benchmarks/OpaqueSurfacePerception/fixtures.ts",
];

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Toolchain {
    rustc_version: String,
    rustc_sha256: String,
    cargo_version: String,
    cargo_sha256: String,
    channel: String,
}
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct SourceProvenance {
    commit: String,
    closure_sha256: String,
    inputs: Vec<FileEntry>,
    toolchain: Toolchain,
}
/// Construction is restricted to a clean, tracked, native Git checkpoint.
#[derive(Clone, Debug)]
pub struct SourceSnapshot {
    root: PathBuf,
    provenance: SourceProvenance,
}
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct CodeSlice {
    cpu_type: u32,
    cpu_subtype: u32,
    identifier: String,
    team: String,
    code_sha256: String,
    code_bytes: u64,
    version: u32,
    flags: u32,
    platform: u8,
    page_size: u8,
    execution_segment: Option<[u64; 3]>,
    runtime: Option<u32>,
    non_resource_special_slots: BTreeMap<u32, String>,
}
type NormalizedCodeIdentity = BTreeMap<String, Vec<CodeSlice>>;
type ProducedArtifacts = (Vec<FileEntry>, NormalizedCodeIdentity);
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Receipt {
    schema_version: u32,
    protocol: String,
    source: SourceProvenance,
    artifacts: Vec<FileEntry>,
    #[serde(rename = "normalizedCodeIdentity")]
    signed_code: NormalizedCodeIdentity,
}
/// Receipt authority can only be obtained after checking a signed candidate.
/// Rebinding preserves its source and exact executable code identities.
pub struct VerifiedSourceReceipt {
    app: PathBuf,
    receipt_sha256: String,
    receipt: Receipt,
    runtime_manifest: Option<serde_json::Value>,
}

fn hash(bytes: &[u8]) -> String {
    hex::encode(Sha256::digest(bytes))
}
fn hex_digest(value: &str, length: usize) -> bool {
    value.len() == length
        && value
            .bytes()
            .all(|c| c.is_ascii_digit() || (b'a'..=b'f').contains(&c))
}
fn relative(value: &str) -> bool {
    !value.is_empty()
        && !value.contains(['\\', '\0'])
        && !value.chars().any(char::is_control)
        && Path::new(value)
            .components()
            .all(|p| matches!(p, Component::Normal(_)))
}
fn included(value: &str) -> bool {
    SOURCE_FILES.contains(&value)
        || SOURCE_DIRS
            .iter()
            .any(|dir| value.starts_with(&format!("{dir}/")))
}
fn native_command(runner: &dyn Runner, args: &[&str]) -> io::Result<String> {
    let result = runner.run(&args.iter().map(|v| (*v).to_owned()).collect::<Vec<_>>())?;
    if result.code != 0 || result.stdout.len() > 16 * 1024 * 1024 {
        return Err(invalid(
            "Could not verify the source checkpoint or compiler",
        ));
    }
    Ok(result.stdout)
}
fn git(root: &Path, runner: &dyn Runner, args: &[&str]) -> io::Result<String> {
    let mut command = vec!["/usr/bin/git", "-C", distribution::text(root)?];
    command.extend_from_slice(args);
    native_command(runner, &command)
}
fn compiler(runner: &dyn Runner, name: &str) -> io::Result<(String, String)> {
    let path = native_command(runner, &["rustup", "which", "--toolchain", "1.95.0", name])?;
    let path = Path::new(path.trim());
    if !path.is_absolute() || path.components().any(|p| matches!(p, Component::ParentDir)) {
        return Err(invalid(
            "Compiler path is not an absolute native toolchain executable",
        ));
    }
    crate::models::safe_directory(
        path.parent()
            .ok_or_else(|| invalid("Missing compiler parent"))?,
        false,
    )?;
    let metadata = fs::symlink_metadata(path)?;
    if !metadata.is_file() || metadata.mode() & 0o111 == 0 || metadata.len() > 512 * 1024 * 1024 {
        return Err(invalid("Compiler is not a bounded regular executable"));
    }
    let version = native_command(
        runner,
        &[
            distribution::text(path)?,
            if name == "rustc" { "-vV" } else { "--version" },
        ],
    )?;
    if !version.starts_with(&format!("{name} 1.95.0 ")) || version.len() > 4096 {
        return Err(invalid(
            "The product requires the reviewed Rust 1.95.0 toolchain",
        ));
    }
    Ok((version.trim().to_owned(), distribution::digest_file(path)?))
}
fn collect_source(root: &Path) -> io::Result<BTreeSet<String>> {
    fn visit(root: &Path, path: &Path, files: &mut BTreeSet<String>) -> io::Result<()> {
        let metadata = fs::symlink_metadata(path)?;
        if metadata.file_type().is_symlink() {
            return Err(invalid("Source closure contains a symlink"));
        }
        if metadata.is_dir() {
            for item in fs::read_dir(path)? {
                visit(root, &item?.path(), files)?;
            }
        } else if metadata.is_file() {
            let value = distribution::text(path.strip_prefix(root).map_err(invalid)?)?.to_owned();
            if !relative(&value) || files.len() >= MAX_FILES {
                return Err(invalid("Source closure exceeds its path bound"));
            }
            files.insert(value);
        } else {
            return Err(invalid("Source closure contains a special file"));
        }
        Ok(())
    }
    let mut result = BTreeSet::new();
    for dir in SOURCE_DIRS {
        visit(root, &root.join(dir), &mut result)?;
    }
    for path in SOURCE_FILES {
        if !result.contains(*path) {
            visit(root, &root.join(path), &mut result)?;
        }
    }
    Ok(result)
}
/// Ignore private weights and build outputs outside the explicit input closure;
/// every file inside that closure must be committed, regular and unchanged.
pub fn capture(root: &Path, runner: &dyn Runner) -> io::Result<SourceSnapshot> {
    crate::models::safe_directory(root, false)?;
    if fs::canonicalize(root)? != root
        || git(root, runner, &["rev-parse", "--show-toplevel"])?.trim() != distribution::text(root)?
    {
        return Err(invalid("Expected the exact canonical source worktree root"));
    }
    let commit = git(root, runner, &["rev-parse", "--verify", "HEAD"])?
        .trim()
        .to_owned();
    if !hex_digest(&commit, 40) {
        return Err(invalid("Source HEAD is not a concrete reviewed commit"));
    }
    let mut tracked = BTreeSet::new();
    for line in git(root, runner, &["ls-files", "--stage", "-z"])?.split_terminator('\0') {
        let (metadata, path) = line
            .split_once('\t')
            .ok_or_else(|| invalid("Invalid Git source entry"))?;
        if !included(path) {
            continue;
        }
        let fields = metadata.split_whitespace().collect::<Vec<_>>();
        if fields.len() != 3
            || !matches!(fields[0], "100644" | "100755")
            || !hex_digest(fields[1], 40)
            || fields[2] != "0"
            || !relative(path)
            || !tracked.insert(path.to_owned())
        {
            return Err(invalid("Source input is unmerged, linked or duplicated"));
        }
    }
    let actual = collect_source(root)?;
    if tracked != actual || SOURCE_FILES.iter().any(|path| !tracked.contains(*path)) {
        return Err(invalid(
            "Commit every product source input before building; untracked or missing inputs remain",
        ));
    }
    let mut diff = vec!["diff", "--quiet", "HEAD", "--"];
    diff.extend_from_slice(SOURCE_DIRS);
    diff.extend_from_slice(SOURCE_FILES);
    git(root, runner, &diff)?;
    let mut inputs = Vec::new();
    let mut total = 0u64;
    for path in tracked {
        let metadata = fs::symlink_metadata(root.join(&path))?;
        total = total
            .checked_add(metadata.len())
            .ok_or_else(|| invalid("Source byte bound overflow"))?;
        if metadata.len() > 64 * 1024 * 1024 || total > 512 * 1024 * 1024 {
            return Err(invalid("Source closure exceeds its byte bound"));
        }
        inputs.push(FileEntry {
            path: path.clone(),
            kind: "file".into(),
            sha256: distribution::digest_file(&root.join(path))?,
            size: metadata.len(),
            executable: metadata.mode() & 0o111 != 0,
        });
    }
    let rustc = compiler(runner, "rustc")?;
    let cargo = compiler(runner, "cargo")?;
    let toolchain = Toolchain {
        rustc_version: rustc.0,
        rustc_sha256: rustc.1,
        cargo_version: cargo.0,
        cargo_sha256: cargo.1,
        channel: "1.95.0".into(),
    };
    if git(root, runner, &["rev-parse", "--verify", "HEAD"])?.trim() != commit {
        return Err(invalid("Source HEAD changed during capture"));
    }
    git(root, runner, &diff)?;
    if collect_source(root)? != actual {
        return Err(invalid("Source path closure changed during capture"));
    }
    let closure_sha256 = hash(&serde_json::to_vec(&inputs).map_err(invalid)?);
    Ok(SourceSnapshot {
        root: root.to_owned(),
        provenance: SourceProvenance {
            commit,
            closure_sha256,
            inputs,
            toolchain,
        },
    })
}
pub fn verify_unchanged(
    root: &Path,
    before: &SourceSnapshot,
    runner: &dyn Runner,
) -> io::Result<()> {
    if root != before.root || capture(root, runner)?.provenance != before.provenance {
        return Err(invalid(
            "The reviewed source checkpoint or toolchain changed during the build",
        ));
    }
    Ok(())
}

fn word(bytes: &[u8], offset: usize, little: bool) -> io::Result<u32> {
    let raw: [u8; 4] = bytes
        .get(
            offset
                ..offset
                    .checked_add(4)
                    .ok_or_else(|| invalid("Mach-O offset overflow"))?,
        )
        .ok_or_else(|| invalid("Truncated Mach-O word"))?
        .try_into()
        .map_err(invalid)?;
    Ok(if little {
        u32::from_le_bytes(raw)
    } else {
        u32::from_be_bytes(raw)
    })
}
fn wide(bytes: &[u8], offset: usize, little: bool) -> io::Result<u64> {
    let raw: [u8; 8] = bytes
        .get(
            offset
                ..offset
                    .checked_add(8)
                    .ok_or_else(|| invalid("Mach-O offset overflow"))?,
        )
        .ok_or_else(|| invalid("Truncated Mach-O wide word"))?
        .try_into()
        .map_err(invalid)?;
    Ok(if little {
        u64::from_le_bytes(raw)
    } else {
        u64::from_be_bytes(raw)
    })
}
fn span(bytes: &[u8], start: usize, length: usize) -> io::Result<&[u8]> {
    bytes
        .get(
            start
                ..start
                    .checked_add(length)
                    .ok_or_else(|| invalid("Code signature length overflow"))?,
        )
        .ok_or_else(|| invalid("Code signature range exceeds its file"))
}
fn cstring(bytes: &[u8], offset: usize) -> io::Result<String> {
    let rest = bytes
        .get(offset..)
        .ok_or_else(|| invalid("Code signature string offset is invalid"))?;
    let end = rest
        .iter()
        .position(|b| *b == 0)
        .ok_or_else(|| invalid("Code signature string is not terminated"))?;
    if end == 0 || end > 256 {
        return Err(invalid("Code signature string exceeds bound"));
    }
    let value = std::str::from_utf8(&rest[..end]).map_err(invalid)?;
    if value.chars().any(char::is_control) {
        return Err(invalid("Invalid code signature identity"));
    }
    Ok(value.to_owned())
}
fn directory(
    slice: &[u8],
    cd: &[u8],
    cpu_type: u32,
    cpu_subtype: u32,
    signature_offset: usize,
    data_size_offset: usize,
    blobs: &BTreeMap<u32, String>,
) -> io::Result<CodeSlice> {
    let version = word(cd, 8, false)?;
    if word(cd, 0, false)? != 0xfade0c02
        || word(cd, 4, false)? as usize != cd.len()
        || !(0x20200..=0x20600).contains(&version)
        || cd.len() < 52
    {
        return Err(invalid("Unsupported signed CodeDirectory"));
    }
    let hash_offset = word(cd, 16, false)? as usize;
    let specials = word(cd, 24, false)? as usize;
    let slots = word(cd, 28, false)? as usize;
    let limit = word(cd, 32, false)? as usize;
    let page_size = cd[39];
    if cd[36] != 32
        || cd[37] != 2
        || !(12..=16).contains(&page_size)
        || specials > 16
        || slots > 131_072
        || limit == 0
        || limit != signature_offset
        || word(cd, 44, false)? != 0
        || (version >= 0x20300 && wide(cd, 56, false)? != 0)
    {
        return Err(invalid("Unsupported or inconsistent signed page table"));
    }
    let page = 1usize << page_size;
    if slots != limit.div_ceil(page)
        || hash_offset < specials * 32
        || hash_offset
            .checked_add(slots * 32)
            .is_none_or(|end| end > cd.len())
    {
        return Err(invalid("Signed page table exceeds CodeDirectory"));
    }
    for index in 0..slots {
        let start = index * page;
        let length = page.min(limit - start);
        let digest = Sha256::digest(span(slice, start, length)?);
        if digest.as_slice() != span(cd, hash_offset + index * 32, 32)? {
            return Err(invalid("Executable page differs from its signed code hash"));
        }
    }
    let identifier = cstring(cd, word(cd, 20, false)? as usize)?;
    let team = cstring(cd, word(cd, 48, false)? as usize)?;
    if team.len() != 10
        || !team
            .bytes()
            .all(|b| b.is_ascii_uppercase() || b.is_ascii_digit())
    {
        return Err(invalid(
            "Source product must have a concrete Apple Team signature",
        ));
    }
    let mut special = BTreeMap::new();
    for index in 1..=specials {
        if index == 1 || index == 3 {
            continue;
        }
        let bytes = span(cd, hash_offset - index * 32, 32)?;
        if bytes.iter().any(|b| *b != 0) {
            special.insert(index as u32, hex::encode(bytes));
        }
    }
    if special != *blobs {
        return Err(invalid(
            "Signed non-resource slot differs from its embedded blob",
        ));
    }
    let mut normalized = span(slice, 0, limit)?.to_vec();
    normalized
        .get_mut(data_size_offset..data_size_offset + 4)
        .ok_or_else(|| invalid("Signature size metadata exceeds code range"))?
        .fill(0);
    Ok(CodeSlice {
        cpu_type,
        cpu_subtype,
        identifier,
        team,
        code_sha256: hash(&normalized),
        code_bytes: limit as u64,
        version,
        flags: word(cd, 12, false)?,
        platform: cd[38],
        page_size,
        execution_segment: if version >= 0x20400 {
            Some([
                wide(cd, 64, false)?,
                wide(cd, 72, false)?,
                wide(cd, 80, false)?,
            ])
        } else {
            None
        },
        runtime: if version >= 0x20500 {
            Some(word(cd, 88, false)?)
        } else {
            None
        },
        non_resource_special_slots: special,
    })
}
fn thin(slice: &[u8]) -> io::Result<CodeSlice> {
    if word(slice, 0, true)? != 0xfeedfacf {
        return Err(invalid("Source executable must be a 64-bit Mach-O"));
    }
    let cpu = word(slice, 4, true)?;
    let subtype = word(slice, 8, true)?;
    if !matches!(cpu, 0x0100000c | 0x01000007) {
        return Err(invalid("Unsupported native product architecture"));
    }
    let count = word(slice, 16, true)? as usize;
    let commands = word(slice, 20, true)? as usize;
    if count == 0 || count > 1024 || commands > 1024 * 1024 {
        return Err(invalid("Mach-O command table exceeds bound"));
    }
    span(slice, 32, commands)?;
    let mut cursor = 32usize;
    let mut signature = None;
    let mut executable_ranges = Vec::new();
    for _ in 0..count {
        let command = word(slice, cursor, true)?;
        let size = word(slice, cursor + 4, true)? as usize;
        if size < 8
            || cursor
                .checked_add(size)
                .is_none_or(|end| end > 32 + commands)
        {
            return Err(invalid("Invalid Mach-O load command"));
        }
        if command == 0x1d {
            if size != 16 || signature.is_some() {
                return Err(invalid("Duplicated or invalid code signature command"));
            }
            signature = Some((
                word(slice, cursor + 8, true)? as usize,
                word(slice, cursor + 12, true)? as usize,
                cursor + 12,
            ));
        } else if command == 0x19 {
            let sections = word(slice, cursor + 64, true)? as usize;
            if size < 72 || sections > 4096 || size != 72 + sections * 80 {
                return Err(invalid("Invalid 64-bit segment command"));
            }
            let start = wide(slice, cursor + 40, true)?;
            let length = wide(slice, cursor + 48, true)?;
            let end = start
                .checked_add(length)
                .ok_or_else(|| invalid("Mach-O segment range overflow"))?;
            if end > slice.len() as u64 {
                return Err(invalid("Mach-O file segment exceeds executable"));
            }
            if word(slice, cursor + 60, true)? & 4 != 0 && length > 0 {
                executable_ranges.push(start..end);
            }
        }
        cursor += size;
    }
    if cursor != 32 + commands {
        return Err(invalid("Inconsistent Mach-O command table"));
    }
    let (offset, size, size_offset) =
        signature.ok_or_else(|| invalid("Source product executable is unsigned"))?;
    if offset < cursor || size > 16 * 1024 * 1024 || offset.checked_add(size) != Some(slice.len()) {
        return Err(invalid(
            "Code signature exceeds its bound or leaves an uncovered file tail",
        ));
    }
    if executable_ranges.is_empty()
        || executable_ranges
            .iter()
            .any(|range| range.end > offset as u64)
    {
        return Err(invalid(
            "Executable segment is absent or extends beyond signed code pages",
        ));
    }
    let blob = span(slice, offset, size)?;
    if word(blob, 0, false)? != 0xfade0cc0 {
        return Err(invalid("Missing embedded code-signature superblob"));
    }
    let length = word(blob, 4, false)? as usize;
    let count = word(blob, 8, false)? as usize;
    if length > blob.len() || count == 0 || count > 32 || 12 + count * 8 > length {
        return Err(invalid("Invalid signature superblob index"));
    }
    if blob[length..].iter().any(|b| *b != 0) {
        return Err(invalid("Code signature has an unreviewed overlay"));
    }
    let blob = &blob[..length];
    let mut primary = None;
    let mut alternates = Vec::new();
    let mut embedded = BTreeMap::new();
    let mut ranges = Vec::new();
    let mut types = BTreeSet::new();
    for index in 0..count {
        let kind = word(blob, 12 + index * 8, false)?;
        let start = word(blob, 16 + index * 8, false)? as usize;
        let size = word(blob, start + 4, false)? as usize;
        if start < 12 + count * 8 || size < 8 || !types.insert(kind) {
            return Err(invalid("Invalid signature blob index"));
        }
        let data = span(blob, start, size)?;
        let range = start..start + size;
        if ranges
            .iter()
            .any(|r: &std::ops::Range<usize>| r.start < range.end && range.start < r.end)
        {
            return Err(invalid("Overlapping signature blobs"));
        }
        ranges.push(range);
        if kind == 0 {
            primary = Some(data);
        } else if (0x1000..=0x1005).contains(&kind) {
            alternates.push(data);
        } else if (1..=16).contains(&kind) && kind != 1 && kind != 3 {
            embedded.insert(kind, hash(data));
        } else if kind != 0x10000 {
            return Err(invalid("Unrecognized executable signing blob"));
        }
    }
    let result = directory(
        slice,
        primary.ok_or_else(|| invalid("Missing primary SHA-256 CodeDirectory"))?,
        cpu,
        subtype,
        offset,
        size_offset,
        &embedded,
    )?;
    for cd in alternates {
        if directory(slice, cd, cpu, subtype, offset, size_offset, &embedded)? != result {
            return Err(invalid(
                "Alternate CodeDirectory differs from primary code identity",
            ));
        }
    }
    Ok(result)
}
fn code_identity(bytes: &[u8]) -> io::Result<Vec<CodeSlice>> {
    if bytes.len() > 512 * 1024 * 1024 {
        return Err(invalid("Executable exceeds code inspection bound"));
    }
    if word(bytes, 0, true)? == 0xfeedfacf {
        return Ok(vec![thin(bytes)?]);
    }
    let magic = word(bytes, 0, false)?;
    if !matches!(magic, 0xcafebabe | 0xcafebabf) {
        return Err(invalid("Unrecognized Mach-O product executable"));
    }
    let count = word(bytes, 4, false)? as usize;
    if count == 0 || count > 8 {
        return Err(invalid("Universal executable exceeds architecture bound"));
    }
    let width = if magic == 0xcafebabf { 32 } else { 20 };
    let table_end = 8 + width * count;
    span(bytes, 0, table_end)?;
    let mut ranges = Vec::new();
    let mut result = Vec::new();
    let mut cpus = BTreeSet::new();
    for index in 0..count {
        let entry = 8 + width * index;
        let cpu = word(bytes, entry, false)?;
        let subtype = word(bytes, entry + 4, false)?;
        let (offset, size) = if width == 32 {
            (
                wide(bytes, entry + 8, false)?,
                wide(bytes, entry + 16, false)?,
            )
        } else {
            (
                word(bytes, entry + 8, false)? as u64,
                word(bytes, entry + 12, false)? as u64,
            )
        };
        let offset = usize::try_from(offset).map_err(invalid)?;
        let size = usize::try_from(size).map_err(invalid)?;
        let end = offset
            .checked_add(size)
            .ok_or_else(|| invalid("Universal executable range overflow"))?;
        if offset < table_end
            || !cpus.insert((cpu, subtype))
            || ranges
                .iter()
                .any(|r: &std::ops::Range<usize>| r.start < end && offset < r.end)
        {
            return Err(invalid("Universal architecture ranges overlap or repeat"));
        }
        let item = thin(span(bytes, offset, size)?)?;
        if item.cpu_type != cpu || item.cpu_subtype != subtype {
            return Err(invalid(
                "Universal architecture identity disagrees with its executable",
            ));
        }
        ranges.push(offset..end);
        result.push(item);
    }
    result.sort_by_key(|item| (item.cpu_type, item.cpu_subtype));
    Ok(result)
}
fn expected_code_identifier(path: &str) -> Option<String> {
    match path {
        MAIN_PATH => Some(distribution::BUNDLE_ID.into()),
        "Contents/Resources/ChromeBridge/ChromeBridgeHost" => {
            Some(format!("{}.ChromeBridgeHost", distribution::BUNDLE_ID))
        }
        "Contents/Resources/AgentRuntime/codex-app-server" => {
            Some(format!("{}.AgentRuntime", distribution::BUNDLE_ID))
        }
        "Contents/Resources/InferenceRuntime/computa-inference-worker" => {
            Some(format!("{}.InferenceWorker", distribution::BUNDLE_ID))
        }
        "Contents/Resources/InferenceRuntime/computa-grounding-worker" => {
            Some(format!("{}.GroundingWorker", distribution::BUNDLE_ID))
        }
        _ => None,
    }
}
fn artifacts(app: &Path, provided: &[FileEntry]) -> io::Result<ProducedArtifacts> {
    if distribution::bundle_files(app)? != provided || provided.len() > MAX_FILES {
        return Err(invalid(
            "Produced artifact inventory is stale or exceeds its bound",
        ));
    }
    let mut ordinary = Vec::new();
    let mut signed = BTreeMap::new();
    let mut team = None;
    for entry in provided {
        if entry.path == RECEIPT_PATH || entry.path == OUTER_SEAL {
            continue;
        }
        if !relative(&entry.path) || entry.kind != "file" || !hex_digest(&entry.sha256, 64) {
            return Err(invalid("Invalid produced artifact inventory"));
        }
        if let Some(expected) = expected_code_identifier(&entry.path) {
            if !entry.executable {
                return Err(invalid("Required signed code is not executable"));
            }
            let code = code_identity(&crate::models::read_regular(
                &app.join(&entry.path),
                512 * 1024 * 1024,
            )?)?;
            for slice in &code {
                if slice.identifier != expected
                    || team.as_ref().is_some_and(|old| old != &slice.team)
                {
                    return Err(invalid(
                        "Product executable has a different identifier or Apple Team",
                    ));
                }
                team = Some(slice.team.clone());
            }
            signed.insert(entry.path.clone(), code);
        } else {
            ordinary.push(entry.clone());
        }
    }
    if !signed.contains_key(MAIN_PATH) {
        return Err(invalid("Missing signed main-code identity"));
    }
    Ok((ordinary, signed))
}
fn receipt(app: &Path) -> io::Result<(Receipt, String)> {
    let bytes = crate::models::read_regular(&app.join(RECEIPT_PATH), MAX_RECEIPT)?;
    let value = computa_contracts::strict_json::parse(&bytes).map_err(invalid)?;
    let receipt: Receipt = serde_json::from_value(value).map_err(invalid)?;
    if receipt.schema_version != 1
        || receipt.protocol != "computa-reviewed-source-build-v1"
        || !hex_digest(&receipt.source.commit, 40)
        || receipt.source.inputs.is_empty()
        || receipt.source.inputs.len() > MAX_FILES
        || receipt.source.closure_sha256
            != hash(&serde_json::to_vec(&receipt.source.inputs).map_err(invalid)?)
        || receipt.source.toolchain.channel != "1.95.0"
        || !receipt
            .source
            .toolchain
            .rustc_version
            .starts_with("rustc 1.95.0 ")
        || !receipt
            .source
            .toolchain
            .cargo_version
            .starts_with("cargo 1.95.0 ")
        || !hex_digest(&receipt.source.toolchain.rustc_sha256, 64)
        || !hex_digest(&receipt.source.toolchain.cargo_sha256, 64)
    {
        return Err(invalid("Invalid sealed source-build receipt"));
    }
    let mut paths = BTreeSet::new();
    for input in &receipt.source.inputs {
        if !relative(&input.path)
            || !included(&input.path)
            || input.kind != "file"
            || !hex_digest(&input.sha256, 64)
            || !paths.insert(input.path.clone())
        {
            return Err(invalid("Invalid sealed source input"));
        }
    }
    if SOURCE_FILES.iter().any(|path| !paths.contains(*path)) {
        return Err(invalid("Sealed receipt omits a required build input"));
    }
    Ok((receipt, hash(&bytes)))
}
fn save(app: &Path, receipt: &Receipt, expected_old: Option<&str>) -> io::Result<()> {
    crate::models::safe_directory(app, false)?;
    let path = app.join(RECEIPT_PATH);
    let parent = path
        .parent()
        .ok_or_else(|| invalid("Missing source receipt parent"))?;
    crate::models::safe_directory(parent, true)?;
    match (expected_old, fs::symlink_metadata(&path)) {
        (None, Err(error)) if error.kind() == io::ErrorKind::NotFound => {}
        (Some(expected), Ok(_)) if distribution::digest_file(&path)? == expected => {}
        _ => return Err(invalid("Source receipt changed before sealing")),
    }
    let bytes = serde_json::to_vec_pretty(receipt).map_err(invalid)?;
    if bytes.len() as u64 > MAX_RECEIPT {
        return Err(invalid("Source receipt exceeds byte bound"));
    }
    let mut temporary = tempfile::NamedTempFile::new_in(parent)?;
    temporary
        .as_file()
        .set_permissions(fs::Permissions::from_mode(0o600))?;
    temporary.write_all(&bytes)?;
    temporary.as_file().sync_all()?;
    if expected_old.is_some_and(|old| distribution::digest_file(&path).ok().as_deref() != Some(old))
    {
        return Err(invalid("Source receipt changed during sealing"));
    }
    if expected_old.is_none() {
        temporary
            .persist_noclobber(&path)
            .map_err(|error| error.error)?;
    } else {
        temporary.persist(&path).map_err(|error| error.error)?;
    }
    Ok(())
}
/// Must be called after signing nested binaries and the main executable, and
/// before the outer app seal. The caller rechecks its opaque source snapshot.
pub fn write_receipt(
    app: &Path,
    snapshot: &SourceSnapshot,
    produced: &[FileEntry],
) -> io::Result<()> {
    let (artifacts, signed_code) = artifacts(app, produced)?;
    save(
        app,
        &Receipt {
            schema_version: 1,
            protocol: "computa-reviewed-source-build-v1".into(),
            source: snapshot.provenance.clone(),
            artifacts,
            signed_code,
        },
        None,
    )
}
fn inspect_inner(app: &Path, produced: &[FileEntry]) -> io::Result<(Receipt, String)> {
    let (receipt, digest) = receipt(app)?;
    let (artifacts, code) = artifacts(app, produced)?;
    if receipt.artifacts != artifacts || receipt.signed_code != code {
        return Err(invalid(
            "Signed product artifacts differ from the sealed source-build receipt",
        ));
    }
    Ok((receipt, digest))
}
/// The distribution caller must also verify the outer Apple app signature.
/// This entry point verifies the sealed receipt without needing a checkout.
pub fn inspect_sealed_receipt(app: &Path, produced: &[FileEntry]) -> io::Result<()> {
    inspect_inner(app, produced).map(|_| ())
}
pub fn verify_receipt(
    app: &Path,
    expected: &SourceSnapshot,
    produced: &[FileEntry],
) -> io::Result<()> {
    let (receipt, _) = inspect_inner(app, produced)?;
    if receipt.source != expected.provenance {
        return Err(invalid(
            "Installed candidate does not match the reviewed source checkpoint",
        ));
    }
    Ok(())
}
fn verify_outer(app: &Path, receipt: &Receipt, runner: &dyn Runner) -> io::Result<()> {
    let team = &receipt
        .signed_code
        .get(MAIN_PATH)
        .and_then(|code| code.first())
        .ok_or_else(|| invalid("Missing signed main identity"))?
        .team;
    let requirement = format!(
        "=anchor apple generic and identifier \"{}\" and certificate leaf[subject.OU] = \"{team}\"",
        distribution::BUNDLE_ID
    );
    distribution::checked(
        runner,
        &[
            "/usr/bin/codesign",
            "--verify",
            "--deep",
            "--strict",
            "--all-architectures",
            "-R",
            &requirement,
            distribution::text(app)?,
        ],
    )?;
    Ok(())
}
pub fn load_verified_sealed_receipt(
    app: &Path,
    produced: &[FileEntry],
    runner: &dyn Runner,
) -> io::Result<VerifiedSourceReceipt> {
    let (receipt, receipt_sha256) = inspect_inner(app, produced)?;
    verify_outer(app, &receipt, runner)?;
    if distribution::bundle_files(app)? != produced {
        return Err(invalid(
            "Signed app changed during source receipt verification",
        ));
    }
    let runtime_manifest = produced
        .iter()
        .any(|file| file.path == "Contents/Resources/AgentRuntime/manifest.json")
        .then(|| {
            let bytes = crate::models::read_regular(
                &app.join("Contents/Resources/AgentRuntime/manifest.json"),
                64 * 1024,
            )?;
            computa_contracts::strict_json::parse(&bytes).map_err(invalid)
        })
        .transpose()?;
    Ok(VerifiedSourceReceipt {
        app: app.to_owned(),
        receipt_sha256,
        receipt,
        runtime_manifest,
    })
}
pub fn load_verified_receipt(
    app: &Path,
    expected: &SourceSnapshot,
    produced: &[FileEntry],
    runner: &dyn Runner,
) -> io::Result<VerifiedSourceReceipt> {
    verify_receipt(app, expected, produced)?;
    load_verified_sealed_receipt(app, produced, runner)
}
/// Re-signing may update executable CMS bytes and the AppServer binary digest
/// in its closed runtime manifest; executable code and all other data stay bound.
pub fn rebind_verified_receipt(
    app: &Path,
    old: &VerifiedSourceReceipt,
    produced: &[FileEntry],
) -> io::Result<()> {
    if app != old.app || distribution::digest_file(&app.join(RECEIPT_PATH))? != old.receipt_sha256 {
        return Err(invalid("Re-signing receipt authority is stale"));
    }
    let (artifacts, signed_code) = artifacts(app, produced)?;
    if signed_code != old.receipt.signed_code {
        return Err(invalid(
            "Re-signing changed executable code identity or Apple Team",
        ));
    }
    let old_files = old
        .receipt
        .artifacts
        .iter()
        .map(|entry| (entry.path.as_str(), entry))
        .collect::<BTreeMap<_, _>>();
    if old_files.len() != artifacts.len() {
        return Err(invalid(
            "Re-signing changed the produced artifact path closure",
        ));
    }
    for entry in &artifacts {
        let before = old_files
            .get(entry.path.as_str())
            .ok_or_else(|| invalid("Re-signing added an artifact"))?;
        if **before != *entry {
            if entry.path != "Contents/Resources/AgentRuntime/manifest.json"
                || before.executable != entry.executable
            {
                return Err(invalid("Re-signing changed a sealed non-code artifact"));
            }
            let mut manifest = computa_contracts::strict_json::parse(&crate::models::read_regular(
                &app.join(&entry.path),
                64 * 1024,
            )?)
            .map_err(invalid)?;
            let original = old
                .runtime_manifest
                .as_ref()
                .ok_or_else(|| invalid("Missing retained runtime provenance"))?;
            let binary = produced
                .iter()
                .find(|file| file.path == "Contents/Resources/AgentRuntime/codex-app-server")
                .ok_or_else(|| invalid("Missing re-signed runtime executable"))?;
            if manifest["binarySHA256"].as_str() != Some(binary.sha256.as_str())
                || manifest["binarySize"].as_u64() != Some(binary.size)
            {
                return Err(invalid(
                    "Re-signed runtime digest does not match its exact executable",
                ));
            }
            let object = manifest
                .as_object_mut()
                .ok_or_else(|| invalid("Runtime manifest is not an object"))?;
            object.insert("binarySHA256".into(), original["binarySHA256"].clone());
            object.insert("binarySize".into(), original["binarySize"].clone());
            if &manifest != original {
                return Err(invalid("Re-signing changed AppServer source provenance"));
            }
        }
    }
    save(
        app,
        &Receipt {
            artifacts,
            signed_code,
            ..old.receipt.clone()
        },
        Some(&old.receipt_sha256),
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::distribution::{CommandResult, SystemRunner};
    use std::cell::Cell;
    use std::os::unix::fs::symlink;

    fn le(bytes: &mut [u8], offset: usize, value: u32) {
        bytes[offset..offset + 4].copy_from_slice(&value.to_le_bytes());
    }
    fn be(bytes: &mut [u8], offset: usize, value: u32) {
        bytes[offset..offset + 4].copy_from_slice(&value.to_be_bytes());
    }
    fn le64(bytes: &mut [u8], offset: usize, value: u64) {
        bytes[offset..offset + 8].copy_from_slice(&value.to_le_bytes());
    }
    fn mach(identifier: &str, cpu: u32, resource: u8, cms: u8, extra: usize) -> Vec<u8> {
        let code_limit = 4096usize;
        let mut code = vec![0u8; code_limit];
        le(&mut code, 0, 0xfeedfacf);
        le(&mut code, 4, cpu);
        le(&mut code, 8, 0);
        le(&mut code, 12, 2);
        le(&mut code, 16, 2);
        le(&mut code, 20, 88);
        le(&mut code, 32, 0x19);
        le(&mut code, 36, 72);
        code[40..46].copy_from_slice(b"__TEXT");
        le64(&mut code, 64, code_limit as u64);
        le64(&mut code, 72, 0);
        le64(&mut code, 80, code_limit as u64);
        le(&mut code, 88, 5);
        le(&mut code, 92, 5);
        le(&mut code, 104, 0x1d);
        le(&mut code, 108, 16);
        le(&mut code, 112, code_limit as u32);
        code[256..269].copy_from_slice(b"OWNED_CODE_OK");
        let ident_offset = 52usize;
        let team_offset = ident_offset + identifier.len() + 1;
        let hash_offset = team_offset + 11 + 3 * 32;
        let cd_size = hash_offset + 32;
        let mut cd = vec![0u8; cd_size];
        be(&mut cd, 0, 0xfade0c02);
        be(&mut cd, 4, cd_size as u32);
        be(&mut cd, 8, 0x20200);
        be(&mut cd, 12, 0x10000);
        be(&mut cd, 16, hash_offset as u32);
        be(&mut cd, 20, ident_offset as u32);
        be(&mut cd, 24, 3);
        be(&mut cd, 28, 1);
        be(&mut cd, 32, code_limit as u32);
        cd[36] = 32;
        cd[37] = 2;
        cd[39] = 12;
        be(&mut cd, 48, team_offset as u32);
        cd[ident_offset..ident_offset + identifier.len()].copy_from_slice(identifier.as_bytes());
        cd[team_offset..team_offset + 10].copy_from_slice(b"MSMG8CJLB3");
        cd[hash_offset - 96..hash_offset - 64].fill(resource);
        let mut cms_blob = vec![cms; 16 + extra];
        let cms_size = cms_blob.len();
        be(&mut cms_blob, 0, 0xfade0b01);
        be(&mut cms_blob, 4, cms_size as u32);
        let total = 28 + cd.len() + cms_blob.len();
        le(&mut code, 116, total as u32);
        cd[hash_offset..].copy_from_slice(&Sha256::digest(&code));
        let mut blob = vec![0u8; 28];
        be(&mut blob, 0, 0xfade0cc0);
        be(&mut blob, 4, total as u32);
        be(&mut blob, 8, 2);
        be(&mut blob, 12, 0);
        be(&mut blob, 16, 28);
        be(&mut blob, 20, 0x10000);
        be(&mut blob, 24, (28 + cd.len()) as u32);
        blob.extend(cd);
        blob.extend(cms_blob);
        code.extend(blob);
        code
    }
    struct Fixture {
        _directory: tempfile::TempDir,
        root: PathBuf,
        rustc: PathBuf,
        cargo: PathBuf,
        signatures: Cell<usize>,
        reject_signing: Cell<bool>,
    }
    impl Fixture {
        fn new() -> Self {
            let directory = tempfile::tempdir().unwrap();
            let base = fs::canonicalize(directory.path()).unwrap();
            let root = base.join("source");
            fs::create_dir(&root).unwrap();
            for path in SOURCE_FILES {
                let file = root.join(path);
                fs::create_dir_all(file.parent().unwrap()).unwrap();
                fs::write(file, format!("reviewed {path}\n")).unwrap();
            }
            fs::create_dir_all(root.join("crates/owned/src")).unwrap();
            fs::write(root.join("crates/owned/src/lib.rs"), "pub fn owned() {}\n").unwrap();
            let rustc = base.join("rustc");
            let cargo = base.join("cargo");
            for file in [&rustc, &cargo] {
                fs::write(file, b"inert compiler fixture").unwrap();
                fs::set_permissions(file, fs::Permissions::from_mode(0o700)).unwrap();
            }
            for args in [
                vec!["init"],
                vec!["add", "."],
                vec![
                    "-c",
                    "user.name=Fixture",
                    "-c",
                    "user.email=fixture@example.test",
                    "-c",
                    "commit.gpgsign=false",
                    "-c",
                    "core.hooksPath=/dev/null",
                    "commit",
                    "-m",
                    "reviewed",
                ],
            ] {
                let mut command = vec![
                    "/usr/bin/git".to_owned(),
                    "-C".to_owned(),
                    root.to_str().unwrap().to_owned(),
                ];
                command.extend(args.into_iter().map(str::to_owned));
                assert_eq!(SystemRunner.run(&command).unwrap().code, 0);
            }
            Self {
                _directory: directory,
                root,
                rustc,
                cargo,
                signatures: Cell::new(0),
                reject_signing: Cell::new(false),
            }
        }
        fn app(&self) -> PathBuf {
            let app = self.root.parent().unwrap().join("Computa.app");
            fs::create_dir_all(app.join("Contents/MacOS")).unwrap();
            fs::write(
                app.join(MAIN_PATH),
                mach(distribution::BUNDLE_ID, 0x0100000c, 1, 2, 0),
            )
            .unwrap();
            fs::set_permissions(app.join(MAIN_PATH), fs::Permissions::from_mode(0o700)).unwrap();
            fs::write(app.join("Contents/Info.plist"), b"reviewed plist").unwrap();
            app
        }
    }
    impl Runner for Fixture {
        fn run(&self, args: &[String]) -> io::Result<CommandResult> {
            if args.first().map(String::as_str) == Some("rustup") {
                return Ok(CommandResult {
                    code: 0,
                    stdout: if args.last().map(String::as_str) == Some("rustc") {
                        self.rustc.to_string_lossy().into_owned()
                    } else {
                        self.cargo.to_string_lossy().into_owned()
                    },
                });
            }
            if args
                .first()
                .is_some_and(|value| Path::new(value) == self.rustc)
            {
                return Ok(CommandResult {
                    code: 0,
                    stdout: "rustc 1.95.0 (reviewed fixture)\nhost: aarch64-apple-darwin".into(),
                });
            }
            if args
                .first()
                .is_some_and(|value| Path::new(value) == self.cargo)
            {
                return Ok(CommandResult {
                    code: 0,
                    stdout: "cargo 1.95.0 (reviewed fixture)".into(),
                });
            }
            if args.first().map(String::as_str) == Some("/usr/bin/codesign") {
                self.signatures.set(self.signatures.get() + 1);
                assert!(args.iter().any(|a| a == "--all-architectures"));
                return Ok(CommandResult {
                    code: if self.reject_signing.get() { 1 } else { 0 },
                    stdout: String::new(),
                });
            }
            SystemRunner.run(args)
        }
    }
    #[test]
    fn reviewed_source_is_closed_and_ignores_private_outputs() {
        let fixture = Fixture::new();
        let snapshot = capture(&fixture.root, &fixture).unwrap();
        fs::create_dir_all(fixture.root.join("work/weights")).unwrap();
        fs::write(
            fixture.root.join("work/weights/private.bin"),
            b"outside the build closure",
        )
        .unwrap();
        verify_unchanged(&fixture.root, &snapshot, &fixture).unwrap();
        fs::write(fixture.root.join("crates/owned/src/new.rs"), b"untracked").unwrap();
        assert!(capture(&fixture.root, &fixture).is_err());
        fs::remove_file(fixture.root.join("crates/owned/src/new.rs")).unwrap();
        fs::write(fixture.root.join("WebUI/src/styles.css"), b"dirty").unwrap();
        assert!(verify_unchanged(&fixture.root, &snapshot, &fixture).is_err());
    }
    #[test]
    fn source_rejects_changed_compiler_missing_file_and_symlink() {
        let fixture = Fixture::new();
        let snapshot = capture(&fixture.root, &fixture).unwrap();
        fs::write(&fixture.rustc, b"different compiler").unwrap();
        assert!(verify_unchanged(&fixture.root, &snapshot, &fixture).is_err());
        fs::remove_file(fixture.root.join("Cargo.lock")).unwrap();
        assert!(capture(&fixture.root, &fixture).is_err());
        symlink(&fixture.cargo, fixture.root.join("Cargo.lock")).unwrap();
        assert!(capture(&fixture.root, &fixture).is_err());
    }
    #[test]
    fn normalized_code_allows_only_resource_cms_and_size_changes() {
        let first = mach(distribution::BUNDLE_ID, 0x0100000c, 1, 2, 0);
        let resealed = mach(distribution::BUNDLE_ID, 0x0100000c, 7, 8, 20);
        assert_eq!(
            code_identity(&first).unwrap(),
            code_identity(&resealed).unwrap()
        );
        let mut changed = first.clone();
        changed[256] ^= 1;
        assert!(code_identity(&changed).is_err());
        assert_ne!(
            code_identity(&first).unwrap(),
            code_identity(&mach("com.example.foreign", 0x0100000c, 1, 2, 0)).unwrap()
        );
        let mut tail = first.clone();
        tail.push(0);
        assert!(code_identity(&tail).is_err());
        let mut uncovered = first.clone();
        let cd = 4096 + 28;
        be(&mut uncovered, cd + 32, 4095);
        assert!(code_identity(&uncovered).is_err());
        let mut unsafe_segment = first;
        le64(&mut unsafe_segment, 80, 4200);
        assert!(code_identity(&unsafe_segment).is_err());
    }
    #[test]
    fn sealed_receipt_binds_checkpoint_data_and_main_code() {
        let fixture = Fixture::new();
        let source = capture(&fixture.root, &fixture).unwrap();
        let app = fixture.app();
        let before = distribution::bundle_files(&app).unwrap();
        write_receipt(&app, &source, &before).unwrap();
        verify_receipt(&app, &source, &distribution::bundle_files(&app).unwrap()).unwrap();
        let authority = load_verified_receipt(
            &app,
            &source,
            &distribution::bundle_files(&app).unwrap(),
            &fixture,
        )
        .unwrap();
        assert_eq!(fixture.signatures.get(), 1);
        fs::write(
            app.join(MAIN_PATH),
            mach(distribution::BUNDLE_ID, 0x0100000c, 9, 4, 20),
        )
        .unwrap();
        rebind_verified_receipt(&app, &authority, &distribution::bundle_files(&app).unwrap())
            .unwrap();
        inspect_sealed_receipt(&app, &distribution::bundle_files(&app).unwrap()).unwrap();
        fs::write(app.join("Contents/Info.plist"), b"changed plist").unwrap();
        assert!(verify_receipt(&app, &source, &distribution::bundle_files(&app).unwrap()).is_err());
    }
    #[test]
    fn opaque_rebinding_requires_outer_signature_and_retains_same_team() {
        let fixture = Fixture::new();
        let source = capture(&fixture.root, &fixture).unwrap();
        let app = fixture.app();
        write_receipt(&app, &source, &distribution::bundle_files(&app).unwrap()).unwrap();
        fixture.reject_signing.set(true);
        assert!(
            load_verified_sealed_receipt(
                &app,
                &distribution::bundle_files(&app).unwrap(),
                &fixture
            )
            .is_err()
        );
        fixture.reject_signing.set(false);
        let old = load_verified_sealed_receipt(
            &app,
            &distribution::bundle_files(&app).unwrap(),
            &fixture,
        )
        .unwrap();
        fs::write(
            app.join(MAIN_PATH),
            mach("com.example.foreign", 0x0100000c, 1, 2, 0),
        )
        .unwrap();
        assert!(
            rebind_verified_receipt(&app, &old, &distribution::bundle_files(&app).unwrap())
                .is_err()
        );
    }
    #[test]
    fn receipt_rejects_stale_inventory_duplicate_claims_and_omitted_main() {
        let fixture = Fixture::new();
        let source = capture(&fixture.root, &fixture).unwrap();
        let app = fixture.app();
        let inventory = distribution::bundle_files(&app).unwrap();
        fs::write(app.join("Contents/extra"), b"new artifact").unwrap();
        assert!(write_receipt(&app, &source, &inventory).is_err());
        write_receipt(&app, &source, &distribution::bundle_files(&app).unwrap()).unwrap();
        let path = app.join(RECEIPT_PATH);
        let bytes = fs::read(&path).unwrap();
        let duplicate = String::from_utf8(bytes).unwrap().replacen(
            "\"schemaVersion\": 1",
            "\"schemaVersion\": 1, \"schemaVersion\": 1",
            1,
        );
        fs::write(&path, duplicate).unwrap();
        assert!(inspect_sealed_receipt(&app, &distribution::bundle_files(&app).unwrap()).is_err());
        fs::remove_file(app.join(MAIN_PATH)).unwrap();
        assert!(artifacts(&app, &distribution::bundle_files(&app).unwrap()).is_err());
    }
    #[test]
    fn universal_code_checks_every_slice_and_rejects_overlap() {
        let arm = mach(distribution::BUNDLE_ID, 0x0100000c, 1, 2, 0);
        let intel = mach(distribution::BUNDLE_ID, 0x01000007, 1, 2, 0);
        let offset = 4096usize;
        let second = offset + arm.len();
        let mut fat = vec![0u8; second + intel.len()];
        be(&mut fat, 0, 0xcafebabe);
        be(&mut fat, 4, 2);
        for (entry, cpu, start, size) in [
            (8, 0x0100000c, offset, arm.len()),
            (28, 0x01000007, second, intel.len()),
        ] {
            be(&mut fat, entry, cpu);
            be(&mut fat, entry + 8, start as u32);
            be(&mut fat, entry + 12, size as u32);
        }
        fat[offset..second].copy_from_slice(&arm);
        fat[second..].copy_from_slice(&intel);
        assert_eq!(code_identity(&fat).unwrap().len(), 2);
        let mut corrupt = fat.clone();
        corrupt[second + 256] ^= 1;
        assert!(code_identity(&corrupt).is_err());
        be(&mut fat, 36, offset as u32);
        assert!(code_identity(&fat).is_err());
    }
    #[test]
    fn rebind_updates_only_exact_runtime_binary_digest_and_preserves_provenance() {
        let fixture = Fixture::new();
        let source = capture(&fixture.root, &fixture).unwrap();
        let app = fixture.app();
        let runtime_path = app.join("Contents/Resources/AgentRuntime/codex-app-server");
        let manifest_path = app.join("Contents/Resources/AgentRuntime/manifest.json");
        fs::create_dir_all(runtime_path.parent().unwrap()).unwrap();
        fs::write(
            &runtime_path,
            mach(
                &format!("{}.AgentRuntime", distribution::BUNDLE_ID),
                0x0100000c,
                1,
                2,
                0,
            ),
        )
        .unwrap();
        fs::set_permissions(&runtime_path, fs::Permissions::from_mode(0o700)).unwrap();
        let mut manifest = serde_json::json!({"sourceCommit":"reviewed-upstream","binarySHA256":distribution::digest_file(&runtime_path).unwrap(),"binarySize":fs::metadata(&runtime_path).unwrap().len()});
        fs::write(&manifest_path, serde_json::to_vec(&manifest).unwrap()).unwrap();
        write_receipt(&app, &source, &distribution::bundle_files(&app).unwrap()).unwrap();
        let old = load_verified_sealed_receipt(
            &app,
            &distribution::bundle_files(&app).unwrap(),
            &fixture,
        )
        .unwrap();
        fs::write(
            &runtime_path,
            mach(
                &format!("{}.AgentRuntime", distribution::BUNDLE_ID),
                0x0100000c,
                1,
                8,
                20,
            ),
        )
        .unwrap();
        manifest["binarySHA256"] = distribution::digest_file(&runtime_path).unwrap().into();
        manifest["binarySize"] = fs::metadata(&runtime_path).unwrap().len().into();
        fs::write(&manifest_path, serde_json::to_vec(&manifest).unwrap()).unwrap();
        rebind_verified_receipt(&app, &old, &distribution::bundle_files(&app).unwrap()).unwrap();
        inspect_sealed_receipt(&app, &distribution::bundle_files(&app).unwrap()).unwrap();
        let old = load_verified_sealed_receipt(
            &app,
            &distribution::bundle_files(&app).unwrap(),
            &fixture,
        )
        .unwrap();
        manifest["sourceCommit"] = "unreviewed-upstream".into();
        fs::write(&manifest_path, serde_json::to_vec(&manifest).unwrap()).unwrap();
        assert!(
            rebind_verified_receipt(&app, &old, &distribution::bundle_files(&app).unwrap())
                .is_err()
        );
    }
}
