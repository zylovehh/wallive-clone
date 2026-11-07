//! MobileBackup2-based PosterBoard install path (GoldenNugget "backup" mode).
//!
//! v1 scope — the fetch half only. The Swift side reads the PBF sqlite out of
//! the backup's Manifest.db, edits it, and builds the restore package; this
//! module only moves bytes between the phone and the backup directory.
//!
//! - `al_backup_fetch_posterboard`: targeted backup of the PosterBoard
//!   container only. Info.plist lists PosterBoard plus this installer app
//!   itself as a companion container in `Applications` (#03 experiment:
//!   make the device honour the list); the upload filter still drains
//!   every other file mid-stream, so only PosterBoard payloads are kept.
//!   Refuses encrypted backups (v1: no password support).
//! - `al_backup_restore`: restore a prepared backup directory.
//! - `al_backup_app_factory_entry`: InstallationProxy factory entry for one
//!   bundle id, for Manifest.plist `Applications` registration.
//!
//! The one vendored-crate change this relies on is the
//! `BackupDelegate::should_preserve_file` hook in
//! `vendor/idevice/src/services/mobilebackup2.rs` (default: keep everything).

use std::collections::HashSet;
use std::ffi::{c_char, c_void};
use std::fs;
use std::future::Future;
use std::io::Read as _;
use std::path::{Path, PathBuf};
use std::pin::Pin;
use std::sync::atomic::{AtomicU32, AtomicU64, Ordering};
use std::sync::Mutex;

use idevice::services::lockdown::LockdownClient;
use idevice::services::mobilebackup2::{
    BackupDelegate, DirEntryInfo, FsBackupDelegate, RestoreOptions,
};
use idevice::IdeviceError;

use crate::exploit::{connect_tunnel, ALLogCallback, Logger};
use crate::ffi_util::{cstr, opt_str};

pub const POSTERBOARD_BUNDLE: &str = "com.apple.PosterBoard";

/// Bundle id of this installer app itself. #03: listed as a second,
/// companion container in `Applications` so the device sees a two-entry
/// list (see `fetch_posterboard_inner`); its files are never kept — the
/// upload filter (`pb_should_preserve`) only keeps PosterBoard + backup
/// metadata, so the companion entry carries its path only, no files.
pub const INSTALLER_BUNDLE: &str = "com.example.walliveclone";

/// Progress callback: percent in [0, 100], or -1 when unknown.
/// `bytes_done`/`files_done` are cumulative across DL batches (the device
/// resets the per-batch counters each batch); `bytes_total` is the current
/// batch's expected total, 0 if unknown.
pub type ALBackupProgressCallback = Option<
    extern "C" fn(ctx: *mut c_void, percent: f64, bytes_done: u64, bytes_total: u64, files_done: u32),
>;

// ---------------------------------------------------------------------------
// Upload filter: keep PosterBoard + backup metadata, drain everything else
// ---------------------------------------------------------------------------

/// Backup metadata files are always preserved (pymobiledevice3 rule:
/// `should_preserve_backup_file`).
const BACKUP_METADATA_FILES: [&str; 6] = [
    "Info.plist",
    "Manifest.plist",
    "Manifest.db",
    "Manifest.db-shm",
    "Manifest.db-wal",
    "Status.plist",
];

fn pb_should_preserve(file_name: &str, device_name: &str) -> bool {
    if let Some(base) = Path::new(file_name).file_name().and_then(|s| s.to_str()) {
        if BACKUP_METADATA_FILES.contains(&base) {
            return true;
        }
    }
    // PosterBoard container, either the AppDomain form or the raw physical
    // tree iOS 27 uploads (mirrors GoldenNugget's pull filter).
    device_name.contains("AppDomain-com.apple.PosterBoard")
        || device_name.contains("PRBPosterExtensionDataStore")
        || device_name.contains("PosterBoard")
}

// ---------------------------------------------------------------------------
// Delegate: FsBackupDelegate + filter + progress + real free-space reporting
// ---------------------------------------------------------------------------

struct FilteringDelegate {
    inner: FsBackupDelegate,
    progress_cb: ALBackupProgressCallback,
    progress_ctx: usize,
    /// Log callback for per-file diagnostic lines (fetch path only).
    /// Mirrors progress_cb/progress_ctx.
    log_cb: ALLogCallback,
    log_ctx: usize,
    kept: AtomicU32,
    discarded: AtomicU32,
    last_progress: AtomicU64,
    last_reported_step: AtomicU64,
    /// Cumulative bytes/files across DL batches (the device resets the
    /// per-batch counters each batch; these keep a running total).
    cum_bytes: AtomicU64,
    cum_files: AtomicU32,
    /// Last per-batch counters seen, to detect a batch reset.
    last_batch_bytes: AtomicU64,
    last_batch_files: AtomicU32,
    /// Backup root for 0-byte placeholders (backup only). `None` on the
    /// restore path, where nothing is ever turned into a placeholder.
    backup_root: Option<PathBuf>,
    /// Paths of placeholders created for filtered payloads, tracked so
    /// renames (the device's end-of-backup commit batch) stay aligned
    /// and `cleanup_placeholders` removes exactly these files.
    placeholders: Mutex<HashSet<PathBuf>>,
    placeholder_count: AtomicU32,
    placeholder_failures: AtomicU32,
}

impl FilteringDelegate {
    fn new(
        progress_cb: ALBackupProgressCallback,
        ctx: *mut c_void,
        log_cb: ALLogCallback,
        log_ctx: *mut c_void,
        backup_root: Option<PathBuf>,
    ) -> Self {
        Self {
            inner: FsBackupDelegate,
            progress_cb,
            progress_ctx: ctx as usize,
            log_cb,
            log_ctx: log_ctx as usize,
            kept: AtomicU32::new(0),
            discarded: AtomicU32::new(0),
            last_progress: AtomicU64::new((-1.0f64).to_bits()),
            last_reported_step: AtomicU64::new(u64::MAX),
            cum_bytes: AtomicU64::new(0),
            cum_files: AtomicU32::new(0),
            last_batch_bytes: AtomicU64::new(0),
            last_batch_files: AtomicU32::new(0),
            backup_root,
            placeholders: Mutex::new(HashSet::new()),
            placeholder_count: AtomicU32::new(0),
            placeholder_failures: AtomicU32::new(0),
        }
    }

    fn last_progress(&self) -> f64 {
        f64::from_bits(self.last_progress.load(Ordering::Relaxed))
    }

    fn placeholder_stats(&self) -> (u32, u32) {
        (
            self.placeholder_count.load(Ordering::Relaxed),
            self.placeholder_failures.load(Ordering::Relaxed),
        )
    }

    /// Per-file diagnostic line (fetch path only): the device offers a
    /// file now, its data follows. If the fetch stalls mid-file, the last
    /// such line names the stuck file. Prefixed "FILE:" so the Swift log
    /// keeps it out of the on-screen lines (it still lands in the log file).
    fn log_file(&self, msg: &str) {
        if self.backup_root.is_none() {
            return;
        }
        if let Some(cb) = self.log_cb {
            let line = format!("FILE:{msg}");
            if let Ok(c) = std::ffi::CString::new(line) {
                cb(self.log_ctx as *mut c_void, c.as_ptr());
            }
        }
    }

    /// Absolute host path for a device-sent shard path, with `""`/`.`/`..`
    /// components dropped so the result can never escape `root`
    /// (mirrors the reference `hostPath`).
    fn host_path(root: &Path, relative: &str) -> PathBuf {
        let mut out = root.to_path_buf();
        for component in relative.split('/') {
            if component.is_empty() || component == "." || component == ".." {
                continue;
            }
            out.push(component);
        }
        out
    }

    /// Materialise the 0-byte stand-in for a payload the filter rejected.
    ///
    /// Never truncates: if something already lives at that path the device
    /// (or a previous attempt) put it there, and clobbering it would lose
    /// real data.
    fn note_rejected_payload(&self, file_name: &str) {
        let Some(root) = self.backup_root.as_deref() else {
            return;
        };
        let path = Self::host_path(root, file_name);
        if let Some(parent) = path.parent() {
            if let Err(e) = fs::create_dir_all(parent) {
                self.placeholder_failures.fetch_add(1, Ordering::Relaxed);
                let _ = e;
                return;
            }
        }
        match fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&path)
        {
            Ok(_) => {
                self.placeholder_count.fetch_add(1, Ordering::Relaxed);
                if let Ok(mut set) = self.placeholders.lock() {
                    set.insert(path);
                }
            }
            Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => {
                // Something is already there: leave it alone.
            }
            Err(_) => {
                self.placeholder_failures.fetch_add(1, Ordering::Relaxed);
            }
        }
    }

    /// Delete every placeholder (deepest first) plus now-empty parent dirs
    /// inside the backup root. Only safe after the exchange has returned:
    /// while it is live the device still validates the backup tree against
    /// the Manifest.db it uploaded, and the placeholders are what keep
    /// that check satisfied (reference: pymobiledevice3
    /// `cleanup_discarded_files()` in a `finally` right after `dl_loop()`).
    fn cleanup_placeholders(&self) -> usize {
        let paths: Vec<PathBuf> = match self.placeholders.lock() {
            Ok(mut set) => set.drain().collect(),
            Err(_) => return 0,
        };
        let Some(root) = self.backup_root.clone() else {
            return 0;
        };
        if paths.is_empty() {
            return 0;
        }
        let mut paths = paths;
        paths.sort_by_key(|p| std::cmp::Reverse(p.components().count()));
        let mut removed = 0;
        for path in &paths {
            if path.exists() && fs::remove_file(path).is_ok() {
                removed += 1;
            }
            // Prune now-empty parents, stopping at the backup root.
            let mut parent = path.parent().map(|p| p.to_path_buf());
            while let Some(dir) = parent {
                if dir == root || !dir.starts_with(&root) {
                    break;
                }
                match fs::read_dir(&dir) {
                    Ok(mut entries) => {
                        if entries.next().is_some() {
                            break;
                        }
                    }
                    Err(_) => break,
                }
                if fs::remove_dir(&dir).is_err() {
                    break;
                }
                parent = dir.parent().map(|p| p.to_path_buf());
            }
        }
        removed
    }
}

impl BackupDelegate for FilteringDelegate {
    fn get_free_disk_space(&self, path: &Path) -> u64 {
        use std::ffi::CString;
        let Ok(cpath) = CString::new(path.to_string_lossy().as_bytes()) else {
            return 0;
        };
        let mut st: libc::statvfs = unsafe { std::mem::zeroed() };
        let rc = unsafe { libc::statvfs(cpath.as_ptr(), &mut st) };
        if rc == 0 {
            st.f_bavail as u64 * st.f_frsize as u64
        } else {
            0
        }
    }

    fn open_file_read<'a>(
        &'a self,
        path: &'a Path,
    ) -> Pin<Box<dyn Future<Output = Result<Box<dyn std::io::Read + Send>, IdeviceError>> + Send + 'a>>
    {
        self.inner.open_file_read(path)
    }

    fn create_file_write<'a>(
        &'a self,
        path: &'a Path,
    ) -> Pin<Box<dyn Future<Output = Result<Box<dyn std::io::Write + Send>, IdeviceError>> + Send + 'a>>
    {
        self.inner.create_file_write(path)
    }

    fn create_dir_all<'a>(
        &'a self,
        path: &'a Path,
    ) -> Pin<Box<dyn Future<Output = Result<(), IdeviceError>> + Send + 'a>> {
        self.inner.create_dir_all(path)
    }

    fn remove<'a>(
        &'a self,
        path: &'a Path,
    ) -> Pin<Box<dyn Future<Output = Result<(), IdeviceError>> + Send + 'a>> {
        Box::pin(async move {
            let res = self.inner.remove(path).await;
            if res.is_ok() {
                if let Ok(mut set) = self.placeholders.lock() {
                    set.remove(path);
                }
            }
            res
        })
    }

    fn rename<'a>(
        &'a self,
        from: &'a Path,
        to: &'a Path,
    ) -> Pin<Box<dyn Future<Output = Result<(), IdeviceError>> + Send + 'a>> {
        Box::pin(async move {
            let res = self.inner.rename(from, to).await;
            if res.is_ok() {
                // The device's end-of-backup commit batch renames staged
                // files to their final shard paths; keep a placeholder's
                // identity aligned with it or cleanup misses the file.
                if let Ok(mut set) = self.placeholders.lock() {
                    if set.remove(from) {
                        set.insert(to.to_path_buf());
                    }
                }
            }
            res
        })
    }

    fn copy<'a>(
        &'a self,
        src: &'a Path,
        dst: &'a Path,
    ) -> Pin<Box<dyn Future<Output = Result<(), IdeviceError>> + Send + 'a>> {
        Box::pin(async move {
            let res = self.inner.copy(src, dst).await;
            if res.is_ok() {
                if let Ok(mut set) = self.placeholders.lock() {
                    if set.contains(src) {
                        set.insert(dst.to_path_buf());
                    }
                }
            }
            res
        })
    }

    fn exists<'a>(&'a self, path: &'a Path) -> Pin<Box<dyn Future<Output = bool> + Send + 'a>> {
        self.inner.exists(path)
    }

    fn is_dir<'a>(&'a self, path: &'a Path) -> Pin<Box<dyn Future<Output = bool> + Send + 'a>> {
        self.inner.is_dir(path)
    }

    fn list_dir<'a>(
        &'a self,
        path: &'a Path,
    ) -> Pin<Box<dyn Future<Output = Result<Vec<DirEntryInfo>, IdeviceError>> + Send + 'a>>
    {
        self.inner.list_dir(path)
    }

    fn should_preserve_file(&self, file_name: &str, device_name: &str) -> bool {
        let keep = pb_should_preserve(file_name, device_name);
        self.log_file(&format!("取文件 {device_name} [{file_name}]"));
        if keep {
            self.kept.fetch_add(1, Ordering::Relaxed);
        } else {
            self.discarded.fetch_add(1, Ordering::Relaxed);
            // The device still lists this payload in the Manifest.db it
            // uploads; a 0-byte stand-in keeps its end-of-run tree check
            // satisfied (removed by cleanup_placeholders once the
            // exchange has returned).
            self.note_rejected_payload(file_name);
        }
        keep
    }

    fn on_progress(&self, bytes_done: u64, bytes_total: u64, overall_progress: f64, files_done: u32) {
        // The device resets the per-batch counters each DL batch; keep a
        // running total so the UI shows cumulative files/bytes. A drop in
        // the per-batch counter can only mean a new batch (within a batch
        // both counters only grow).
        let prev_bytes = self.last_batch_bytes.swap(bytes_done, Ordering::Relaxed);
        if bytes_done < prev_bytes {
            self.cum_bytes.fetch_add(prev_bytes, Ordering::Relaxed);
        }
        let prev_files = self.last_batch_files.swap(files_done, Ordering::Relaxed);
        if files_done < prev_files {
            self.cum_files.fetch_add(prev_files, Ordering::Relaxed);
        }
        let cum_bytes = self.cum_bytes.load(Ordering::Relaxed) + bytes_done;
        let cum_files = self.cum_files.load(Ordering::Relaxed) + files_done;
        let pct = if overall_progress >= 0.0 {
            overall_progress
        } else if bytes_total > 0 {
            bytes_done as f64 / bytes_total as f64 * 100.0
        } else {
            -1.0
        };
        if pct >= 0.0 {
            self.last_progress.store(pct.to_bits(), Ordering::Relaxed);
            // Throttle the C callback to whole-percent steps (the device
            // fires this per file; unthrottled it floods the UI thread).
            let step = pct.floor() as u64;
            if self.last_reported_step.swap(step, Ordering::Relaxed) != step {
                if let Some(cb) = self.progress_cb {
                    cb(self.progress_ctx as *mut c_void, pct, cum_bytes, bytes_total, cum_files);
                }
            }
        }
    }
}

// ---------------------------------------------------------------------------
// plist helpers
// ---------------------------------------------------------------------------

fn plist_to_json(v: &plist::Value) -> serde_json::Value {
    match v {
        plist::Value::String(s) => serde_json::Value::String(s.clone()),
        plist::Value::Integer(_) => {
            if let Some(n) = v.as_signed_integer() {
                serde_json::json!(n)
            } else if let Some(n) = v.as_unsigned_integer() {
                serde_json::json!(n)
            } else {
                serde_json::Value::Null
            }
        }
        plist::Value::Real(f) => serde_json::json!(f),
        plist::Value::Boolean(b) => serde_json::Value::Bool(*b),
        plist::Value::Data(d) => serde_json::Value::String(hex::encode(d)),
        plist::Value::Date(d) => serde_json::Value::String(format!("{d:?}")),
        plist::Value::Array(a) => {
            serde_json::Value::Array(a.iter().map(plist_to_json).collect())
        }
        plist::Value::Dictionary(d) => {
            let mut o = serde_json::Map::new();
            for (k, v) in d.iter() {
                o.insert(k.clone(), plist_to_json(v));
            }
            serde_json::Value::Object(o)
        }
        plist::Value::Uid(u) => serde_json::json!(u.get()),
        // plist::Value is #[non_exhaustive]: future variants fall here.
        _ => serde_json::Value::Null,
    }
}

fn random_bytes_16() -> [u8; 16] {
    let mut b = [0u8; 16];
    if let Ok(mut f) = fs::File::open("/dev/urandom") {
        if f.read_exact(&mut b).is_ok() {
            return b;
        }
    }
    // Fallback: time + pid xorshift (only used when /dev/urandom is missing).
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_nanos())
        .unwrap_or(0);
    let mut x = now ^ ((std::process::id() as u128) << 64) ^ 0x9e3779b97f4a7c15;
    for slot in b.iter_mut() {
        x ^= x << 13;
        x ^= x >> 7;
        x ^= x << 17;
        *slot = (x & 0xff) as u8;
    }
    b
}

fn write_plist_xml(path: &Path, value: &plist::Value) -> Result<(), String> {
    let file = fs::File::create(path)
        .map_err(|e| format!("create {} failed: {e}", path.display()))?;
    plist::to_writer_xml(file, value)
        .map_err(|e| format!("write {} failed: {e}", path.display()))
}

/// Info.plist for the backup: the `Applications` dict is what tells the
/// device which app containers to include. PosterBoard plus the installer
/// app itself as a companion container (#03); `Installed Applications`
/// lists the same two bundle ids — the two must always match.
#[allow(clippy::too_many_arguments)]
fn write_info_plist(
    path: &Path,
    udid: &str,
    serial: &str,
    product_version: &str,
    product_type: &str,
    build_version: &str,
    device_name: &str,
    applications: plist::Dictionary,
) -> Result<(), String> {
    let guid = random_bytes_16();
    let mut dict = plist::Dictionary::new();
    dict.insert(
        "iTunes Version".to_string(),
        plist::Value::String("10.0.1".to_string()),
    );
    dict.insert(
        "iTunes Files".to_string(),
        plist::Value::Dictionary(plist::Dictionary::new()),
    );
    dict.insert(
        "Unique Identifier".to_string(),
        plist::Value::String(udid.to_uppercase()),
    );
    dict.insert(
        "Target Type".to_string(),
        plist::Value::String("Device".to_string()),
    );
    dict.insert(
        "Target Identifier".to_string(),
        plist::Value::String(udid.to_string()),
    );
    dict.insert(
        "Serial Number".to_string(),
        plist::Value::String(serial.to_string()),
    );
    dict.insert(
        "Product Version".to_string(),
        plist::Value::String(product_version.to_string()),
    );
    dict.insert(
        "Product Type".to_string(),
        plist::Value::String(product_type.to_string()),
    );
    dict.insert(
        "Installed Applications".to_string(),
        plist::Value::Array(vec![
            plist::Value::String(POSTERBOARD_BUNDLE.to_string()),
            plist::Value::String(INSTALLER_BUNDLE.to_string()),
        ]),
    );
    dict.insert("GUID".to_string(), plist::Value::Data(guid.to_vec()));
    dict.insert(
        "Display Name".to_string(),
        plist::Value::String(device_name.to_string()),
    );
    dict.insert(
        "Device Name".to_string(),
        plist::Value::String(device_name.to_string()),
    );
    dict.insert(
        "Build Version".to_string(),
        plist::Value::String(build_version.to_string()),
    );
    dict.insert(
        "Applications".to_string(),
        plist::Value::Dictionary(applications),
    );
    write_plist_xml(path, &plist::Value::Dictionary(dict))
}

// ---------------------------------------------------------------------------
// Lockdown helpers
// ---------------------------------------------------------------------------

async fn lockdown_string(
    lockdown: &mut LockdownClient,
    key: &str,
    domain: Option<&str>,
) -> Result<String, String> {
    match lockdown.get_value(Some(key), domain).await {
        Ok(plist::Value::String(s)) => Ok(s),
        Ok(other) => Err(format!("lockdown value {key} is not a string: {other:?}")),
        Err(e) => Err(format!("lockdown get_value({key}) failed: {e:?}")),
    }
}

// ---------------------------------------------------------------------------
// Async implementations
// ---------------------------------------------------------------------------

async fn fetch_posterboard_inner(
    pairing_path: String,
    backup_root: String,
    log_cb: ALLogCallback,
    progress_cb: ALBackupProgressCallback,
    ctx_usize: usize,
) -> Result<String, String> {
    let logger = Logger::new(log_cb, ctx_usize as *mut c_void);
    let pairing_bytes =
        fs::read(&pairing_path).map_err(|e| format!("read pairing file failed: {e}"))?;
    let mut tunnel = connect_tunnel(&pairing_bytes, &logger).await?;

    // Device values + encryption gate (v1 refuses encrypted backups).
    let mut lockdown = tunnel.connect_lockdown(&logger).await?;
    let udid = lockdown_string(&mut lockdown, "UniqueDeviceID", None).await?;
    let serial = lockdown_string(&mut lockdown, "SerialNumber", None).await?;
    let product_version = lockdown_string(&mut lockdown, "ProductVersion", None).await?;
    let product_type = lockdown_string(&mut lockdown, "ProductType", None).await?;
    let build_version = lockdown_string(&mut lockdown, "BuildVersion", None).await?;
    let device_name = lockdown_string(&mut lockdown, "DeviceName", None)
        .await
        .unwrap_or_default();
    let will_encrypt = matches!(
        lockdown
            .get_value(Some("WillEncrypt"), Some("com.apple.mobile.backup"))
            .await,
        Ok(plist::Value::Boolean(true))
    );
    if will_encrypt {
        return Err("backup encryption is enabled on this device. Turn off \"Encrypt local backup\" in Finder/iTunes first (backup passwords are not supported in v1)."
            .to_string());
    }
    drop(lockdown);

    // PosterBoard factory entry via InstallationProxy. #03 asks for the
    // companion container in the same lookup (one call, same channel).
    let mut ip = tunnel.connect_installation_proxy(&logger).await?;
    let apps = ip
        .get_apps(
            Some("Any"),
            Some(vec![
                POSTERBOARD_BUNDLE.to_string(),
                INSTALLER_BUNDLE.to_string(),
            ]),
        )
        .await
        .map_err(|e| format!("installation_proxy lookup failed: {e:?}"))?;
    let pb_info = apps
        .get(POSTERBOARD_BUNDLE)
        .ok_or_else(|| "PosterBoard app not found via installation proxy".to_string())?;
    let info_dict = pb_info
        .as_dictionary()
        .ok_or_else(|| "PosterBoard lookup result is not a dictionary".to_string())?;
    if !matches!(info_dict.get("Container"), Some(plist::Value::String(_))) {
        return Err(
            "installation_proxy entry for PosterBoard has no Container".to_string(),
        );
    }
    // 原样转发手机给的 installation_proxy 完整记录（参考 GoldenNugget
    // `syncAppFactoryEntry`：FactoryInfo 里 Applications 下的条目必须和手机
    // 刚给的那条一模一样，形状就是手机的约定）。之前只挑 5 个键
    // （CFBundleIdentifier/Container/CFBundleVersion/ApplicationSINF/
    // iTunesMetadata）拼一条新的，手机认不出、过滤作废，于是把所有 App
    // 容器都报出来（#30 真机：1665 个文件、495.7 MB，10% 断 ConnectionReset）。
    let mut applications = plist::Dictionary::new();
    applications.insert(
        POSTERBOARD_BUNDLE.to_string(),
        plist::Value::Dictionary(info_dict.clone()),
    );

    // #03 第二容器陪衬实验：Applications 里再加安装器自己——真实存在
    // 的容器，记录现取、原样转发，只为让手机认这张清单。只给路径、
    // 不给文件：条目里只有身份信息（Container 路径、包名、签名等），
    // 没有文件；文件那头过滤器 `pb_should_preserve` 只留 PosterBoard
    // + 备份元数据，安装器容器的文件一律只排空、不落盘——配对文件和
    // 备份目录本身都在这个容器里，同样一个都不会写进备份载荷。陪衬
    // 找不到或没有 Container 时不报错，只记一行日志、退回单条
    // PosterBoard（= #02），不把安装本身堵死。
    let mut companion_container: Option<String> = None;
    if let Some(inst_dict) = apps
        .get(INSTALLER_BUNDLE)
        .and_then(|v| v.as_dictionary())
    {
        if let Some(plist::Value::String(container)) = inst_dict.get("Container") {
            companion_container = Some(container.clone());
            applications.insert(
                INSTALLER_BUNDLE.to_string(),
                plist::Value::Dictionary(inst_dict.clone()),
            );
        }
    }
    match &companion_container {
        Some(path) => logger.log(&format!(
            "backup: Applications lists 2 containers: {}, {} (companion Container: {})",
            POSTERBOARD_BUNDLE, INSTALLER_BUNDLE, path
        )),
        None => logger.log(
            "backup: companion container not found via installation proxy, continuing with PosterBoard only",
        ),
    }

    // Prepare the backup directory. The caller (Swift) seeds it first with
    // the host-side manifests — most importantly the placeholder sqlite
    // Manifest.db (ManifestEntry + Properties, empty): on iOS 27 the
    // device's second DL message is a DownloadFiles request for
    // `<udid>/Manifest.db`, and a host that cannot serve it aborts the
    // transfer before a single payload is offered (GoldenNugget Mobile,
    // HostManifests.writeSQLiteManifest). The empty table is the "nothing
    // backed up previously" answer, so the device streams the full set.
    // This function only writes Info.plist (the Applications dict decides
    // what the device uploads) and runs the backup.
    let backup_root = PathBuf::from(&backup_root);
    let device_dir = backup_root.join(&udid);
    fs::create_dir_all(&device_dir)
        .map_err(|e| format!("create backup dir failed: {e}"))?;
    let placeholder = device_dir.join("Manifest.db");
    match fs::metadata(&placeholder) {
        Ok(m) if m.len() > 0 => {}
        _ => {
            return Err(
                "backup dir not prepared: Manifest.db placeholder missing. \
                 Seed the directory first (placeholder sqlite Manifest.db + \
                 Status.plist + empty Manifest.plist) before calling the fetch."
                    .to_string(),
            )
        }
    }
    // #02 实验 C：定点只靠磁盘上的 Info.plist（下面 write_info_plist 写的
    // Applications 列 PosterBoard + 安装器自己两条，条目都是手机给的整条
    // 记录原样转发），手机备份开始后自己下载它来决定备什么。Backup 消息
    // 本身不再带 FactoryInfo / Options / SourceIdentifier，只发
    // MessageName + TargetIdentifier（参考 pymobiledevice3 的 backup()）。
    // 之前 29–31 号把 FactoryInfo 顶层键随消息一起发，手机照样备整台
    // （#30：1665 个文件、495.7 MB，10% 断）；#02 单变量只改请求形状，
    // #03 单变量只在清单里加一条陪衬，消息形状和过滤器都不动。
    write_info_plist(
        &device_dir.join("Info.plist"),
        &udid,
        &serial,
        &product_version,
        &product_type,
        &build_version,
        &device_name,
        applications,
    )?;
    // The device uploads Manifest.plist itself; only ensure the file exists
    // (pymobiledevice3 touches it before the backup).
    let manifest_plist = device_dir.join("Manifest.plist");
    if !manifest_plist.exists() {
        fs::File::create(&manifest_plist)
            .map_err(|e| format!("create Manifest.plist failed: {e}"))?;
    }

    // Targeted backup: only PosterBoard + metadata are written to disk.
    let delegate = FilteringDelegate::new(
        progress_cb,
        ctx_usize as *mut c_void,
        log_cb,
        ctx_usize as *mut c_void,
        Some(backup_root.clone()),
    );
    let mut mb2 = tunnel.connect_mobilebackup2(&logger).await?;
    // The Backup request's TargetIdentifier comes from this cached UDID;
    // the connect path never sets it, so without this line the request
    // carries no TargetIdentifier and the device drops the channel.
    mb2.idevice.set_udid(udid.clone());
    logger.log("backup: starting targeted PosterBoard backup…");
    // #02 实验 C：backup_from_path 只发 MessageName + TargetIdentifier
    // （pm3 原样），不再传 Options / FactoryInfo。set_udid 在上面已调，
    // TargetIdentifier 一定在；backup_from_path 里没调 set_udid 会直接报错。
    let backup_result = mb2
        .backup_from_path(&backup_root, Some(&udid), &delegate)
        .await;
    // The 0-byte stand-ins for filtered payloads must outlive the whole
    // exchange and are removed only now that it has returned (reference:
    // pymobiledevice3 `cleanup_discarded_files()` in a `finally` right
    // after `dl_loop()`).
    let (placeholders_created, placeholders_failed) = delegate.placeholder_stats();
    let placeholders_removed = delegate.cleanup_placeholders();
    if placeholders_created > 0 || placeholders_failed > 0 {
        logger.log(&format!(
            "backup: filtered payloads: {placeholders_created} placeholders created, \
             {placeholders_removed} removed, {placeholders_failed} failed"
        ));
    }
    let final_response =
        backup_result.map_err(|e| format!("targeted backup failed: {e:?}"))?;
    let kept = delegate.kept.load(Ordering::Relaxed);
    let discarded = delegate.discarded.load(Ordering::Relaxed);
    let last_progress = delegate.last_progress();

    // Sanity: the device's Manifest.plist says whether the backup it wrote
    // is encrypted (should be false — we gated on WillEncrypt above).
    let manifest_plist_path = device_dir.join("Manifest.plist");
    let is_encrypted = fs::read(&manifest_plist_path)
        .ok()
        .and_then(|bytes| plist::Value::from_reader(std::io::Cursor::new(bytes)).ok())
        .and_then(|v: plist::Value| v.as_dictionary().cloned())
        .and_then(|d| d.get("IsEncrypted").cloned())
        .map_or(false, |v| matches!(v, plist::Value::Boolean(true)));
    let manifest_db_bytes = fs::metadata(device_dir.join("Manifest.db"))
        .map(|m| m.len())
        .unwrap_or(0);

    Ok(serde_json::json!({
        "udid": udid,
        "backup_dir": device_dir.to_string_lossy(),
        "is_encrypted": is_encrypted,
        "kept_files": kept,
        "discarded_files": discarded,
        "last_progress": last_progress,
        "manifest_db_bytes": manifest_db_bytes,
        "final_response": final_response
            .map(|d| plist_to_json(&plist::Value::Dictionary(d)))
            .unwrap_or(serde_json::Value::Null),
    })
    .to_string())
}

async fn restore_inner(
    pairing_path: String,
    backup_root: String,
    options_json: String,
    log_cb: ALLogCallback,
    progress_cb: ALBackupProgressCallback,
    ctx_usize: usize,
) -> Result<String, String> {
    let logger = Logger::new(log_cb, ctx_usize as *mut c_void);
    let pairing_bytes =
        fs::read(&pairing_path).map_err(|e| format!("read pairing file failed: {e}"))?;
    let mut tunnel = connect_tunnel(&pairing_bytes, &logger).await?;
    // The Restore request's TargetIdentifier (and its default Source)
    // come from this cached UDID; without it restore_from_path fails
    // with InvalidHostID before anything is sent.
    let mut lockdown = tunnel.connect_lockdown(&logger).await?;
    let udid = lockdown_string(&mut lockdown, "UniqueDeviceID", None).await?;
    drop(lockdown);
    let mut mb2 = tunnel.connect_mobilebackup2(&logger).await?;
    mb2.idevice.set_udid(udid);

    // v1 defaults mirror GoldenNugget Mobile: no reboot here (the caller
    // reboots explicitly after the restore), system files on.
    let mut opts = RestoreOptions::new()
        .with_reboot(false)
        .with_system_files(true);
    if let Ok(v) = serde_json::from_str::<serde_json::Value>(&options_json) {
        if let Some(p) = v.get("password").and_then(|x| x.as_str()) {
            opts = opts.with_password(p);
        }
        if let Some(r) = v.get("reboot").and_then(|x| x.as_bool()) {
            opts = opts.with_reboot(r);
        }
    }

    let delegate = FilteringDelegate::new(
        progress_cb,
        ctx_usize as *mut c_void,
        None,
        std::ptr::null_mut(),
        None,
    );
    logger.log("backup: restoring prepared backup…");
    let final_response = mb2
        .restore_from_path(Path::new(&backup_root), None, Some(opts), &delegate)
        .await
        .map_err(|e| format!("restore failed: {e:?}"))?;
    let last_progress = delegate.last_progress();

    // A restore the device abandons part-way ends exactly as cleanly as one
    // it completes (same trap GoldenNugget Mobile documents): only trust it
    // when the final response is present, carries no ErrorCode, and the
    // device-reported progress reached the end (or never reported one).
    let completed = match &final_response {
        Some(d) => {
            !matches!(d.get("ErrorCode"), Some(_))
                && (last_progress < 0.0 || last_progress >= 99.0)
        }
        None => false,
    };

    Ok(serde_json::json!({
        "completed": completed,
        "last_progress": last_progress,
        "final_response": final_response
            .map(|d| plist_to_json(&plist::Value::Dictionary(d)))
            .unwrap_or(serde_json::Value::Null),
    })
    .to_string())
}

async fn app_factory_entry_inner(
    pairing_path: String,
    bundle_id: String,
    log_cb: ALLogCallback,
    ctx_usize: usize,
) -> Result<String, String> {
    let logger = Logger::new(log_cb, ctx_usize as *mut c_void);
    let pairing_bytes =
        fs::read(&pairing_path).map_err(|e| format!("read pairing file failed: {e}"))?;
    let mut tunnel = connect_tunnel(&pairing_bytes, &logger).await?;
    let mut ip = tunnel.connect_installation_proxy(&logger).await?;
    let apps = ip
        .get_apps(Some("Any"), Some(vec![bundle_id.clone()]))
        .await
        .map_err(|e| format!("installation_proxy lookup failed: {e:?}"))?;
    let info = apps
        .get(&bundle_id)
        .ok_or_else(|| format!("app {bundle_id} not found via installation proxy"))?;
    let mut entry = serde_json::Map::new();
    if let Some(d) = info.as_dictionary() {
        // 原样转发手机给的 installation_proxy 完整记录（同 fetch_posterboard_inner：
        // FactoryInfo 条目必须和手机刚给的那条一模一样，只挑 5 个键手机认不出、
        // 过滤作废）。plist_to_json 是逐值转的，整条字典直接传即可。
        for (k, v) in d.iter() {
            entry.insert(k.clone(), plist_to_json(v));
        }
    }
    entry.insert(
        "CFBundleIdentifier".to_string(),
        serde_json::Value::String(bundle_id.clone()),
    );
    Ok(serde_json::json!({
        "bundle_id": bundle_id,
        "entry": entry,
    })
    .to_string())
}

// ---------------------------------------------------------------------------
// FFI entry points (called from lib.rs wrappers)
// ---------------------------------------------------------------------------

/// # Safety
/// All pointer args must be null or valid for their documented types.
pub unsafe fn fetch_posterboard(
    pairing_path: *const c_char,
    backup_root: *const c_char,
    log_cb: ALLogCallback,
    progress_cb: ALBackupProgressCallback,
    ctx: *mut c_void,
    out_json: *mut *mut c_char,
    out_error: *mut *mut c_char,
) -> i32 {
    if out_json.is_null() && out_error.is_null() {
        return 2;
    }
    let pairing_path = opt_str(pairing_path, "airlift_pairing.plist");
    let backup_root = opt_str(backup_root, "");
    if backup_root.is_empty() {
        if !out_error.is_null() {
            *out_error = cstr("backup_root is required");
        }
        return 1;
    }
    let ctx_usize = ctx as usize;
    let res = crate::ffi_util::run_with_large_stack("al_backup_fetch_posterboard", move || {
        idevice_ffi::run_sync_local(fetch_posterboard_inner(
            pairing_path,
            backup_root,
            log_cb,
            progress_cb,
            ctx_usize,
        ))
    });
    match res {
        Ok(Ok(json)) => {
            if !out_json.is_null() {
                *out_json = cstr(json);
            }
            0
        }
        Ok(Err(e)) => {
            if !out_error.is_null() {
                *out_error = cstr(e);
            }
            1
        }
        Err(panic_msg) => {
            if !out_error.is_null() {
                *out_error = cstr(panic_msg);
            }
            1
        }
    }
}

/// # Safety
/// All pointer args must be null or valid for their documented types.
pub unsafe fn restore(
    pairing_path: *const c_char,
    backup_root: *const c_char,
    options_json: *const c_char,
    log_cb: ALLogCallback,
    progress_cb: ALBackupProgressCallback,
    ctx: *mut c_void,
    out_json: *mut *mut c_char,
    out_error: *mut *mut c_char,
) -> i32 {
    if out_json.is_null() && out_error.is_null() {
        return 2;
    }
    let pairing_path = opt_str(pairing_path, "airlift_pairing.plist");
    let backup_root = opt_str(backup_root, "");
    if backup_root.is_empty() {
        if !out_error.is_null() {
            *out_error = cstr("backup_root is required");
        }
        return 1;
    }
    let options_json = opt_str(options_json, "{}");
    let ctx_usize = ctx as usize;
    let res = crate::ffi_util::run_with_large_stack("al_backup_restore", move || {
        idevice_ffi::run_sync_local(restore_inner(
            pairing_path,
            backup_root,
            options_json,
            log_cb,
            progress_cb,
            ctx_usize,
        ))
    });
    match res {
        Ok(Ok(json)) => {
            if !out_json.is_null() {
                *out_json = cstr(json);
            }
            0
        }
        Ok(Err(e)) => {
            if !out_error.is_null() {
                *out_error = cstr(e);
            }
            1
        }
        Err(panic_msg) => {
            if !out_error.is_null() {
                *out_error = cstr(panic_msg);
            }
            1
        }
    }
}

/// # Safety
/// All pointer args must be null or valid for their documented types.
pub unsafe fn app_factory_entry(
    pairing_path: *const c_char,
    bundle_id: *const c_char,
    log_cb: ALLogCallback,
    ctx: *mut c_void,
    out_json: *mut *mut c_char,
    out_error: *mut *mut c_char,
) -> i32 {
    if out_json.is_null() && out_error.is_null() {
        return 2;
    }
    let pairing_path = opt_str(pairing_path, "airlift_pairing.plist");
    let bundle_id = opt_str(bundle_id, POSTERBOARD_BUNDLE);
    let ctx_usize = ctx as usize;
    let res = crate::ffi_util::run_with_large_stack("al_backup_app_factory_entry", move || {
        idevice_ffi::run_sync_local(app_factory_entry_inner(
            pairing_path,
            bundle_id,
            log_cb,
            ctx_usize,
        ))
    });
    match res {
        Ok(Ok(json)) => {
            if !out_json.is_null() {
                *out_json = cstr(json);
            }
            0
        }
        Ok(Err(e)) => {
            if !out_error.is_null() {
                *out_error = cstr(e);
            }
            1
        }
        Err(panic_msg) => {
            if !out_error.is_null() {
                *out_error = cstr(panic_msg);
            }
            1
        }
    }
}
