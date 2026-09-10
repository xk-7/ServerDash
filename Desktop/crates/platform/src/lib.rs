//! Desktop operating-system adapters. Session lifetime belongs to the application.
use anyhow::{bail, ensure, Context, Result};
use base64::Engine;
use portable_pty::{native_pty_system, Child, ChildKiller, CommandBuilder, MasterPty, PtySize};
use serde_json::{json, Value};
use serverdash_core::{Backend, OutputChunk};
use std::{
    collections::HashMap,
    io::{Read, Write},
    path::{Path, PathBuf},
    sync::{
        atomic::{AtomicU64, Ordering},
        Arc, Mutex,
    },
    time::Duration,
};
use tokio::sync::{mpsc, OwnedSemaphorePermit, Semaphore};
use tokio_util::sync::CancellationToken;

struct Session {
    id: String,
    generation: u64,
    machine_id: Option<String>,
    cancellation: CancellationToken,
    writer: Mutex<Option<Box<dyn Write + Send>>>,
    master: Mutex<Option<Box<dyn MasterPty + Send>>>,
    reader_thread: Mutex<Option<std::thread::JoinHandle<()>>>,
    reaper_thread: Mutex<Option<std::thread::JoinHandle<()>>>,
    killer: Mutex<Option<Box<dyn ChildKiller + Send + Sync>>>,
    receiver: Mutex<Option<mpsc::Receiver<OutputChunk>>>,
    pending: Arc<Mutex<HashMap<u64, OwnedSemaphorePermit>>>,
    sent: Arc<AtomicU64>,
    #[cfg(windows)]
    job: Mutex<Option<windows_job::Job>>,
}

#[derive(Clone)]
pub struct Platform(Arc<Inner>);
struct Inner {
    backend: Backend,
    sessions: Mutex<HashMap<String, Arc<Session>>>,
    generation: AtomicU64,
}

impl Platform {
    pub fn new(backend: Backend) -> Self {
        Self(Arc::new(Inner {
            backend,
            sessions: Mutex::new(HashMap::new()),
            generation: AtomicU64::new(1),
        }))
    }
    pub fn owns(&self, id: &str) -> bool {
        self.0.sessions.lock().unwrap().contains_key(id)
    }
    fn session(&self, params: &Value) -> Result<Arc<Session>> {
        let id = string(params, "sessionId")?;
        let session = self
            .0
            .sessions
            .lock()
            .unwrap()
            .get(id)
            .cloned()
            .context("本地会话已关闭")?;
        ensure!(
            params["generation"].as_u64() == Some(session.generation),
            "连接已更新，请重新打开会话"
        );
        Ok(session)
    }
    pub fn output(&self, id: &str, generation: u64) -> Result<mpsc::Receiver<OutputChunk>> {
        let session = self.session(&json!({"sessionId":id,"generation":generation}))?;
        let output = session
            .receiver
            .lock()
            .unwrap()
            .take()
            .context("输出已被订阅");
        output
    }
    pub async fn request(&self, method: &str, params: Value) -> Result<Value> {
        match method {
            "serial_list" => Ok(json!(serialport::available_ports()?
                .into_iter()
                .map(|p| json!({"path":p.port_name,"name":format!("{:?}",p.port_type)}))
                .collect::<Vec<_>>())),
            "session_open" => {
                let platform = self.clone();
                tokio::task::spawn_blocking(move || platform.open(params)).await?
            }
            "session_write" => {
                let s = self.session(&params)?;
                ensure!(!s.cancellation.is_cancelled(), "会话已断开");
                let bytes =
                    base64::engine::general_purpose::STANDARD.decode(string(&params, "data")?)?;
                ensure!(bytes.len() <= 1024 * 1024, "输入超过 1 MiB");
                tokio::task::spawn_blocking(move || -> Result<()> {
                    let mut writer = s.writer.lock().unwrap();
                    let writer = writer.as_mut().context("会话已关闭")?;
                    writer.write_all(&bytes)?;
                    writer.flush()?;
                    Ok(())
                })
                .await??;
                Ok(Value::Null)
            }
            "session_ack" => {
                let s = self.session(&params)?;
                let seq = params["sequence"].as_u64().context("缺少输出序号")?;
                ensure!(
                    seq <= s.sent.load(Ordering::Acquire),
                    "确认序号超出已发送范围"
                );
                s.pending.lock().unwrap().retain(|&k, _| k > seq);
                Ok(Value::Null)
            }
            "session_resize" => {
                let s = self.session(&params)?;
                if let Some(master) = s.master.lock().unwrap().as_ref() {
                    master.resize(size(&params))?;
                }
                Ok(Value::Null)
            }
            "session_close" => {
                let s = self.session(&params)?;
                self.close(s).await;
                Ok(Value::Null)
            }
            "vnc_open" => {
                let machine = self.machine(string(&params, "machineId")?).await?;
                let bootstrap = self.0.backend.request("bootstrap", json!({})).await?;
                let viewer = bootstrap["settings"]["vncViewerPath"]
                    .as_str()
                    .context("请在设置中选择 TigerVNC Viewer 程序")?;
                let executable = Path::new(viewer);
                ensure!(
                    executable.is_absolute() && executable.is_file(),
                    "VNC 客户端路径不可用"
                );
                let host = string(&machine, "host")?;
                ensure!(
                    !host.is_empty()
                        && !host.starts_with('-')
                        && !host
                            .chars()
                            .any(|c| c.is_whitespace() || c.is_control() || "/@\\".contains(c)),
                    "VNC 地址无效"
                );
                let port = machine["port"].as_u64().unwrap_or(5900);
                ensure!((1..=65535).contains(&port), "VNC 端口无效");
                let host = if host.contains(':') {
                    format!("[{}]", host.trim_matches(['[', ']']))
                } else {
                    host.into()
                };
                let mut child = std::process::Command::new(executable)
                    .arg(format!("{host}::{port}"))
                    .spawn()?;
                std::thread::spawn(move || {
                    let _ = child.wait();
                });
                Ok(json!({"launched":true}))
            }
            _ => bail!("未知平台操作：{method}"),
        }
    }
    async fn machine(&self, id: &str) -> Result<Value> {
        let list = self.0.backend.request("machine_list", json!({})).await?;
        list.as_array()
            .context("机器列表无效")?
            .iter()
            .find(|m| m["id"] == id)
            .cloned()
            .context("机器已删除")
    }
    fn open(&self, params: Value) -> Result<Value> {
        let kind = params["kind"].as_str().unwrap_or("local");
        ensure!(matches!(kind, "local" | "serial"), "不支持的本机会话类型");
        let runtime = tokio::runtime::Handle::current();
        let mut config = if kind == "serial" {
            runtime.block_on(self.machine(string(&params, "machineId")?))?
        } else {
            params.clone()
        };
        if kind == "local" && config["shellPath"].is_null() {
            if let Ok(settings) = self.0.backend.repository().get("settings", "default") {
                config["shellPath"] = settings["localShell"].clone();
            }
        }
        let id = uuid::Uuid::new_v4().to_string();
        let generation = self.0.generation.fetch_add(1, Ordering::Relaxed);
        let cancellation = CancellationToken::new();
        let (sender, receiver) = mpsc::channel(8);
        let pending = Arc::new(Mutex::new(HashMap::new()));
        let sent = Arc::new(AtomicU64::new(0));
        let mut session = Session {
            id: id.clone(),
            generation,
            machine_id: params["machineId"].as_str().map(str::to_owned),
            cancellation: cancellation.clone(),
            writer: Mutex::new(None),
            master: Mutex::new(None),
            reader_thread: Mutex::new(None),
            reaper_thread: Mutex::new(None),
            killer: Mutex::new(None),
            receiver: Mutex::new(Some(receiver)),
            pending: pending.clone(),
            sent: sent.clone(),
            #[cfg(windows)]
            job: Mutex::new(None),
        };
        let mut reader: Box<dyn Read + Send>;
        let mut child_to_reap: Option<Box<dyn Child + Send + Sync>> = None;
        if kind == "local" {
            let shell = config["shellPath"]
                .as_str()
                .filter(|s| !s.is_empty())
                .map(PathBuf::from)
                .unwrap_or_else(default_shell);
            ensure!(
                shell.is_absolute() && shell.is_file(),
                "本地 Shell 必须是现有程序的绝对路径"
            );
            let pair = native_pty_system().openpty(size(&config))?;
            let mut command = CommandBuilder::new(shell.as_os_str());
            let clean = config["cleanEnvironment"].as_bool().unwrap_or(false);
            if clean {
                command.env_clear();
                for key in [
                    "PATH",
                    "SYSTEMROOT",
                    "WINDIR",
                    "COMSPEC",
                    "USERPROFILE",
                    "HOME",
                    "HOMEDRIVE",
                    "HOMEPATH",
                    "TEMP",
                    "TMP",
                    "LANG",
                ] {
                    if let Some(value) = std::env::var_os(key) {
                        command.env(key, value);
                    }
                }
            }
            let name = shell
                .file_stem()
                .and_then(|v| v.to_str())
                .unwrap_or("")
                .to_lowercase();
            if name == "powershell" || name == "pwsh" {
                command.arg("-NoLogo");
                if clean {
                    command.arg("-NoProfile");
                }
            } else if clean && name == "bash" {
                command.args(["--noprofile", "--norc"]);
            } else if clean && name == "zsh" {
                command.arg("-f");
            }
            command.env("TERM", "xterm-256color");
            if let Some(home) = std::env::var_os(if cfg!(windows) { "USERPROFILE" } else { "HOME" })
            {
                command.cwd(home);
            }
            // Acquire both pipes before launching: a pipe failure must not orphan a shell.
            reader = pair.master.try_clone_reader()?;
            *session.writer.get_mut().unwrap() = Some(pair.master.take_writer()?);
            #[allow(unused_mut)]
            let mut child = pair.slave.spawn_command(command)?;
            #[cfg(windows)]
            {
                match child
                    .as_raw_handle()
                    .context("本地 Shell 未返回进程句柄")
                    .and_then(windows_job::Job::new)
                {
                    Ok(job) => *session.job.get_mut().unwrap() = Some(job),
                    Err(e) => {
                        let _ = child.kill();
                        let _ = child.wait();
                        return Err(e);
                    }
                }
            }
            *session.killer.get_mut().unwrap() = Some(child.clone_killer());
            child_to_reap = Some(child);
            *session.master.get_mut().unwrap() = Some(pair.master);
            drop(pair.slave);
        } else {
            let path = config["devicePath"]
                .as_str()
                .or_else(|| config["path"].as_str())
                .or_else(|| config["host"].as_str())
                .filter(|s| !s.is_empty())
                .context("请选择串口设备")?;
            ensure!(!path.chars().any(char::is_control), "串口路径无效");
            let bits = match config["dataBits"].as_u64().unwrap_or(8) {
                5 => serialport::DataBits::Five,
                6 => serialport::DataBits::Six,
                7 => serialport::DataBits::Seven,
                8 => serialport::DataBits::Eight,
                _ => bail!("数据位无效"),
            };
            let parity = match config["parity"].as_str().unwrap_or("none") {
                "none" => serialport::Parity::None,
                "odd" => serialport::Parity::Odd,
                "even" => serialport::Parity::Even,
                _ => bail!("校验位无效"),
            };
            let stop = match config["stopBits"].as_u64().unwrap_or(1) {
                1 => serialport::StopBits::One,
                2 => serialport::StopBits::Two,
                _ => bail!("停止位无效"),
            };
            let flow = match config["flowControl"].as_str().unwrap_or("none") {
                "none" => serialport::FlowControl::None,
                "hardware" => serialport::FlowControl::Hardware,
                "software" => serialport::FlowControl::Software,
                _ => bail!("流控无效"),
            };
            let baud = config["baudRate"].as_u64().unwrap_or(115200);
            ensure!((300..=921600).contains(&baud), "波特率超出范围");
            let port = serialport::new(path, baud as u32)
                .data_bits(bits)
                .parity(parity)
                .stop_bits(stop)
                .flow_control(flow)
                .timeout(Duration::from_millis(200))
                .open()?;
            reader = Box::new(port.try_clone()?);
            *session.writer.get_mut().unwrap() = Some(Box::new(port));
        }
        let session = Arc::new(session);
        self.0
            .sessions
            .lock()
            .unwrap()
            .insert(id.clone(), session.clone());
        let backend = self.0.backend.clone();
        let event_id = id.clone();
        let permits = Arc::new(Semaphore::new(8));
        let reader_session = session.clone();
        let drain_conpty = cfg!(windows) && kind == "local";
        let reader_thread = std::thread::spawn(move || {
            let mut buffer = [0u8; 16384];
            let mut error = None;
            loop {
                if cancellation.is_cancelled() && !drain_conpty {
                    break;
                }
                let count = match reader.read(&mut buffer) {
                    Ok(0) => break,
                    Ok(n) => n,
                    Err(e)
                        if matches!(
                            e.kind(),
                            std::io::ErrorKind::TimedOut | std::io::ErrorKind::Interrupted
                        ) =>
                    {
                        continue
                    }
                    Err(e) => {
                        error = Some(e.to_string());
                        break;
                    }
                };
                // Before Windows 11 24H2 ClosePseudoConsole can wait for pipe
                // drainage. Cancellation releases terminal backpressure but keeps
                // this reader alive until the independent reaper closes HPCON.
                // https://learn.microsoft.com/windows/console/closepseudoconsole
                if drain_conpty && cancellation.is_cancelled() {
                    continue;
                }
                let accepted=runtime.block_on(async {
                    let permit=tokio::select!{p=permits.clone().acquire_owned()=>p.ok(),_=cancellation.cancelled()=>None};
                    let Some(permit)=permit else{return false;};
                    let sequence=sent.fetch_add(1,Ordering::AcqRel)+1;
                    pending.lock().unwrap().insert(sequence,permit);
                    tokio::select!{r=sender.send(OutputChunk{sequence,data:buffer[..count].to_vec()})=>r.is_ok(),_=cancellation.cancelled()=>false}
                });
                if !accepted {
                    cancellation.cancel();
                    if !drain_conpty {
                        break;
                    }
                    // A dropped frontend receiver must also terminate the child;
                    // otherwise there would be no close request to wake the reaper.
                    reader_session.terminate();
                }
            }
            drop(reader);
            cancellation.cancel();
            pending.lock().unwrap().clear();
            reader_session.terminate();
            backend.publish("session_status",json!({"sessionId":event_id,"generation":generation,"status":"closed","error":error}));
        });
        *session.reader_thread.lock().unwrap() = Some(reader_thread);
        if let Some(mut child) = child_to_reap {
            let reaper_session = session.clone();
            let reaper = std::thread::spawn(move || {
                let _ = child.wait();
                // A ConPTY read can remain blocked after the shell exits until HPCON is
                // closed. Keep draining output while closing it; do not cancel first.
                #[cfg(windows)]
                {
                    reaper_session.job.lock().unwrap().take();
                }
                reaper_session.writer.lock().unwrap().take();
                reaper_session.master.lock().unwrap().take();
                reaper_session.killer.lock().unwrap().take();
            });
            *session.reaper_thread.lock().unwrap() = Some(reaper);
        }
        self.0.backend.publish(
            "session_status",
            json!({"sessionId":id,"generation":generation,"status":"connected","kind":kind}),
        );
        Ok(json!({"sessionId":id,"generation":generation}))
    }
    async fn close(&self, session: Arc<Session>) {
        session.cancellation.cancel();
        session.pending.lock().unwrap().clear();
        self.0.sessions.lock().unwrap().remove(&session.id);
        tokio::task::spawn_blocking(move || {
            session.terminate();
            // The child must be reaped and the serial/PTY reader stopped before exit.
            if let Some(thread) = session.reaper_thread.lock().unwrap().take() {
                let _ = thread.join();
            }
            if let Some(thread) = session.reader_thread.lock().unwrap().take() {
                let _ = thread.join();
            }
        })
        .await
        .ok();
    }
    pub async fn close_machine(&self, id: &str) {
        let sessions: Vec<_> = self
            .0
            .sessions
            .lock()
            .unwrap()
            .values()
            .filter(|s| s.machine_id.as_deref() == Some(id))
            .cloned()
            .collect();
        for session in sessions {
            self.close(session).await;
        }
    }
    pub async fn reconcile_machines(&self) {
        // Imported configuration tombstones must end sessions bound to deleted machines.
        let Ok(machines) = self.0.backend.repository().list("machines") else {
            return;
        };
        let sessions: Vec<_> = self
            .0
            .sessions
            .lock()
            .unwrap()
            .values()
            .filter(|s| {
                s.machine_id
                    .as_deref()
                    .is_some_and(|id| !machines.iter().any(|m| m["id"] == id))
            })
            .cloned()
            .collect();
        for session in sessions {
            self.close(session).await;
        }
    }
    pub async fn shutdown(&self) {
        let sessions: Vec<_> = self.0.sessions.lock().unwrap().values().cloned().collect();
        for session in sessions {
            self.close(session).await;
        }
    }
}
impl Session {
    fn terminate(&self) {
        #[cfg(windows)]
        {
            self.job.lock().unwrap().take();
        }
        if let Some(mut killer) = self.killer.lock().unwrap().take() {
            let _ = killer.kill();
        }
        self.writer.lock().unwrap().take();
        // The Windows child reaper owns HPCON teardown; calling it on the pipe
        // reader could deadlock while the console is still writing final output.
        #[cfg(not(windows))]
        self.master.lock().unwrap().take();
    }
}
fn default_shell() -> PathBuf {
    #[cfg(windows)]
    {
        PathBuf::from(std::env::var_os("SYSTEMROOT").unwrap_or_else(|| "C:\\Windows".into()))
            .join("System32/WindowsPowerShell/v1.0/powershell.exe")
    }
    #[cfg(not(windows))]
    {
        std::env::var_os("SHELL")
            .map(PathBuf::from)
            .filter(|p| p.is_absolute() && p.is_file())
            .unwrap_or_else(|| PathBuf::from("/bin/sh"))
    }
}
fn size(p: &Value) -> PtySize {
    PtySize {
        rows: p["rows"].as_u64().unwrap_or(24).clamp(2, 512) as u16,
        cols: p["columns"].as_u64().unwrap_or(80).clamp(2, 1024) as u16,
        pixel_width: 0,
        pixel_height: 0,
    }
}
fn string<'a>(p: &'a Value, key: &str) -> Result<&'a str> {
    p[key].as_str().with_context(|| format!("缺少参数：{key}"))
}

#[cfg(windows)]
mod windows_job {
    use anyhow::Result;
    use windows_sys::Win32::{
        Foundation::{CloseHandle, HANDLE},
        System::JobObjects::*,
    };
    pub struct Job(HANDLE);
    unsafe impl Send for Job {}
    unsafe impl Sync for Job {}
    impl Job {
        pub fn new(process: std::os::windows::io::RawHandle) -> Result<Self> {
            unsafe {
                let handle = CreateJobObjectW(std::ptr::null(), std::ptr::null());
                if handle.is_null() {
                    return Err(std::io::Error::last_os_error().into());
                }
                let job = Self(handle);
                let mut info: JOBOBJECT_EXTENDED_LIMIT_INFORMATION = std::mem::zeroed();
                info.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
                if SetInformationJobObject(
                    handle,
                    JobObjectExtendedLimitInformation,
                    &info as *const _ as *const _,
                    std::mem::size_of_val(&info) as u32,
                ) == 0
                {
                    return Err(std::io::Error::last_os_error().into());
                }
                // Borrow the handle owned by portable-pty, avoiding PID reuse and OpenProcess races.
                if AssignProcessToJobObject(handle, process as HANDLE) == 0 {
                    return Err(std::io::Error::last_os_error().into());
                }
                Ok(job)
            }
        }
    }
    impl Drop for Job {
        fn drop(&mut self) {
            unsafe {
                CloseHandle(self.0);
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn shell_config() -> Value {
        #[cfg(unix)]
        {
            json!({"kind":"local","cleanEnvironment":true,"shellPath":"/bin/sh"})
        }
        #[cfg(not(unix))]
        {
            json!({"kind":"local","cleanEnvironment":true})
        }
    }

    async fn write(platform: &Platform, opened: &Value, command: &str) {
        let mut params = opened.clone();
        params["data"] = json!(base64::engine::general_purpose::STANDARD.encode(command));
        platform.request("session_write", params).await.unwrap();
    }

    async fn terminal_handshake(
        platform: &Platform,
        opened: &Value,
        output: &mut mpsc::Receiver<OutputChunk>,
    ) {
        // portable-pty requests PSEUDOCONSOLE_INHERIT_CURSOR. xterm.js answers
        // this DSR in the app; the headless test must act as the terminal too.
        if cfg!(windows) {
            let mut received = Vec::new();
            tokio::time::timeout(Duration::from_secs(20), async {
                while let Some(chunk) = output.recv().await {
                    received.extend_from_slice(&chunk.data);
                    platform.request("session_ack", json!({"sessionId":opened["sessionId"],"generation":opened["generation"],"sequence":chunk.sequence})).await.unwrap();
                    if received.windows(4).any(|bytes| bytes == b"\x1b[6n") {
                        write(platform, opened, "\x1b[1;1R").await;
                        return;
                    }
                    assert!(received.len() < 65536, "ConPTY did not request initial cursor position");
                }
                panic!("ConPTY closed before startup handshake");
            }).await.unwrap_or_else(|_| panic!("ConPTY cursor handshake timed out: {:?}", String::from_utf8_lossy(&received)));
        }
    }

    #[tokio::test]
    async fn local_shell_executes_and_reaps_natural_exit() {
        let directory = tempfile::tempdir().unwrap();
        let core = Backend::new(directory.path().into()).unwrap();
        let platform = Platform::new(core);
        let opened = platform
            .request("session_open", shell_config())
            .await
            .unwrap();
        let id = opened["sessionId"].as_str().unwrap();
        let generation = opened["generation"].as_u64().unwrap();
        let session = platform.session(&opened).unwrap();
        let mut output = platform.output(id, generation).unwrap();
        terminal_handshake(&platform, &opened, &mut output).await;
        // The expected marker never occurs in the input, so terminal echo cannot pass.
        let command = if cfg!(windows) {
            "[Console]::WriteLine(('serverdash-platform-{0}-ok' -f (17 * 19)))\r\n"
        } else {
            "printf 'serverdash-platform-%s-ok\\n' $((17 * 19))\n"
        };
        write(&platform, &opened, command).await;
        let mut text = String::new();
        tokio::time::timeout(Duration::from_secs(20), async {
            while let Some(chunk) = output.recv().await {
                text.push_str(&String::from_utf8_lossy(&chunk.data));
                platform
                    .request(
                        "session_ack",
                        json!({"sessionId":id,"generation":generation,"sequence":chunk.sequence}),
                    )
                    .await
                    .unwrap();
                if text.contains("serverdash-platform-323-ok") {
                    break;
                }
            }
        })
        .await
        .unwrap();
        assert!(
            text.contains("serverdash-platform-323-ok"),
            "shell must execute the command"
        );
        assert!(platform.output(id, generation + 1).is_err());
        write(&platform, &opened, "exit\r\n").await;
        tokio::time::timeout(Duration::from_secs(20), async {
            while let Some(chunk) = output.recv().await {
                platform
                    .request(
                        "session_ack",
                        json!({"sessionId":id,"generation":generation,"sequence":chunk.sequence}),
                    )
                    .await
                    .unwrap();
            }
        })
        .await
        .unwrap();
        assert!(session.cancellation.is_cancelled());
        tokio::time::timeout(Duration::from_secs(10), platform.shutdown())
            .await
            .unwrap();
        assert!(!platform.owns(id));
        assert!(session.writer.lock().unwrap().is_none());
        assert!(session.master.lock().unwrap().is_none());
        assert!(session.killer.lock().unwrap().is_none());
        assert!(session.reader_thread.lock().unwrap().is_none());
        assert!(session.reaper_thread.lock().unwrap().is_none());
    }

    #[tokio::test]
    async fn shutdown_releases_a_shell_blocked_by_terminal_backpressure() {
        let directory = tempfile::tempdir().unwrap();
        let core = Backend::new(directory.path().into()).unwrap();
        let platform = Platform::new(core);
        let opened = platform
            .request("session_open", shell_config())
            .await
            .unwrap();
        let session = platform.session(&opened).unwrap();
        let mut output = platform.output(&session.id, session.generation).unwrap();
        terminal_handshake(&platform, &opened, &mut output).await;
        let command = if cfg!(windows) {
            "while ($true) { [Console]::Write(('x' * 16384)) }\r\n"
        } else {
            "while :; do printf 'xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx'; done\n"
        };
        write(&platform, &opened, command).await;
        // Leave the bounded output channel unconsumed and do not acknowledge output.
        tokio::time::timeout(Duration::from_secs(20), async {
            while session.pending.lock().unwrap().len() < 8 {
                tokio::time::sleep(Duration::from_millis(10)).await;
            }
        })
        .await
        .unwrap();
        tokio::time::timeout(Duration::from_secs(10), platform.shutdown())
            .await
            .unwrap();
        assert!(!platform.owns(&session.id));
        assert!(session.pending.lock().unwrap().is_empty());
        assert!(session.reader_thread.lock().unwrap().is_none());
        assert!(session.reaper_thread.lock().unwrap().is_none());
    }
}
