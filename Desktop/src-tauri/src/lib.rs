mod recordings;
mod services;
use serde_json::{json, Value};
use serverdash_core::Backend;
use serverdash_platform::Platform;
use std::sync::{
    atomic::{AtomicBool, Ordering},
    Arc,
};
use tauri::{
    ipc::{Channel, InvokeResponseBody},
    Emitter, Manager,
};

#[derive(Clone)]
pub struct DesktopState {
    backend: Backend,
    platform: Platform,
    services: Arc<services::Services>,
    closing: Arc<AtomicBool>,
    configuration: Arc<tokio::sync::Mutex<()>>,
}

#[tauri::command]
async fn desktop_request(
    app: tauri::AppHandle,
    state: tauri::State<'_, DesktopState>,
    method: String,
    params: Option<Value>,
) -> Result<Value, String> {
    let params = params.unwrap_or(json!({}));
    dispatch(&app, &state, &method, params)
        .await
        .map_err(|e| e.to_string())
}
async fn dispatch(
    app: &tauri::AppHandle,
    state: &DesktopState,
    method: &str,
    params: Value,
) -> anyhow::Result<Value> {
    anyhow::ensure!(!state.closing.load(Ordering::Acquire), "应用正在关闭");
    // Configuration previews and conditional sync writes serialize with local edits.
    // Terminal traffic, cancellation and monitoring remain independent.
    let _configuration = if matches!(
        method,
        "machine_save"
            | "machine_delete"
            | "settings_save"
            | "snippet_save"
            | "snippet_delete"
            | "config_export"
            | "config_import_preview"
            | "config_import_apply"
            | "sync_preview"
            | "sync_apply"
            | "sync_settings_save"
            | "sync_key_generate"
            | "sync_key_import"
            | "sessions_import_apply"
    ) {
        Some(state.configuration.lock().await)
    } else {
        None
    };
    if method == "bootstrap" {
        let mut value = state.backend.request(method, params).await?;
        value["capabilities"]["localTerminal"] = json!(true);
        value["capabilities"]["serial"] = json!(true);
        value["capabilities"]["vnc"] = json!(true);
        value["capabilities"]["ai"] = json!(true);
        value["capabilities"]["configurationTransfer"] = json!(true);
        value["capabilities"]["webdavSync"] = json!(true);
        value["capabilities"]["rdp"] = json!(false);
        value["capabilities"]["recording"] = json!(true);
        return Ok(value);
    }
    if method == "machine_delete" {
        if let Some(id) = params["id"].as_str() {
            state.platform.close_machine(id).await;
        }
    }
    if method == "session_close" {
        let _ = state.services.recordings.stop(&params);
    }
    if method == "session_open" && matches!(params["kind"].as_str(), Some("local" | "serial")) {
        return state.platform.request(method, params).await;
    }
    if matches!(method, "serial_list" | "vnc_open")
        || params["sessionId"]
            .as_str()
            .is_some_and(|id| state.platform.owns(id))
    {
        return state.platform.request(method, params).await;
    }
    if let Some(result) = state
        .services
        .request(app, &state.backend, method, &params)
        .await
    {
        if result.is_ok() && matches!(method, "config_import_apply" | "sync_apply") {
            state.backend.reconcile_machines().await;
            state.platform.reconcile_machines().await;
        }
        return result;
    }
    state.backend.request(method, params).await
}

#[tauri::command]
async fn session_subscribe(
    state: tauri::State<'_, DesktopState>,
    session_id: String,
    generation: u64,
    on_output: Channel<InvokeResponseBody>,
) -> Result<(), String> {
    let mut output = if state.platform.owns(&session_id) {
        state.platform.output(&session_id, generation)
    } else {
        state.backend.session_output(&session_id, generation)
    }
    .map_err(|e| e.to_string())?;
    let owned = state.inner().clone();
    tauri::async_runtime::spawn(async move {
        while let Some(chunk) = output.recv().await {
            owned
                .services
                .recordings
                .output(&owned.backend, &session_id, generation, &chunk.data);
            let mut bytes = Vec::with_capacity(8 + chunk.data.len());
            bytes.extend_from_slice(&chunk.sequence.to_le_bytes());
            bytes.extend_from_slice(&chunk.data);
            if on_output.send(InvokeResponseBody::Raw(bytes)).is_err() {
                let params = json!({"sessionId":session_id,"generation":generation});
                if owned.platform.owns(&session_id) {
                    let _ = owned.platform.request("session_close", params).await;
                } else {
                    let _ = owned.backend.request("session_close", params).await;
                }
                break;
            }
        }
        let _ = owned
            .services
            .recordings
            .stop(&json!({"sessionId":session_id,"generation":generation}));
    });
    Ok(())
}

pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_dialog::init())
        .setup(|app| {
            let root = app.path().app_local_data_dir()?;
            let backend = Backend::new(root.clone())?;
            let platform = Platform::new(backend.clone());
            let recordings = app
                .path()
                .document_dir()
                .unwrap_or_else(|_| root.clone())
                .join("ServerDash")
                .join("Recordings");
            let services = Arc::new(services::Services::new(root, recordings)?);
            let state = DesktopState {
                backend: backend.clone(),
                platform,
                services,
                closing: Arc::new(AtomicBool::new(false)),
                configuration: Arc::new(tokio::sync::Mutex::new(())),
            };
            app.manage(state);
            let handle = app.handle().clone();
            let mut events = backend.subscribe();
            tauri::async_runtime::spawn(async move {
                loop {
                    match events.recv().await {
                        Ok(event) => {
                            let _ = handle.emit_to("main", "desktop:event", event);
                        }
                        Err(tokio::sync::broadcast::error::RecvError::Lagged(_)) => {
                            let _ = handle.emit_to(
                                "main",
                                "desktop:event",
                                json!({"kind":"resync","payload":{}}),
                            );
                        }
                        Err(_) => break,
                    }
                }
            });
            Ok(())
        })
        .invoke_handler(tauri::generate_handler![desktop_request, session_subscribe])
        .build(tauri::generate_context!())
        .expect("ServerDash could not initialize")
        .run(|app, event| {
            if let tauri::RunEvent::ExitRequested { api, .. } = event {
                let state = app.state::<DesktopState>().inner().clone();
                if !state.closing.swap(true, Ordering::AcqRel) {
                    api.prevent_exit();
                    let handle = app.clone();
                    tauri::async_runtime::spawn(async move {
                        state.services.shutdown().await;
                        state.platform.shutdown().await;
                        state.backend.shutdown().await;
                        handle.exit(0);
                    });
                }
            }
        });
}
