//! Platform-neutral ServerDash persistence and remote-session engine.
pub mod monitor;
mod ssh;
pub mod storage;

use anyhow::{bail, ensure, Context, Result};
use base64::Engine;
use russh::{client, ChannelMsg, ChannelWriteHalf};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::{
    collections::HashMap,
    path::PathBuf,
    sync::{
        atomic::{AtomicU64, Ordering},
        Arc, Mutex,
    },
    time::Duration,
};
use storage::{Credentials, Repository, SecretStore};
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    sync::{broadcast, mpsc, OwnedSemaphorePermit, Semaphore},
};
use tokio_util::sync::CancellationToken;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct BackendEvent {
    pub kind: String,
    pub payload: Value,
}
#[derive(Debug, Serialize)]
pub struct OutputChunk {
    pub sequence: u64,
    pub data: Vec<u8>,
}

struct Session {
    id: String,
    generation: u64,
    machine_id: String,
    remote: Arc<ssh::RemoteSession>,
    writer: Arc<ChannelWriteHalf<client::Msg>>,
    receiver: Mutex<Option<mpsc::Receiver<OutputChunk>>>,
    cancellation: CancellationToken,
    pending: Arc<Mutex<HashMap<u64, OwnedSemaphorePermit>>>,
    sent: Arc<AtomicU64>,
    sftp: tokio::sync::OnceCell<russh_sftp::client::SftpSession>,
}
struct Opening {
    machine_id: String,
    cancellation: CancellationToken,
}
struct Inner {
    repository: Arc<Repository>,
    secrets: Arc<SecretStore>,
    events: broadcast::Sender<BackendEvent>,
    trust: ssh::PendingTrust,
    sessions: Mutex<HashMap<String, Arc<Session>>>,
    generation: AtomicU64,
    opening: Mutex<HashMap<String, Opening>>,
    monitoring: Mutex<HashMap<String, CancellationToken>>,
    transfers: Mutex<HashMap<String, CancellationToken>>,
}
#[derive(Clone)]
pub struct Backend(Arc<Inner>);

impl Backend {
    pub fn new(data_dir: PathBuf) -> Result<Self> {
        std::fs::create_dir_all(&data_dir)?;
        let (events, _) = broadcast::channel(512);
        Ok(Self(Arc::new(Inner {
            repository: Arc::new(Repository::open(&data_dir.join("serverdash.sqlite3"))?),
            secrets: Arc::new(SecretStore::new(&data_dir.join("credentials"))?),
            events,
            trust: Arc::new(Mutex::new(HashMap::new())),
            sessions: Mutex::new(HashMap::new()),
            generation: AtomicU64::new(1),
            opening: Mutex::new(HashMap::new()),
            monitoring: Mutex::new(HashMap::new()),
            transfers: Mutex::new(HashMap::new()),
        })))
    }
    pub fn subscribe(&self) -> broadcast::Receiver<BackendEvent> {
        self.0.events.subscribe()
    }
    pub fn repository(&self) -> Arc<Repository> {
        self.0.repository.clone()
    }
    pub fn secrets(&self) -> Arc<SecretStore> {
        self.0.secrets.clone()
    }
    pub fn session_output(
        &self,
        session_id: &str,
        generation: u64,
    ) -> Result<mpsc::Receiver<OutputChunk>> {
        let session =
            self.session_entry(&json!({"sessionId":session_id,"generation":generation}))?;
        let receiver = session
            .receiver
            .lock()
            .unwrap()
            .take()
            .context("Terminal stream was already subscribed");
        receiver
    }
    pub fn publish(&self, kind: &str, payload: Value) {
        let _ = self.0.events.send(BackendEvent {
            kind: kind.into(),
            payload,
        });
    }
    pub async fn request(&self, method: &str, params: Value) -> Result<Value> {
        match method {
            "bootstrap"=>Ok(json!({"machines":self.0.repository.list("machines")?,"settings":self.0.repository.get("settings","default").unwrap_or(json!({"theme":"dark","terminalFontSize":14,"refreshInterval":30})),"snippets":self.0.repository.list("snippets")?,"identities":self.0.repository.list("identities")?,"sshKeys":self.0.repository.list("sshKeys")?,"trustedHosts":self.0.repository.hosts()?,"capabilities":{"ssh":true,"sftp":true,"monitoring":true,"fileEditor":true,"jumpHosts":true,"socks5Proxy":true,"httpConnectProxy":true,"sshAgent":true,"externalPrivateKeyPath":true,"persistentCredentials":cfg!(windows)}})),
            "machine_list"=>Ok(json!(self.0.repository.list("machines")?)),
            "machine_save"=>{
                let mut machine=params.get("machine").unwrap_or(&params).clone();
                ensure!(machine.is_object(),"Machine must be an object");
                if machine["id"].as_str().is_none_or(|v|v.is_empty()){machine["id"]=json!(uuid::Uuid::new_v4().to_string());}
                validate_machine(&machine)?;
                let id=field(&machine,"id")?;self.0.repository.save("machines",id,&machine)?;Ok(machine)
            },
            "machine_delete"=>{
                let id=field(&params,"id")?;
                let sessions:Vec<_>={let sessions=self.0.sessions.lock().unwrap();self.0.repository.delete("machines",id)?;sessions.values().filter(|s|s.machine_id==id).cloned().collect()};
                for opening in self.0.opening.lock().unwrap().values().filter(|o|o.machine_id==id){opening.cancellation.cancel();}
                if let Some(cancel)=self.0.monitoring.lock().unwrap().get(id){cancel.cancel();}
                for session in sessions {self.close_session(&session).await;}Ok(json!({"deleted":true}))
            },
            "credential_save"|"credentials_save"=>{
                let id=params["id"].as_str().map(str::to_owned).unwrap_or_else(||uuid::Uuid::new_v4().to_string());
                let value=params.get("secret").unwrap_or(&params);
                let mut credentials=if let Some(password)=value.as_str(){{let mut c=Credentials::default();c.password=password.into();c}}else{let mut v=value.clone();if let Some(o)=v.as_object_mut(){o.remove("id");o.remove("name");}serde_json::from_value(v)?};
                if let Some(base)=params["baseCredentialId"].as_str(){
                    let old=self.0.secrets.get(base)?;
                    ensure!(value.is_object(),"Credential updates require named fields");
                    if value.get("password").is_none(){credentials.password=old.password.clone();}
                    if value.get("privateKey").is_none(){credentials.private_key=old.private_key.clone();}
                    if value.get("passphrase").is_none(){credentials.passphrase=old.passphrase.clone();}
                    if value.get("apiKey").is_none(){credentials.api_key=old.api_key.clone();}
                }
                self.0.secrets.save(&id,&credentials)?;Ok(json!({"credentialId":id}))
            },
            "credential_delete"=>{self.0.secrets.delete(field(&params,"credentialId")?)?;Ok(Value::Null)},
            "settings_save"|"snippet_save"|"identity_save"|"ssh_key_save"=>{
                let (collection,wrapper)=match method{"settings_save"=>("settings","settings"),"snippet_save"=>("snippets","snippet"),"identity_save"=>("identities","identity"),_=>("sshKeys","key")};
                let mut value=params.get(wrapper).unwrap_or(&params).clone();ensure!(value.is_object(),"Record must be an object");
                let id=if collection=="settings"{"default".into()}else{value["id"].as_str().filter(|s|!s.is_empty()).map(str::to_owned).unwrap_or_else(||uuid::Uuid::new_v4().to_string())};
                if collection!="settings"{value["id"]=json!(id);}
                self.0.repository.save(collection,&id,&value)?;Ok(value)
            },
            "snippet_delete"|"identity_delete"|"ssh_key_delete"=>{let collection=match method{"snippet_delete"=>"snippets","identity_delete"=>"identities",_=>"sshKeys"};self.0.repository.delete(collection,field(&params,"id")?)?;Ok(Value::Null)},
            "trust_decide"=>{let id=field(&params,"requestId")?;let decision=field(&params,"decision")?;ensure!(matches!(decision,"once"|"store"|"reject"),"Unknown trust decision");let sender=self.0.trust.lock().unwrap().remove(id).context("Host confirmation expired")?;sender.send(decision.into()).map_err(|_|anyhow::anyhow!("Host confirmation expired"))?;Ok(Value::Null)},
            "trust_delete"=>{self.0.repository.forget_host(field(&params,"host")?,port(&params,"port",22)?)?;Ok(Value::Null)},
            "session_open"=>self.open_session(&params).await,
            "session_cancel_open"=>{if let Some(cancel)=self.0.opening.lock().unwrap().remove(field(&params,"requestId")?){cancel.cancellation.cancel();}Ok(Value::Null)},
            "session_write"=>{let session=self.session(&params)?;let data=base64::engine::general_purpose::STANDARD.decode(field(&params,"data")?)?;ensure!(data.len()<=1024*1024,"Terminal input exceeded limit");session.writer.data_bytes(data).await?;Ok(Value::Null)},
            "session_resize"=>{let session=self.session(&params)?;session.writer.window_change(dimension(&params,"columns",80),dimension(&params,"rows",24),0,0).await?;Ok(Value::Null)},
            "session_ack"=>{let session=self.session_entry(&params)?;let seq=params["sequence"].as_u64().context("Sequence required")?;ensure!(seq<=session.sent.load(Ordering::Acquire),"Acknowledgment exceeds sent sequence");session.pending.lock().unwrap().retain(|&s,_|s>seq);Ok(Value::Null)},
            "session_close"=>{let session=self.session_entry(&params)?;self.close_session(&session).await;Ok(Value::Null)},
            "session_execute"=>{let session=self.session(&params)?;session.remote.execute(field(&params,"command")?,Duration::from_secs(params["timeoutSeconds"].as_u64().unwrap_or(30).clamp(1,600)),4*1024*1024).await},
            "session_list"=>Ok(json!(self.0.sessions.lock().unwrap().values().filter(|s|!s.cancellation.is_cancelled()).map(|s|json!({"sessionId":s.id,"generation":s.generation,"machineId":s.machine_id,"kind":"ssh"})).collect::<Vec<_>>())),
            "file_list"|"file_upload"|"file_download"|"file_mkdir"|"file_rename"|"file_delete"|"file_read"|"file_write"|"file_chmod"=>self.file_request(method,&params).await,
            "transfer_cancel"=>{if let Some(cancel)=self.0.transfers.lock().unwrap().remove(field(&params,"taskId")?){cancel.cancel();}Ok(Value::Null)},
            "monitor_refresh"=>self.monitor_refresh(field(&params,"machineId")?).await,
            "monitor_history"=>Ok(json!({"samples":self.0.repository.history(field(&params,"machineId")?,params["since"].as_u64().unwrap_or(0))?})),
            "shutdown"=>{self.shutdown().await;Ok(Value::Null)},
            _=>bail!("Unsupported desktop operation: {method}"),
        }
    }
    fn session(&self, params: &Value) -> Result<Arc<Session>> {
        let session = self.session_entry(params)?;
        ensure!(!session.cancellation.is_cancelled(), "Session is closed");
        Ok(session)
    }
    fn session_entry(&self, params: &Value) -> Result<Arc<Session>> {
        let id = field(params, "sessionId")?;
        let generation = params["generation"]
            .as_u64()
            .context("Connection generation required")?;
        let session = self
            .0
            .sessions
            .lock()
            .unwrap()
            .get(id)
            .cloned()
            .context("Session is closed")?;
        ensure!(
            session.generation == generation,
            "Session generation is stale or closed"
        );
        Ok(session)
    }
    async fn connect(
        &self,
        machine: &Value,
        cancel: CancellationToken,
    ) -> Result<ssh::RemoteSession> {
        tokio::time::timeout(
            Duration::from_secs(180),
            ssh::connect(
                machine,
                self.0.repository.clone(),
                self.0.secrets.clone(),
                self.0.trust.clone(),
                self.0.events.clone(),
                cancel,
            ),
        )
        .await
        .context("SSH connection timed out")?
    }
    async fn open_session(&self, params: &Value) -> Result<Value> {
        ensure!(
            params["kind"].as_str().unwrap_or("ssh") == "ssh",
            "This core handles SSH; local and serial sessions use the platform adapter"
        );
        let machine_id = field(params, "machineId")?.to_owned();
        let machine = self.0.repository.get("machines", &machine_id)?;
        let id = uuid::Uuid::new_v4().to_string();
        let generation = self.0.generation.fetch_add(1, Ordering::Relaxed);
        let request_id = params["requestId"].as_str().unwrap_or(&id).to_owned();
        let cancellation = CancellationToken::new();
        {
            let mut opening = self.0.opening.lock().unwrap();
            ensure!(
                !opening.contains_key(&request_id),
                "Connection request is already running"
            );
            opening.insert(
                request_id.clone(),
                Opening {
                    machine_id: machine_id.clone(),
                    cancellation: cancellation.clone(),
                },
            );
        }
        let connection = tokio::select! {result=async {
            let remote=Arc::new(self.connect(&machine,cancellation.clone()).await?);
            let channel=tokio::time::timeout(Duration::from_secs(30),remote.shell(dimension(params,"columns",80),dimension(params,"rows",24))).await.context("Terminal setup timed out")??;
            Ok::<_,anyhow::Error>((remote,channel))
        }=>result,_=cancellation.cancelled()=>Err(anyhow::anyhow!("Connection cancelled"))};
        self.0.opening.lock().unwrap().remove(&request_id);
        let (remote, channel) = connection?;
        let (mut reader, writer) = channel.split();
        let writer = Arc::new(writer);
        let (output, receiver) = mpsc::channel(8);
        let pending = Arc::new(Mutex::new(HashMap::new()));
        let permits = Arc::new(Semaphore::new(8));
        let sent = Arc::new(AtomicU64::new(0));
        let session = Arc::new(Session {
            id: id.clone(),
            generation,
            machine_id: machine_id.clone(),
            remote: remote.clone(),
            writer: writer.clone(),
            receiver: Mutex::new(Some(receiver)),
            cancellation: cancellation.clone(),
            pending: pending.clone(),
            sent: sent.clone(),
            sftp: tokio::sync::OnceCell::new(),
        });
        {
            let mut sessions = self.0.sessions.lock().unwrap();
            ensure!(
                !cancellation.is_cancelled()
                    && self.0.repository.get("machines", &machine_id).is_ok(),
                "Machine was removed while connecting"
            );
            sessions.insert(id.clone(), session);
        }
        let events = self.0.events.clone();
        let task_id = id.clone();
        tokio::spawn(async move {
            let mut exit_code = None;
            'reading: loop {
                let message =
                    tokio::select! {msg=reader.wait()=>msg,_=cancellation.cancelled()=>break};
                match message {
                    Some(ChannelMsg::Data { data })
                    | Some(ChannelMsg::ExtendedData { data, .. }) => {
                        for bytes in data.chunks(16384) {
                            let permit = tokio::select! {p=permits.clone().acquire_owned()=>p.unwrap(),_=cancellation.cancelled()=>break 'reading};
                            let sequence = sent.fetch_add(1, Ordering::AcqRel) + 1;
                            pending.lock().unwrap().insert(sequence, permit);
                            let chunk = OutputChunk {
                                sequence,
                                data: bytes.to_vec(),
                            };
                            tokio::select! {r=output.send(chunk)=>if r.is_err(){break 'reading},_=cancellation.cancelled()=>break 'reading};
                        }
                    }
                    Some(ChannelMsg::ExitStatus { exit_status }) => exit_code = Some(exit_status),
                    Some(ChannelMsg::Close) | None => break,
                    _ => {}
                }
            }
            cancellation.cancel();
            pending.lock().unwrap().clear();
            let _ = writer.close().await;
            remote.close().await;
            let _=events.send(BackendEvent{kind:"session_status".into(),payload:json!({"sessionId":task_id,"generation":generation,"status":"closed","exitCode":exit_code})});
        });
        self.publish("session_status",json!({"sessionId":id,"generation":generation,"machineId":machine_id,"status":"connected"}));
        Ok(json!({"sessionId":id,"generation":generation}))
    }
    async fn close_session(&self, session: &Session) {
        session.cancellation.cancel();
        session.pending.lock().unwrap().clear();
        self.0.sessions.lock().unwrap().remove(&session.id);
        let _ = tokio::time::timeout(Duration::from_secs(2), session.writer.close()).await;
        session.remote.close().await;
    }
    pub async fn reconcile_machines(&self) {
        for opening in self.0.opening.lock().unwrap().values() {
            if self
                .0
                .repository
                .get("machines", &opening.machine_id)
                .is_err()
            {
                opening.cancellation.cancel();
            }
        }
        for (id, cancel) in self.0.monitoring.lock().unwrap().iter() {
            if self.0.repository.get("machines", id).is_err() {
                cancel.cancel();
            }
        }
        let sessions: Vec<_> = self
            .0
            .sessions
            .lock()
            .unwrap()
            .values()
            .filter(|s| self.0.repository.get("machines", &s.machine_id).is_err())
            .cloned()
            .collect();
        for session in sessions {
            self.close_session(&session).await;
        }
    }
    pub async fn shutdown(&self) {
        for opening in self.0.opening.lock().unwrap().values() {
            opening.cancellation.cancel();
        }
        for cancel in self.0.monitoring.lock().unwrap().values() {
            cancel.cancel();
        }
        for cancel in self.0.transfers.lock().unwrap().values() {
            cancel.cancel();
        }
        self.0.trust.lock().unwrap().clear();
        let sessions: Vec<_> = self.0.sessions.lock().unwrap().values().cloned().collect();
        for session in sessions {
            self.close_session(&session).await;
        }
    }
    async fn monitor_refresh(&self, id: &str) -> Result<Value> {
        let cancel = CancellationToken::new();
        {
            let mut running = self.0.monitoring.lock().unwrap();
            ensure!(
                !running.contains_key(id),
                "Monitoring collection is already running"
            );
            running.insert(id.into(), cancel.clone());
        }
        let result = tokio::select! {result=self.collect_monitor(id,cancel.clone())=>result,_=cancel.cancelled()=>Err(anyhow::anyhow!("Monitoring cancelled"))};
        self.0.monitoring.lock().unwrap().remove(id);
        result
    }
    async fn collect_monitor(&self, id: &str, cancel: CancellationToken) -> Result<Value> {
        let machine = self.0.repository.get("machines", id)?;
        ensure!(
            machine["kind"].as_str().unwrap_or("ssh") == "ssh",
            "Monitoring requires a Linux SSH machine"
        );
        let start = std::time::Instant::now();
        let result: Result<Value> = async {
            let existing = self
                .0
                .sessions
                .lock()
                .unwrap()
                .values()
                .find(|s| s.machine_id == id && !s.cancellation.is_cancelled())
                .map(|s| s.remote.clone());
            let is_temporary = existing.is_none();
            let remote = if let Some(remote) = existing {
                remote
            } else {
                Arc::new(self.connect(&machine, cancel).await?)
            };
            let response = remote
                .execute(monitor::COMMAND, Duration::from_secs(45), 4 * 1024 * 1024)
                .await;
            if is_temporary {
                remote.close().await;
            }
            let response = response?;
            ensure!(response["exitCode"] == 0, "Linux monitor collection failed");
            monitor::parse(response["stdout"].as_str().unwrap_or(""))
        }
        .await;
        match result {
            Ok(mut snapshot) => {
                snapshot["machineId"] = json!(id);
                snapshot["latencyMs"] = json!(start.elapsed().as_millis() as u64);
                self.0
                    .repository
                    .history_push(id, monitor::now_ms(), &snapshot)?;
                self.publish("monitoring", snapshot.clone());
                Ok(snapshot)
            }
            Err(e) => {
                let gap = json!({"machineId":id,"timestamp":monitor::now_ms(),"status":"failed","gap":true,"error":e.to_string()});
                self.0
                    .repository
                    .history_push(id, monitor::now_ms(), &gap)?;
                self.publish("monitoring", gap);
                Err(e)
            }
        }
    }
    async fn file_request(&self, method: &str, p: &Value) -> Result<Value> {
        let session = self.session(p)?;
        let sftp = session
            .sftp
            .get_or_try_init(|| session.remote.sftp())
            .await?;
        match method {
            "file_list" => {
                let path = p["path"].as_str().unwrap_or(".");
                let canonical = sftp.canonicalize(path).await?;
                let mut entries = Vec::new();
                for entry in sftp.read_dir(&canonical).await? {
                    let name = entry.file_name();
                    if name == "." || name == ".." {
                        continue;
                    }
                    let meta = entry.metadata();
                    entries.push(json!({"name":name,"path":format!("{}/{}",canonical.trim_end_matches('/'),name),"isDirectory":meta.is_dir(),"isSymlink":meta.is_symlink(),"size":meta.len(),"permissions":meta.permissions,"modifiedAt":meta.mtime}));
                }
                Ok(json!({"path":canonical,"entries":entries}))
            }
            "file_mkdir" => {
                sftp.create_dir(field(p, "path")?).await?;
                Ok(Value::Null)
            }
            "file_rename" => {
                sftp.rename(field(p, "from")?, field(p, "to")?).await?;
                Ok(Value::Null)
            }
            "file_delete" => {
                let path = field(p, "path")?;
                ensure!(
                    !["/", ".", "..", ""].contains(&path),
                    "Cannot delete the remote root"
                );
                let meta = sftp.symlink_metadata(path).await?;
                if meta.is_dir() && !meta.is_symlink() {
                    sftp.remove_dir(path).await?;
                } else {
                    sftp.remove_file(path).await?;
                }
                Ok(Value::Null)
            }
            "file_chmod" => {
                let path = field(p, "path")?;
                let mut meta = sftp.metadata(path).await?;
                let mode = p["permissions"].as_u64().context("Permissions required")?;
                ensure!(mode <= 0o7777, "Invalid file permissions");
                meta.permissions = Some(mode as u32);
                sftp.set_metadata(path, meta).await?;
                Ok(Value::Null)
            }
            "file_read" => {
                let path = field(p, "path")?;
                let meta = sftp.metadata(path).await?;
                ensure!(
                    meta.len() <= 2 * 1024 * 1024,
                    "Editor supports files up to 2 MiB"
                );
                let file = sftp.open(path).await?;
                let mut bytes = Vec::new();
                file.take(2 * 1024 * 1024 + 1)
                    .read_to_end(&mut bytes)
                    .await?;
                ensure!(
                    bytes.len() <= 2 * 1024 * 1024,
                    "File grew beyond editor limit"
                );
                let text = String::from_utf8(bytes).context("Remote editor requires UTF-8 text")?;
                Ok(
                    json!({"text":text,"version":format!("{}:{}",meta.len(),meta.mtime.unwrap_or(0))}),
                )
            }
            "file_write" => {
                let path = field(p, "path")?;
                let text = field(p, "text")?;
                ensure!(
                    text.len() <= 2 * 1024 * 1024,
                    "Editor supports files up to 2 MiB"
                );
                let mut meta = sftp.metadata(path).await?;
                if let Some(version) = p["version"].as_str() {
                    ensure!(
                        version == format!("{}:{}", meta.len(), meta.mtime.unwrap_or(0)),
                        "Remote file changed; reload before saving"
                    );
                }
                let temporary = format!("{path}.serverdash-{}.tmp", uuid::Uuid::new_v4());
                let mut file = sftp
                    .open_with_flags(
                        &temporary,
                        russh_sftp::protocol::OpenFlags::WRITE
                            | russh_sftp::protocol::OpenFlags::CREATE
                            | russh_sftp::protocol::OpenFlags::EXCLUDE,
                    )
                    .await?;
                let result: Result<()> = async {
                    file.write_all(text.as_bytes()).await?;
                    file.shutdown().await?;
                    meta.size = Some(text.len() as u64);
                    sftp.set_metadata(&temporary, meta).await?;
                    session.remote.atomic_replace(&temporary, path).await?;
                    Ok(())
                }
                .await;
                if result.is_err() {
                    let _ = sftp.remove_file(&temporary).await;
                }
                result?;
                Ok(json!({"saved":true}))
            }
            "file_upload" | "file_download" => self.transfer(method, p, sftp, &session).await,
            _ => unreachable!(),
        }
    }
    async fn transfer(
        &self,
        method: &str,
        p: &Value,
        sftp: &russh_sftp::client::SftpSession,
        session: &Session,
    ) -> Result<Value> {
        let id = p["taskId"]
            .as_str()
            .map(str::to_owned)
            .unwrap_or_else(|| uuid::Uuid::new_v4().to_string());
        uuid::Uuid::parse_str(&id).context("Invalid transfer task ID")?;
        let cancel = session.cancellation.child_token();
        {
            let mut transfers = self.0.transfers.lock().unwrap();
            ensure!(!transfers.contains_key(&id), "Transfer task already exists");
            transfers.insert(id.clone(), cancel.clone());
        }
        let result = self.copy_file(method, p, sftp, &id, session, &cancel).await;
        self.0.transfers.lock().unwrap().remove(&id);
        self.publish("transfer",json!({"taskId":id,"status":if result.is_ok(){"completed"}else{"failed"},"error":result.as_ref().err().map(ToString::to_string)}));
        result
    }
    async fn copy_file(
        &self,
        method: &str,
        p: &Value,
        sftp: &russh_sftp::client::SftpSession,
        id: &str,
        session: &Session,
        cancel: &CancellationToken,
    ) -> Result<Value> {
        let local = PathBuf::from(field(p, "localPath")?);
        let remote = field(p, "remotePath")?;
        let overwrite = p["overwrite"].as_bool().unwrap_or(false);
        validate_local_path(&local)?;
        let mut copied = 0u64;
        let mut buffer = vec![0u8; 64 * 1024];
        if method == "file_upload" {
            ensure!(
                overwrite || !sftp.try_exists(remote).await?,
                "Remote file exists; confirm overwrite"
            );
            let mut input = tokio::fs::File::open(&local).await?;
            let total = input.metadata().await?.len();
            let temporary = format!("{remote}.serverdash-{id}.tmp");
            let mut output = sftp
                .open_with_flags_and_attributes(
                    &temporary,
                    russh_sftp::protocol::OpenFlags::CREATE
                        | russh_sftp::protocol::OpenFlags::WRITE
                        | russh_sftp::protocol::OpenFlags::EXCLUDE,
                    russh_sftp::protocol::FileAttributes {
                        permissions: Some(0o600),
                        ..Default::default()
                    },
                )
                .await?;
            let result: Result<()> = tokio::select! {result=async {loop{let n=input.read(&mut buffer).await?;if n==0{break;}output.write_all(&buffer[..n]).await?;copied+=n as u64;self.publish("transfer",json!({"taskId":id,"status":"running","direction":"upload","bytesTransferred":copied,"totalBytes":total,"name":remote}));}output.shutdown().await?;ensure!(overwrite||!sftp.try_exists(remote).await?,"Remote file appeared during transfer");if overwrite{session.remote.atomic_replace(&temporary,remote).await?;}else{sftp.rename(&temporary,remote).await?;}Ok(())}=>result,_=cancel.cancelled()=>Err(anyhow::anyhow!("Transfer cancelled"))};
            drop(output);
            if result.is_err() {
                let _ = sftp.remove_file(&temporary).await;
            }
            result?;
        } else {
            ensure!(
                overwrite || !local.exists(),
                "Local file exists; confirm overwrite"
            );
            let mut input = sftp.open(remote).await?;
            let total = sftp.metadata(remote).await?.len();
            let parent = local.parent().context("Download path has no parent")?;
            let temporary = parent.join(format!(".serverdash-{id}.tmp"));
            let mut options = tokio::fs::OpenOptions::new();
            options.create_new(true).write(true);
            #[cfg(unix)]
            options.mode(0o600);
            let mut output = options.open(&temporary).await?;
            let result: Result<()> = tokio::select! {result=async {loop{let n=input.read(&mut buffer).await?;if n==0{break;}output.write_all(&buffer[..n]).await?;copied+=n as u64;self.publish("transfer",json!({"taskId":id,"status":"running","direction":"download","bytesTransferred":copied,"totalBytes":total,"name":remote}));}output.sync_all().await?;ensure!(overwrite||!local.exists(),"Local file appeared during transfer");Ok(())}=>result,_=cancel.cancelled()=>Err(anyhow::anyhow!("Transfer cancelled"))};
            drop(output);
            let result = result.and_then(|()| install_download(&temporary, &local, overwrite));
            if result.is_err() {
                let _ = tokio::fs::remove_file(&temporary).await;
            }
            result?;
        }
        Ok(json!({"taskId":id,"bytesTransferred":copied}))
    }
}

fn install_download(
    temporary: &std::path::Path,
    destination: &std::path::Path,
    overwrite: bool,
) -> Result<()> {
    validate_local_path(destination)?;
    #[cfg(windows)]
    {
        use std::os::windows::ffi::OsStrExt;
        use windows_sys::Win32::Storage::FileSystem::*;
        let from: Vec<_> = temporary.as_os_str().encode_wide().chain(Some(0)).collect();
        let to: Vec<_> = destination
            .as_os_str()
            .encode_wide()
            .chain(Some(0))
            .collect();
        let flags = MOVEFILE_WRITE_THROUGH
            | if overwrite {
                MOVEFILE_REPLACE_EXISTING
            } else {
                0
            };
        ensure!(
            unsafe { MoveFileExW(from.as_ptr(), to.as_ptr(), flags) } != 0,
            "{}",
            std::io::Error::last_os_error()
        );
    }
    #[cfg(not(windows))]
    {
        if overwrite {
            std::fs::rename(temporary, destination)?;
        } else {
            std::fs::hard_link(temporary, destination)?;
            std::fs::remove_file(temporary)?;
        }
    }
    Ok(())
}

fn field<'a>(value: &'a Value, key: &str) -> Result<&'a str> {
    value[key]
        .as_str()
        .with_context(|| format!("Missing string field: {key}"))
}
fn dimension(value: &Value, key: &str, default: u32) -> u32 {
    value[key].as_u64().unwrap_or(default as u64).clamp(2, 1000) as u32
}
fn port(value: &Value, key: &str, default: u16) -> Result<u16> {
    let number = match value.get(key) {
        None | Some(Value::Null) => default as u64,
        Some(v) => v.as_u64().context("Port must be an integer")?,
    };
    ensure!(
        (1..=65535).contains(&number),
        "Port must be between 1 and 65535"
    );
    Ok(number as u16)
}
fn validate_machine(machine: &Value) -> Result<()> {
    uuid::Uuid::parse_str(field(machine, "id")?).context("Invalid machine ID")?;
    let kind = machine["kind"].as_str().unwrap_or("ssh");
    ensure!(
        matches!(kind, "ssh" | "rdp" | "vnc" | "local" | "serial"),
        "Unknown machine protocol"
    );
    if matches!(kind, "ssh" | "rdp" | "vnc") {
        let host = field(machine, "host")?;
        ensure!(
            !host.trim().is_empty()
                && !host.chars().any(char::is_whitespace)
                && !host.contains('\0'),
            "Invalid hostname"
        );
        port(machine, "port", 22)?;
    }
    if kind == "ssh" {
        ensure!(
            !field(machine, "username")?.trim().is_empty(),
            "SSH username is required"
        );
        ensure!(
            matches!(
                machine["authentication"].as_str().unwrap_or("agent"),
                "agent" | "privateKey" | "password" | "keyThenPassword"
            ),
            "Unknown authentication method"
        );
    }
    Ok(())
}
fn validate_local_path(path: &std::path::Path) -> Result<()> {
    ensure!(path.is_absolute(), "Local transfer path must be absolute");
    for ancestor in path.ancestors() {
        if let Ok(meta) = std::fs::symlink_metadata(ancestor) {
            ensure!(
                !meta.file_type().is_symlink(),
                "Local transfer path must not traverse symbolic links"
            );
            #[cfg(windows)]
            {
                use std::os::windows::fs::MetadataExt;
                ensure!(
                    meta.file_attributes() & 0x400 == 0,
                    "Local transfer path must not traverse reparse points"
                );
            }
        }
    }
    #[cfg(windows)]
    for component in path.components() {
        if let std::path::Component::Normal(name) = component {
            let name = name.to_string_lossy();
            ensure!(
                !name.contains(':') && !name.ends_with([' ', '.']),
                "Invalid Windows filename"
            );
            let base = name.split('.').next().unwrap_or("").to_ascii_uppercase();
            ensure!(
                !matches!(
                    base.as_str(),
                    "CON"
                        | "PRN"
                        | "AUX"
                        | "NUL"
                        | "COM1"
                        | "COM2"
                        | "COM3"
                        | "COM4"
                        | "COM5"
                        | "COM6"
                        | "COM7"
                        | "COM8"
                        | "COM9"
                        | "LPT1"
                        | "LPT2"
                        | "LPT3"
                        | "LPT4"
                        | "LPT5"
                        | "LPT6"
                        | "LPT7"
                        | "LPT8"
                        | "LPT9"
                ),
                "Reserved Windows filename"
            );
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[tokio::test]
    async fn machine_crud_and_stale_generation() {
        let dir = tempfile::tempdir().unwrap();
        let b = Backend::new(dir.path().into()).unwrap();
        let m=b.request("machine_save",json!({"machine":{"name":"Windows dev","kind":"ssh","host":"localhost","username":"tester","port":22,"authentication":"agent"}})).await.unwrap();
        assert!(m["id"].is_string());
        assert_eq!(
            b.request("machine_list", json!({}))
                .await
                .unwrap()
                .as_array()
                .unwrap()
                .len(),
            1
        );
        assert!(b
            .request(
                "session_write",
                json!({"sessionId":"gone","generation":1,"data":"YQ=="})
            )
            .await
            .is_err());
        b.request("machine_delete", json!({"id":m["id"]}))
            .await
            .unwrap();
        assert!(b
            .request("machine_list", json!({}))
            .await
            .unwrap()
            .as_array()
            .unwrap()
            .is_empty());
    }
    #[test]
    fn invalid_ports_are_not_truncated() {
        assert!(port(&json!({"port":65536}), "port", 22).is_err());
    }
    #[tokio::test]
    async fn editing_a_key_passphrase_preserves_password_without_exposing_it() {
        let dir = tempfile::tempdir().unwrap();
        let b = Backend::new(dir.path().into()).unwrap();
        let original = b
            .request(
                "credential_save",
                json!({"secret":{"password":"keep-password","passphrase":"old-passphrase"}}),
            )
            .await
            .unwrap();
        let updated = b.request("credential_save", json!({"baseCredentialId":original["credentialId"],"secret":{"passphrase":"new-passphrase"}})).await.unwrap();
        assert_eq!(updated.as_object().unwrap().len(), 1);
        assert_ne!(updated["credentialId"], original["credentialId"]);
        let saved = b
            .secrets()
            .get(updated["credentialId"].as_str().unwrap())
            .unwrap();
        assert_eq!(saved.password, "keep-password");
        assert_eq!(saved.passphrase, "new-passphrase");
        assert_eq!(
            b.secrets()
                .get(original["credentialId"].as_str().unwrap())
                .unwrap()
                .passphrase,
            "old-passphrase"
        );
    }
}
