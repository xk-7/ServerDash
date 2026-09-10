use crate::{
    storage::{Credentials, Repository, SecretStore},
    BackendEvent,
};
use anyhow::{bail, ensure, Context, Result};
use base64::Engine;
use russh::{
    client,
    keys::{HashAlg, PrivateKeyWithHashAlg, PublicKeyOrCertificate},
    Channel, ChannelMsg,
};
use serde_json::{json, Value};
use std::{
    collections::{HashMap, HashSet},
    sync::{Arc, Mutex},
    time::Duration,
};
use tokio::{
    io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt},
    net::TcpStream,
    sync::{broadcast, oneshot},
};
use tokio_util::sync::CancellationToken;

pub type PendingTrust = Arc<Mutex<HashMap<String, oneshot::Sender<String>>>>;
pub struct HostHandler {
    host: String,
    port: u16,
    repository: Arc<Repository>,
    pending: PendingTrust,
    events: broadcast::Sender<BackendEvent>,
    cancellation: CancellationToken,
}
impl client::Handler for HostHandler {
    type Error = anyhow::Error;
    async fn check_server_key(&mut self, presented: &PublicKeyOrCertificate) -> Result<bool> {
        ensure!(
            presented.certificate().is_none(),
            "SSH host certificates are not enabled; configure a regular host key"
        );
        let key = presented.public_key();
        let algorithm = key.algorithm().to_string();
        let fingerprint = key.fingerprint(HashAlg::Sha256).to_string();
        let previous = self
            .repository
            .trusted_fingerprint(&self.host, self.port, &algorithm)?;
        if previous.as_ref() == Some(&fingerprint) {
            return Ok(true);
        }
        let id = uuid::Uuid::new_v4().to_string();
        let (tx, rx) = oneshot::channel();
        self.pending.lock().unwrap().insert(id.clone(), tx);
        struct Cleanup {
            pending: PendingTrust,
            id: String,
            events: broadcast::Sender<BackendEvent>,
        }
        impl Drop for Cleanup {
            fn drop(&mut self) {
                self.pending.lock().unwrap().remove(&self.id);
                let _ = self.events.send(BackendEvent {
                    kind: "trust_expired".into(),
                    payload: json!({"requestId":self.id}),
                });
            }
        }
        let _cleanup = Cleanup {
            pending: self.pending.clone(),
            id: id.clone(),
            events: self.events.clone(),
        };
        let delivered=self.events.send(BackendEvent{kind:"trust".into(),payload:json!({"id":id,"requestId":id,"host":self.host,"port":self.port,"algorithm":algorithm,"fingerprint":fingerprint,"previousFingerprint":previous,"changed":previous.is_some(),"replacing":previous.is_some()})});
        ensure!(
            delivered.is_ok(),
            "No active UI is available for host-key confirmation"
        );
        let decision = tokio::select! {result=tokio::time::timeout(Duration::from_secs(120),rx)=>result.context("Host-key confirmation timed out")??,_=self.cancellation.cancelled()=>bail!("Connection cancelled")};
        match decision.as_str() {
            "store" => {
                self.repository
                    .trust(&self.host, self.port, &algorithm, &fingerprint)?;
                Ok(true)
            }
            "once" => Ok(true),
            _ => Ok(false),
        }
    }
}

trait Transport: AsyncRead + AsyncWrite + Unpin + Send {}
impl<T: AsyncRead + AsyncWrite + Unpin + Send> Transport for T {}
type Stream = Box<dyn Transport>;
// Dropping a russh handshake future alone does not stop its spawned IO task.
// Cancellation must wake transport reads as well as a pending trust callback.
struct CancellableStream {
    inner: Stream,
    cancelled: std::pin::Pin<Box<dyn std::future::Future<Output = ()> + Send>>,
}
impl CancellableStream {
    fn new(inner: Stream, token: CancellationToken) -> Self {
        Self {
            inner,
            cancelled: Box::pin(token.cancelled_owned()),
        }
    }
}
impl AsyncRead for CancellableStream {
    fn poll_read(
        mut self: std::pin::Pin<&mut Self>,
        cx: &mut std::task::Context<'_>,
        buffer: &mut tokio::io::ReadBuf<'_>,
    ) -> std::task::Poll<std::io::Result<()>> {
        if self.cancelled.as_mut().poll(cx).is_ready() {
            return std::task::Poll::Ready(Err(std::io::Error::new(
                std::io::ErrorKind::ConnectionAborted,
                "Connection cancelled",
            )));
        }
        std::pin::Pin::new(&mut self.inner).poll_read(cx, buffer)
    }
}
impl AsyncWrite for CancellableStream {
    fn poll_write(
        mut self: std::pin::Pin<&mut Self>,
        cx: &mut std::task::Context<'_>,
        bytes: &[u8],
    ) -> std::task::Poll<std::io::Result<usize>> {
        std::pin::Pin::new(&mut self.inner).poll_write(cx, bytes)
    }
    fn poll_flush(
        mut self: std::pin::Pin<&mut Self>,
        cx: &mut std::task::Context<'_>,
    ) -> std::task::Poll<std::io::Result<()>> {
        std::pin::Pin::new(&mut self.inner).poll_flush(cx)
    }
    fn poll_shutdown(
        mut self: std::pin::Pin<&mut Self>,
        cx: &mut std::task::Context<'_>,
    ) -> std::task::Poll<std::io::Result<()>> {
        std::pin::Pin::new(&mut self.inner).poll_shutdown(cx)
    }
}

pub struct RemoteSession {
    pub handle: client::Handle<HostHandler>,
    // Intermediate authenticated handles remain alive for the entire route.
    pub jumps: Vec<client::Handle<HostHandler>>,
    cancellation: CancellationToken,
}
impl Drop for RemoteSession {
    fn drop(&mut self) {
        self.cancellation.cancel();
    }
}
impl RemoteSession {
    pub async fn close(&self) {
        let _ = self
            .handle
            .disconnect(russh::Disconnect::ByApplication, "Session closed", "en")
            .await;
        for jump in self.jumps.iter().rev() {
            let _ = jump
                .disconnect(russh::Disconnect::ByApplication, "Route closed", "en")
                .await;
        }
        self.cancellation.cancel();
    }
    pub async fn shell(&self, columns: u32, rows: u32) -> Result<Channel<client::Msg>> {
        let mut channel = self.handle.channel_open_session().await?;
        channel
            .request_pty(
                true,
                "xterm-256color",
                columns.clamp(2, 1000),
                rows.clamp(2, 1000),
                0,
                0,
                &[],
            )
            .await?;
        wait_success(&mut channel, "PTY request").await?;
        channel.request_shell(true).await?;
        wait_success(&mut channel, "Shell request").await?;
        Ok(channel)
    }
    pub async fn sftp(&self) -> Result<russh_sftp::client::SftpSession> {
        let mut channel = self.handle.channel_open_session().await?;
        channel.request_subsystem(true, "sftp").await?;
        wait_success(&mut channel, "SFTP subsystem").await?;
        Ok(russh_sftp::client::SftpSession::new(channel.into_stream()).await?)
    }
    /// Use OpenSSH's atomic rename extension. Never delete the destination first.
    pub async fn atomic_replace(&self, source: &str, destination: &str) -> Result<()> {
        let mut channel = self.handle.channel_open_session().await?;
        channel.request_subsystem(true, "sftp").await?;
        wait_success(&mut channel, "SFTP subsystem").await?;
        let raw = russh_sftp::client::RawSftpSession::new(channel.into_stream());
        let version = raw.init().await?;
        ensure!(
            version
                .extensions
                .get("posix-rename@openssh.com")
                .is_some_and(|v| v == "1"),
            "Server lacks atomic replacement support; original file was preserved"
        );
        let mut payload = Vec::new();
        for path in [source, destination] {
            payload.extend_from_slice(&u32::try_from(path.len())?.to_be_bytes());
            payload.extend_from_slice(path.as_bytes());
        }
        let result = raw.extended("posix-rename@openssh.com", payload).await;
        let _ = raw.close_session();
        match result? {
            russh_sftp::protocol::Packet::Status(status)
                if status.status_code == russh_sftp::protocol::StatusCode::Ok =>
            {
                Ok(())
            }
            _ => bail!("Atomic replacement failed; original file was preserved"),
        }
    }
    pub async fn execute(&self, command: &str, timeout: Duration, limit: usize) -> Result<Value> {
        let mut channel = self.handle.channel_open_session().await?;
        channel.exec(true, command).await?;
        let result=tokio::time::timeout(timeout,async {
            let mut stdout=Vec::new();let mut stderr=Vec::new();let mut exit_code=None;
            while let Some(msg)=channel.wait().await {
                match msg {
                    ChannelMsg::Data{data}=>stdout.extend_from_slice(&data),
                    ChannelMsg::ExtendedData{data,..}=>stderr.extend_from_slice(&data),
                    ChannelMsg::ExitStatus{exit_status}=>exit_code=Some(exit_status),
                    ChannelMsg::Close=>break,
                    ChannelMsg::Failure=>bail!("Remote command was rejected"),
                    _=>{},
                }
                ensure!(stdout.len()+stderr.len()<=limit,"Remote command output exceeded limit");
            }
            Ok(json!({"stdout":String::from_utf8_lossy(&stdout),"stderr":String::from_utf8_lossy(&stderr),"exitCode":exit_code}))
        }).await;
        let _ = channel.close().await;
        result.context("Remote command timed out")?
    }
}

async fn wait_success(channel: &mut Channel<client::Msg>, operation: &str) -> Result<()> {
    tokio::time::timeout(Duration::from_secs(15), async {
        match channel.wait().await {
            Some(ChannelMsg::Success) => Ok(()),
            _ => bail!("{operation} was rejected or the channel closed"),
        }
    })
    .await
    .context("SSH channel setup timed out")?
}

pub async fn connect(
    machine: &Value,
    repository: Arc<Repository>,
    secrets: Arc<SecretStore>,
    pending: PendingTrust,
    events: broadcast::Sender<BackendEvent>,
    cancellation: CancellationToken,
) -> Result<RemoteSession> {
    let guard = cancellation.clone().drop_guard();
    let mut route = Vec::new();
    let mut visited = HashSet::new();
    fn visit(
        machine: Value,
        repo: &Repository,
        seen: &mut HashSet<String>,
        route: &mut Vec<Value>,
    ) -> Result<()> {
        ensure!(route.len() < 16, "SSH route exceeds 16 hops");
        let id = machine["id"]
            .as_str()
            .context("Machine ID missing")?
            .to_owned();
        ensure!(seen.insert(id), "SSH jump route contains a cycle");
        if let Some(jumps) = machine["jumpHostIds"].as_array() {
            for jump in jumps {
                visit(
                    repo.get("machines", jump.as_str().context("Invalid jump host ID")?)?,
                    repo,
                    seen,
                    route,
                )?;
            }
        }
        route.push(machine);
        Ok(())
    }
    visit(machine.clone(), &repository, &mut visited, &mut route)?;
    ensure!(route.len() <= 16, "SSH route exceeds 16 hops");
    let mut handles: Vec<client::Handle<HostHandler>> = Vec::new();
    for hop in route {
        let host = hop["host"]
            .as_str()
            .context("SSH hostname missing")?
            .to_owned();
        let port = crate::port(&hop, "port", 22)?;
        let stream: Stream = if let Some(previous) = handles.last() {
            ensure!(
                hop.get("proxy").is_none_or(|v| v.is_null()),
                "A proxy on an intermediate jump hop is not supported"
            );
            Box::new(
                previous
                    .channel_open_direct_tcpip(&host, port as u32, "127.0.0.1", 0)
                    .await?
                    .into_stream(),
            )
        } else {
            connect_transport(&host, port, hop.get("proxy"), &secrets).await?
        };
        let handler = HostHandler {
            host,
            port,
            repository: repository.clone(),
            pending: pending.clone(),
            events: events.clone(),
            cancellation: cancellation.clone(),
        };
        let config = client::Config {
            keepalive_interval: Some(Duration::from_secs(20)),
            keepalive_max: 3,
            window_size: 256 * 1024,
            maximum_packet_size: 32768,
            ..Default::default()
        };
        let mut handle = client::connect_stream(
            Arc::new(config),
            CancellableStream::new(stream, cancellation.clone()),
            handler,
        )
        .await?;
        let credential_id = hop["credentialId"].as_str();
        let credential = if let Some(id) = credential_id {
            secrets.get(id)?
        } else {
            Credentials::default()
        };
        let username = hop["username"].as_str().context("SSH username missing")?;
        authenticate(&mut handle, username, &hop, &credential).await?;
        handles.push(handle);
    }
    let handle = handles.pop().context("No SSH target")?;
    guard.disarm();
    Ok(RemoteSession {
        handle,
        jumps: handles,
        cancellation,
    })
}

async fn authenticate(
    handle: &mut client::Handle<HostHandler>,
    username: &str,
    machine: &Value,
    credential: &Credentials,
) -> Result<()> {
    let mode = machine["authentication"].as_str().unwrap_or("agent");
    if mode == "agent" {
        #[cfg(unix)]
        let mut agent = russh::keys::agent::client::AgentClient::connect_env()
            .await
            .context("SSH Agent unavailable; check SSH_AUTH_SOCK")?;
        #[cfg(windows)]
        let mut agent = russh::keys::agent::client::AgentClient::connect(
            tokio::net::windows::named_pipe::ClientOptions::new()
                .open(r"\\.\pipe\openssh-ssh-agent")
                .context("Windows OpenSSH Agent service is unavailable")?,
        );
        #[cfg(any(unix, windows))]
        {
            let hash = handle.best_supported_rsa_hash().await?.flatten();
            for identity in agent.request_identities().await? {
                if let russh::keys::agent::AgentIdentity::PublicKey { key, .. } = identity {
                    if handle
                        .authenticate_publickey_with(username, key, hash, &mut agent)
                        .await?
                        .success()
                    {
                        return Ok(());
                    }
                }
            }
            bail!("SSH Agent has no accepted identity");
        }
        #[cfg(not(any(unix, windows)))]
        bail!("SSH Agent is unsupported on this platform");
    }
    if matches!(mode, "privateKey" | "keyThenPassword") {
        let path = machine["privateKeyPath"].as_str().unwrap_or("");
        let passphrase =
            (!credential.passphrase.is_empty()).then_some(credential.passphrase.as_str());
        let key = if !credential.private_key.is_empty() {
            russh::keys::decode_secret_key(&credential.private_key, passphrase)
        } else {
            russh::keys::load_secret_key(path, passphrase)
        };
        match key {
            Ok(key) => {
                let hash = handle.best_supported_rsa_hash().await?.flatten();
                if handle
                    .authenticate_publickey(
                        username,
                        PrivateKeyWithHashAlg::new(Arc::new(key), hash),
                    )
                    .await?
                    .success()
                {
                    return Ok(());
                }
            }
            Err(_) if mode == "keyThenPassword" => {}
            Err(_) => bail!("Private key is missing, invalid or requires a different passphrase"),
        }
    }
    if matches!(mode, "password" | "keyThenPassword")
        && handle
            .authenticate_password(username, &credential.password)
            .await?
            .success()
    {
        return Ok(());
    }
    bail!("SSH authentication failed")
}

async fn connect_transport(
    host: &str,
    port: u16,
    proxy: Option<&Value>,
    secrets: &SecretStore,
) -> Result<Stream> {
    let proxy = proxy.filter(|p| p.is_object());
    let mut stream = TcpStream::connect(if let Some(proxy) = proxy {
        (
            proxy["host"].as_str().context("Proxy hostname missing")?,
            crate::port(proxy, "port", 1080)?,
        )
    } else {
        (host, port)
    })
    .await?;
    stream.set_nodelay(true)?;
    if let Some(proxy) = proxy {
        match proxy["kind"].as_str().unwrap_or("socks5") {
            "http" | "httpConnect" => {
                ensure!(
                    !host.chars().any(|c| c.is_whitespace() || c.is_control()),
                    "Invalid destination hostname"
                );
                let target = if host.contains(':') {
                    format!("[{host}]:{port}")
                } else {
                    format!("{host}:{port}")
                };
                let mut request = format!("CONNECT {target} HTTP/1.1\r\nHost: {target}\r\n");
                if let Some(id) = proxy["credentialId"].as_str() {
                    let c = secrets.get(id)?;
                    let auth = base64::engine::general_purpose::STANDARD.encode(format!(
                        "{}:{}",
                        proxy["username"].as_str().unwrap_or(""),
                        c.password
                    ));
                    request.push_str(&format!("Proxy-Authorization: Basic {auth}\r\n"));
                }
                request.push_str("\r\n");
                stream.write_all(request.as_bytes()).await?;
                let mut response = Vec::new();
                while !response.ends_with(b"\r\n\r\n") {
                    ensure!(response.len() < 16384, "Proxy response header too large");
                    response.push(stream.read_u8().await?);
                }
                let text = String::from_utf8(response)?;
                ensure!(
                    text.lines()
                        .next()
                        .and_then(|l| l.split_whitespace().nth(1))
                        == Some("200"),
                    "HTTP CONNECT proxy rejected the connection"
                );
            }
            "socks5" => {
                let credential = proxy["credentialId"]
                    .as_str()
                    .map(|id| secrets.get(id))
                    .transpose()?;
                stream
                    .write_all(if credential.is_some() {
                        &[5, 2, 0, 2]
                    } else {
                        &[5, 1, 0]
                    })
                    .await?;
                let mut reply = [0; 2];
                stream.read_exact(&mut reply).await?;
                ensure!(reply[0] == 5, "Invalid SOCKS version");
                if reply[1] == 2 {
                    let c = credential.context("SOCKS proxy requires credentials")?;
                    let user = proxy["username"].as_str().unwrap_or("").as_bytes();
                    let password = c.password.as_bytes();
                    ensure!(
                        user.len() <= 255 && password.len() <= 255,
                        "SOCKS credentials too long"
                    );
                    let mut auth = vec![1, user.len() as u8];
                    auth.extend_from_slice(user);
                    auth.push(password.len() as u8);
                    auth.extend_from_slice(password);
                    stream.write_all(&auth).await?;
                    stream.read_exact(&mut reply).await?;
                    ensure!(reply == [1, 0], "SOCKS proxy authentication failed");
                } else {
                    ensure!(reply[1] == 0, "SOCKS proxy rejected authentication");
                }
                ensure!(host.len() <= 255, "Hostname too long for SOCKS");
                let mut request = vec![5, 1, 0, 3, host.len() as u8];
                request.extend_from_slice(host.as_bytes());
                request.extend_from_slice(&port.to_be_bytes());
                stream.write_all(&request).await?;
                let mut header = [0; 4];
                stream.read_exact(&mut header).await?;
                ensure!(
                    header[0] == 5 && header[1] == 0,
                    "SOCKS proxy rejected destination"
                );
                let n = match header[3] {
                    1 => 4,
                    4 => 16,
                    3 => stream.read_u8().await? as usize,
                    _ => bail!("Invalid SOCKS address"),
                };
                let mut rest = vec![0; n + 2];
                stream.read_exact(&mut rest).await?;
            }
            _ => bail!("Unknown proxy kind"),
        }
    }
    Ok(Box::new(stream))
}
