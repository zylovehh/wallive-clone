//! Airlift FFI — C-callable surface for the iOS on-device exploit.
//!
//! Exports:
//!   al_log_init            — install the tracing subscriber
//!   al_pairing_run_host    — RPPairing host (blocks until paired)
//!   al_pairing_result_free — free the ALPairResult heap strings
//!   al_exploit_run         — run the AirTraffic exploit over the loopback tunnel
//!   al_verify_descriptor   — read-back check: confirm an injected descriptor
//!                            is really on the device (HouseArrest channel)
//!   al_probe_posterboard_container — read-only HouseArrest probe: vend the
//!                            PosterBoard container once and list it (store
//!                            version + sqlite header); writes nothing
//!   al_probe_posterboard_export — read-only AirTraffic export probe:
//!                            ask AirTraffic to copy the PosterBoard
//!                            sqlite (+ -wal) out to Media and read it
//!                            back over AFC; reports size / SHA-256 /
//!                            header checks, saves nothing
//!   al_probe_posterboard_save — probe 3: same export channel, v61
//!                            only, but the recovered DB + -wal are
//!                            saved under the caller-supplied dest dir
//!                            (Documents/posterboard-table) with a
//!                            timestamped name, re-read and SHA-verified
//!   al_fileservice_posterboard_export — FileService export: same
//!                            save + JSON shape as probe 3, but the
//!                            table is read over the CoreDevice file
//!                            service (27.2 only; copy-back is dead
//!                            there and backup returns 0 files)
//!   al_restore_posterboard_writeback — restore test: write a modified
//!                            store (+ 0-byte -wal/-shm) back into the
//!                            device store dir over the direct-write
//!                            AirTraffic channel
//!   al_posterboard_refresh — DVT refresh: SIGKILL PosterBoard, wait for
//!                            respawn, verify with a fresh client
//!   al_backup_fetch_posterboard — targeted backup of the PosterBoard
//!                            container only (GoldenNugget backup mode)
//!   al_backup_restore    — restore a prepared backup directory
//!   al_backup_app_factory_entry — InstallationProxy factory entry for one
//!                            bundle id (Manifest.plist registration)
//!   al_device_info         — read-only device identity (UDID, iOS version,
//!                            build, model) for the dual-mode switch
//!   al_string_free         — free any char* returned by this library

use std::ffi::{c_char, c_void};

pub mod backup;
pub mod device;
pub mod exploit;
pub mod ffi_util;
pub mod file_service;
pub mod grappa;
pub mod logging;
pub mod pairing;

// Re-export idevice-ffi's symbols into our staticlib (tunnel_create_rppairing,
// afc_*, rsd_*, adapter_*, etc.) so Swift can call them directly.
#[allow(unused_imports)]
extern crate idevice_ffi;

pub use pairing::{ALPairPinCb, ALPairReadyCb, ALPairResult};

// ---------------------------------------------------------------------------
// Logging
// ---------------------------------------------------------------------------

/// Install the global tracing subscriber. Returns 0 on success, 1 if already
/// initialised. Call once at launch.
#[no_mangle]
pub extern "C" fn al_log_init(cb: logging::LogCallback, ctx: *mut c_void) -> i32 {
    logging::init(cb, ctx)
}

// ---------------------------------------------------------------------------
// Pairing
// ---------------------------------------------------------------------------

/// Run the RPPairing host. Blocks until a device pairs or an error occurs.
/// Returns 0 on success. `port` 0 lets the OS pick a free port.
///
/// # Safety
/// All `*const c_char` args must be null or valid C strings.
/// `out` must point to a writable `ALPairResult`.
#[no_mangle]
#[allow(clippy::too_many_arguments)]
pub unsafe extern "C" fn al_pairing_run_host(
    bind_addr: *const c_char,
    port: u16,
    name: *const c_char,
    model: *const c_char,
    out_path: *const c_char,
    host_alt_irk_hex: *const c_char,
    ready_cb: ALPairReadyCb,
    pin_cb: ALPairPinCb,
    ctx: *mut c_void,
    out: *mut ALPairResult,
) -> i32 {
    pairing::run_host(
        bind_addr, port, name, model, out_path, host_alt_irk_hex,
        ready_cb, pin_cb, ctx, out,
    )
}

/// Free the heap strings inside an `ALPairResult`.
///
/// # Safety
/// `r` must be null or a `ALPairResult` populated by `al_pairing_run_host`.
#[no_mangle]
pub unsafe extern "C" fn al_pairing_result_free(r: *mut ALPairResult) {
    pairing::result_free(r)
}

// ---------------------------------------------------------------------------
// Exploit
// ---------------------------------------------------------------------------

/// Run the AirTraffic sandbox escape.
///
/// `pairing_path` — path to the RPPairing file produced by `al_pairing_run_host`.
/// `target`       — absolute iOS directory to write the canary into
///                  (e.g. "/var/mobile/Library/SpringBoard").
/// `log_cb`       — receives log lines (called from arbitrary threads).
/// `ctx`          — passed back untouched to every log_cb invocation.
/// `out_json`     — set to a heap JSON result string (free with al_string_free).
/// `out_error`    — set to a heap error string on failure (free with al_string_free).
///
/// Returns 0 on success (exploit confirmed, bytes match), 1 on failure.
///
/// # Safety
/// All pointer arguments must be null or valid for their documented use.
#[no_mangle]
pub unsafe extern "C" fn al_exploit_run(
    pairing_path: *const c_char,
    target: *const c_char,
    log_cb: exploit::ALLogCallback,
    ctx: *mut c_void,
    out_json: *mut *mut c_char,
    out_error: *mut *mut c_char,
) -> i32 {
    let res = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        exploit::run(pairing_path, target, log_cb, ctx, out_json, out_error)
    }));
    match res {
        Ok(rc) => rc,
        Err(e) => {
            if !out_error.is_null() {
                *out_error = ffi_util::cstr(format!("Rust panic in al_exploit_run: {e:?}"));
            }
            1
        }
    }
}

/// Write all files from `source_dir` into `target_dir` outside the sandbox via AirTraffic exploit.
///
/// # Safety
/// All pointer arguments must be null or valid for their documented use.
#[no_mangle]
pub unsafe extern "C" fn al_exploit_write_dir(
    pairing_path: *const c_char,
    source_dir: *const c_char,
    target_dir: *const c_char,
    log_cb: exploit::ALLogCallback,
    ctx: *mut c_void,
    out_error: *mut *mut c_char,
) -> i32 {
    let res = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        exploit::write_dir(pairing_path, source_dir, target_dir, log_cb, ctx, out_error)
    }));
    match res {
        Ok(rc) => rc,
        Err(e) => {
            if !out_error.is_null() {
                *out_error = ffi_util::cstr(format!("Rust panic in al_exploit_write_dir: {e:?}"));
            }
            1
        }
    }
}

/// Inject an entire directory `folder_path` into `target_parent_dir/dest_name` outside the sandbox via AirTraffic exploit.
///
/// # Safety
/// All pointer arguments must be null or valid for their documented use.
#[no_mangle]
pub unsafe extern "C" fn al_exploit_inject_folder(
    pairing_path: *const c_char,
    folder_path: *const c_char,
    target_parent_dir: *const c_char,
    dest_name: *const c_char,
    log_cb: exploit::ALLogCallback,
    ctx: *mut c_void,
    out_error: *mut *mut c_char,
) -> i32 {
    let res = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        exploit::inject_folder(pairing_path, folder_path, target_parent_dir, dest_name, log_cb, ctx, out_error)
    }));
    match res {
        Ok(rc) => rc,
        Err(e) => {
            if !out_error.is_null() {
                *out_error = ffi_util::cstr(format!("Rust panic in al_exploit_inject_folder: {e:?}"));
            }
            1
        }
    }
}

/// Read-back check: confirm an injected descriptor is really on the device.
/// See exploit::verify_descriptor. Returns 0 only when the descriptor dir,
/// the identifier file and Wallpaper.plist are all present. out_json is set
/// whenever the read-back channel works, with the per-item report
/// (free with al_string_free). out_error names missing items, or the channel
/// failure (house_arrest_unavailable: ...).
///
/// # Safety
/// All pointer arguments must be null or valid for their documented use.
#[no_mangle]
pub unsafe extern "C" fn al_verify_descriptor(
    pairing_path: *const c_char,
    target_parent_dir: *const c_char,
    dest_name: *const c_char,
    log_cb: exploit::ALLogCallback,
    ctx: *mut c_void,
    out_json: *mut *mut c_char,
    out_error: *mut *mut c_char,
) -> i32 {
    let res = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        exploit::verify_descriptor(pairing_path, target_parent_dir, dest_name, log_cb, ctx, out_json, out_error)
    }));
    match res {
        Ok(rc) => rc,
        Err(e) => {
            if !out_error.is_null() {
                *out_error = ffi_util::cstr(format!("Rust panic in al_verify_descriptor: {e:?}"));
            }
            1
        }
    }
}

/// Read-only HouseArrest probe of the PosterBoard container. See
/// exploit::probe_posterboard_container. Returns 0 with out_json set
/// whenever the vend worked (even when the sqlite file was not found);
/// 1 with out_error on channel failure (tunnel / HouseArrest / vend),
/// with the device's own error text verbatim. Writes nothing to the
/// device. `pairing_path` may be null (falls back to
/// "wallpaper_pairing.plist").
///
/// # Safety
/// All pointer arguments must be null or valid for their documented use.
#[no_mangle]
pub unsafe extern "C" fn al_probe_posterboard_container(
    pairing_path: *const c_char,
    log_cb: exploit::ALLogCallback,
    ctx: *mut c_void,
    out_json: *mut *mut c_char,
    out_error: *mut *mut c_char,
) -> i32 {
    let res = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        exploit::probe_posterboard_container(pairing_path, log_cb, ctx, out_json, out_error)
    }));
    match res {
        Ok(rc) => rc,
        Err(e) => {
            if !out_error.is_null() {
                *out_error = ffi_util::cstr(format!("Rust panic in al_probe_posterboard_container: {e:?}"));
            }
            1
        }
    }
}

/// Read-only AirTraffic export probe of the PosterBoard sqlite. See
/// exploit::probe_posterboard_export. Returns 0 with out_json set
/// whenever the channel ran (even when no valid sqlite was recovered);
/// 1 with out_error on channel failure (tunnel / AFC connect), with
/// the device's own error text verbatim. Writes nothing into the
/// PosterBoard container and does not save the recovered bytes
/// anywhere. `pairing_path` may be null (falls back to
/// "wallpaper_pairing.plist").
///
/// # Safety
/// All pointer arguments must be null or valid for their documented use.
#[no_mangle]
pub unsafe extern "C" fn al_probe_posterboard_export(
    pairing_path: *const c_char,
    log_cb: exploit::ALLogCallback,
    ctx: *mut c_void,
    out_json: *mut *mut c_char,
    out_error: *mut *mut c_char,
) -> i32 {
    let res = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        exploit::probe_posterboard_export(pairing_path, log_cb, ctx, out_json, out_error)
    }));
    match res {
        Ok(rc) => rc,
        Err(e) => {
            if !out_error.is_null() {
                *out_error = ffi_util::cstr(format!("Rust panic in al_probe_posterboard_export: {e:?}"));
            }
            1
        }
    }
}

/// Read-only AirTraffic export probe of the PosterBoard sqlite, with
/// save (probe 3). See exploit::probe_posterboard_save. Only store
/// version 61 is tried (probe 2 proved it live on 27.0.1). Returns 0
/// with out_json set whenever the channel ran (even when nothing was
/// saved — the JSON tells the truth); 1 with out_error on channel
/// failure (tunnel / AFC connect) or a missing/uncreatable save
/// directory, with the device's own error text verbatim. Writes
/// nothing into the PosterBoard container; the saved files land in the
/// app's own Documents/posterboard-table directory. `pairing_path` may
/// be null (falls back to "wallpaper_pairing.plist"); `dest_dir` has no
/// silent fallback (Swift always passes it); an empty `stamp` falls
/// back to unix seconds so file names still never collide.
///
/// # Safety
/// All pointer arguments must be null or valid for their documented use.
#[no_mangle]
pub unsafe extern "C" fn al_probe_posterboard_save(
    pairing_path: *const c_char,
    dest_dir: *const c_char,
    stamp: *const c_char,
    log_cb: exploit::ALLogCallback,
    ctx: *mut c_void,
    out_json: *mut *mut c_char,
    out_error: *mut *mut c_char,
) -> i32 {
    let res = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        exploit::probe_posterboard_save(pairing_path, dest_dir, stamp, log_cb, ctx, out_json, out_error)
    }));
    match res {
        Ok(rc) => rc,
        Err(e) => {
            if !out_error.is_null() {
                *out_error = ffi_util::cstr(format!("Rust panic in al_probe_posterboard_save: {e:?}"));
            }
            1
        }
    }
}

/// Read-only CoreDevice FileService export of the PosterBoard sqlite,
/// with save. Same save + JSON shape as al_probe_posterboard_save
/// (v61 only, dest_dir + stamp, re-read and SHA-verified), but the
/// table is read over the file service instead of AirTraffic
/// copy-back. Only used on iOS 27.2+ (Swift gates it): copy-back is
/// dead there and backup returns 0 files. Whether the service lets
/// this app read the PosterBoard container is unproven — that needs a
/// real 27.2 device; a refusal comes back as out_error, not a silent
/// wrong table. Writes nothing into the PosterBoard container.
/// `pairing_path` may be null (falls back to "wallpaper_pairing.plist");
/// `dest_dir` has no silent fallback (Swift always passes it); an empty
/// `stamp` falls back to unix seconds so file names still never collide.
///
/// # Safety
/// All pointer arguments must be null or valid for their documented use.
#[no_mangle]
pub unsafe extern "C" fn al_fileservice_posterboard_export(
    pairing_path: *const c_char,
    dest_dir: *const c_char,
    stamp: *const c_char,
    log_cb: exploit::ALLogCallback,
    ctx: *mut c_void,
    out_json: *mut *mut c_char,
    out_error: *mut *mut c_char,
) -> i32 {
    let res = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        exploit::fileservice_posterboard_export(pairing_path, dest_dir, stamp, log_cb, ctx, out_json, out_error)
    }));
    match res {
        Ok(rc) => rc,
        Err(e) => {
            if !out_error.is_null() {
                *out_error = ffi_util::cstr(format!("Rust panic in al_fileservice_posterboard_export: {e:?}"));
            }
            1
        }
    }
}

/// Restore-test writeback: write a modified PosterBoard store (plus 0-byte
/// -wal/-shm) back into the device store directory. See
/// exploit::restore_posterboard_writeback. Returns 0 with out_json set
/// whenever the write ran (even when the device rejected it — the JSON
/// tells the truth); 1 with out_error only for local validation failures
/// or channel failures, with the device's own error text verbatim.
/// `pairing_path` may be null (falls back to "wallpaper_pairing.plist");
/// `staged_dir` / `target_dir` have no silent fallback (Swift passes both).
///
/// # Safety
/// All pointer arguments must be null or valid for their documented use.
#[no_mangle]
pub unsafe extern "C" fn al_restore_posterboard_writeback(
    pairing_path: *const c_char,
    staged_dir: *const c_char,
    target_dir: *const c_char,
    log_cb: exploit::ALLogCallback,
    ctx: *mut c_void,
    out_json: *mut *mut c_char,
    out_error: *mut *mut c_char,
) -> i32 {
    let res = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        exploit::restore_posterboard_writeback(pairing_path, staged_dir, target_dir, log_cb, ctx, out_json, out_error)
    }));
    match res {
        Ok(rc) => rc,
        Err(e) => {
            if !out_error.is_null() {
                *out_error = ffi_util::cstr(format!("Rust panic in al_restore_posterboard_writeback: {e:?}"));
            }
            1
        }
    }
}

/// DVT poster refresh: kill PosterBoard (SIGKILL) and wait for it to
/// respawn so the gallery re-reads the extension store. See
/// exploit::posterboard_refresh. Returns 0 with out_json set whenever the
/// refresh ran (even when refresh_confirmed is false); 1 with out_error on
/// operational failure before the signal is sent.
/// `pairing_path` may be null (falls back to "wallpaper_pairing.plist").
/// Never restarts SpringBoard or the device.
///
/// # Safety
/// All pointer arguments must be null or valid for their documented use.
#[no_mangle]
pub unsafe extern "C" fn al_posterboard_refresh(
    pairing_path: *const c_char,
    log_cb: exploit::ALLogCallback,
    ctx: *mut c_void,
    out_json: *mut *mut c_char,
    out_error: *mut *mut c_char,
) -> i32 {
    let res = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        exploit::posterboard_refresh(pairing_path, log_cb, ctx, out_json, out_error)
    }));
    match res {
        Ok(rc) => rc,
        Err(e) => {
            if !out_error.is_null() {
                *out_error = ffi_util::cstr(format!("Rust panic in al_posterboard_refresh: {e:?}"));
            }
            1
        }
    }
}

/// DVT SpringBoard respring (test only). See exploit::springboard_respring.
/// Returns 0 with out_json set whenever the respring ran (even when
/// respring_confirmed is false); 1 with out_error on operational failure
/// before the signal is sent.
/// `pairing_path` may be null (falls back to "wallpaper_pairing.plist").
/// Restarts the desktop only — never restarts the device.
///
/// # Safety
/// All pointer arguments must be null or valid for their documented use.
#[no_mangle]
pub unsafe extern "C" fn al_springboard_respring(
    pairing_path: *const c_char,
    log_cb: exploit::ALLogCallback,
    ctx: *mut c_void,
    out_json: *mut *mut c_char,
    out_error: *mut *mut c_char,
) -> i32 {
    let res = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        exploit::springboard_respring(pairing_path, log_cb, ctx, out_json, out_error)
    }));
    match res {
        Ok(rc) => rc,
        Err(e) => {
            if !out_error.is_null() {
                *out_error = ffi_util::cstr(format!("Rust panic in al_springboard_respring: {e:?}"));
            }
            1
        }
    }
}

/// Free any `*mut c_char` returned by this library.
///
/// # Safety
/// `p` must be null or a pointer returned by one of this library's functions.
#[no_mangle]
pub unsafe extern "C" fn al_string_free(p: *mut c_char) {
    let _ = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        ffi_util::string_free(p);
    }));
}

// ---------------------------------------------------------------------------
// Live Card Scanner / Syslog Stream
// ---------------------------------------------------------------------------

/// Stream device syslog lines over the RSD tunnel.
/// Blocks until `al_syslog_stream_stop()` is called or an error occurs.
///
/// # Safety
/// All pointers must be valid or null as documented.
#[no_mangle]
pub unsafe extern "C" fn al_syslog_stream_start(
    pairing_path: *const c_char,
    line_cb: exploit::ALSyslogLineCallback,
    ctx: *mut c_void,
    out_error: *mut *mut c_char,
) -> i32 {
    let res = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        exploit::run_syslog_stream(pairing_path, line_cb, ctx, out_error)
    }));
    match res {
        Ok(rc) => rc,
        Err(e) => {
            if !out_error.is_null() {
                *out_error = ffi_util::cstr(format!("Rust panic in al_syslog_stream_start: {e:?}"));
            }
            1
        }
    }
}

/// Request the running syslog stream to stop.
#[no_mangle]
pub extern "C" fn al_syslog_stream_stop() {
    let _ = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        exploit::stop_syslog_stream();
    }));
}

// ---------------------------------------------------------------------------
// Passthm Archive Extractor
// ---------------------------------------------------------------------------

/// Extract all image and asset files from a .passthm zip archive into `dest_dir`.
/// Returns 0 on success.
#[no_mangle]
pub unsafe extern "C" fn al_passthm_extract(
    archive_path: *const c_char,
    dest_dir: *const c_char,
) -> i32 {
    let res = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        let archive_path = match ffi_util::opt_str(archive_path, "").as_str() {
            "" => return 1,
            s => s.to_string(),
        };
        let dest_dir = match ffi_util::opt_str(dest_dir, "").as_str() {
            "" => return 1,
            s => s.to_string(),
        };

        let file = match std::fs::File::open(&archive_path) {
            Ok(f) => f,
            Err(_) => return 2,
        };

        let mut archive = match zip::ZipArchive::new(file) {
            Ok(a) => a,
            Err(_) => return 3,
        };

        let dest = std::path::Path::new(&dest_dir);
        if std::fs::create_dir_all(dest).is_err() {
            return 4;
        }

        for i in 0..archive.len() {
            let mut file = match archive.by_index(i) {
                Ok(f) => f,
                Err(_) => continue,
            };
            let name = match file.enclosed_name() {
                Some(n) => n.to_owned(),
                None => continue,
            };
            if file.is_file() {
                let file_name = name.file_name().unwrap_or(name.as_os_str());
                let outpath = dest.join(file_name);
                if let Ok(mut outfile) = std::fs::File::create(&outpath) {
                    let _ = std::io::copy(&mut file, &mut outfile);
                }
            }
        }
        0
    }));
    res.unwrap_or(1)
}

/// Extract all files and directories from a zip archive into `dest_dir`.
/// Preserves directory hierarchies and skips unsafe path traversals.
/// Returns 0 on success.
#[no_mangle]
pub unsafe extern "C" fn al_zip_extract_all(
    archive_path: *const c_char,
    dest_dir: *const c_char,
) -> i32 {
    let res = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        let archive_path = match ffi_util::opt_str(archive_path, "").as_str() {
            "" => return 1,
            s => s.to_string(),
        };
        let dest_dir = match ffi_util::opt_str(dest_dir, "").as_str() {
            "" => return 1,
            s => s.to_string(),
        };

        let file = match std::fs::File::open(&archive_path) {
            Ok(f) => f,
            Err(_) => return 2,
        };

        let mut archive = match zip::ZipArchive::new(file) {
            Ok(a) => a,
            Err(_) => return 3,
        };

        let dest = std::path::Path::new(&dest_dir);
        if std::fs::create_dir_all(dest).is_err() {
            return 4;
        }

        for i in 0..archive.len() {
            let mut file = match archive.by_index(i) {
                Ok(f) => f,
                Err(_) => continue,
            };
            let name = match file.enclosed_name() {
                Some(n) => n.to_owned(),
                None => continue,
            };
            let name_str = name.to_string_lossy();
            if name_str.contains("__MACOSX") || name_str.ends_with(".DS_Store") {
                continue;
            }
            let outpath = dest.join(&name);
            if file.is_dir() {
                let _ = std::fs::create_dir_all(&outpath);
            } else {
                if let Some(parent) = outpath.parent() {
                    let _ = std::fs::create_dir_all(parent);
                }
                if let Ok(mut outfile) = std::fs::File::create(&outpath) {
                    let _ = std::io::copy(&mut file, &mut outfile);
                }
            }
        }
        0
    }));
    res.unwrap_or(1)
}

/// Query InstallationProxy over the pairing tunnel for an application's Container directory path.
/// Returns 0 on success (with out_container set), 1 on error (with out_error set).
#[no_mangle]
pub unsafe extern "C" fn al_find_app_container(
    pairing_path: *const c_char,
    bundle_id: *const c_char,
    log_cb: exploit::ALLogCallback,
    ctx: *mut c_void,
    out_container: *mut *mut c_char,
    out_error: *mut *mut c_char,
) -> i32 {
    let res = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        exploit::find_container(pairing_path, bundle_id, log_cb, ctx, out_container, out_error)
    }));
    match res {
        Ok(rc) => rc,
        Err(e) => {
            if !out_error.is_null() {
                *out_error = ffi_util::cstr(format!("Rust panic in al_find_app_container: {e:?}"));
            }
            1
        }
    }
}

/// Trigger device restart / respring via Diagnostics Relay over the pairing tunnel.
/// Returns 0 on success, 1 on error.
#[no_mangle]
pub unsafe extern "C" fn al_device_respring(
    pairing_path: *const c_char,
    log_cb: exploit::ALLogCallback,
    ctx: *mut c_void,
    out_error: *mut *mut c_char,
) -> i32 {
    let res = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        exploit::device_respring(pairing_path, log_cb, ctx, out_error)
    }));
    match res {
        Ok(rc) => rc,
        Err(e) => {
            if !out_error.is_null() {
                *out_error = ffi_util::cstr(format!("Rust panic in al_device_respring: {e:?}"));
            }
            1
        }
    }
}

// ---------------------------------------------------------------------------
// Target Host Configuration
// ---------------------------------------------------------------------------

/// Set the primary target host/IP (e.g. "10.7.0.1") to dial first for RSD and tunnel operations.
/// Passing NULL or empty string resets to None.
/// Returns 0 on success.
#[no_mangle]
pub unsafe extern "C" fn al_set_target_host(host: *const c_char) -> i32 {
    let res = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        let host_str = if host.is_null() {
            None
        } else {
            let s = ffi_util::opt_str(host, "").trim().to_string();
            if s.is_empty() { None } else { Some(s) }
        };
        exploit::set_target_host(host_str);
        0
    }));
    res.unwrap_or(1)
}

/// Set additional candidate target hosts (e.g. from local interface discovery).
/// `hosts` is an array of C-strings of length `count`.
/// Returns 0 on success.
#[no_mangle]
pub unsafe extern "C" fn al_set_target_hosts(hosts: *const *const c_char, count: usize) -> i32 {
    let res = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        let mut list = Vec::new();
        if !hosts.is_null() {
            for i in 0..count {
                let p = *hosts.add(i);
                if !p.is_null() {
                    let s = ffi_util::opt_str(p, "").trim().to_string();
                    if !s.is_empty() && !list.contains(&s) {
                        list.push(s);
                    }
                }
            }
        }
        exploit::set_target_hosts(list);
        0
    }));
    res.unwrap_or(1)
}

/// Clear custom target host settings, reverting to default tunnel IP fallbacks.
#[no_mangle]
pub extern "C" fn al_clear_target_hosts() {
    let _ = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        exploit::clear_target_hosts();
    }));
}

// ---------------------------------------------------------------------------
// MobileBackup2-based PosterBoard install path (GoldenNugget "backup" mode)
// ---------------------------------------------------------------------------

/// Targeted backup of the PosterBoard container only. `backup_root` is the
/// directory the backup is written to (a `<UDID>` subdirectory is created
/// under it). Returns 0 with JSON in `out_json`:
/// `{udid, backup_dir, is_encrypted, kept_files, discarded_files,
///   last_progress, manifest_db_bytes, final_response}`.
/// Returns 1 with `out_error` on failure (incl. encrypted backups, v1).
///
/// # Safety
/// All pointer arguments must be null or valid for their documented types.
#[no_mangle]
pub unsafe extern "C" fn al_backup_fetch_posterboard(
    pairing_path: *const c_char,
    backup_root: *const c_char,
    log_cb: exploit::ALLogCallback,
    progress_cb: backup::ALBackupProgressCallback,
    ctx: *mut c_void,
    out_json: *mut *mut c_char,
    out_error: *mut *mut c_char,
) -> i32 {
    let res = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        backup::fetch_posterboard(
            pairing_path,
            backup_root,
            log_cb,
            progress_cb,
            ctx,
            out_json,
            out_error,
        )
    }));
    match res {
        Ok(rc) => rc,
        Err(e) => {
            if !out_error.is_null() {
                *out_error = ffi_util::cstr(format!("Rust panic in al_backup_fetch_posterboard: {e:?}"));
            }
            1
        }
    }
}

/// Restore a prepared backup directory (`backup_root` holds the `<UDID>`
/// subdirectory). `options_json` is an optional JSON object, e.g.
/// `{"password": "...", "reboot": false}`. Returns 0 with JSON in `out_json`:
/// `{completed, last_progress, final_response}`. `completed` is only true
/// when the device confirmed the restore AND its progress reached the end.
/// Returns 1 with `out_error` on failure.
///
/// # Safety
/// All pointer arguments must be null or valid for their documented types.
#[no_mangle]
pub unsafe extern "C" fn al_backup_restore(
    pairing_path: *const c_char,
    backup_root: *const c_char,
    options_json: *const c_char,
    log_cb: exploit::ALLogCallback,
    progress_cb: backup::ALBackupProgressCallback,
    ctx: *mut c_void,
    out_json: *mut *mut c_char,
    out_error: *mut *mut c_char,
) -> i32 {
    let res = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        backup::restore(
            pairing_path,
            backup_root,
            options_json,
            log_cb,
            progress_cb,
            ctx,
            out_json,
            out_error,
        )
    }));
    match res {
        Ok(rc) => rc,
        Err(e) => {
            if !out_error.is_null() {
                *out_error = ffi_util::cstr(format!("Rust panic in al_backup_restore: {e:?}"));
            }
            1
        }
    }
}

/// Read-only device identity over the pairing tunnel (for the dual-mode
/// switch). Returns 0 with JSON in `out_json`:
/// `{udid, product_version, build_version, product_type, device_name}`.
/// Returns 1 with `out_error` on failure. Writes nothing to the device.
///
/// # Safety
/// All pointer arguments must be null or valid for their documented types.
#[no_mangle]
pub unsafe extern "C" fn al_device_info(
    pairing_path: *const c_char,
    log_cb: exploit::ALLogCallback,
    ctx: *mut c_void,
    out_json: *mut *mut c_char,
    out_error: *mut *mut c_char,
) -> i32 {
    let res = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        device::device_info(pairing_path, log_cb, ctx, out_json, out_error)
    }));
    match res {
        Ok(rc) => rc,
        Err(e) => {
            if !out_error.is_null() {
                *out_error = ffi_util::cstr(format!("Rust panic in al_device_info: {e:?}"));
            }
            1
        }
    }
}

/// InstallationProxy factory entry for one bundle id, for Manifest.plist
/// `Applications` registration. Returns 0 with JSON in `out_json`:
/// `{bundle_id, entry: {Container, CFBundleVersion, ApplicationSINF (hex),
///   iTunesMetadata, CFBundleIdentifier}}`.
/// Returns 1 with `out_error` on failure.
///
/// # Safety
/// All pointer arguments must be null or valid for their documented types.
#[no_mangle]
pub unsafe extern "C" fn al_backup_app_factory_entry(
    pairing_path: *const c_char,
    bundle_id: *const c_char,
    log_cb: exploit::ALLogCallback,
    ctx: *mut c_void,
    out_json: *mut *mut c_char,
    out_error: *mut *mut c_char,
) -> i32 {
    let res = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        backup::app_factory_entry(pairing_path, bundle_id, log_cb, ctx, out_json, out_error)
    }));
    match res {
        Ok(rc) => rc,
        Err(e) => {
            if !out_error.is_null() {
                *out_error = ffi_util::cstr(format!("Rust panic in al_backup_app_factory_entry: {e:?}"));
            }
            1
        }
    }
}
