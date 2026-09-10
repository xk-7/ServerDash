//! Version 1 configuration packages and three-way merge. Only whitelisted, portable fields
//! belong here. Passwords, private keys, filesystem grants and trust decisions never do.
use crate::{Error, Result};
use aes_gcm::{
    aead::{Aead, AeadCore, OsRng, Payload},
    Aes256Gcm, KeyInit, Nonce,
};
use futures_util::StreamExt;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::{
    collections::{BTreeMap, BTreeSet},
    time::Duration,
};
use tokio_util::sync::CancellationToken;
use url::Url;
use uuid::Uuid;
use zeroize::Zeroizing;

mod nested;
pub use nested::{default_rdp_settings, sanitize_nested_for_export};

pub const MAX_BYTES: usize = 32 * 1024 * 1024;
const HEADER: &[u8] = b"ServerDash.ConfigSync.v1\n";

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct SyncObject {
    #[serde(with = "crate::swift_uuid")]
    pub id: Uuid,
    pub kind: String,
    pub fields: BTreeMap<String, String>,
    pub deleted: bool,
}
impl SyncObject {
    pub fn validate(&self) -> Result<()> {
        let keys: &[&str] = match self.kind.as_str() {
            "ssh" => &[
                "name",
                "host",
                "port",
                "username",
                "authentication",
                "group",
                "tags",
                "notes",
                "sftpPath",
            ],
            "rdp" => &[
                "name", "host", "port", "username", "domain", "group", "tags", "notes", "settings",
            ],
            "vnc" => &["name", "host", "port", "group", "tags", "notes"],
            "serial" => &[
                "name", "baud", "bits", "parity", "stop", "flow", "group", "tags", "notes",
            ],
            "group" => &["name", "parent"],
            "tag" => &["name", "color"],
            "snippet" => &["title", "command", "category", "notes", "favorite"],
            "advanced" => &["server", "settings"],
            "route" => &["server", "route"],
            "tunnel" => &[
                "server",
                "name",
                "direction",
                "bind",
                "port",
                "target",
                "targetPort",
            ],
            _ => return Err(Error::Invalid),
        };
        if self
            .fields
            .iter()
            .any(|(k, v)| !keys.contains(&k.as_str()) || v.len() > 262_144 || v.contains('\0'))
            || (!self.deleted
                && keys.iter().any(|k| {
                    !self.fields.contains_key(*k) && !(self.kind == "group" && *k == "parent")
                }))
        {
            return Err(Error::Invalid);
        }
        // JSON encoded inside a string is still structured configuration. Checking only
        // the outer fields would admit proxy credentials, RDP bookmarks and local grants.
        if let Some(value) = match self.kind.as_str() {
            "rdp" | "advanced" => self.fields.get("settings"),
            "route" => self.fields.get("route"),
            _ => None,
        } {
            nested::validate(&self.kind, value)?;
        }
        if self.kind == "ssh"
            && self.fields.get("authentication").is_some_and(|v| {
                !["privateKey", "password", "keyThenPassword"].contains(&v.as_str())
            })
        {
            return Err(Error::Invalid);
        }
        Ok(())
    }
    /// Mirrors ConfigurationSyncCatalog.capture: remove device permissions and credential
    /// references before serialization. Imported objects must pass validate() unchanged.
    pub fn sanitize_for_export(&self) -> Result<Self> {
        let mut result = self.clone();
        if let Some(key) = match self.kind.as_str() {
            "rdp" | "advanced" => Some("settings"),
            "route" => Some("route"),
            _ => None,
        } {
            if let Some(value) = result.fields.get_mut(key) {
                *value = sanitize_nested_for_export(&self.kind, value)?;
            }
        }
        result.validate()?;
        Ok(result)
    }
    pub fn name(&self) -> &str {
        self.fields
            .get("name")
            .or_else(|| self.fields.get("title"))
            .map(String::as_str)
            .unwrap_or(&self.kind)
    }
}
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct SyncPackage {
    pub version: u32,
    #[serde(rename = "spaceID", with = "crate::swift_uuid")]
    pub space_id: Uuid,
    pub objects: Vec<SyncObject>,
}
impl SyncPackage {
    pub fn validate(&self) -> Result<()> {
        if self.version != 1
            || self.objects.len() > 20_000
            || self
                .objects
                .iter()
                .map(|o| o.id)
                .collect::<BTreeSet<_>>()
                .len()
                != self.objects.len()
        {
            return Err(Error::Invalid);
        }
        self.objects.iter().try_for_each(SyncObject::validate)
    }
}
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct LocalPackage {
    pub format: String,
    pub version: u32,
    #[serde(rename = "sourceID", with = "crate::swift_uuid")]
    pub source_id: Uuid,
    pub objects: Vec<SyncObject>,
}
impl LocalPackage {
    pub fn new(source_id: Uuid, objects: Vec<SyncObject>) -> Self {
        Self {
            format: "ServerDash.LocalHostConfiguration".into(),
            version: 1,
            source_id,
            objects,
        }
    }
    pub fn mapping_space_id(&self) -> Uuid {
        mapping_space_id(self.source_id)
    }
    pub fn validate(&self) -> Result<()> {
        if self.format != "ServerDash.LocalHostConfiguration"
            || self.version != 1
            || self.objects.iter().any(|o| o.kind == "snippet")
        {
            return Err(Error::Invalid);
        }
        SyncPackage {
            version: self.version,
            space_id: self.mapping_space_id(),
            objects: self.objects.clone(),
        }
        .validate()
    }
    pub fn decode(data: &[u8]) -> Result<Self> {
        if data.len() > MAX_BYTES {
            return Err(Error::TooLarge);
        }
        let package: Self = serde_json::from_slice(data)?;
        package.validate()?;
        Ok(package)
    }
    pub fn encode(&self) -> Result<Vec<u8>> {
        self.validate()?;
        let data = serde_json::to_vec_pretty(self)?;
        if data.len() > MAX_BYTES {
            return Err(Error::TooLarge);
        }
        Ok(data)
    }
    /// A local file is a selected subset, never a directory snapshot. Omitted objects
    /// cannot delete local data, and incoming tombstones are ignored.
    pub fn preview(
        &self,
        local: &[SyncObject],
        baseline: &BTreeMap<Uuid, SyncObject>,
    ) -> Result<Vec<Change>> {
        self.validate()?;
        let incoming: Vec<_> = self
            .objects
            .iter()
            .filter(|o| !o.deleted)
            .cloned()
            .collect();
        let ids: BTreeSet<_> = incoming.iter().map(|o| o.id).collect();
        if incoming.is_empty() {
            return Err(Error::Invalid);
        }
        Ok(changes(
            &local
                .iter()
                .filter(|o| ids.contains(&o.id))
                .cloned()
                .collect::<Vec<_>>(),
            &incoming,
            &baseline
                .iter()
                .filter(|(id, _)| ids.contains(id))
                .map(|(id, o)| (*id, o.clone()))
                .collect(),
        ))
    }
    pub fn apply(
        &self,
        local: &[SyncObject],
        preview: &[Change],
        expected_fingerprint: &[u8; 32],
    ) -> Result<Vec<SyncObject>> {
        if &fingerprint(local)? != expected_fingerprint {
            return Err(Error::Changed);
        }
        let mut combined: BTreeMap<_, _> = local.iter().map(|o| (o.id, o.clone())).collect();
        for o in self.objects.iter().filter(|o| !o.deleted) {
            combined.insert(o.id, o.clone());
        }
        Ok(
            resolve(local, &combined.into_values().collect::<Vec<_>>(), preview)?
                .into_iter()
                .filter(|o| !o.deleted)
                .collect(),
        )
    }
}
pub fn mapping_space_id(source: Uuid) -> Uuid {
    let digest = Sha256::digest(format!(
        "ServerDash.LocalHostConfiguration.mapping.v1:{}",
        source.to_string().to_uppercase()
    ));
    let mut bytes = [0; 16];
    bytes.copy_from_slice(&digest[..16]);
    bytes[6] = (bytes[6] & 15) | 128;
    bytes[8] = (bytes[8] & 63) | 128;
    Uuid::from_bytes(bytes)
}
pub fn fingerprint(objects: &[SyncObject]) -> Result<[u8; 32]> {
    let mut sorted = objects.to_vec();
    sorted.sort_by_key(|o| o.id);
    Ok(Sha256::digest(serde_json::to_vec(&sorted)?).into())
}
pub fn new_key() -> Zeroizing<Vec<u8>> {
    Zeroizing::new(Aes256Gcm::generate_key(OsRng).to_vec())
}
pub fn encrypt(package: &SyncPackage, key: &[u8]) -> Result<Vec<u8>> {
    package.validate()?;
    let raw = Zeroizing::new(serde_json::to_vec(package)?);
    if raw.len() > MAX_BYTES {
        return Err(Error::TooLarge);
    }
    let cipher = Aes256Gcm::new_from_slice(key).map_err(|_| Error::Crypto)?;
    let nonce = Aes256Gcm::generate_nonce(&mut OsRng);
    let packed = cipher
        .encrypt(
            &nonce,
            Payload {
                msg: &raw,
                aad: HEADER,
            },
        )
        .map_err(|_| Error::Crypto)?;
    let mut output = HEADER.to_vec();
    output.extend_from_slice(&nonce);
    output.extend_from_slice(&packed);
    Ok(output)
}
pub fn decrypt(data: &[u8], key: &[u8]) -> Result<SyncPackage> {
    if data.len() > MAX_BYTES + 1024 || !data.starts_with(HEADER) || data.len() < HEADER.len() + 28
    {
        return Err(Error::Invalid);
    }
    let cipher = Aes256Gcm::new_from_slice(key).map_err(|_| Error::Crypto)?;
    let body = &data[HEADER.len()..];
    let raw = Zeroizing::new(
        cipher
            .decrypt(
                Nonce::from_slice(&body[..12]),
                Payload {
                    msg: &body[12..],
                    aad: HEADER,
                },
            )
            .map_err(|_| Error::Crypto)?,
    );
    let package: SyncPackage = serde_json::from_slice(&raw)?;
    package.validate()?;
    Ok(package)
}
#[derive(Clone, Copy, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub enum Choice {
    Unresolved,
    Local,
    Remote,
    Both,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Change {
    pub id: Uuid,
    pub local: Option<SyncObject>,
    pub remote: Option<SyncObject>,
    pub choice: Choice,
    pub conflict: bool,
}
pub fn changes(
    local: &[SyncObject],
    remote: &[SyncObject],
    baseline: &BTreeMap<Uuid, SyncObject>,
) -> Vec<Change> {
    let l: BTreeMap<_, _> = local.iter().map(|o| (o.id, o)).collect();
    let r: BTreeMap<_, _> = remote.iter().map(|o| (o.id, o)).collect();
    let ids: BTreeSet<_> = l
        .keys()
        .chain(r.keys())
        .chain(baseline.keys())
        .copied()
        .collect();
    let mut result = Vec::new();
    for id in ids {
        let base = baseline.get(&id);
        let tombstone = || {
            base.map(|o| {
                let mut o = o.clone();
                o.deleted = true;
                o
            })
        };
        let local = l.get(&id).map(|o| (*o).clone()).or_else(tombstone);
        let remote = r.get(&id).map(|o| (*o).clone()).or_else(tombstone);
        if local == remote {
            continue;
        }
        let lc = local.as_ref() != base;
        let rc = remote.as_ref() != base;
        result.push(Change {
            id,
            local,
            remote,
            conflict: lc && rc,
            choice: if lc && rc {
                Choice::Unresolved
            } else if lc {
                Choice::Local
            } else {
                Choice::Remote
            },
        });
    }
    result.sort_by_key(|c| {
        c.local
            .as_ref()
            .or(c.remote.as_ref())
            .map(|o| o.name().to_owned())
    });
    result
}
pub fn resolve(
    local: &[SyncObject],
    remote: &[SyncObject],
    changes: &[Change],
) -> Result<Vec<SyncObject>> {
    let mut merged: BTreeMap<_, _> = local
        .iter()
        .chain(remote)
        .map(|o| (o.id, o.clone()))
        .collect();
    for c in changes {
        let chosen = match c.choice {
            Choice::Unresolved => return Err(Error::Conflict),
            Choice::Local => c.local.clone(),
            Choice::Remote => c.remote.clone(),
            Choice::Both => {
                let o = c.local.as_ref().ok_or(Error::Conflict)?;
                if !["ssh", "rdp", "vnc", "serial", "snippet"].contains(&o.kind.as_str()) {
                    return Err(Error::Conflict);
                }
                if !o.deleted {
                    let mut copy = o.clone();
                    copy.id = Uuid::new_v4();
                    for key in ["name", "title"] {
                        if let Some(v) = copy.fields.get_mut(key) {
                            v.push_str("（本机副本）");
                        }
                    }
                    merged.insert(copy.id, copy);
                }
                c.remote.clone()
            }
        };
        if let Some(o) = chosen {
            merged.insert(c.id, o);
        } else {
            merged.remove(&c.id);
        }
    }
    let mut result: Vec<_> = merged.into_values().collect();
    normalize(&mut result);
    Ok(result)
}
pub fn normalize(objects: &mut [SyncObject]) {
    let deleted_ssh: BTreeSet<_> = objects
        .iter()
        .filter(|o| o.kind == "ssh" && o.deleted)
        .map(|o| o.id.to_string().to_uppercase())
        .collect();
    let deleted_groups: BTreeMap<_, _> = objects
        .iter()
        .filter(|o| o.kind == "group" && o.deleted)
        .map(|o| {
            (
                o.id.to_string().to_uppercase(),
                o.fields.get("parent").cloned(),
            )
        })
        .collect();
    let deleted_names = |kind: &str| -> BTreeSet<String> {
        let live: BTreeSet<_> = objects
            .iter()
            .filter(|o| o.kind == kind && !o.deleted)
            .filter_map(|o| o.fields.get("name").cloned())
            .collect();
        objects
            .iter()
            .filter(|o| o.kind == kind && o.deleted)
            .filter_map(|o| o.fields.get("name").cloned())
            .filter(|n| !live.contains(n))
            .collect()
    };
    let groups = deleted_names("group");
    let tags = deleted_names("tag");
    for o in objects {
        if ["advanced", "route", "tunnel"].contains(&o.kind.as_str())
            && o.fields
                .get("server")
                .is_some_and(|s| deleted_ssh.contains(s))
        {
            o.deleted = true;
        }
        if ["ssh", "rdp", "vnc", "serial"].contains(&o.kind.as_str()) {
            if o.fields.get("group").is_some_and(|g| groups.contains(g)) {
                o.fields.insert("group".into(), "默认分组".into());
            }
            if let Some(t) = o.fields.get_mut("tags") {
                *t = t
                    .split([',', '，', ';', '；'])
                    .map(str::trim)
                    .filter(|s| !s.is_empty() && !tags.contains(*s))
                    .collect::<Vec<_>>()
                    .join(",");
            }
        }
        if o.kind == "group" && !o.deleted {
            let mut visited = BTreeSet::new();
            while let Some(parent) = o.fields.get("parent").cloned() {
                if !visited.insert(parent.clone()) {
                    break;
                }
                match deleted_groups.get(&parent) {
                    Some(Some(next)) => {
                        o.fields.insert("parent".into(), next.clone());
                    }
                    Some(None) => {
                        o.fields.remove("parent");
                    }
                    None => break,
                }
            }
        }
    }
}

pub fn is_strong_etag(value: &str) -> bool {
    let b = value.as_bytes();
    b.len() >= 2
        && b[0] == b'"'
        && b[b.len() - 1] == b'"'
        && b[1..b.len() - 1]
            .iter()
            .all(|c| *c == 0x21 || (0x23..=0x7e).contains(c) || *c >= 0x80)
}
pub struct WebDavClient {
    client: reqwest::Client,
    directory: Url,
    username: String,
    password: Zeroizing<String>,
}
impl WebDavClient {
    pub fn new(address: &str, username: String, password: String) -> Result<Self> {
        let mut directory = Url::parse(address.trim()).map_err(|_| Error::Configuration)?;
        if directory.scheme() != "https"
            || directory.host_str().is_none()
            || !directory.username().is_empty()
            || directory.password().is_some()
            || directory.query().is_some()
            || directory.fragment().is_some()
        {
            return Err(Error::Configuration);
        }
        if !directory.path().ends_with('/') {
            directory.set_path(&format!("{}/", directory.path()));
        }
        Ok(Self {
            client: reqwest::Client::builder()
                .redirect(reqwest::redirect::Policy::none())
                .connect_timeout(Duration::from_secs(30))
                .timeout(Duration::from_secs(120))
                .build()
                .map_err(|_| Error::Network)?,
            directory,
            username,
            password: Zeroizing::new(password),
        })
    }
    fn request(&self, method: reqwest::Method, resource: &str) -> Result<reqwest::RequestBuilder> {
        Ok(self
            .client
            .request(
                method,
                self.directory
                    .join(resource)
                    .map_err(|_| Error::Configuration)?,
            )
            .basic_auth(&self.username, Some(self.password.as_str())))
    }
    async fn send(
        request: reqwest::RequestBuilder,
        cancel: &CancellationToken,
    ) -> Result<reqwest::Response> {
        tokio::select! { biased; _ = cancel.cancelled() => Err(Error::Cancelled), r = request.send() => r.map_err(|_| Error::Network) }
    }
    pub async fn fetch(
        &self,
        cancel: &CancellationToken,
    ) -> Result<(Option<Vec<u8>>, Option<String>)> {
        let response = Self::send(
            self.request(reqwest::Method::GET, "ServerDash.configsync")?,
            cancel,
        )
        .await?;
        if response.status().as_u16() == 404 {
            return Ok((None, None));
        }
        if response.status().as_u16() != 200 {
            return Err(Error::Http(response.status().as_u16()));
        }
        let etag = response
            .headers()
            .get("etag")
            .and_then(|h| h.to_str().ok())
            .filter(|s| is_strong_etag(s))
            .ok_or(Error::ConditionalWrites)?
            .to_owned();
        let mut stream = response.bytes_stream();
        let mut data = Vec::new();
        loop {
            let chunk = tokio::select! { biased; _ = cancel.cancelled() => return Err(Error::Cancelled), c = stream.next() => c };
            match chunk {
                Some(Ok(chunk)) if data.len() + chunk.len() <= MAX_BYTES + 1024 => {
                    data.extend_from_slice(&chunk)
                }
                Some(Ok(_)) => return Err(Error::TooLarge),
                Some(Err(_)) => return Err(Error::Network),
                None => break,
            }
        }
        Ok((Some(data), Some(etag)))
    }
    pub async fn put(
        &self,
        data: Vec<u8>,
        etag: Option<&str>,
        cancel: &CancellationToken,
    ) -> Result<()> {
        if data.len() > MAX_BYTES + 1024 {
            return Err(Error::TooLarge);
        }
        if etag.is_some_and(|v| !is_strong_etag(v)) {
            return Err(Error::ConditionalWrites);
        }
        self.verify_conditional_writes(cancel).await?;
        let mut request = self
            .request(reqwest::Method::PUT, "ServerDash.configsync")?
            .header("Content-Type", "application/octet-stream")
            .body(data);
        request = if let Some(etag) = etag {
            request.header("If-Match", etag)
        } else {
            request.header("If-None-Match", "*")
        };
        let status = Self::send(request, cancel).await?.status().as_u16();
        match status {
            200 | 201 | 204 => Ok(()),
            412 => Err(Error::Changed),
            _ => Err(Error::Http(status)),
        }
    }
    async fn verify_conditional_writes(&self, cancel: &CancellationToken) -> Result<()> {
        let resource = format!(".serverdash-condition-{}", Uuid::new_v4());
        let stale = format!("\"nonexistent-{}\"", Uuid::new_v4());
        let result = async {
            let status = Self::send(
                self.request(reqwest::Method::PUT, &resource)?
                    .header("If-Match", &stale)
                    .body(Vec::new()),
                cancel,
            )
            .await?
            .status()
            .as_u16();
            if status != 412 {
                return Err(Error::ConditionalWrites);
            }
            for expected in [false, true] {
                let status = Self::send(
                    self.request(reqwest::Method::PUT, &resource)?
                        .header("If-None-Match", "*")
                        .body(Vec::new()),
                    cancel,
                )
                .await?
                .status()
                .as_u16();
                if if expected {
                    status != 412
                } else {
                    ![200, 201, 204].contains(&status)
                } {
                    return Err(Error::ConditionalWrites);
                }
            }
            if Self::send(
                self.request(reqwest::Method::PUT, &resource)?
                    .header("If-Match", &stale)
                    .body(Vec::new()),
                cancel,
            )
            .await?
            .status()
            .as_u16()
                != 412
            {
                return Err(Error::ConditionalWrites);
            }
            Ok(())
        }
        .await;
        // Cleanup is bounded and intentionally independent of cancellation; only our random probe is removed.
        if let Ok(cleanup) = self.request(reqwest::Method::DELETE, &resource) {
            let _ = cleanup.timeout(Duration::from_secs(5)).send().await;
        }
        result
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn group(id: Uuid, name: &str) -> SyncObject {
        SyncObject {
            id,
            kind: "group".into(),
            fields: BTreeMap::from([("name".into(), name.into())]),
            deleted: false,
        }
    }
    #[test]
    fn crypto_tamper_wrong_key() {
        let p = SyncPackage {
            version: 1,
            space_id: Uuid::new_v4(),
            objects: vec![],
        };
        let key = new_key();
        let mut bytes = encrypt(&p, &key).unwrap();
        assert_eq!(decrypt(&bytes, &key).unwrap(), p);
        assert!(decrypt(&bytes, &[0; 32]).is_err());
        *bytes.last_mut().unwrap() ^= 1;
        assert!(decrypt(&bytes, &key).is_err());
    }
    #[test]
    fn merge_conflict_tombstone() {
        let id = Uuid::new_v4();
        let a = group(id, "A");
        let b = group(id, "B");
        let c = group(id, "C");
        let baseline = BTreeMap::from([(id, a)]);
        let mut preview = changes(&[b.clone()], &[c.clone()], &baseline);
        assert!(preview[0].conflict);
        assert!(resolve(&[b.clone()], &[c.clone()], &preview).is_err());
        preview[0].choice = Choice::Local;
        assert_eq!(resolve(&[b.clone()], &[c], &preview).unwrap(), vec![b]);
        let d = changes(&[], &[group(id, "A")], &baseline);
        assert!(d[0].local.as_ref().unwrap().deleted);
    }
    #[test]
    fn local_omissions_never_delete() {
        let a = group(Uuid::new_v4(), "A");
        let b = group(Uuid::new_v4(), "B");
        let local = vec![a.clone(), b.clone()];
        let p = LocalPackage::new(Uuid::new_v4(), vec![a]);
        let preview = p.preview(&local, &BTreeMap::new()).unwrap();
        assert!(preview.is_empty());
        assert_eq!(
            p.apply(&local, &preview, &fingerprint(&local).unwrap())
                .unwrap()
                .len(),
            2
        );
    }
    #[test]
    fn rejects_credentials_and_weak_etag() {
        let mut o = group(Uuid::new_v4(), "A");
        o.fields.insert("password".into(), "secret".into());
        assert!(o.validate().is_err());
        for s in ["W/\"x\"", "x", "\"x\ny\"", "\"x\"y\""] {
            assert!(!is_strong_etag(s));
        }
        assert!(is_strong_etag("\"abc\""));
    }
}
