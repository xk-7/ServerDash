//! The nested JSON contracts are the Codable types captured by ConfigurationSyncCatalog.
//! Do not pass unknown JSON through to the repository: it can contain local capabilities.
use crate::{Error, Result};
use serde::{Deserialize, Serialize};
use serde_json::{json, Map, Value};
use uuid::Uuid;

#[derive(Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct RdpSettings {
    version: u32,
    width: u32,
    height: u32,
    color_depth: u32,
    dynamic_resolution: bool,
    #[serde(rename = "screenIDs")]
    screen_ids: Vec<u32>,
    keyboard_mode: String,
    audio: String,
    text_clipboard: bool,
    file_clipboard: bool,
    shares: Vec<Value>,
    bitmap_cache: bool,
    disable_wallpaper: bool,
    disable_window_drag: bool,
    disable_menu_animations: bool,
    disable_themes: bool,
    certificate_policy: String,
    auto_reconnect: bool,
}
#[derive(Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Advanced {
    keep_alive_enabled: bool,
    keep_alive_interval: u32,
    keep_alive_count_max: u32,
    connect_timeout: u32,
    authentication_timeout: u32,
    log_output: bool,
    commands_enabled: bool,
    before_connect_command: String,
    after_connect_command: String,
}
#[derive(Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Route {
    #[serde(with = "crate::swift_uuid")]
    id: Uuid,
    #[serde(with = "crate::swift_uuid")]
    revision: Uuid,
    name: String,
    hops: Vec<Hop>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    proxy: Option<Proxy>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    imported_proxy_command: Option<String>,
    imported_proxy_command_confirmed: bool,
}
#[derive(Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Hop {
    #[serde(with = "crate::swift_uuid")]
    id: Uuid,
    name: String,
    endpoint: Endpoint,
    credential: Value,
    connect_timeout: f64,
}
#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Endpoint {
    host: String,
    port: u32,
    username: String,
}
#[derive(Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Proxy {
    kind: String,
    host: String,
    port: u32,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    username: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    secret_account: Option<String>,
}
pub fn default_rdp_settings() -> Value {
    json!({"version":1,"width":1920,"height":1080,"colorDepth":32,"dynamicResolution":false,"screenIDs":[],"keyboardMode":"fullscreen","audio":"local","textClipboard":false,"fileClipboard":false,"shares":[],"bitmapCache":true,"disableWallpaper":false,"disableWindowDrag":false,"disableMenuAnimations":false,"disableThemes":false,"certificatePolicy":"confirm","autoReconnect":true})
}
fn default_advanced() -> Value {
    json!({"keepAliveEnabled":true,"keepAliveInterval":30,"keepAliveCountMax":3,"connectTimeout":15,"authenticationTimeout":30,"logOutput":false,"commandsEnabled":false,"beforeConnectCommand":"","afterConnectCommand":""})
}
pub(super) fn validate(kind: &str, text: &str) -> Result<()> {
    match kind {
        "rdp" => {
            let s: RdpSettings = serde_json::from_str(text)?;
            if s.version != 1
                || !(200..=8192).contains(&s.width)
                || !(200..=8192).contains(&s.height)
                || u64::from(s.width) * u64::from(s.height) > 32 * 1024 * 1024
                || ![16, 24, 32].contains(&s.color_depth)
                || !s.shares.is_empty()
                || !s.screen_ids.is_empty()
                || !["fullscreen", "local", "remote"].contains(&s.keyboard_mode.as_str())
                || !["local", "remote", "disabled"].contains(&s.audio.as_str())
                || !["confirm", "strict"].contains(&s.certificate_policy.as_str())
            {
                return Err(Error::Invalid);
            }
        }
        "advanced" => {
            let s: Advanced = serde_json::from_str(text)?;
            if !(10..=300).contains(&s.keep_alive_interval)
                || !(1..=10).contains(&s.keep_alive_count_max)
                || !(5..=300).contains(&s.connect_timeout)
                || !(10..=120).contains(&s.authentication_timeout)
                || s.commands_enabled
                || s.before_connect_command.len() > 16384
                || s.after_connect_command.len() > 16384
                || s.before_connect_command.contains('\0')
                || s.after_connect_command.contains('\0')
            {
                return Err(Error::Invalid);
            }
        }
        "route" => {
            let s: Route = serde_json::from_str(text)?;
            if s.hops.len() > 8
                || s.imported_proxy_command.is_some()
                || s.imported_proxy_command_confirmed
            {
                return Err(Error::Invalid);
            }
            let mut visited = std::collections::BTreeSet::new();
            for hop in s.hops {
                let endpoint = hop.endpoint;
                if hop.credential != json!({"sshAgent":{}})
                    || !hop.connect_timeout.is_finite()
                    || hop.connect_timeout < 1.0
                    || !endpoint_text(&endpoint.host)
                    || !endpoint_text(&endpoint.username)
                    || !(1..=65535).contains(&endpoint.port)
                    || !visited.insert((endpoint.host.trim().to_lowercase(), endpoint.port))
                {
                    return Err(Error::Invalid);
                }
            }
            if let Some(p) = s.proxy {
                if p.username.is_some()
                    || p.secret_account.is_some()
                    || !endpoint_text(&p.host)
                    || !(1..=65535).contains(&p.port)
                    || !["socks5", "httpConnect"].contains(&p.kind.as_str())
                {
                    return Err(Error::Invalid);
                }
            }
        }
        _ => return Err(Error::Invalid),
    }
    Ok(())
}
fn endpoint_text(s: &str) -> bool {
    let s = s.trim();
    !s.is_empty() && !s.chars().any(|c| c.is_control() || c.is_whitespace())
}
fn object(value: &mut Value) -> Result<&mut Map<String, Value>> {
    value.as_object_mut().ok_or(Error::Invalid)
}
fn retain_keys(value: &mut Value, keys: &[&str]) -> Result<()> {
    object(value)?.retain(|k, _| keys.contains(&k.as_str()));
    Ok(())
}
fn merge_defaults(value: &mut Value, defaults: Value) -> Result<()> {
    let mut defaults = defaults.as_object().ok_or(Error::Invalid)?.clone();
    for (k, v) in object(value)?.iter() {
        if defaults.contains_key(k) {
            defaults.insert(k.clone(), v.clone());
        }
    }
    *value = Value::Object(defaults);
    Ok(())
}
/// Call this at capture time, before fingerprints, previews, encryption, or file export.
/// Decode rejects untrusted grants rather than silently importing them.
pub fn sanitize_nested_for_export(kind: &str, text: &str) -> Result<String> {
    let mut value: Value = serde_json::from_str(text)?;
    match kind {
        "rdp" => {
            merge_defaults(&mut value, default_rdp_settings())?;
            value["shares"] = json!([]);
            value["screenIDs"] = json!([]);
        }
        "advanced" => {
            merge_defaults(&mut value, default_advanced())?;
            value["commandsEnabled"] = json!(false);
        }
        "route" => {
            retain_keys(
                &mut value,
                &[
                    "id",
                    "revision",
                    "name",
                    "hops",
                    "proxy",
                    "importedProxyCommandConfirmed",
                ],
            )?;
            value["importedProxyCommandConfirmed"] = json!(false);
            if let Some(proxy) = value.get_mut("proxy").filter(|v| !v.is_null()) {
                retain_keys(proxy, &["kind", "host", "port"])?;
            }
            for hop in value
                .get_mut("hops")
                .and_then(Value::as_array_mut)
                .ok_or(Error::Invalid)?
            {
                retain_keys(
                    hop,
                    &["id", "name", "endpoint", "credential", "connectTimeout"],
                )?;
                hop["credential"] = json!({"sshAgent":{}});
                retain_keys(
                    hop.get_mut("endpoint").ok_or(Error::Invalid)?,
                    &["host", "port", "username"],
                )?;
            }
        }
        _ => return Err(Error::Invalid),
    }
    let output = serde_json::to_string(&value)?;
    validate(kind, &output)?;
    Ok(output)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn rdp_export_removes_all_local_grants_and_import_rejects_them() {
        let mut value = default_rdp_settings();
        value["screenIDs"] = json!([37]);
        value["shares"] = json!([{"bookmark":"c2VjcmV0","path":"C:/secret"}]);
        value["credentialID"] = json!("secret");
        assert!(validate("rdp", &value.to_string()).is_err());
        let encoded = sanitize_nested_for_export("rdp", &value.to_string()).unwrap();
        assert!(!encoded.contains("secret"));
        let safe: Value = serde_json::from_str(&encoded).unwrap();
        assert_eq!(safe["screenIDs"], json!([]));
        validate("rdp", &encoded).unwrap();
    }
    #[test]
    fn route_export_replaces_credentials_and_removes_proxy_authorization() {
        let value = json!({"id":Uuid::new_v4(),"revision":Uuid::new_v4(),"name":"route","hops":[{"id":Uuid::new_v4(),"name":"hop","endpoint":{"host":"jump.example","port":22,"username":"u","password":"secret"},"credential":{"password":{"accountID":"secret"}},"connectTimeout":8}],"proxy":{"kind":"socks5","host":"proxy.example","port":1080,"username":"secret","secretAccount":"secret"},"importedProxyCommand":"echo secret","importedProxyCommandConfirmed":true});
        assert!(validate("route", &value.to_string()).is_err());
        let encoded = sanitize_nested_for_export("route", &value.to_string()).unwrap();
        assert!(!encoded.contains("secret"));
        assert!(encoded.contains("sshAgent"));
        validate("route", &encoded).unwrap();
    }
    #[test]
    fn remote_commands_need_fresh_local_authorization() {
        let mut value = default_advanced();
        value["commandsEnabled"] = json!(true);
        value["afterConnectCommand"] = json!("pwd");
        assert!(validate("advanced", &value.to_string()).is_err());
        let encoded = sanitize_nested_for_export("advanced", &value.to_string()).unwrap();
        assert_eq!(
            serde_json::from_str::<Value>(&encoded).unwrap()["commandsEnabled"],
            false
        );
    }
    #[test]
    fn boolean_does_not_decode_as_number() {
        let mut value = default_rdp_settings();
        value["width"] = json!(true);
        assert!(validate("rdp", &value.to_string()).is_err());
    }
}
