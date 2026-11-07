// Airlift Rust core — C FFI surface.
//
// All fallible calls return an int32 code (0 == OK). Heap strings must be
// released with al_string_free().
#ifndef AIRLIFT_H
#define AIRLIFT_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// ---------------------------------------------------------------------------
// Logging
// ---------------------------------------------------------------------------

// Receives every formatted log line. `msg` is only valid for the duration of
// the call — copy it. May be called from arbitrary Rust threads.
typedef void (*ALLogCallback)(void *ctx, const char *msg);

// Install the global tracing subscriber. Returns 0 on success, 1 if already
// initialised. Call once at launch.
int32_t al_log_init(ALLogCallback cb, void *ctx);

// Free any char* returned by this library.
void al_string_free(char *p);

// ---------------------------------------------------------------------------
// Pairing — RPPairing host
// ---------------------------------------------------------------------------

// Fires once the host is bound. The Swift side publishes `service_id` over
// Bonjour (NetService). All pointers are only valid during the call.
typedef void (*ALPairReadyCb)(void *ctx,
                               const char *service_id,
                               uint16_t port,
                               const char *const *txt_keys,
                               const char *const *txt_vals,
                               size_t txt_count);

// Fires with the PIN the user must confirm in Settings → Developer Mode.
typedef void (*ALPairPinCb)(const char *pin, void *ctx);

// Heap-allocated result of one pairing run. Free with al_pairing_result_free().
typedef struct {
    char *error;
    char *device_name;
    char *device_model;
    char *device_udid;
    char *pairing_file_path;
    char *host_alt_irk_hex;
} ALPairResult;

// Run the RPPairing host. BLOCKS until paired or errored — run off main thread.
// `port` 0 lets the OS pick a free port.
// `host_alt_irk_hex` is the value a previous run returned, or NULL/"" first time.
// Returns 0 on success, non-zero on error (with out->error set).
int32_t al_pairing_run_host(const char *bind_addr,
                             uint16_t port,
                             const char *name,
                             const char *model,
                             const char *out_path,
                             const char *host_alt_irk_hex,
                             ALPairReadyCb ready_cb,
                             ALPairPinCb pin_cb,
                             void *ctx,
                             ALPairResult *out);

// Free the heap strings inside an ALPairResult.
void al_pairing_result_free(ALPairResult *r);

// ---------------------------------------------------------------------------
// Exploit
// ---------------------------------------------------------------------------

// Run the AirTraffic sandbox escape. BLOCKS — run off the main thread.
// `pairing_path` — path produced by al_pairing_run_host.
// `target`       — absolute iOS directory (e.g. "/var/mobile/Library/SpringBoard").
// `log_cb`       — receives log lines (called from arbitrary threads; may be NULL).
// `out_json`     — set to a JSON result string; free with al_string_free().
// `out_error`    — set on failure; free with al_string_free().
// Returns 0 if the canary write was confirmed, 1 otherwise.
int32_t al_exploit_run(const char *pairing_path,
                        const char *target,
                        ALLogCallback log_cb,
                        void *ctx,
                        char **out_json,
                        char **out_error);

// Write all files from `source_dir` into `target_dir` on the device.
// Returns 0 on success, 1 on error (with out_error set).
int32_t al_exploit_write_dir(const char *pairing_path,
                             const char *source_dir,
                             const char *target_dir,
                             ALLogCallback log_cb,
                             void *ctx,
                             char **out_error);

// Inject an entire directory `folder_path` into `target_parent_dir/dest_name` on the device.
// Preserves complete folder hierarchy and all internal assets in one AirTraffic operation.
// Returns 0 on success, 1 on error (with out_error set).
int32_t al_exploit_inject_folder(const char *pairing_path,
                                 const char *folder_path,
                                 const char *target_parent_dir,
                                 const char *dest_name,
                                 ALLogCallback log_cb,
                                 void *ctx,
                                 char **out_error);

// Read-back check for one injected descriptor. Returns 0 only when the
// descriptor dir, the identifier file and Wallpaper.plist are all present.
// `out_json` is set whenever the read-back channel works, with the per-item
// report (free with al_string_free()); `out_error` names missing items, or
// the channel failure ("house_arrest_unavailable: ...").
// `target_parent_dir` is the absolute device path used at inject time
// (.../PRBPosterExtensionDataStore/<ver>/Extensions/<ext>/descriptors);
// the implementation reads it through the PosterBoard container
// (HouseArrest VendContainer — plain jailed AFC cannot see these paths).
int32_t al_verify_descriptor(const char *pairing_path,
                             const char *target_parent_dir,
                             const char *dest_name,
                             ALLogCallback log_cb,
                             void *ctx,
                             char **out_json,
                             char **out_error);

// Read-only HouseArrest probe of the PosterBoard container. BLOCKS — run
// off the main thread. Vends the container exactly once (no retry) and
// lists it: container root entries, store version dirs (61 / 62 / ...),
// the PBFPosterExtensionDataStoreSQLiteDatabase.sqlite3 file (size + first
// 100 bytes header, SQLite magic checked), and its -wal / -shm companions
// (sizes only). Writes nothing to the device. Returns 0 with out_json set
// whenever the vend worked (even when the sqlite file was not found — the
// JSON tells the truth); 1 with out_error on channel failure (tunnel /
// HouseArrest connect / vend), with the device's own error text verbatim.
// out_json format:
//   {"channel": "house_arrest", "vend_ok": true, "root_entries": [...],
//    "root_count": N, "store_versions": ["61", ...],
//    "version_entries": [...], "db_path": "..."|null, "db_exists": bool,
//    "db_size": N|null, "db_header_hex": "..."|null,
//    "db_is_sqlite": bool, "db_wal_size": N|null, "db_shm_size": N|null}
int32_t al_probe_posterboard_container(const char *pairing_path,
                                       ALLogCallback log_cb,
                                       void *ctx,
                                       char **out_json,
                                       char **out_error);

// Read-only AirTraffic export probe: ask AirTraffic to copy the
// PosterBoard sqlite (+ -wal) out to Media and read it back over AFC.
// Tries store version 61, then 62, then the -wal of the version whose
// DB read back as valid SQLite. Writes nothing into the PosterBoard
// container and does not save the recovered bytes anywhere — it only
// reports size / SHA-256 / header checks. Returns 0 with out_json set
// whenever the channel ran (even when no valid sqlite was recovered —
// the JSON tells the truth); 1 with out_error on channel failure
// (tunnel / AFC connect), with the device's own error text verbatim.
// out_json format:
//   {"channel": "airtraffic_export", "container": "...",
//    "attempts": [{"version": "61"|"62", "kind": "db"|"wal",
//    "path": "...", "ok": bool, "size": N|null, "sha256": "..."|null,
//    "is_sqlite": bool, "is_wal": bool, "error": "..."|null}, ...],
//    "db_version": "61"|"62"|null, "db_size": N|null,
//    "db_sha256": "..."|null, "db_is_sqlite": bool,
//    "wal_size": N|null, "wal_sha256": "..."|null, "wal_is_wal": bool,
//    "success": bool}
int32_t al_probe_posterboard_export(const char *pairing_path,
                                    ALLogCallback log_cb,
                                    void *ctx,
                                    char **out_json,
                                    char **out_error);

// Read-only AirTraffic export probe of the PosterBoard sqlite, with
// save (probe 3): same channel as al_probe_posterboard_export, but
// only store version 61 is tried (probe 2 proved it live on 27.0.1),
// and the recovered DB + -wal are saved under `dest_dir` (the app's
// own Documents/posterboard-table, passed in by Swift) with a
// timestamped name, then re-read and SHA-verified. The -wal is NOT
// merged here — Swift merges it with system SQLite3 on a copy.
// Writes nothing into the PosterBoard container. Returns 0 with
// out_json set whenever the channel ran (even when nothing was saved —
// the JSON tells the truth); 1 with out_error on channel failure
// (tunnel / AFC connect) or a missing/uncreatable save directory.
// out_json format:
//   {"channel": "airtraffic_export_save", "container": "...",
//    "attempts": [{"version": "61", "kind": "db"|"wal",
//    "path": "...", "ok": bool, "size": N|null, "sha256": "..."|null,
//    "is_sqlite": bool, "is_wal": bool, "error": "..."|null}, ...],
//    "db_version": "61", "db_size": N|null, "db_sha256": "..."|null,
//    "db_is_sqlite": bool, "saved_db_path": "..."|null,
//    "saved_db_size": N|null, "saved_db_sha256": "..."|null,
//    "saved_db_ok": bool, "wal_size": N|null, "wal_sha256": "..."|null,
//    "wal_is_wal": bool, "saved_wal_path": "..."|null,
//    "saved_wal_size": N|null, "saved_wal_sha256": "..."|null,
//    "saved_wal_ok": bool, "success": bool}
int32_t al_probe_posterboard_save(const char *pairing_path,
                                  const char *dest_dir,
                                  const char *stamp,
                                  ALLogCallback log_cb,
                                  void *ctx,
                                  char **out_json,
                                  char **out_error);

// DVT poster refresh: SIGKILL PosterBoard (signal 9) and wait for launchd
// to respawn it, so the gallery re-reads the extension store. Returns 0
// with out_json set whenever the refresh ran (even when refresh_confirmed
// is false — the JSON tells the truth); 1 with out_error on operational
// failure before the signal is sent. `pairing_path` may be null (falls back
// to "wallpaper_pairing.plist"). Never restarts SpringBoard or the device.
// out_json format (our own, parsed leniently by Swift):
//   {"refresh_confirmed": bool, "wallpaper_visible": "unverified",
//    "old_pid": N, "new_pid": N|null, "verified_pid": N|null,
//    "verify_error": "..."|null, "error": "..."|null}
// wallpaper_visible is always "unverified": only looking at the lock-screen
// gallery can confirm the wallpaper is listed.
int32_t al_posterboard_refresh(const char *pairing_path,
                               ALLogCallback log_cb,
                               void *ctx,
                               char **out_json,
                               char **out_error);

// ---------------------------------------------------------------------------
// Syslog Stream / Live Card Detection
// ---------------------------------------------------------------------------

typedef void (*ALSyslogLineCallback)(void *ctx, const char *line);

// Stream device syslog messages over RSD.
// Blocks until al_syslog_stream_stop() is called.
int32_t al_syslog_stream_start(const char *pairing_path,
                               ALSyslogLineCallback line_cb,
                               void *ctx,
                               char **out_error);

// Stop any running syslog stream.
void al_syslog_stream_stop(void);

// Extract all files from a .passthm archive into dest_dir. Returns 0 on success.
int32_t al_passthm_extract(const char *archive_path, const char *dest_dir);

// Extract all files and directories from a zip archive into dest_dir. Returns 0 on success.
int32_t al_zip_extract_all(const char *archive_path, const char *dest_dir);

// Look up the Data Application Container directory for a bundle ID (e.g. "com.apple.PosterBoard").
// Blocks until resolved or errored. Returns 0 on success, with out_container set.
int32_t al_find_app_container(const char *pairing_path,
                             const char *bundle_id,
                             ALLogCallback log_cb,
                             void *ctx,
                             char **out_container,
                             char **out_error);

// Restart device / respring via Diagnostics Relay over the pairing tunnel.
// Blocks until sent. Returns 0 on success.
int32_t al_device_respring(const char *pairing_path,
                          ALLogCallback log_cb,
                          void *ctx,
                          char **out_error);

// ---------------------------------------------------------------------------
// MobileBackup2-based PosterBoard install path (GoldenNugget "backup" mode)
// ---------------------------------------------------------------------------

// Progress callback: percent in [0, 100], or -1 when unknown.
// bytes_done/files_done are cumulative across DL batches; bytes_total is the
// current batch's expected total (0 if unknown). May be NULL.
// Called from arbitrary Rust threads, throttled to whole-percent steps.
typedef void (*ALBackupProgressCallback)(void *ctx, double percent, uint64_t bytes_done, uint64_t bytes_total, uint32_t files_done);

// Targeted backup of the PosterBoard container only. BLOCKS — run off the
// main thread. `backup_root` is the directory the backup is written to (a
// `<UDID>` subdirectory is created under it). Returns 0 with out_json set:
//   {"udid", "backup_dir", "is_encrypted", "kept_files", "discarded_files",
//    "last_progress", "manifest_db_bytes", "final_response"}
// Returns 1 with out_error on failure. Refuses encrypted backups (v1).
int32_t al_backup_fetch_posterboard(const char *pairing_path,
                                    const char *backup_root,
                                    ALLogCallback log_cb,
                                    ALBackupProgressCallback progress_cb,
                                    void *ctx,
                                    char **out_json,
                                    char **out_error);

// Restore a prepared backup directory (`backup_root` holds the `<UDID>`
// subdirectory). BLOCKS — run off the main thread. `options_json` is an
// optional JSON object, e.g. {"password": "...", "reboot": false}.
// Returns 0 with out_json set:
//   {"completed", "last_progress", "final_response"}
// `completed` is only true when the device confirmed the restore AND its
// progress reached the end. Returns 1 with out_error on failure.
int32_t al_backup_restore(const char *pairing_path,
                          const char *backup_root,
                          const char *options_json,
                          ALLogCallback log_cb,
                          ALBackupProgressCallback progress_cb,
                          void *ctx,
                          char **out_json,
                          char **out_error);

// InstallationProxy factory entry for one bundle id, for Manifest.plist
// `Applications` registration. Returns 0 with out_json set:
//   {"bundle_id", "entry": {"Container", "CFBundleVersion",
//     "ApplicationSINF" (hex), "iTunesMetadata", "CFBundleIdentifier"}}
// Returns 1 with out_error on failure.
int32_t al_backup_app_factory_entry(const char *pairing_path,
                                    const char *bundle_id,
                                    ALLogCallback log_cb,
                                    void *ctx,
                                    char **out_json,
                                    char **out_error);

// Read-only device identity over the pairing tunnel (for the dual-mode
// switch). BLOCKS — run off the main thread. Writes nothing to the device.
// Returns 0 with out_json set:
//   {"udid", "product_version", "build_version", "product_type",
//    "device_name"}
// Returns 1 with out_error on failure.
int32_t al_device_info(const char *pairing_path,
                       ALLogCallback log_cb,
                       void *ctx,
                       char **out_json,
                       char **out_error);

// ---------------------------------------------------------------------------
// Target Host Configuration
// ---------------------------------------------------------------------------

// Set the primary target host/IP (e.g. "10.7.0.1") to dial first for RSD and tunnel operations.
// Passing NULL or "" resets to None.
// Returns 0 on success.
int32_t al_set_target_host(const char *host);

// Set additional candidate target hosts (e.g. from local interface discovery).
// `hosts` is an array of C-strings of length `count`.
// Returns 0 on success.
int32_t al_set_target_hosts(const char *const *hosts, size_t count);

// Clear custom target host settings, reverting to default tunnel IP fallbacks.
void al_clear_target_hosts(void);


#ifdef __cplusplus
}
#endif

#endif /* AIRLIFT_H */

