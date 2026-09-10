use russh_sftp::protocol::{
    Attrs, Data, File, FileAttributes, Handle, Name, OpenFlags, Packet, Status, StatusCode, Version,
};
use std::{
    collections::HashMap,
    sync::{Arc, Mutex},
};

/// Minimal protocol peer, independent of the client implementation. Standard
/// rename deliberately refuses an existing target; only POSIX rename replaces.
pub struct Peer {
    files: Arc<Mutex<HashMap<String, Vec<u8>>>>,
    handles: HashMap<String, String>,
    directory_finished: bool,
}

impl Peer {
    pub fn new(files: Arc<Mutex<HashMap<String, Vec<u8>>>>) -> Self {
        Self {
            files,
            handles: HashMap::new(),
            directory_finished: false,
        }
    }
    fn ok(id: u32) -> Status {
        Status {
            id,
            status_code: StatusCode::Ok,
            error_message: String::new(),
            language_tag: "en".into(),
        }
    }
    fn attributes(&self, path: &str) -> Result<FileAttributes, StatusCode> {
        let files = self.files.lock().unwrap();
        let bytes = files.get(path).ok_or(StatusCode::NoSuchFile)?;
        Ok(FileAttributes {
            size: Some(bytes.len() as u64),
            permissions: Some(0o100600),
            mtime: Some(1),
            ..Default::default()
        })
    }
}

impl russh_sftp::server::Handler for Peer {
    type Error = StatusCode;
    fn unimplemented(&self) -> Self::Error {
        StatusCode::OpUnsupported
    }

    async fn init(&mut self, _: u32, _: HashMap<String, String>) -> Result<Version, Self::Error> {
        let mut version = Version::new();
        version
            .extensions
            .insert("posix-rename@openssh.com".into(), "1".into());
        Ok(version)
    }

    async fn open(
        &mut self,
        id: u32,
        filename: String,
        flags: OpenFlags,
        _: FileAttributes,
    ) -> Result<Handle, Self::Error> {
        let mut files = self.files.lock().unwrap();
        if flags.contains(OpenFlags::CREATE) {
            if flags.contains(OpenFlags::EXCLUDE) && files.contains_key(&filename) {
                return Err(StatusCode::Failure);
            }
            files.entry(filename.clone()).or_default();
        }
        let file = files.get_mut(&filename).ok_or(StatusCode::NoSuchFile)?;
        if flags.contains(OpenFlags::TRUNCATE) {
            file.clear();
        }
        let handle = format!("file-{id}");
        self.handles.insert(handle.clone(), filename);
        Ok(Handle { id, handle })
    }

    async fn close(&mut self, id: u32, handle: String) -> Result<Status, Self::Error> {
        self.handles.remove(&handle);
        Ok(Self::ok(id))
    }
    async fn read(
        &mut self,
        id: u32,
        handle: String,
        offset: u64,
        len: u32,
    ) -> Result<Data, Self::Error> {
        let path = self.handles.get(&handle).ok_or(StatusCode::Failure)?;
        let files = self.files.lock().unwrap();
        let bytes = files.get(path).ok_or(StatusCode::NoSuchFile)?;
        let offset = usize::try_from(offset).map_err(|_| StatusCode::Failure)?;
        if offset >= bytes.len() {
            return Err(StatusCode::Eof);
        }
        Ok(Data {
            id,
            data: bytes[offset..bytes.len().min(offset + len as usize)].to_vec(),
        })
    }

    async fn write(
        &mut self,
        id: u32,
        handle: String,
        offset: u64,
        data: Vec<u8>,
    ) -> Result<Status, Self::Error> {
        let path = self.handles.get(&handle).ok_or(StatusCode::Failure)?;
        let mut files = self.files.lock().unwrap();
        let bytes = files.get_mut(path).ok_or(StatusCode::NoSuchFile)?;
        let offset = usize::try_from(offset).map_err(|_| StatusCode::Failure)?;
        let end = offset.checked_add(data.len()).ok_or(StatusCode::Failure)?;
        if end > 8 * 1024 * 1024 {
            return Err(StatusCode::Failure);
        }
        bytes.resize(bytes.len().max(end), 0);
        bytes[offset..end].copy_from_slice(&data);
        Ok(Self::ok(id))
    }

    async fn stat(&mut self, id: u32, path: String) -> Result<Attrs, Self::Error> {
        Ok(Attrs {
            id,
            attrs: self.attributes(&path)?,
        })
    }
    async fn lstat(&mut self, id: u32, path: String) -> Result<Attrs, Self::Error> {
        self.stat(id, path).await
    }
    async fn fstat(&mut self, id: u32, handle: String) -> Result<Attrs, Self::Error> {
        let path = self.handles.get(&handle).ok_or(StatusCode::Failure)?;
        Ok(Attrs {
            id,
            attrs: self.attributes(path)?,
        })
    }
    async fn setstat(
        &mut self,
        id: u32,
        path: String,
        _: FileAttributes,
    ) -> Result<Status, Self::Error> {
        self.attributes(&path)?;
        Ok(Self::ok(id))
    }
    async fn realpath(&mut self, id: u32, _: String) -> Result<Name, Self::Error> {
        Ok(Name {
            id,
            files: vec![File::dummy("/")],
        })
    }
    async fn opendir(&mut self, id: u32, _: String) -> Result<Handle, Self::Error> {
        self.directory_finished = false;
        Ok(Handle {
            id,
            handle: "directory".into(),
        })
    }
    async fn readdir(&mut self, id: u32, _: String) -> Result<Name, Self::Error> {
        if self.directory_finished {
            return Err(StatusCode::Eof);
        }
        self.directory_finished = true;
        let files = self
            .files
            .lock()
            .unwrap()
            .iter()
            .map(|(path, bytes)| {
                File::new(
                    path.trim_start_matches('/'),
                    FileAttributes {
                        size: Some(bytes.len() as u64),
                        permissions: Some(0o100600),
                        ..Default::default()
                    },
                )
            })
            .collect();
        Ok(Name { id, files })
    }
    async fn rename(&mut self, id: u32, from: String, to: String) -> Result<Status, Self::Error> {
        let mut files = self.files.lock().unwrap();
        if files.contains_key(&to) {
            return Err(StatusCode::Failure);
        }
        let contents = files.remove(&from).ok_or(StatusCode::NoSuchFile)?;
        files.insert(to, contents);
        Ok(Self::ok(id))
    }
    async fn remove(&mut self, id: u32, path: String) -> Result<Status, Self::Error> {
        self.files
            .lock()
            .unwrap()
            .remove(&path)
            .ok_or(StatusCode::NoSuchFile)?;
        Ok(Self::ok(id))
    }
    async fn extended(
        &mut self,
        id: u32,
        request: String,
        data: Vec<u8>,
    ) -> Result<Packet, Self::Error> {
        if request != "posix-rename@openssh.com" {
            return Err(StatusCode::OpUnsupported);
        }
        let mut cursor = data.as_slice();
        let mut paths = Vec::new();
        for _ in 0..2 {
            if cursor.len() < 4 {
                return Err(StatusCode::BadMessage);
            }
            let length = u32::from_be_bytes(cursor[..4].try_into().unwrap()) as usize;
            cursor = &cursor[4..];
            if length > cursor.len() {
                return Err(StatusCode::BadMessage);
            }
            paths.push(
                String::from_utf8(cursor[..length].to_vec()).map_err(|_| StatusCode::BadMessage)?,
            );
            cursor = &cursor[length..];
        }
        if !cursor.is_empty() {
            return Err(StatusCode::BadMessage);
        }
        let mut files = self.files.lock().unwrap();
        let bytes = files.remove(&paths[0]).ok_or(StatusCode::NoSuchFile)?;
        files.insert(paths[1].clone(), bytes);
        Ok(Packet::Status(Self::ok(id)))
    }
}
