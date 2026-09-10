use anyhow::{bail, Context, Result};
use rusqlite::{params, Connection, OptionalExtension};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::{collections::HashMap, path::Path, sync::Mutex};
use zeroize::Zeroizing;

/// The repository stores public configuration only. Secret bytes never enter SQLite.
pub struct Repository(Mutex<Connection>);

impl Repository {
    pub fn open(path: &Path) -> Result<Self> {
        let connection = Connection::open(path)?;
        connection.busy_timeout(std::time::Duration::from_secs(5))?;
        connection.pragma_update(None, "journal_mode", "WAL")?;
        connection.pragma_update(None, "foreign_keys", "ON")?;
        let version: u32 = connection.pragma_query_value(None, "user_version", |r| r.get(0))?;
        if version > 1 {
            bail!("This database was created by a newer ServerDash version");
        }
        if version == 0 {
            connection.execute_batch("BEGIN IMMEDIATE;
                CREATE TABLE records (collection TEXT NOT NULL, id TEXT NOT NULL, body TEXT NOT NULL, PRIMARY KEY(collection,id));
                CREATE TABLE trusted_hosts (host TEXT NOT NULL, port INTEGER NOT NULL, algorithm TEXT NOT NULL, fingerprint TEXT NOT NULL, PRIMARY KEY(host,port,algorithm));
                CREATE TABLE monitor_history (machine_id TEXT NOT NULL, timestamp INTEGER NOT NULL, body TEXT NOT NULL, PRIMARY KEY(machine_id,timestamp));
                CREATE INDEX monitor_history_time ON monitor_history(timestamp);
                PRAGMA user_version=1;
                COMMIT;")?;
        }
        Ok(Self(Mutex::new(connection)))
    }
    pub fn list(&self, collection: &str) -> Result<Vec<Value>> {
        let c = self.0.lock().unwrap();
        let mut stmt = c.prepare("SELECT body FROM records WHERE collection=?1 ORDER BY rowid")?;
        let values = stmt.query_map([collection], |r| r.get::<_, String>(0))?;
        values.map(|v| Ok(serde_json::from_str(&v?)?)).collect()
    }
    pub fn get(&self, collection: &str, id: &str) -> Result<Value> {
        let body: Option<String> = self
            .0
            .lock()
            .unwrap()
            .query_row(
                "SELECT body FROM records WHERE collection=?1 AND id=?2",
                params![collection, id],
                |r| r.get(0),
            )
            .optional()?;
        serde_json::from_str(&body.context("Record does not exist")?).map_err(Into::into)
    }
    pub fn save(&self, collection: &str, id: &str, value: &Value) -> Result<()> {
        reject_secrets(value)?;
        self.0.lock().unwrap().execute("INSERT INTO records(collection,id,body) VALUES (?1,?2,?3) ON CONFLICT(collection,id) DO UPDATE SET body=excluded.body",params![collection,id,value.to_string()])?;
        Ok(())
    }
    pub fn delete(&self, collection: &str, id: &str) -> Result<()> {
        let mut c = self.0.lock().unwrap();
        let tx = c.transaction()?;
        tx.execute(
            "DELETE FROM records WHERE collection=?1 AND id=?2",
            params![collection, id],
        )?;
        if collection == "machines" {
            tx.execute("DELETE FROM monitor_history WHERE machine_id=?1", [id])?;
        }
        tx.commit()?;
        Ok(())
    }
    pub fn batch(
        &self,
        upserts: Vec<(String, String, Value)>,
        deletes: Vec<(String, String)>,
    ) -> Result<()> {
        for (_, _, value) in &upserts {
            reject_secrets(value)?;
        }
        let mut connection = self.0.lock().unwrap();
        let tx = connection.transaction()?;
        for (collection, id, value) in upserts {
            tx.execute("INSERT INTO records(collection,id,body) VALUES(?1,?2,?3) ON CONFLICT(collection,id) DO UPDATE SET body=excluded.body",params![collection,id,value.to_string()])?;
        }
        for (collection, id) in deletes {
            tx.execute(
                "DELETE FROM records WHERE collection=?1 AND id=?2",
                params![collection, id],
            )?;
            if collection == "machines" {
                tx.execute("DELETE FROM monitor_history WHERE machine_id=?1", [id])?;
            }
        }
        tx.commit()?;
        Ok(())
    }
    pub fn trusted_fingerprint(
        &self,
        host: &str,
        port: u16,
        algorithm: &str,
    ) -> Result<Option<String>> {
        Ok(self
            .0
            .lock()
            .unwrap()
            .query_row(
                "SELECT fingerprint FROM trusted_hosts WHERE host=?1 AND port=?2 AND algorithm=?3",
                params![host, port, algorithm],
                |r| r.get(0),
            )
            .optional()?)
    }
    pub fn trust(&self, host: &str, port: u16, algorithm: &str, fingerprint: &str) -> Result<()> {
        self.0.lock().unwrap().execute("INSERT INTO trusted_hosts(host,port,algorithm,fingerprint) VALUES(?1,?2,?3,?4) ON CONFLICT(host,port,algorithm) DO UPDATE SET fingerprint=excluded.fingerprint",params![host,port,algorithm,fingerprint])?;
        Ok(())
    }
    pub fn hosts(&self) -> Result<Vec<Value>> {
        let c = self.0.lock().unwrap();
        let mut stmt =
            c.prepare("SELECT host,port,algorithm,fingerprint FROM trusted_hosts ORDER BY host")?;
        let rows=stmt.query_map([], |r| Ok(json!({"host":r.get::<_,String>(0)?,"port":r.get::<_,u16>(1)?,"algorithm":r.get::<_,String>(2)?,"fingerprint":r.get::<_,String>(3)?})))?;
        Ok(rows.collect::<rusqlite::Result<_>>()?)
    }
    pub fn forget_host(&self, host: &str, port: u16) -> Result<()> {
        self.0.lock().unwrap().execute(
            "DELETE FROM trusted_hosts WHERE host=?1 AND port=?2",
            params![host, port],
        )?;
        Ok(())
    }
    pub fn history_push(&self, id: &str, time: u64, value: &Value) -> Result<()> {
        let c = self.0.lock().unwrap();
        let changed=c.execute("INSERT OR REPLACE INTO monitor_history(machine_id,timestamp,body) SELECT ?1,?2,?3 WHERE EXISTS (SELECT 1 FROM records WHERE collection='machines' AND id=?1)",params![id,i64::try_from(time)?,value.to_string()])?;
        anyhow::ensure!(changed == 1, "Machine was deleted during collection");
        c.execute(
            "DELETE FROM monitor_history WHERE timestamp < ?1",
            [i64::try_from(time.saturating_sub(7 * 24 * 60 * 60 * 1000))?],
        )?;
        Ok(())
    }
    pub fn history(&self, id: &str, since: u64) -> Result<Vec<Value>> {
        let c = self.0.lock().unwrap();
        let mut stmt=c.prepare("SELECT body FROM monitor_history WHERE machine_id=?1 AND timestamp>=?2 ORDER BY timestamp DESC LIMIT 10000")?;
        let rows = stmt.query_map(params![id, i64::try_from(since)?], |r| {
            r.get::<_, String>(0)
        })?;
        let mut values: Vec<Value> = rows
            .map(|r| Ok(serde_json::from_str(&r?)?))
            .collect::<Result<_>>()?;
        values.reverse();
        Ok(values)
    }
}

fn reject_secrets(v: &Value) -> Result<()> {
    match v {
        Value::Object(object) => {
            for (key, value) in object {
                if matches!(
                    key.to_ascii_lowercase().as_str(),
                    "password"
                        | "privatekey"
                        | "passphrase"
                        | "apikey"
                        | "secret"
                        | "token"
                        | "authorization"
                ) {
                    bail!("Secret fields must be stored through credentials_save");
                }
                reject_secrets(value)?;
            }
        }
        Value::Array(values) => {
            for value in values {
                reject_secrets(value)?;
            }
        }
        _ => {}
    };
    Ok(())
}

#[derive(Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Credentials {
    #[serde(default)]
    pub password: String,
    #[serde(default)]
    pub private_key: String,
    #[serde(default)]
    pub passphrase: String,
    #[serde(default)]
    pub api_key: String,
}
impl Drop for Credentials {
    fn drop(&mut self) {
        use zeroize::Zeroize;
        self.password.zeroize();
        self.private_key.zeroize();
        self.passphrase.zeroize();
        self.api_key.zeroize();
    }
}

/// Windows uses user-bound DPAPI. Non-Windows development credentials are memory-only.
pub struct SecretStore {
    #[cfg(windows)]
    directory: std::path::PathBuf,
    memory: Mutex<HashMap<String, Zeroizing<Vec<u8>>>>,
}
impl SecretStore {
    pub fn new(directory: &Path) -> Result<Self> {
        std::fs::create_dir_all(directory)?;
        Ok(Self {
            #[cfg(windows)]
            directory: directory.into(),
            memory: Mutex::new(HashMap::new()),
        })
    }
    pub fn save(&self, id: &str, credentials: &Credentials) -> Result<()> {
        uuid::Uuid::parse_str(id).context("Invalid credential identifier")?;
        let data = Zeroizing::new(serde_json::to_vec(credentials)?);
        #[cfg(windows)]
        {
            let encrypted = dpapi(&data, true)?;
            let temporary = self.directory.join(format!("{}.tmp", uuid::Uuid::new_v4()));
            std::fs::write(&temporary, encrypted)?;
            let destination = self.directory.join(id);
            // Persist encrypted replacement atomically on Windows via MoveFileExW.
            use std::os::windows::ffi::OsStrExt;
            let from: Vec<u16> = temporary.as_os_str().encode_wide().chain(Some(0)).collect();
            let to: Vec<u16> = destination
                .as_os_str()
                .encode_wide()
                .chain(Some(0))
                .collect();
            unsafe {
                if windows_sys::Win32::Storage::FileSystem::MoveFileExW(
                    from.as_ptr(),
                    to.as_ptr(),
                    windows_sys::Win32::Storage::FileSystem::MOVEFILE_REPLACE_EXISTING
                        | windows_sys::Win32::Storage::FileSystem::MOVEFILE_WRITE_THROUGH,
                ) == 0
                {
                    let e = std::io::Error::last_os_error();
                    let _ = std::fs::remove_file(temporary);
                    return Err(e.into());
                }
            }
        }
        #[cfg(not(windows))]
        self.memory.lock().unwrap().insert(id.into(), data);
        Ok(())
    }
    pub fn get(&self, id: &str) -> Result<Credentials> {
        uuid::Uuid::parse_str(id).context("Invalid credential identifier")?;
        #[cfg(windows)]
        {
            let data = Zeroizing::new(dpapi(
                &std::fs::read(self.directory.join(id))
                    .context("Credential missing on this Windows account")?,
                false,
            )?);
            Ok(serde_json::from_slice(&data)?)
        }
        #[cfg(not(windows))]
        {
            let lock = self.memory.lock().unwrap();
            let data = lock.get(id).context(
                "Credential missing; non-Windows development credentials last only for this run",
            )?;
            Ok(serde_json::from_slice(data)?)
        }
    }
    pub fn delete(&self, id: &str) -> Result<()> {
        uuid::Uuid::parse_str(id)?;
        self.memory.lock().unwrap().remove(id);
        #[cfg(windows)]
        match std::fs::remove_file(self.directory.join(id)) {
            Ok(()) => {}
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
            Err(e) => return Err(e.into()),
        }
        Ok(())
    }
}

#[cfg(windows)]
fn dpapi(bytes: &[u8], protect: bool) -> Result<Vec<u8>> {
    use windows_sys::Win32::{Foundation::LocalFree, Security::Cryptography::*};
    anyhow::ensure!(bytes.len() <= u32::MAX as usize, "Credential too large");
    let input = CRYPT_INTEGER_BLOB {
        cbData: bytes.len() as u32,
        pbData: bytes.as_ptr() as *mut u8,
    };
    let mut output = CRYPT_INTEGER_BLOB {
        cbData: 0,
        pbData: std::ptr::null_mut(),
    };
    unsafe {
        let ok = if protect {
            CryptProtectData(
                &input,
                std::ptr::null(),
                std::ptr::null(),
                std::ptr::null_mut(),
                std::ptr::null(),
                CRYPTPROTECT_UI_FORBIDDEN,
                &mut output,
            )
        } else {
            CryptUnprotectData(
                &input,
                std::ptr::null_mut(),
                std::ptr::null(),
                std::ptr::null_mut(),
                std::ptr::null(),
                CRYPTPROTECT_UI_FORBIDDEN,
                &mut output,
            )
        };
        if ok == 0 {
            return Err(std::io::Error::last_os_error().into());
        }
        let data = std::slice::from_raw_parts(output.pbData, output.cbData as usize).to_vec();
        if !protect {
            std::ptr::write_bytes(output.pbData, 0, output.cbData as usize);
        }
        LocalFree(output.pbData as _);
        Ok(data)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn repository_reopens_and_refuses_secrets() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("db");
        {
            let r = Repository::open(&path).unwrap();
            r.save(
                "machines",
                "a",
                &json!({"name":"生产","credentialId":"ref"}),
            )
            .unwrap();
            assert!(r
                .save(
                    "machines",
                    "b",
                    &json!({"proxy":{"password":"never persist"}})
                )
                .is_err());
        }
        let r = Repository::open(&path).unwrap();
        assert_eq!(r.get("machines", "a").unwrap()["name"], "生产");
    }
    #[test]
    fn secrets_never_written_as_plaintext() {
        let dir = tempfile::tempdir().unwrap();
        let s = SecretStore::new(dir.path()).unwrap();
        let id = uuid::Uuid::new_v4().to_string();
        let mut credential = Credentials::default();
        credential.password = "sensitive-marker".into();
        s.save(&id, &credential).unwrap();
        assert_eq!(s.get(&id).unwrap().password, "sensitive-marker");
        let reopened = SecretStore::new(dir.path()).unwrap();
        #[cfg(windows)]
        {
            assert_eq!(reopened.get(&id).unwrap().password, "sensitive-marker");
            let path = dir.path().join(&id);
            let encrypted = std::fs::read(&path).unwrap();
            let mut damaged = encrypted.clone();
            let last = damaged.len() - 1;
            damaged[last] ^= 1;
            std::fs::write(&path, damaged).unwrap();
            assert!(
                reopened.get(&id).is_err(),
                "DPAPI must reject modified ciphertext"
            );
            std::fs::write(&path, encrypted).unwrap();
        }
        #[cfg(not(windows))]
        assert!(
            reopened.get(&id).is_err(),
            "Development credentials are process-local"
        );
        for item in std::fs::read_dir(dir.path()).unwrap() {
            assert!(
                !String::from_utf8_lossy(&std::fs::read(item.unwrap().path()).unwrap())
                    .contains("sensitive-marker")
            );
        }
        s.delete(&id).unwrap();
        assert!(s.get(&id).is_err());
    }
}
