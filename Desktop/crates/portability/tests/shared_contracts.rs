use serde_json::{json, Value};
use serverdash_portability::{ai, config, recording, sessions};
use std::path::PathBuf;
use tokio_util::sync::CancellationToken;

fn fixture(name: &str) -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../../../Shared/Contracts/fixtures")
        .join(name)
}
fn bytes(name: &str) -> Vec<u8> {
    std::fs::read(fixture(name)).unwrap()
}
fn value(name: &str) -> Value {
    serde_json::from_slice(&bytes(name)).unwrap()
}

#[test]
fn swift_configuration_and_recording_roundtrip() {
    let local = config::LocalPackage::decode(&bytes("swift-local.json")).unwrap();
    let metadata = value("swift-metadata.json");
    assert_eq!(
        local.mapping_space_id().to_string().to_uppercase(),
        metadata["mappingSpaceID"]
    );
    let key: Vec<u8> = (0..32).collect();
    let encrypted = config::decrypt(&bytes("swift-sync.configsync"), &key).unwrap();
    assert_eq!(encrypted.objects, local.objects);
    assert_eq!(encrypted.space_id, local.mapping_space_id());
    let frame: recording::Frame = serde_json::from_value(value("swift-frame.json")).unwrap();
    let document = recording::Document::open(fixture("swift-recording.sdrec"), false).unwrap();
    assert!(document.complete);
    assert_eq!(document.duration, 2.0);
    assert_eq!(
        document.header.date,
        metadata["recordingDate"].as_f64().unwrap()
    );
    let mut cursor = recording::Cursor::new(document.clone()).unwrap();
    assert_eq!(cursor.seek(0.0).unwrap(), frame);
    assert_eq!(
        cursor.seek(0.9).unwrap(),
        frame,
        "OSC output must not execute during playback"
    );
    assert_eq!(
        cursor.seek(1.1).unwrap().screen.lines[0].cells[0].text,
        "文"
    );
    let partial = recording::Document::open(fixture("swift-recording.partial"), true).unwrap();
    assert!(!partial.complete);
    let temporary = tempfile::tempdir().unwrap();
    partial
        .recover(temporary.path().join("recovered.sdrec"))
        .unwrap();
    // Optional outputs are consumed by the real Swift decoder in generate.py --verify-rust.
    let output = std::env::var_os("SERVERDASH_CONTRACT_OUTPUT")
        .map(PathBuf::from)
        .unwrap_or_else(|| temporary.path().into());
    std::fs::create_dir_all(&output).unwrap();
    std::fs::write(output.join("rust-local.json"), local.encode().unwrap()).unwrap();
    std::fs::write(
        output.join("rust-sync.configsync"),
        config::encrypt(&encrypted, &key).unwrap(),
    )
    .unwrap();
    let mut writer =
        recording::Writer::create(output.join("rust-recording.sdrec"), document.header.clone())
            .unwrap();
    writer.screen(0.0, frame.clone()).unwrap();
    writer
        .output(0.5, b"\x1b]52;c;bm90LWV4ZWN1dGVk\x07")
        .unwrap();
    let mut delta = frame;
    delta.changed_rows = Some(vec![0]);
    delta.screen.lines[0].cells[0].text = "文".into();
    writer.screen(1.0, delta).unwrap();
    writer.finish(2.0, Some("user".into())).unwrap();
}

#[test]
fn swift_ai_requests_and_byte_fragmented_streams_match_all_eight_providers() {
    let fixtures = value("swift-ai.json");
    assert_eq!(fixtures.as_array().unwrap().len(), 8);
    for fixture in fixtures.as_array().unwrap() {
        let provider: ai::Provider = serde_json::from_value(fixture["provider"].clone()).unwrap();
        let mut decoder = ai::StreamDecoder::new(provider);
        let mut events = Vec::new();
        for byte in fixture["wire"].as_str().unwrap().as_bytes() {
            events.extend(decoder.receive(&[*byte]).unwrap());
        }
        events.extend(decoder.finish().unwrap());
        let text: String = events
            .iter()
            .filter_map(|e| {
                if let ai::StreamEvent::Text(text) = e {
                    Some(text.as_str())
                } else {
                    None
                }
            })
            .collect();
        assert_eq!(text, fixture["text"]);
        assert!(events.contains(&ai::StreamEvent::Finished(ai::FinishReason::Complete)));
        let mut profile = ai::Profile::new(provider);
        profile.model = "fixture-model".into();
        let request = ai::build_request(
            &profile,
            "fixture-only-not-a-real-key",
            &[
                ai::Message {
                    role: "system".into(),
                    content: "Help".into(),
                },
                ai::Message {
                    role: "user".into(),
                    content: "Hello".into(),
                },
            ],
        )
        .unwrap();
        assert_eq!(request.url().as_str(), fixture["url"]);
        let body: Value =
            serde_json::from_slice(request.body().unwrap().as_bytes().unwrap()).unwrap();
        assert_eq!(body, fixture["body"], "Provider {:?}", provider);
    }
}

#[test]
fn swift_session_document_is_read_without_exposing_credentials() {
    let inspected = sessions::import(
        vec![sessions::SourceFile {
            path: "swift-sessions.json".into(),
            data: bytes("swift-sessions.json"),
        }],
        sessions::Format::ServerDash,
        &CancellationToken::new(),
    )
    .unwrap();
    assert_eq!(inspected.candidates.len(), 1);
    assert_eq!(inspected.candidates[0].record.port, 2222);
    assert_eq!(inspected.candidates[0].record.name, "测试");
    assert!(inspected.candidates[0].errors.is_empty());
    assert!(serde_json::to_value(&inspected.candidates[0])
        .unwrap()
        .get("password")
        .is_none());
    assert_eq!(json!(inspected.candidates[0].record.tags), json!(["开发"]));
}
