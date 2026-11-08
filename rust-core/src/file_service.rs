//! Minimal CoreDevice FileService client (read-only), following upstream
//! idevice `core_device::file_service` (MIT).
//!
//! Only the calls the PosterBoard table fetch needs: CreateSession +
//! RetrieveFile. The vendored idevice (rev 7bd551c) has no file_service
//! module and no `recv_any`, so this lives here and uses the
//! already-enabled `RemoteXpcClient`. Channel rule (upstream comment):
//! CreateSession is answered on the reply channel, every later command
//! on the root channel.
//!
//! Unproven on 27.2: whether the service lets this app open a session
//! on the PosterBoard container (bundle id com.apple.PosterBoard) and
//! read a known path. That needs a real 27.2 device to test; this code
//! only wires the channel up, it does not claim the device allows it.

use idevice::xpc::XPCObject;
use idevice::{ReadWrite, RemoteXpcClient};
use tokio::io::{AsyncReadExt, AsyncWriteExt};

/// Fixed-size preamble the data port answers a `rwb!FILE` request with,
/// before the length-prefixed payload.
const DATA_PREAMBLE_LEN: usize = 0x24;

/// Which of the device's filesystem domains a session is scoped to.
/// Only AppDataContainer is used here (value 1).
const DOMAIN_APP_DATA_CONTAINER: u64 = 1;

#[derive(Debug)]
pub struct FileServiceClient {
    inner: RemoteXpcClient<Box<dyn ReadWrite>>,
    session: Option<String>,
}

impl FileServiceClient {
    pub async fn new(stream: Box<dyn ReadWrite>) -> Result<Self, String> {
        let mut inner = RemoteXpcClient::new(stream)
            .await
            .map_err(|e| format!("file service: RemoteXpcClient::new failed: {e:?}"))?;
        inner
            .do_handshake()
            .await
            .map_err(|e| format!("file service: handshake failed: {e:?}"))?;
        Ok(Self {
            inner,
            session: None,
        })
    }

    /// Opens a session on the app-data container of `bundle_id`.
    pub async fn create_session(&mut self, bundle_id: &str) -> Result<String, String> {
        let res = self
            .send_receive(
                idevice::xpc!({
                    "Cmd": "CreateSession",
                    "Domain": XPCObject::UInt64(DOMAIN_APP_DATA_CONTAINER),
                    "Identifier": bundle_id,
                    "Session": "",
                    "User": "mobile"
                }),
                true, // CreateSession is answered on the reply channel.
            )
            .await?;
        let session = res
            .as_dictionary()
            .and_then(|d| d.get("NewSessionID"))
            .and_then(|v| v.as_string())
            .ok_or_else(|| {
                "file service: CreateSession reply has no NewSessionID".to_string()
            })?
            .to_string();
        self.session = Some(session.clone());
        Ok(session)
    }

    /// Downloads `path`, relative to the session's domain root.
    /// `data_stream` is a fresh connection to the file-service data port
    /// (`com.apple.coredevice.fileservice.data`).
    pub async fn retrieve_file(
        &mut self,
        path: &str,
        mut data_stream: Box<dyn ReadWrite>,
    ) -> Result<Vec<u8>, String> {
        let session = self.session()?;
        let res = self
            .send_receive(
                idevice::xpc!({
                    "Cmd": "RetrieveFile",
                    "Path": path,
                    "SessionID": session
                }),
                false, // Later commands are answered on the root channel.
            )
            .await?;
        let res = res
            .as_dictionary()
            .ok_or_else(|| {
                "file service: RetrieveFile reply is not a dictionary".to_string()
            })?;
        let response = res
            .get("Response")
            .and_then(plist_u64)
            .ok_or_else(|| {
                "file service: RetrieveFile reply has no Response".to_string()
            })?;
        let file_id = res
            .get("NewFileID")
            .and_then(plist_u64)
            .ok_or_else(|| {
                "file service: RetrieveFile reply has no NewFileID".to_string()
            })?;

        // `rwb!FILE` then four big-endian u64s: the control reply's Response,
        // zero, the file ID it handed out, zero.
        let mut req = Vec::with_capacity(8 + 32);
        req.extend_from_slice(b"rwb!FILE");
        req.extend_from_slice(&response.to_be_bytes());
        req.extend_from_slice(&0u64.to_be_bytes());
        req.extend_from_slice(&file_id.to_be_bytes());
        req.extend_from_slice(&0u64.to_be_bytes());
        data_stream
            .write_all(&req)
            .await
            .map_err(|e| format!("file service: data port write failed: {e}"))?;
        data_stream
            .flush()
            .await
            .map_err(|e| format!("file service: data port flush failed: {e}"))?;

        let mut preamble = [0u8; DATA_PREAMBLE_LEN];
        data_stream
            .read_exact(&mut preamble)
            .await
            .map_err(|e| format!("file service: data port preamble read failed: {e}"))?;

        let mut len = [0u8; 4];
        data_stream
            .read_exact(&mut len)
            .await
            .map_err(|e| format!("file service: data port length read failed: {e}"))?;
        let mut payload = vec![0u8; u32::from_be_bytes(len) as usize];
        data_stream
            .read_exact(&mut payload)
            .await
            .map_err(|e| format!("file service: data port payload read failed: {e}"))?;
        Ok(payload)
    }

    fn session(&self) -> Result<String, String> {
        self.session.clone().ok_or_else(|| {
            "file service: no session; call create_session first".to_string()
        })
    }

    /// Send one XPC object and wait for its reply. `reply_channel`
    /// selects the reply channel (CreateSession) vs the root channel
    /// (every later command) — see the module doc.
    async fn send_receive(
        &mut self,
        request: impl Into<XPCObject>,
        reply_channel: bool,
    ) -> Result<plist::Value, String> {
        self.inner
            .send_object(request, true)
            .await
            .map_err(|e| format!("file service: send failed: {e:?}"))?;
        let res = if reply_channel {
            self.inner.recv().await
        } else {
            self.inner.recv_root().await
        }
        .map_err(|e| format!("file service: recv failed: {e:?}"))?;

        if let Some(dict) = res.as_dictionary() {
            if dict.contains_key("EncodedError") {
                let detail = dict
                    .get("LocalizedDescription")
                    .and_then(|v| v.as_string())
                    .map(str::to_string)
                    .unwrap_or_else(|| format!("{:?}", dict.get("EncodedError")));
                return Err(format!("file service: device error: {detail}"));
            }
        }
        Ok(res)
    }
}

fn plist_u64(value: &plist::Value) -> Option<u64> {
    value
        .as_unsigned_integer()
        .or_else(|| value.as_signed_integer().map(|x| x as u64))
}
