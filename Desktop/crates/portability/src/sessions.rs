//! Credential-free session exchange and bounded in-memory archive inspection. Imported
//! paths are hints only: the host must obtain a fresh local filesystem authorization.
use crate::{Error, Result};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::{
    collections::{BTreeMap, BTreeSet},
    io::{Read, Write},
    path::Path,
};
use tokio_util::sync::CancellationToken;
use zeroize::Zeroizing;

pub const MAX_FILE: usize = 16 * 1024 * 1024;
pub const MAX_ARCHIVE: usize = 64 * 1024 * 1024;
pub const MAX_EXPANDED: usize = 256 * 1024 * 1024;
#[derive(Clone, Copy, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub enum Format {
    #[serde(rename = "automatic")]
    Automatic,
    #[serde(rename = "xShell")]
    XShell,
    #[serde(rename = "secureCRT")]
    SecureCRT,
    #[serde(rename = "mobaXterm")]
    MobaXterm,
    #[serde(rename = "finalShell")]
    FinalShell,
    #[serde(rename = "xTerminal")]
    XTerminal,
    #[serde(rename = "putty")]
    Putty,
    #[serde(rename = "serverDash")]
    ServerDash,
    #[serde(rename = "openSSH")]
    OpenSSH,
}
#[derive(Clone, Copy, Debug, Serialize, Deserialize, PartialEq, Eq, Default)]
#[serde(rename_all = "camelCase")]
pub enum Authentication {
    Password,
    PrivateKey,
    KeyThenPassword,
    #[default]
    Unspecified,
}
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct Record {
    pub name: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub group: Option<String>,
    pub host: String,
    pub port: i32,
    pub username: String,
    #[serde(default)]
    pub authentication: Authentication,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub external_private_key_path: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub notes: Option<String>,
    #[serde(default)]
    pub tags: Vec<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub default_remote_path: Option<String>,
}
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Candidate {
    pub record: Record,
    pub source: Format,
    pub source_path: String,
    pub warnings: Vec<String>,
    pub errors: Vec<String>,
    #[serde(skip)]
    pub password: Option<Zeroizing<String>>,
}
#[derive(Serialize, Default)]
pub struct Inspection {
    pub candidates: Vec<Candidate>,
    pub warnings: Vec<String>,
}
pub struct SourceFile {
    pub path: String,
    pub data: Vec<u8>,
}
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Artifact {
    pub suggested_file_name: String,
    pub data: Vec<u8>,
    pub warnings: Vec<String>,
}

fn normalized(s: &str) -> String {
    let s = s.trim().to_lowercase();
    let value = if let (Some(a), Some(b)) = (s.find('"'), s.rfind('"')) {
        if a < b {
            &s[a + 1..b]
        } else {
            &s
        }
    } else {
        &s
    };
    value.chars().filter(|c| c.is_alphanumeric()).collect()
}
fn clean(s: &str) -> String {
    let s = s.trim();
    let s = if s.len() >= 2
        && ((s.starts_with('"') && s.ends_with('"')) || (s.starts_with('\'') && s.ends_with('\'')))
    {
        &s[1..s.len() - 1]
    } else {
        s
    };
    s.replace("\\\"", "\"").replace("\\\\", "\\")
}
fn norm_fields(fields: &BTreeMap<String, String>) -> BTreeMap<String, String> {
    let mut out = BTreeMap::new();
    for (k, v) in fields {
        out.entry(normalized(k)).or_insert_with(|| clean(v));
    }
    out
}
fn val<'a>(fields: &'a BTreeMap<String, String>, keys: &[&str]) -> Option<&'a str> {
    keys.iter().find_map(|k| {
        fields
            .get(&normalized(k))
            .map(String::as_str)
            .filter(|s| !s.trim().is_empty())
    })
}
fn parse_number(s: &str) -> Option<i32> {
    let s = clean(s).replace(',', "");
    if s.to_lowercase().starts_with("0x") {
        i32::from_str_radix(&s[2..], 16).ok()
    } else {
        s.parse().ok()
    }
}
pub fn external_key_path(s: Option<&str>) -> Option<String> {
    s.map(str::trim)
        .filter(|s| {
            !s.is_empty()
                && s.len() <= 4096
                && !s.contains(['\0', '\r', '\n'])
                && !s.to_uppercase().contains("-----BEGIN")
        })
        .map(str::to_owned)
}
fn path_group(path: &str) -> Option<String> {
    let normalized = path.replace('\\', "/");
    let parts: Vec<_> = normalized
        .rsplit_once('/')
        .map(|(d, _)| {
            d.split('/')
                .filter(|s| {
                    !s.is_empty()
                        && !["config", "conn", "sessions", "xshell"]
                            .contains(&s.to_lowercase().as_str())
                })
                .collect()
        })
        .unwrap_or_default();
    if parts.is_empty() {
        None
    } else {
        Some(parts.join("/"))
    }
}
pub fn decode_text(data: &[u8]) -> Result<String> {
    if let Some(body) = data.strip_prefix(b"\xef\xbb\xbf") {
        return String::from_utf8(body.to_vec()).map_err(|_| Error::Invalid);
    }
    let utf16 = if data.starts_with(&[255, 254]) {
        Some((&data[2..], false))
    } else if data.starts_with(&[254, 255]) {
        Some((&data[2..], true))
    } else {
        let sample = &data[..data.len().min(512)];
        let even = sample.iter().step_by(2).filter(|c| **c == 0).count();
        let odd = sample
            .iter()
            .skip(1)
            .step_by(2)
            .filter(|c| **c == 0)
            .count();
        if odd > sample.len() / 8 {
            Some((data, false))
        } else if even > sample.len() / 8 {
            Some((data, true))
        } else {
            None
        }
    };
    if let Some((data, big)) = utf16 {
        if data.len() % 2 != 0 {
            return Err(Error::Invalid);
        }
        let words: Vec<_> = data
            .chunks_exact(2)
            .map(|b| {
                if big {
                    u16::from_be_bytes([b[0], b[1]])
                } else {
                    u16::from_le_bytes([b[0], b[1]])
                }
            })
            .collect();
        return String::from_utf16(&words).map_err(|_| Error::Invalid);
    }
    if let Ok(s) = std::str::from_utf8(data) {
        return Ok(s.to_owned());
    }
    Ok(encoding_rs::WINDOWS_1252.decode(data).0.into_owned())
}
fn candidate(
    fields: BTreeMap<String, String>,
    source: Format,
    path: &str,
    fallback: &str,
    allow_password: bool,
) -> Candidate {
    let f = norm_fields(&fields);
    let mut host = val(
        &f,
        &["hostname", "host", "hostaddress", "server", "ip", "address"],
    )
    .unwrap_or("")
    .to_owned();
    let mut uri_port = None;
    let mut uri_user = None;
    if let Ok(u) = url::Url::parse(&host) {
        if u.scheme() == "ssh" {
            host = u
                .host_str()
                .unwrap_or(&host)
                .trim_matches(['[', ']'])
                .to_owned();
            uri_port = u.port().map(i32::from);
            if !u.username().is_empty() {
                uri_user = Some(percent_decode(u.username()));
            }
        }
    }
    let port_text = val(&f, &["port", "portnumber", "sshport", "ssh2port"]);
    let parsed_port = port_text.and_then(parse_number);
    let port = uri_port.or(parsed_port).unwrap_or(22);
    let username = val(
        &f,
        &["username", "user", "usernamevalue", "login", "account"],
    )
    .map(str::to_owned)
    .or(uri_user)
    .unwrap_or_default();
    let key = val(
        &f,
        &[
            "identityfile",
            "privatekeypath",
            "publickeyfile",
            "userkey",
            "identityfilenamev2",
            "privatekey",
        ],
    );
    let key_path = external_key_path(key);
    let auth = val(
        &f,
        &[
            "authentication",
            "authenticationmethod",
            "auth",
            "authtype",
            "method",
            "logintype",
        ],
    )
    .unwrap_or("")
    .to_lowercase();
    let has_key = key_path.is_some() || auth.contains("key");
    let has_password = auth.contains("password") || auth.contains("keyboard");
    let mut authentication = match (has_key, has_password) {
        (true, true) => Authentication::KeyThenPassword,
        (true, false) => Authentication::PrivateKey,
        (false, true) => Authentication::Password,
        _ => Authentication::Unspecified,
    };
    let mut warnings = vec![];
    let mut errors = vec![];
    if let Some(protocol) = val(&f, &["protocol", "protocolname", "connectiontype", "type"]) {
        let p = protocol.to_lowercase();
        if !p.contains("ssh") && !p.contains("sftp") && p != "2" {
            errors.push(format!("不支持的协议：{protocol}"));
        }
    }
    if host.trim().is_empty() {
        errors.push("缺少主机地址".into());
    }
    if username.trim().is_empty() {
        errors.push("缺少用户名".into());
    }
    if !(1..=65535).contains(&port)
        || (uri_port.is_none() && port_text.is_some() && parsed_port.is_none())
    {
        errors.push("端口无效".into());
    }
    let password = if allow_password {
        val(&f, &["password", "passwd", "pass"])
            .filter(|s| {
                *s != "***"
                    && !s.to_lowercase().starts_with("enc:")
                    && !s.to_lowercase().starts_with("encrypted:")
            })
            .map(|s| Zeroizing::new(s.to_owned()))
    } else {
        None
    };
    if password.is_some() {
        authentication = match authentication {
            Authentication::PrivateKey => Authentication::KeyThenPassword,
            Authentication::Unspecified => Authentication::Password,
            other => other,
        };
    }
    if !allow_password
        && val(
            &f,
            &["password", "passwd", "passwordv2", "encryptedpassword"],
        )
        .is_some()
    {
        warnings.push("已忽略客户端加密密码，请重新填写".into());
    }
    if key.is_some() && key_path.is_none() {
        warnings.push("已忽略嵌入式私钥正文，请单独导入".into());
    }
    for (keys, message) in [
        (
            &["passphrase", "keypassphrase", "privatekeypassword"][..],
            "已忽略私钥口令",
        ),
        (
            &["identityid", "credentialid", "credentials"][..],
            "已忽略其他客户端的凭据引用",
        ),
        (
            &["initscript", "loginscript", "remotecommand"][..],
            "已忽略客户端脚本或远程命令",
        ),
        (
            &["proxyjump", "proxycommand", "tunnel", "portforwarding"][..],
            "已忽略代理链、跳板机或端口转发配置",
        ),
    ] {
        if val(&f, keys).is_some() {
            warnings.push(message.into());
        }
    }
    Candidate {
        record: Record {
            name: val(&f, &["sessionname", "title", "name", "label"])
                .unwrap_or(fallback)
                .to_owned(),
            group: val(&f, &["folder", "group", "groupname", "subrep", "category"])
                .map(str::to_owned)
                .or_else(|| path_group(path)),
            host,
            port,
            username,
            authentication,
            external_private_key_path: key_path,
            notes: val(&f, &["note", "notes", "description", "remark", "remarks"])
                .map(str::to_owned),
            tags: val(&f, &["tags", "tag"])
                .unwrap_or("")
                .split([',', ';'])
                .map(str::trim)
                .filter(|s| !s.is_empty())
                .map(str::to_owned)
                .collect(),
            default_remote_path: val(
                &f,
                &[
                    "defaultpath",
                    "defaultremotepath",
                    "initialpath",
                    "sftppath",
                ],
            )
            .map(str::to_owned),
        },
        source,
        source_path: path.to_owned(),
        warnings,
        errors,
        password,
    }
}
fn ini(text: &str) -> Vec<(String, BTreeMap<String, String>)> {
    let mut sections = vec![(String::new(), BTreeMap::new())];
    for raw in text.replace('\r', "").lines() {
        let line = raw.trim();
        if line.is_empty() || line.starts_with([';', '#']) {
            continue;
        }
        if line.starts_with('[') {
            if let Some(end) = line.find(']') {
                sections.push((line[1..end].to_owned(), BTreeMap::new()));
                continue;
            }
        }
        if let Some((k, v)) = line.split_once('=') {
            sections
                .last_mut()
                .unwrap()
                .1
                .insert(k.trim().to_owned(), clean(v));
        }
    }
    sections
}
fn merge_ini(sections: &[(String, BTreeMap<String, String>)]) -> BTreeMap<String, String> {
    let mut all = BTreeMap::new();
    for (section, values) in sections {
        for (k, v) in values {
            all.insert(format!("{section}.{k}"), v.clone());
            all.entry(k.clone()).or_insert_with(|| v.clone());
        }
    }
    norm_fields(&all)
}
fn json_records(value: &Value, out: &mut Vec<BTreeMap<String, String>>) {
    match value {
        Value::Array(a) => {
            for v in a {
                json_records(v, out)
            }
        }
        Value::Object(o) => {
            if o.keys().any(|k| {
                ["host", "hostname", "hostaddress", "ip", "address"]
                    .contains(&normalized(k).as_str())
            }) {
                out.push(
                    o.iter()
                        .filter_map(|(k, v)| match v {
                            Value::String(s) => Some((k.clone(), s.clone())),
                            Value::Number(n) => Some((k.clone(), n.to_string())),
                            Value::Bool(b) => Some((k.clone(), if *b { "1" } else { "0" }.into())),
                            _ => None,
                        })
                        .collect(),
                );
            } else {
                for v in o.values() {
                    json_records(v, out);
                }
            }
        }
        _ => {}
    }
}

/// Reads ZIP members without extracting them. Relative paths and symlink modes are
/// checked before decompression, followed by actual-byte limits against ZIP bombs.
pub fn expand_archive(file: SourceFile, cancel: &CancellationToken) -> Result<Vec<SourceFile>> {
    if !file.data.starts_with(b"PK\x03\x04") {
        if file.data.len() > MAX_FILE {
            return Err(Error::TooLarge);
        }
        return Ok(vec![file]);
    }
    if file.data.len() > MAX_ARCHIVE {
        return Err(Error::TooLarge);
    }
    let mut archive =
        zip::ZipArchive::new(std::io::Cursor::new(file.data)).map_err(|_| Error::Invalid)?;
    if archive.len() > 10_000 {
        return Err(Error::TooLarge);
    }
    let mut out = vec![];
    let mut total = 0usize;
    let mut paths = BTreeSet::new();
    for i in 0..archive.len() {
        if cancel.is_cancelled() {
            return Err(Error::Cancelled);
        }
        let mut entry = archive.by_index(i).map_err(|_| Error::Invalid)?;
        let path = entry.name().replace('\\', "/");
        if path.starts_with('/')
            || path
                .split('/')
                .any(|s| s == ".." || s.contains(':') || s.contains('\0'))
            || entry.unix_mode().is_some_and(|m| m & 0o170000 == 0o120000)
        {
            return Err(Error::Invalid);
        }
        if entry.is_dir() {
            continue;
        }
        if !paths.insert(path.to_lowercase()) || entry.size() > MAX_FILE as u64 {
            return Err(Error::TooLarge);
        }
        let mut data = vec![];
        (&mut entry)
            .take((MAX_FILE + 1) as u64)
            .read_to_end(&mut data)?;
        total = total.checked_add(data.len()).ok_or(Error::TooLarge)?;
        if data.len() > MAX_FILE || total > MAX_EXPANDED {
            return Err(Error::TooLarge);
        }
        out.push(SourceFile { path, data });
    }
    Ok(out)
}
fn detect(path: &str, text: &str) -> Format {
    let lower = text.to_lowercase();
    let path = path.to_lowercase();
    if lower.contains("com.serverdash.sessions") {
        Format::ServerDash
    } else if path.ends_with(".xsh") || lower.contains("[connection") {
        Format::XShell
    } else if lower.contains("\\putty\\sessions\\")
        || (lower.contains("hostname=") && lower.contains("portnumber="))
    {
        Format::Putty
    } else if path.ends_with(".mxtsessions") || lower.contains("[bookmarks") {
        Format::MobaXterm
    } else if lower.contains("s:\"hostname\"")
        || lower.contains("vandyke")
        || lower.contains("securecrt")
        || (path.ends_with(".csv") && lower.contains("hostname"))
    {
        Format::SecureCRT
    } else if lower
        .lines()
        .any(|l| l.trim_start().starts_with("host ") || l.trim_start().starts_with("host\t"))
    {
        Format::OpenSSH
    } else if path.contains("conn/")
        || lower.contains("\"user_name\"")
        || lower.contains("\"authentication_type\"")
    {
        Format::FinalShell
    } else {
        Format::XTerminal
    }
}
pub fn import(
    files: Vec<SourceFile>,
    format: Format,
    cancel: &CancellationToken,
) -> Result<Inspection> {
    let mut result = Inspection::default();
    let mut total = 0usize;
    for source in files {
        for file in expand_archive(source, cancel)? {
            if cancel.is_cancelled() {
                return Err(Error::Cancelled);
            }
            total = total.checked_add(file.data.len()).ok_or(Error::TooLarge)?;
            if total > MAX_EXPANDED {
                return Err(Error::TooLarge);
            }
            let text = decode_text(&file.data)?;
            let format = if format == Format::Automatic {
                detect(&file.path, &text)
            } else {
                format
            };
            let fallback = Path::new(&file.path)
                .file_stem()
                .and_then(|s| s.to_str())
                .unwrap_or("session");
            let mut fields: Vec<(BTreeMap<String, String>, String, bool)> = vec![];
            match format {
                Format::ServerDash => {
                    #[derive(Deserialize)]
                    struct Document {
                        format: String,
                        version: u32,
                        sessions: Vec<Record>,
                    }
                    let doc: Document = serde_json::from_str(&text)?;
                    if doc.format != "com.serverdash.sessions" || doc.version != 1 {
                        return Err(Error::Invalid);
                    }
                    for mut record in doc.sessions {
                        let mut warnings = vec![];
                        let key = external_key_path(record.external_private_key_path.as_deref());
                        if record.external_private_key_path.is_some() && key.is_none() {
                            warnings.push("已忽略嵌入式私钥正文，请单独导入".into());
                        }
                        record.external_private_key_path = key;
                        let mut errors = vec![];
                        if record.host.trim().is_empty() {
                            errors.push("缺少主机地址".into());
                        }
                        if record.username.trim().is_empty() {
                            errors.push("缺少用户名".into());
                        }
                        if !(1..=65535).contains(&record.port) {
                            errors.push("端口无效".into());
                        }
                        result.candidates.push(Candidate {
                            record,
                            source: format,
                            source_path: file.path.clone(),
                            warnings,
                            errors,
                            password: None,
                        });
                    }
                }
                Format::OpenSSH => {
                    let parsed = import_openssh(&text, &file.path);
                    result.candidates.extend(parsed.candidates);
                    result.warnings.extend(parsed.warnings);
                }
                Format::MobaXterm => {
                    for (section, values) in ini(&text) {
                        if !section.to_lowercase().starts_with("bookmarks") {
                            continue;
                        }
                        let group = values
                            .iter()
                            .find(|(k, _)| normalized(k) == "subrep")
                            .map(|(_, v)| v.clone());
                        for (name, value) in values {
                            if ["subrep", "imgnum"].contains(&normalized(&name).as_str()) {
                                continue;
                            }
                            let Some(body) = value
                                .split_once("#109#")
                                .and_then(|(_, v)| v.split_once('%').map(|(_, v)| v))
                            else {
                                result
                                    .warnings
                                    .push(format!("已跳过无法识别的 MobaXterm 会话：{name}"));
                                continue;
                            };
                            let p: Vec<_> = body.split('%').collect();
                            if p.len() < 3 {
                                continue;
                            }
                            let mut f = BTreeMap::from([
                                ("name".into(), name.clone()),
                                ("host".into(), percent_decode(p[0])),
                                ("port".into(), p[1].into()),
                                ("username".into(), percent_decode(p[2])),
                            ]);
                            if let Some(g) = &group {
                                f.insert("group".into(), g.clone());
                            }
                            fields.push((f, name, false));
                        }
                    }
                }
                Format::Putty => {
                    if text.to_lowercase().contains("windows registry editor") {
                        for (section, values) in ini(&text) {
                            if let Some(index) = section.to_lowercase().rfind("\\sessions\\") {
                                let mut f = BTreeMap::new();
                                for (k, v) in values {
                                    let value = if let Some(hex) = v.strip_prefix("dword:") {
                                        u32::from_str_radix(hex, 16)
                                            .map(|v| v.to_string())
                                            .map_err(|_| Error::Invalid)?
                                    } else {
                                        clean(&v)
                                    };
                                    f.insert(clean(&k), value);
                                }
                                fields.push((f, percent_decode(&section[index + 10..]), false));
                            }
                        }
                    } else {
                        fields.push((merge_ini(&ini(&text)), percent_decode(fallback), false));
                    }
                }
                Format::SecureCRT => {
                    if text.trim_start().starts_with('<') {
                        for f in xml_sessions(&text)? {
                            fields.push((f, fallback.into(), false));
                        }
                    } else if ["csv", "tsv", "txt"].contains(
                        &Path::new(&file.path)
                            .extension()
                            .and_then(|s| s.to_str())
                            .unwrap_or(""),
                    ) {
                        let first = text.lines().next().unwrap_or("");
                        let delimiter = [b',', b'\t', b';']
                            .into_iter()
                            .max_by_key(|d| first.bytes().filter(|b| b == d).count())
                            .unwrap();
                        let mut reader = csv::ReaderBuilder::new()
                            .delimiter(delimiter)
                            .flexible(true)
                            .from_reader(text.as_bytes());
                        let header = reader.headers().map_err(|_| Error::Invalid)?.clone();
                        for row in reader.records() {
                            let row = row.map_err(|_| Error::Invalid)?;
                            fields.push((
                                header
                                    .iter()
                                    .zip(row.iter())
                                    .map(|(k, v)| (k.to_owned(), v.to_owned()))
                                    .collect(),
                                fallback.into(),
                                true,
                            ));
                        }
                    } else if !["default.ini", "__folderdata__.ini"].contains(
                        &Path::new(&file.path)
                            .file_name()
                            .and_then(|s| s.to_str())
                            .unwrap_or("")
                            .to_lowercase()
                            .as_str(),
                    ) {
                        let mut f = merge_ini(&ini(&text));
                        if let Some(p) = val(&f, &["ssh2port", "port"]) {
                            if p.len() == 8 && p.bytes().all(|b| b.is_ascii_hexdigit()) {
                                let p = i32::from_str_radix(p, 16).map_err(|_| Error::Invalid)?;
                                f.insert("port".into(), p.to_string());
                            }
                        }
                        fields.push((f, fallback.into(), false));
                    }
                }
                Format::FinalShell | Format::XTerminal => {
                    if let Ok(value) = serde_json::from_str::<Value>(&text) {
                        let mut records = vec![];
                        json_records(&value, &mut records);
                        for mut f in records {
                            if format == Format::FinalShell {
                                if let Some(user) = f.get("user_name").cloned() {
                                    f.entry("username".into()).or_insert(user);
                                }
                                if let Some(auth) = val(&norm_fields(&f), &["authenticationtype"]) {
                                    f.insert(
                                        "authentication".into(),
                                        if auth == "0" {
                                            "password"
                                        } else {
                                            "privateKey"
                                        }
                                        .into(),
                                    );
                                }
                            }
                            fields.push((f, fallback.into(), format == Format::XTerminal));
                        }
                    } else if format == Format::XTerminal {
                        for line in text.lines() {
                            let line = line.trim();
                            if line.is_empty() || line.starts_with('#') || line.starts_with("//") {
                                continue;
                            }
                            let p: Vec<_> = line.split('|').map(str::trim).collect();
                            let f = if p.len() >= 3 {
                                if p[0].to_lowercase().contains("host")
                                    && p[1].to_lowercase().contains("user")
                                {
                                    continue;
                                }
                                let endpoint = if p[0].starts_with("ssh://") {
                                    p[0].to_owned()
                                } else {
                                    format!("ssh://{}", p[0])
                                };
                                let mut f = BTreeMap::from([
                                    ("host".into(), endpoint),
                                    ("username".into(), p[1].into()),
                                    ("password".into(), p[2].into()),
                                ]);
                                if let Some(name) = p.get(3) {
                                    f.insert("title".into(), (*name).into());
                                }
                                if let Some(note) = p.get(4) {
                                    f.insert("note".into(), (*note).into());
                                }
                                f
                            } else {
                                tokens(line, false)
                                    .into_iter()
                                    .filter_map(|t| {
                                        t.split_once('=').map(|(k, v)| (k.to_owned(), v.to_owned()))
                                    })
                                    .collect()
                            };
                            if !f.is_empty() {
                                fields.push((f, fallback.into(), true));
                            }
                        }
                    } else {
                        return Err(Error::Invalid);
                    }
                }
                Format::XShell => {
                    let mut f = merge_ini(&ini(&text));
                    for (target, keys) in [
                        ("sessionname", vec!["sessioninfo.name", "name"]),
                        ("hostname", vec!["connection.host", "host"]),
                        (
                            "username",
                            vec!["connectionauthentication.username", "username", "user"],
                        ),
                        (
                            "authentication",
                            vec!["connectionauthentication.method", "method"],
                        ),
                        (
                            "identityfile",
                            vec![
                                "connectionauthentication.userkey",
                                "userkey",
                                "identityfile",
                            ],
                        ),
                    ] {
                        if let Some(v) = val(&f, &keys).map(str::to_owned) {
                            f.insert(target.into(), v);
                        }
                    }
                    fields.push((f, fallback.into(), false));
                }
                Format::Automatic => unreachable!(),
            }
            for (f, name, allow) in fields {
                result
                    .candidates
                    .push(candidate(f, format, &file.path, &name, allow));
            }
            if result.candidates.len() > 20_000 {
                return Err(Error::TooLarge);
            }
        }
    }
    if result.candidates.is_empty() {
        return Err(Error::Invalid);
    }
    Ok(result)
}

fn tokens(line: &str, comments: bool) -> Vec<String> {
    let mut out = vec![];
    let mut text = String::new();
    let mut quote = None;
    let mut chars = line.chars().peekable();
    while let Some(c) = chars.next() {
        if c == '\\' {
            if chars
                .peek()
                .is_some_and(|n| Some(*n) == quote || *n == '\\' || *n == '"')
            {
                text.push(chars.next().unwrap());
            } else {
                text.push(c);
            }
            continue;
        }
        if let Some(q) = quote {
            if c == q {
                quote = None;
            } else {
                text.push(c);
            }
            continue;
        }
        if c == '"' || c == '\'' {
            quote = Some(c);
        } else if c == '#' && comments {
            break;
        } else if c.is_whitespace() {
            if !text.is_empty() {
                out.push(std::mem::take(&mut text));
            }
        } else {
            text.push(c);
        }
    }
    if !text.is_empty() {
        out.push(text);
    }
    out
}
fn import_openssh(text: &str, path: &str) -> Inspection {
    let mut out = Inspection::default();
    let mut aliases: Vec<String> = vec![];
    let mut fields = BTreeMap::new();
    let mut warnings = vec![];
    let append = |out: &mut Inspection,
                  aliases: &[String],
                  fields: &BTreeMap<String, String>,
                  warnings: &[String]| {
        for alias in aliases {
            let mut f = fields.clone();
            f.entry("hostname".into()).or_insert_with(|| alias.clone());
            f.insert("name".into(), alias.clone());
            let mut c = candidate(f, Format::OpenSSH, path, alias, false);
            c.warnings.extend_from_slice(warnings);
            out.candidates.push(c);
        }
    };
    for line in text.lines() {
        let t = tokens(line, true);
        let Some(key) = t.first() else { continue };
        let key = key.to_lowercase();
        if key == "host" || key == "match" {
            append(&mut out, &aliases, &fields, &warnings);
            aliases.clear();
            fields.clear();
            warnings.clear();
            if key == "host" {
                aliases = t
                    .into_iter()
                    .skip(1)
                    .filter(|s| !s.contains(['*', '?']) && !s.starts_with('!'))
                    .collect();
            } else {
                out.warnings.push("已跳过 Match 条件块".into());
            }
            continue;
        }
        if key == "include" {
            out.warnings
                .push("导入不会展开 Include，请直接选择被包含的文件".into());
            continue;
        }
        if aliases.is_empty() || t.len() < 2 {
            continue;
        }
        let value = t[1..].join(" ");
        match key.as_str() {
            "hostname" | "port" => {
                fields.insert(key, value);
            }
            "user" => {
                fields.insert("username".into(), value);
            }
            "identityfile" => {
                fields.entry(key).or_insert(value);
            }
            "proxyjump" | "proxycommand" => warnings.push("已忽略跳板机或代理配置".into()),
            "remotecommand" | "localforward" | "remoteforward" | "dynamicforward" => {
                warnings.push("已忽略命令或端口转发配置".into())
            }
            _ => {}
        }
    }
    append(&mut out, &aliases, &fields, &warnings);
    out
}
fn xml_sessions(text: &str) -> Result<Vec<BTreeMap<String, String>>> {
    use quick_xml::{events::Event, Reader};
    #[derive(Default)]
    struct Node {
        name: String,
        attrs: BTreeMap<String, String>,
        text: String,
        children: Vec<Node>,
    }
    fn visit(node: &Node, out: &mut Vec<BTreeMap<String, String>>) {
        let mut fields = node.attrs.clone();
        if let Some(n) = node.attrs.get("name") {
            fields.insert("name".into(), n.clone());
        }
        for child in &node.children {
            fields.insert(
                child.attrs.get("name").unwrap_or(&child.name).clone(),
                child.text.trim().to_owned(),
            );
        }
        let normalized = norm_fields(&fields);
        if val(&normalized, &["host", "hostname", "hostnameipaddress"]).is_some() {
            if let Some(host) = val(&normalized, &["hostnameipaddress"]) {
                fields.insert("host".into(), host.into());
            }
            out.push(fields);
        } else {
            for c in &node.children {
                visit(c, out);
            }
        }
    }
    let mut reader = Reader::from_str(text);
    let mut stack = vec![Node::default()];
    loop {
        match reader.read_event().map_err(|_| Error::Invalid)? {
            Event::Start(e) => {
                if stack.len() > 128 {
                    return Err(Error::TooLarge);
                }
                let mut node = Node {
                    name: String::from_utf8_lossy(e.name().as_ref()).into_owned(),
                    ..Node::default()
                };
                for attr in e.attributes() {
                    let a = attr.map_err(|_| Error::Invalid)?;
                    node.attrs.insert(
                        String::from_utf8_lossy(a.key.as_ref()).into_owned(),
                        a.decode_and_unescape_value(reader.decoder())
                            .map_err(|_| Error::Invalid)?
                            .into_owned(),
                    );
                }
                stack.push(node);
            }
            Event::Text(e) => stack
                .last_mut()
                .unwrap()
                .text
                .push_str(&e.unescape().map_err(|_| Error::Invalid)?),
            Event::End(_) => {
                if stack.len() < 2 {
                    return Err(Error::Invalid);
                }
                let node = stack.pop().unwrap();
                stack.last_mut().unwrap().children.push(node);
            }
            Event::DocType(_) => return Err(Error::Invalid),
            Event::Eof => break,
            _ => {}
        }
    }
    if stack.len() != 1 {
        return Err(Error::Invalid);
    }
    let mut out = vec![];
    visit(&stack[0], &mut out);
    Ok(out)
}
fn safe_line(s: &str) -> String {
    s.replace(['\r', '\n', '\0'], " ")
}
fn quote(s: &str) -> String {
    format!(
        "\"{}\"",
        safe_line(s).replace('\\', "\\\\").replace('"', "\\\"")
    )
}
fn component(s: &str) -> String {
    let value: String = s
        .chars()
        .map(|c| {
            if c.is_alphanumeric() || "-_. ".contains(c) {
                c
            } else {
                '-'
            }
        })
        .take(120)
        .collect();
    let value = value.trim_matches(['.', ' ']);
    if value.is_empty() {
        "session".into()
    } else {
        value.into()
    }
}
fn percent_encode(s: &str, allowed: &[u8]) -> String {
    s.bytes()
        .map(|b| {
            if b.is_ascii_alphanumeric() || allowed.contains(&b) {
                (b as char).to_string()
            } else {
                format!("%{b:02X}")
            }
        })
        .collect()
}
fn percent_decode(s: &str) -> String {
    let mut bytes = vec![];
    let b = s.as_bytes();
    let mut i = 0;
    while i < b.len() {
        if b[i] == b'%' && i + 2 < b.len() {
            if let Ok(n) = std::str::from_utf8(&b[i + 1..i + 3])
                .ok()
                .and_then(|s| u8::from_str_radix(s, 16).ok())
                .ok_or(())
            {
                bytes.push(n);
                i += 3;
                continue;
            }
        }
        bytes.push(b[i]);
        i += 1;
    }
    String::from_utf8(bytes).unwrap_or_else(|_| s.into())
}
fn make_zip(entries: Vec<(String, Vec<u8>)>) -> Result<Vec<u8>> {
    let mut zip = zip::ZipWriter::new(std::io::Cursor::new(vec![]));
    for (path, data) in entries {
        zip.start_file(
            path,
            zip::write::SimpleFileOptions::default()
                .compression_method(zip::CompressionMethod::Deflated),
        )
        .map_err(|_| Error::Invalid)?;
        zip.write_all(&data)?;
    }
    Ok(zip.finish().map_err(|_| Error::Invalid)?.into_inner())
}
/// SecureCRT and FinalShell exports intentionally preserve the Apple client's validation
/// gate. Import remains available; generated test-only dialects are not advertised.
pub fn export(
    records: &[Record],
    format: Format,
    generated_at: &str,
    app_version: &str,
    cancel: &CancellationToken,
) -> Result<Artifact> {
    if records.is_empty() || records.len() > 20_000 {
        return Err(Error::Invalid);
    }
    if matches!(format, Format::SecureCRT | Format::FinalShell) {
        return Err(Error::UnvalidatedExport);
    }
    if format == Format::Automatic {
        return Err(Error::Configuration);
    }
    let mut records = records.to_vec();
    for r in &mut records {
        if !(1..=65535).contains(&r.port)
            || r.host.trim().is_empty()
            || r.username.trim().is_empty()
        {
            return Err(Error::Invalid);
        }
        r.external_private_key_path = external_key_path(r.external_private_key_path.as_deref());
    }
    let mut warnings = vec![];
    if records.iter().any(|r| {
        matches!(
            r.authentication,
            Authentication::Password | Authentication::KeyThenPassword
        )
    }) {
        warnings.push("密码不会写入导出文件，请在目标客户端重新配置".into());
    }
    let (name, data) = match format {
        Format::ServerDash => (
            "ServerDash-Sessions.json",
            serde_json::to_vec_pretty(
                &json!({"format":"com.serverdash.sessions","version":1,"exportedAt":generated_at,"generator":{"name":"ServerDash","version":app_version},"sessions":records}),
            )?,
        ),
        Format::XTerminal => {
            let objects:Vec<_>=records.iter().map(|r|{let mut j=json!({"title":r.name,"host":r.host,"port":r.port,"username":r.username,"auth":match r.authentication{Authentication::Password=>"password",Authentication::PrivateKey=>"privateKey",Authentication::KeyThenPassword=>"privateKey,password",Authentication::Unspecified=>"none"}});for(k,v)in [("folder",&r.group),("note",&r.notes),("defaultPath",&r.default_remote_path),("privateKey",&r.external_private_key_path)]{if let Some(v)=v{j[k]=json!(v);}}j}).collect();
            (
                "ServerDash-XTerminal.json",
                serde_json::to_vec_pretty(&objects)?,
            )
        }
        Format::XShell => {
            let mut entries = vec![];
            let mut paths = BTreeSet::new();
            for r in &records {
                if cancel.is_cancelled() {
                    return Err(Error::Cancelled);
                }
                let base = format!(
                    "XShell/{}/{}",
                    component(r.group.as_deref().unwrap_or("Sessions")),
                    component(&r.name)
                );
                let mut path = format!("{base}.xsh");
                let mut suffix = 2;
                while !paths.insert(path.to_lowercase()) {
                    path = format!("{base}-{suffix}.xsh");
                    suffix += 1;
                }
                let method = match r.authentication {
                    Authentication::Password => "Password",
                    Authentication::KeyThenPassword => "PublicKey,Password",
                    _ => "PublicKey",
                };
                let mut lines=format!("[CONNECTION]\r\nHost={}\r\nPort={}\r\nProtocol=SSH\r\n\r\n[CONNECTION:AUTHENTICATION]\r\nUserName={}\r\nMethod={method}\r\n",safe_line(&r.host),r.port,safe_line(&r.username));
                if let Some(key) = &r.external_private_key_path {
                    lines.push_str(&format!("UserKey={}\r\n", safe_line(key)));
                }
                lines.push_str(&format!(
                    "\r\n[SESSION_INFO]\r\nName={}\r\n",
                    safe_line(&r.name)
                ));
                entries.push((path, lines.into_bytes()));
            }
            ("ServerDash-XShell.zip", make_zip(entries)?)
        }
        Format::Putty => {
            let mut out = String::from("Windows Registry Editor Version 5.00\r\n\r\n");
            let mut used = BTreeSet::new();
            for r in &records {
                if cancel.is_cancelled() {
                    return Err(Error::Cancelled);
                }
                let base = if r.name.is_empty() {
                    "Session"
                } else {
                    &r.name
                };
                let mut name = percent_encode(base, b" -._");
                let mut n = 2;
                while !used.insert(name.to_lowercase()) {
                    name = percent_encode(&format!("{base} ({n})"), b" -._");
                    n += 1;
                }
                out.push_str(&format!("[HKEY_CURRENT_USER\\Software\\SimonTatham\\PuTTY\\Sessions\\{name}]\r\n\"HostName\"={}\r\n\"PortNumber\"=dword:{:08x}\r\n\"UserName\"={}\r\n\"Protocol\"=\"ssh\"\r\n",quote(&r.host),r.port,quote(&r.username)));
                if let Some(key) = &r.external_private_key_path {
                    out.push_str(&format!("\"PublicKeyFile\"={}\r\n", quote(key)));
                }
                out.push_str("\r\n");
            }
            let mut bytes = vec![255, 254];
            for word in out.encode_utf16() {
                bytes.extend_from_slice(&word.to_le_bytes());
            }
            ("ServerDash-PuTTY.reg", bytes)
        }
        Format::MobaXterm => {
            let mut groups: BTreeMap<String, Vec<&Record>> = BTreeMap::new();
            for r in &records {
                groups
                    .entry(r.group.clone().unwrap_or_else(|| "ServerDash".into()))
                    .or_default()
                    .push(r);
            }
            let mut out = String::from("[MobaXterm sessions]\r\nImgNum=42\r\n\r\n");
            for (i, (group, records)) in groups.into_iter().enumerate() {
                out.push_str(&format!(
                    "[{}]\r\nSubRep={}\r\nImgNum=42\r\n",
                    if i == 0 {
                        "Bookmarks".into()
                    } else {
                        format!("Bookmarks_{}", i + 1)
                    },
                    safe_line(&group)
                ));
                for r in records {
                    out.push_str(&format!(
                        "{}=#109#0%{}%{}%{}%%-1%-1%%%%%0%0%0%%%-1%0%0%0%%1080%%0%0%1#\r\n",
                        safe_line(&r.name).replace('=', "-"),
                        percent_encode(&r.host, b"-._~:"),
                        r.port,
                        percent_encode(&r.username, b"-._~:")
                    ));
                }
                out.push_str("\r\n");
            }
            ("ServerDash.mxtsessions", out.into_bytes())
        }
        Format::OpenSSH => {
            let mut out = format!(
                "# Generated by ServerDash {}\n# Credentials are omitted.\n\n",
                safe_line(app_version)
            );
            let mut aliases = BTreeSet::new();
            for r in &records {
                if cancel.is_cancelled() {
                    return Err(Error::Cancelled);
                }
                let base: String = r
                    .name
                    .to_lowercase()
                    .chars()
                    .map(|c| {
                        if c.is_alphanumeric() || "-_.".contains(c) {
                            c
                        } else {
                            '-'
                        }
                    })
                    .collect();
                let base = base.trim_matches(['-', '_', '.']);
                let base = if base.is_empty() { "server" } else { base };
                let mut alias = base.to_owned();
                let mut n = 2;
                while !aliases.insert(alias.clone()) {
                    alias = format!("{base}-{n}");
                    n += 1;
                }
                if let Some(g) = &r.group {
                    out.push_str(&format!("# Group: {}\n", safe_line(g).replace('#', "")));
                }
                out.push_str(&format!(
                    "Host {alias}\n    HostName {}\n    Port {}\n    User {}\n",
                    quote(&r.host),
                    r.port,
                    quote(&r.username)
                ));
                if let Some(key) = &r.external_private_key_path {
                    out.push_str(&format!("    IdentityFile {}\n", quote(key)));
                }
                out.push('\n');
            }
            ("ServerDash-SSH-Config.conf", out.into_bytes())
        }
        _ => return Err(Error::Configuration),
    };
    if cancel.is_cancelled() {
        return Err(Error::Cancelled);
    }
    if data.len() > MAX_ARCHIVE {
        return Err(Error::TooLarge);
    }
    Ok(Artifact {
        suggested_file_name: name.into(),
        data,
        warnings,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    fn sample() -> Record {
        Record {
            name: "测试 host".into(),
            group: Some("生产".into()),
            host: "example.com".into(),
            port: 2222,
            username: "user".into(),
            authentication: Authentication::PrivateKey,
            external_private_key_path: Some("C:\\Users\\A B\\key".into()),
            notes: Some("note".into()),
            tags: vec![],
            default_remote_path: Some("/srv".into()),
        }
    }
    #[test]
    fn supported_formats_roundtrip() {
        for format in [
            Format::ServerDash,
            Format::XShell,
            Format::XTerminal,
            Format::Putty,
            Format::MobaXterm,
            Format::OpenSSH,
        ] {
            let c = CancellationToken::new();
            let out = export(&[sample()], format, "2026-09-09T00:00:00Z", "0.1", &c).unwrap();
            let input = import(
                vec![SourceFile {
                    path: out.suggested_file_name,
                    data: out.data,
                }],
                Format::Automatic,
                &c,
            )
            .unwrap();
            assert_eq!(input.candidates.len(), 1, "{format:?}");
            let r = &input.candidates[0].record;
            assert_eq!(r.host, "example.com", "{format:?}");
            assert_eq!(r.port, 2222, "{format:?}");
            assert_eq!(r.username, "user", "{format:?}");
        }
    }
    #[test]
    fn secret_body_never_enters_preview() {
        let input=br#"[{"host":"x","username":"u","privateKey":"-----BEGIN OPENSSH PRIVATE KEY-----\nsecret","password":"pass","credentialID":"foreign"}]"#;
        let p = import(
            vec![SourceFile {
                path: "x.json".into(),
                data: input.to_vec(),
            }],
            Format::XTerminal,
            &CancellationToken::new(),
        )
        .unwrap();
        assert!(p.candidates[0].record.external_private_key_path.is_none());
        assert_eq!(
            p.candidates[0].password.as_deref().map(|s| s.as_str()),
            Some("pass")
        );
        let json = serde_json::to_string(&p).unwrap();
        assert!(
            !json.contains("secret") && !json.contains("foreign") && !json.contains(":\"pass\"")
        );
    }
    #[test]
    fn no_implicit_scripts_or_include() {
        let p=import(vec![SourceFile{path:"config".into(),data:b"Include ~/.ssh/config.d/*\nHost a\n HostName x\n User u\n ProxyCommand execute-me\n Match exec touch-file\n HostName wrong\n".to_vec()}],Format::OpenSSH,&CancellationToken::new()).unwrap();
        assert_eq!(p.candidates[0].record.host, "x");
        assert!(!p.warnings.is_empty());
        assert!(!p.candidates[0].warnings.is_empty());
    }
    #[test]
    fn unvalidated_export_stays_gated() {
        for f in [Format::SecureCRT, Format::FinalShell] {
            assert!(matches!(
                export(
                    &[sample()],
                    f,
                    "2026-09-09T00:00:00Z",
                    "0.1",
                    &CancellationToken::new()
                ),
                Err(Error::UnvalidatedExport)
            ));
        }
    }
    #[test]
    fn unsafe_archive_is_rejected() {
        let data = make_zip(vec![("../outside.json".into(), b"{}".to_vec())]).unwrap();
        assert!(expand_archive(
            SourceFile {
                path: "x.zip".into(),
                data
            },
            &CancellationToken::new()
        )
        .is_err());
    }
}
