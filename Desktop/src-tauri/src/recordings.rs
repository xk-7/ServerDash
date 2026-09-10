//! App-owned output recording. The bounded writer never stalls a live SSH session.
use anyhow::{ensure, Context, Result};
use serde_json::{json, Value};
use serverdash_core::Backend;
use serverdash_portability::recording::{self, Document, Frame, Header, Writer};
use std::{
    collections::HashMap,
    path::{Path, PathBuf},
    sync::{Arc, Mutex},
    time::Instant,
};
use tokio::sync::{mpsc, OwnedSemaphorePermit, Semaphore};

enum Item {
    Output(f64, Vec<u8>),
    Screen(f64, Frame),
}
struct Active {
    id: String,
    reason: Arc<Mutex<Option<String>>>,
    start: Instant,
    sender: mpsc::Sender<(Item, OwnedSemaphorePermit)>,
}
pub struct Recordings {
    directory: PathBuf,
    active: Arc<Mutex<HashMap<(String, u64), Active>>>,
    budget: Arc<Semaphore>,
    documents: Mutex<HashMap<String, Document>>,
    workers: Mutex<Vec<tokio::task::JoinHandle<()>>>,
}
impl Recordings {
    pub fn new(directory: PathBuf) -> Result<Self> {
        std::fs::create_dir_all(&directory)?;
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            std::fs::set_permissions(&directory, std::fs::Permissions::from_mode(0o700))?;
        }
        Ok(Self {
            directory,
            active: Arc::new(Mutex::new(HashMap::new())),
            budget: Arc::new(Semaphore::new(32 * 1024 * 1024)),
            documents: Mutex::new(HashMap::new()),
            workers: Mutex::new(Vec::new()),
        })
    }
    pub async fn start(&self, backend: &Backend, p: &Value) -> Result<Value> {
        let session = target(p)?;
        let sessions = backend.request("session_list", json!({})).await?;
        ensure!(
            sessions.as_array().is_some_and(|items| items
                .iter()
                .any(|s| s["sessionId"] == session.0 && s["generation"] == session.1)),
            "仅支持当前已连接的 SSH 会话"
        );
        let frame: Frame = serde_json::from_value(p["frame"].clone())?;
        frame.validate()?;
        ensure!(frame.changed_rows.is_none(), "录制需要完整初始画面");
        let mut active = self.active.lock().unwrap();
        ensure!(!active.contains_key(&session), "此面板正在录制");
        let header = Header::new(
            p["name"]
                .as_str()
                .unwrap_or("SSH 会话")
                .chars()
                .take(128)
                .collect(),
        );
        let id = header.id.to_string();
        let path = self.directory.join(format!("{id}.sdrec.partial"));
        let mut options = std::fs::OpenOptions::new();
        options.create_new(true).write(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            options.mode(0o600);
        }
        let mut writer = Writer::new(options.open(&path)?, header)?;
        writer.screen(0.0, frame)?;
        writer.flush()?;
        let (sender, mut receiver) = mpsc::channel::<(Item, OwnedSemaphorePermit)>(512);
        let started = Instant::now();
        let reason = Arc::new(Mutex::new(None));
        active.insert(
            session.clone(),
            Active {
                id: id.clone(),
                reason: reason.clone(),
                start: started,
                sender,
            },
        );
        let backend = backend.clone();
        let result_id = id.clone();
        let records = self.active.clone();
        let worker = tokio::task::spawn_blocking(move || {
            let mut latest = 0.0;
            let result: Result<PathBuf> = (|| {
                while let Some((item, _permit)) = receiver.blocking_recv() {
                    match item {
                        Item::Output(time, data) => {
                            latest = time;
                            writer.output(time, &data)?;
                        }
                        Item::Screen(time, frame) => {
                            latest = time;
                            writer.screen(time, frame)?;
                        }
                    }
                }
                let file = writer.finish(
                    started.elapsed().as_secs_f64().max(latest),
                    reason.lock().unwrap().clone(),
                )?;
                file.sync_all()?;
                drop(file);
                let destination = path.with_extension("");
                ensure!(!destination.exists(), "录制目标文件已存在");
                std::fs::rename(&path, &destination)?;
                Ok(destination)
            })();
            let mut records = records.lock().unwrap();
            if records.get(&session).is_some_and(|r| r.id == result_id) {
                records.remove(&session);
            }
            drop(records);
            backend.publish("recording",json!({"id":result_id,"sessionId":session.0,"generation":session.1,"status":if result.is_ok(){"saved"}else{"failed"},"path":result.as_ref().ok(),"error":result.err().map(|e|e.to_string())}));
        });
        let mut workers = self.workers.lock().unwrap();
        workers.retain(|w| !w.is_finished());
        workers.push(worker);
        Ok(json!({"id":id,"status":"recording"}))
    }
    fn enqueue(
        &self,
        backend: &Backend,
        session: &(String, u64),
        item: impl FnOnce(f64) -> Item,
        cost: usize,
    ) -> Result<()> {
        let mut active = self.active.lock().unwrap();
        let Some(record) = active.get(session) else {
            return Ok(());
        };
        let permit = self
            .budget
            .clone()
            .try_acquire_many_owned(cost.min(u32::MAX as usize) as u32);
        let result = permit.ok().and_then(|permit| {
            record
                .sender
                .try_send((item(record.start.elapsed().as_secs_f64()), permit))
                .ok()
        });
        if result.is_none() {
            let record = active.remove(session).unwrap();
            *record.reason.lock().unwrap() = Some("Recording queue overflow".into());
            backend.publish("recording",json!({"id":record.id,"sessionId":session.0,"generation":session.1,"status":"stopped","error":"录制写入队列已满，已停止录制；SSH 连接继续。"}));
        }
        Ok(())
    }
    pub fn output(&self, backend: &Backend, id: &str, generation: u64, bytes: &[u8]) {
        let _ = self.enqueue(
            backend,
            &(id.into(), generation),
            |time| Item::Output(time, bytes.to_vec()),
            bytes.len() + 256,
        );
    }
    pub fn screen(&self, backend: &Backend, p: &Value) -> Result<Value> {
        let session = target(p)?;
        let frame: Frame = serde_json::from_value(p["frame"].clone())?;
        frame.validate()?;
        let cost = serde_json::to_vec(&frame)?.len() + 256;
        self.enqueue(backend, &session, |time| Item::Screen(time, frame), cost)?;
        Ok(Value::Null)
    }
    pub fn stop(&self, p: &Value) -> Result<Value> {
        let record = self.active.lock().unwrap().remove(&target(p)?);
        Ok(json!({"stopped":record.is_some()}))
    }
    pub async fn shutdown(&self) {
        self.active.lock().unwrap().clear();
        let workers = std::mem::take(&mut *self.workers.lock().unwrap());
        for worker in workers {
            let _ = worker.await;
        }
    }
    pub fn list(&self) -> Result<Value> {
        let mut results = Vec::new();
        for entry in std::fs::read_dir(&self.directory)? {
            let path = entry?.path();
            if !path.is_file() {
                continue;
            }
            if matches!(
                path.extension().and_then(|s| s.to_str()),
                Some("sdrec" | "partial")
            ) {
                if let Ok(document) = Document::open(&path, true) {
                    let id = document.header.id.to_string();
                    results.push(json!({"id":id,"name":document.header.name,"duration":document.duration,"complete":document.complete,"date":document.header.date,"path":path}));
                    self.documents.lock().unwrap().insert(id, document);
                }
            }
        }
        Ok(json!(results))
    }
    pub fn open(&self, path: &Path) -> Result<Value> {
        let document = Document::open(path, true)?;
        let id = document.header.id.to_string();
        let result = json!({"id":id,"name":document.header.name,"duration":document.duration,"complete":document.complete,"hasImages":document.has_images,"maximumWidth":document.maximum_width,"maximumHeight":document.maximum_height});
        self.documents.lock().unwrap().insert(id, document);
        Ok(result)
    }
    pub fn frame(&self, p: &Value) -> Result<Value> {
        let id = p["id"].as_str().context("请选择录制")?;
        let document = self
            .documents
            .lock()
            .unwrap()
            .get(id)
            .cloned()
            .context("录制未打开")?;
        let mut cursor = recording::Cursor::new(document)?;
        Ok(json!(cursor.seek(p["time"].as_f64().unwrap_or(0.0))?))
    }
}
fn target(p: &Value) -> Result<(String, u64)> {
    Ok((
        p["sessionId"].as_str().context("缺少会话")?.into(),
        p["generation"].as_u64().context("缺少连接代次")?,
    ))
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn empty_recording_library_has_no_fake_entries() {
        let d = tempfile::tempdir().unwrap();
        let r = Recordings::new(d.path().into()).unwrap();
        assert_eq!(r.list().unwrap(), json!([]));
        assert!(r.frame(&json!({"id":"missing"})).is_err());
    }
}
