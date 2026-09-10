//! End-to-end backend tests over real encrypted loopback SSH and SFTP streams.
mod support;

use base64::{engine::general_purpose::STANDARD, Engine};
use serde_json::{json, Value};
use serverdash_core::{Backend, BackendEvent};
use std::{sync::atomic::Ordering, time::Duration};
use support::{TestServer, PASSWORD, USER};
use tokio::{sync::broadcast, task::JoinHandle, time::timeout};

const DEADLINE: Duration = Duration::from_secs(10);

struct Harness {
    server: TestServer,
    backend: Backend,
    events: broadcast::Receiver<BackendEvent>,
    machine_id: String,
    _directory: tempfile::TempDir,
}

impl Harness {
    async fn new(password: &str) -> Self {
        let server = TestServer::start().await;
        let directory = tempfile::tempdir().unwrap();
        let backend = Backend::new(directory.path().into()).unwrap();
        let events = backend.subscribe();
        let credential = backend
            .request("credential_save", json!({"secret":{"password":password}}))
            .await
            .unwrap();
        let machine = backend.request("machine_save", json!({"machine":{
            "name":"Loopback integration peer", "host":"127.0.0.1", "port":server.address.port(),
            "kind":"ssh", "username":USER, "authentication":"password", "credentialId":credential["credentialId"]
        }})).await.unwrap();
        Self {
            server,
            backend,
            events,
            machine_id: machine["id"].as_str().unwrap().into(),
            _directory: directory,
        }
    }

    fn begin_open(&self, request_id: &str) -> JoinHandle<anyhow::Result<Value>> {
        let backend = self.backend.clone();
        let params = json!({"machineId":self.machine_id,"requestId":request_id,"kind":"ssh","columns":93,"rows":31});
        tokio::spawn(async move { backend.request("session_open", params).await })
    }

    async fn event(&mut self, kind: &str) -> Value {
        timeout(DEADLINE, async {
            loop {
                let event = self.events.recv().await.unwrap();
                if event.kind == kind {
                    return event.payload;
                }
            }
        })
        .await
        .expect("Expected backend event did not arrive")
    }

    async fn decide(&self, event: &Value, decision: &str) {
        self.backend
            .request(
                "trust_decide",
                json!({"requestId":event["requestId"],"decision":decision}),
            )
            .await
            .unwrap();
    }

    async fn open(&mut self) -> Value {
        let opening = self.begin_open("open");
        let trust = self.event("trust").await;
        self.decide(&trust, "once").await;
        timeout(DEADLINE, opening).await.unwrap().unwrap().unwrap()
    }

    async fn close(&self, session: Value) {
        self.backend
            .request("session_close", session)
            .await
            .unwrap();
        self.server.assert_disconnected().await;
    }

    async fn assert_no_sessions(&self) {
        assert!(self
            .backend
            .request("session_list", json!({}))
            .await
            .unwrap()
            .as_array()
            .unwrap()
            .is_empty());
    }
}

fn parameters(session: &Value, extra: Value) -> Value {
    let mut params = session.clone();
    params
        .as_object_mut()
        .unwrap()
        .extend(extra.as_object().unwrap().clone());
    params
}

#[tokio::test]
async fn key_then_password_falls_back_when_a_migrated_key_is_unavailable() {
    let mut h = Harness::new(PASSWORD).await;
    let mut machine = h
        .backend
        .repository()
        .get("machines", &h.machine_id)
        .unwrap();
    machine["authentication"] = json!("keyThenPassword");
    machine["privateKeyPath"] = json!(h._directory.path().join("missing-private-key"));
    h.backend
        .request("machine_save", json!({"machine":machine}))
        .await
        .unwrap();
    let session = h.open().await;
    assert_eq!(
        h.server
            .state
            .authentication_attempts
            .load(Ordering::Acquire),
        1
    );
    h.close(session).await;
}

#[tokio::test]
async fn unknown_host_waits_before_auth_and_stored_trust_reconnects_without_prompt() {
    let mut h = Harness::new(PASSWORD).await;
    let opening = h.begin_open("unknown-key");
    let trust = h.event("trust").await;
    assert_eq!(trust["host"], "127.0.0.1");
    assert_eq!(trust["changed"], false);
    assert!(trust["fingerprint"]
        .as_str()
        .unwrap()
        .starts_with("SHA256:"));
    assert_eq!(
        h.server
            .state
            .authentication_attempts
            .load(Ordering::Acquire),
        0
    );
    assert!(
        !opening.is_finished(),
        "Connection bypassed the trust decision"
    );
    h.decide(&trust, "store").await;
    let session = timeout(DEADLINE, opening).await.unwrap().unwrap().unwrap();
    assert_eq!(h.backend.repository().hosts().unwrap().len(), 1);
    h.close(session).await;

    let session = timeout(DEADLINE, h.begin_open("stored-key"))
        .await
        .unwrap()
        .unwrap()
        .unwrap();
    while let Ok(event) = h.events.try_recv() {
        assert_ne!(
            event.kind, "trust",
            "Stored fingerprint asked for redundant trust"
        );
    }
    h.close(session).await;
}

#[tokio::test]
async fn changed_fingerprint_requires_confirmation_and_rejection_keeps_previous_key() {
    let mut h = Harness::new(PASSWORD).await;
    let opening = h.begin_open("initial-key");
    let original = h.event("trust").await;
    h.decide(&original, "store").await;
    h.close(timeout(DEADLINE, opening).await.unwrap().unwrap().unwrap())
        .await;
    h.server.rotate_key();

    let opening = h.begin_open("changed-key");
    let changed = h.event("trust").await;
    assert_eq!(changed["changed"], true);
    assert_eq!(changed["previousFingerprint"], original["fingerprint"]);
    assert_ne!(changed["fingerprint"], original["fingerprint"]);
    h.decide(&changed, "reject").await;
    assert!(timeout(DEADLINE, opening).await.unwrap().unwrap().is_err());
    assert_eq!(
        h.backend.repository().hosts().unwrap()[0]["fingerprint"],
        original["fingerprint"]
    );
    h.assert_no_sessions().await;
    h.server.assert_disconnected().await;

    let opening = h.begin_open("accept-new-key");
    let changed = h.event("trust").await;
    h.decide(&changed, "store").await;
    h.close(timeout(DEADLINE, opening).await.unwrap().unwrap().unwrap())
        .await;
    assert_eq!(
        h.backend.repository().hosts().unwrap()[0]["fingerprint"],
        changed["fingerprint"]
    );
}

#[tokio::test]
async fn rejected_password_does_not_create_a_shell_or_reveal_the_secret() {
    let mut h = Harness::new("wrong-test-secret").await;
    let opening = h.begin_open("bad-password");
    let trust = h.event("trust").await;
    h.decide(&trust, "once").await;
    let error = timeout(DEADLINE, opening)
        .await
        .unwrap()
        .unwrap()
        .unwrap_err()
        .to_string();
    assert!(error.contains("authentication failed"));
    assert!(!error.contains("wrong-test-secret"));
    assert_eq!(
        h.server
            .state
            .authentication_attempts
            .load(Ordering::Acquire),
        1
    );
    assert!(h.server.state.sizes.lock().unwrap().is_empty());
    assert!(
        h.backend.repository().hosts().unwrap().is_empty(),
        "Trust once was persisted"
    );
    h.assert_no_sessions().await;
    h.server.assert_disconnected().await;
}

#[tokio::test]
async fn cancel_during_host_confirmation_releases_connection_and_invalidates_decision() {
    let mut h = Harness::new(PASSWORD).await;
    let opening = h.begin_open("cancel-me");
    let trust = h.event("trust").await;
    h.backend
        .request("session_cancel_open", json!({"requestId":"cancel-me"}))
        .await
        .unwrap();
    assert!(timeout(Duration::from_secs(2), opening)
        .await
        .unwrap()
        .unwrap()
        .is_err());
    h.assert_no_sessions().await;
    h.server.assert_disconnected().await;
    assert!(h
        .backend
        .request(
            "trust_decide",
            json!({"requestId":trust["requestId"],"decision":"store"})
        )
        .await
        .is_err());
    assert!(h.backend.repository().hosts().unwrap().is_empty());
}

#[tokio::test]
async fn deleting_machine_during_handshake_cannot_publish_a_late_session() {
    let mut h = Harness::new(PASSWORD).await;
    let opening = h.begin_open("delete-me");
    let trust = h.event("trust").await;
    h.backend
        .request("machine_delete", json!({"id":h.machine_id}))
        .await
        .unwrap();
    assert!(timeout(Duration::from_secs(2), opening)
        .await
        .unwrap()
        .unwrap()
        .is_err());
    h.assert_no_sessions().await;
    h.server.assert_disconnected().await;
    assert!(h
        .backend
        .request("machine_list", json!({}))
        .await
        .unwrap()
        .as_array()
        .unwrap()
        .is_empty());
    assert!(h
        .backend
        .request(
            "trust_decide",
            json!({"requestId":trust["requestId"],"decision":"once"})
        )
        .await
        .is_err());
    while let Ok(event) = h.events.try_recv() {
        assert!(!(event.kind == "session_status" && event.payload["status"] == "connected"));
    }
}

#[tokio::test]
async fn terminal_keeps_early_output_applies_ack_backpressure_and_closes_stale_generation() {
    let mut h = Harness::new(PASSWORD).await;
    let session = h.open().await;
    // Subscribe after session_open: the server greeting must still be available.
    let mut output = h
        .backend
        .session_output(
            session["sessionId"].as_str().unwrap(),
            session["generation"].as_u64().unwrap(),
        )
        .unwrap();
    let greeting = timeout(DEADLINE, output.recv()).await.unwrap().unwrap();
    assert_eq!(greeting.data, support::GREETING);
    h.backend
        .request(
            "session_ack",
            parameters(&session, json!({"sequence":greeting.sequence})),
        )
        .await
        .unwrap();
    assert!(h
        .backend
        .request(
            "session_ack",
            parameters(&session, json!({"sequence":u64::MAX}))
        )
        .await
        .is_err());

    let unicode_and_interrupt = "中文🙂\u{3}".as_bytes();
    h.backend
        .request(
            "session_write",
            parameters(
                &session,
                json!({"data":STANDARD.encode(unicode_and_interrupt)}),
            ),
        )
        .await
        .unwrap();
    let echo = timeout(DEADLINE, output.recv()).await.unwrap().unwrap();
    assert_eq!(
        echo.data, unicode_and_interrupt,
        "Input bytes, including Ctrl+C, changed in transit"
    );
    h.backend
        .request(
            "session_ack",
            parameters(&session, json!({"sequence":echo.sequence})),
        )
        .await
        .unwrap();
    h.backend
        .request(
            "session_resize",
            parameters(&session, json!({"columns":121,"rows":42})),
        )
        .await
        .unwrap();
    h.backend
        .request(
            "session_write",
            parameters(&session, json!({"data":STANDARD.encode(b"BULK")})),
        )
        .await
        .unwrap();

    let mut bytes = 0;
    let mut last_sequence = echo.sequence;
    for _ in 0..8 {
        let chunk = timeout(DEADLINE, output.recv()).await.unwrap().unwrap();
        assert_eq!(chunk.sequence, last_sequence + 1);
        assert!(chunk.data.len() <= 16384);
        assert!(chunk.data.iter().all(|b| *b == b'x'));
        bytes += chunk.data.len();
        last_sequence = chunk.sequence;
    }
    assert!(
        timeout(Duration::from_millis(120), output.recv())
            .await
            .is_err(),
        "Output advanced beyond eight unacknowledged chunks"
    );
    h.backend
        .request(
            "session_ack",
            parameters(&session, json!({"sequence":last_sequence})),
        )
        .await
        .unwrap();
    while bytes < support::BULK_SIZE {
        let chunk = timeout(DEADLINE, output.recv()).await.unwrap().unwrap();
        assert_eq!(chunk.sequence, last_sequence + 1);
        bytes += chunk.data.len();
        last_sequence = chunk.sequence;
        h.backend
            .request(
                "session_ack",
                parameters(&session, json!({"sequence":last_sequence})),
            )
            .await
            .unwrap();
    }
    assert_eq!(bytes, support::BULK_SIZE);
    assert!(h.server.state.sizes.lock().unwrap().contains(&(93, 31)));
    assert!(h.server.state.sizes.lock().unwrap().contains(&(121, 42)));
    let stale = parameters(
        &session,
        json!({"generation":session["generation"].as_u64().unwrap()+1,"data":STANDARD.encode(b"bad")}),
    );
    assert!(h.backend.request("session_write", stale).await.is_err());
    h.close(session.clone()).await;
    assert!(h
        .backend
        .request(
            "session_write",
            parameters(&session, json!({"data":STANDARD.encode(b"late")}))
        )
        .await
        .is_err());
}

#[tokio::test]
async fn sftp_roundtrip_preserves_unicode_paths_refuses_conflicts_and_atomically_edits() {
    let mut h = Harness::new(PASSWORD).await;
    let session = h.open().await;
    let local = tempfile::tempdir().unwrap();
    // Resolve the system temporary-directory alias on macOS before path checks.
    let directory = local.path().canonicalize().unwrap();
    let source = directory.join("source.bin");
    let destination = directory.join("download.bin");
    let content: Vec<u8> = (0..256 * 1024 + 7).map(|i| (i % 251) as u8).collect();
    std::fs::write(&source, &content).unwrap();
    let remote = "/中文 空格 ' $ file.bin";
    let transfer = parameters(
        &session,
        json!({"localPath":source,"remotePath":remote,"overwrite":false}),
    );
    h.backend
        .request("file_upload", transfer.clone())
        .await
        .unwrap();
    assert_eq!(
        h.server.state.files.lock().unwrap().get(remote).unwrap(),
        &content
    );
    assert!(h
        .backend
        .request("file_upload", transfer.clone())
        .await
        .is_err());
    let listing = h
        .backend
        .request("file_list", parameters(&session, json!({"path":"/"})))
        .await
        .unwrap();
    assert_eq!(listing["entries"][0]["name"], "中文 空格 ' $ file.bin");

    h.backend
        .request(
            "file_download",
            parameters(
                &session,
                json!({"localPath":destination,"remotePath":remote,"overwrite":false}),
            ),
        )
        .await
        .unwrap();
    assert_eq!(std::fs::read(&destination).unwrap(), content);
    assert!(h
        .backend
        .request(
            "file_download",
            parameters(
                &session,
                json!({"localPath":destination,"remotePath":remote,"overwrite":false})
            )
        )
        .await
        .is_err());

    let new_text = "你好，Windows!\n";
    std::fs::write(&source, new_text).unwrap();
    h.backend
        .request(
            "file_upload",
            parameters(&transfer, json!({"overwrite":true})),
        )
        .await
        .unwrap();
    let document = h
        .backend
        .request("file_read", parameters(&session, json!({"path":remote})))
        .await
        .unwrap();
    assert_eq!(document["text"], new_text);
    assert!(h
        .backend
        .request(
            "file_write",
            parameters(
                &session,
                json!({"path":remote,"text":"must not replace","version":"stale-version"})
            )
        )
        .await
        .is_err());
    h.backend
        .request(
            "file_write",
            parameters(
                &session,
                json!({"path":remote,"text":"已更新\n","version":document["version"]}),
            ),
        )
        .await
        .unwrap();
    assert_eq!(
        h.server.state.files.lock().unwrap().get(remote).unwrap(),
        "已更新\n".as_bytes()
    );
    assert!(
        h.server
            .state
            .files
            .lock()
            .unwrap()
            .keys()
            .all(|key| !key.ends_with(".tmp")),
        "SFTP temporary file leaked"
    );
    h.backend
        .request(
            "file_delete",
            parameters(&session, json!({"path":remote,"isDirectory":false})),
        )
        .await
        .unwrap();
    assert!(h.server.state.files.lock().unwrap().is_empty());
    h.close(session).await;
}
