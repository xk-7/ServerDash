//! SDRC0001: independently LZFSE-compressed JSON events with SHA-256 block checksums.
//! Playback exposes display snapshots only. Raw output is activity metadata and is never
//! interpreted or sent to a terminal, so OSC/clipboard/control sequences cannot execute.
use crate::{Error, Result, FOUNDATION_EPOCH_UNIX_SECONDS};
use base64::{engine::general_purpose::STANDARD, Engine};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::{
    fs::{File, OpenOptions},
    io::{Read, Seek, SeekFrom, Write},
    path::{Path, PathBuf},
    time::{SystemTime, UNIX_EPOCH},
};
use tokio_util::sync::CancellationToken;
use unicode_segmentation::UnicodeSegmentation;
use uuid::Uuid;

pub const MAGIC: &[u8; 8] = b"SDRC0001";
pub const MAX_BLOCK: usize = 16 * 1024 * 1024;
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Appearance {
    pub font_name: String,
    pub font_size: f64,
    pub cell_width: f64,
    pub cell_height: f64,
}
impl Appearance {
    pub fn validate(&self) -> Result<()> {
        if self.font_name.len() > 256
            || !self.font_size.is_finite()
            || !(8.0..=48.0).contains(&self.font_size)
            || !self.cell_width.is_finite()
            || !(1.0..=128.0).contains(&self.cell_width)
            || !self.cell_height.is_finite()
            || !(1.0..=256.0).contains(&self.cell_height)
        {
            return Err(Error::Invalid);
        }
        Ok(())
    }
}
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Header {
    pub format: String,
    pub version: u32,
    #[serde(with = "crate::swift_uuid")]
    pub id: Uuid,
    pub name: String,
    pub date: f64,
}
impl Header {
    pub fn new(name: String) -> Self {
        Self {
            format: "com.serverdash.recording".into(),
            version: 1,
            id: Uuid::new_v4(),
            name,
            date: SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap_or_default()
                .as_secs_f64()
                - FOUNDATION_EPOCH_UNIX_SECONDS,
        }
    }
    fn validate(&self) -> Result<()> {
        if self.format != "com.serverdash.recording"
            || self.version != 1
            || self.name.len() > 1024
            || !self.date.is_finite()
        {
            return Err(Error::Invalid);
        }
        Ok(())
    }
}
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct Cell {
    pub text: String,
    pub width: i32,
    pub foreground: u32,
    pub background: u32,
    pub style: u8,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub underline: Option<u32>,
}
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct Line {
    pub cells: Vec<Cell>,
    pub mode: i32,
}
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Snapshot {
    pub columns: i32,
    pub rows: i32,
    pub lines: Vec<Line>,
    pub cursor_column: i32,
    pub cursor_row: i32,
    pub cursor_visible: bool,
    pub cursor_style: String,
    pub foreground: u32,
    pub background: u32,
    pub has_images: bool,
}
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Frame {
    pub screen: Snapshot,
    pub appearance: Appearance,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub changed_rows: Option<Vec<i32>>,
}
impl Frame {
    pub fn validate(&self) -> Result<()> {
        self.appearance.validate()?;
        let s = &self.screen;
        if !(1..=1024).contains(&s.columns)
            || !(1..=512).contains(&s.rows)
            || s.columns * s.rows > 131_072
            || !(0..=s.columns).contains(&s.cursor_column)
            || !(-512..=1024).contains(&s.cursor_row)
            || s.cursor_style.graphemes(true).count() > 32
            || s.foreground > 0xffffff
            || s.background > 0xffffff
        {
            return Err(Error::Invalid);
        }
        if let Some(rows) = &self.changed_rows {
            if rows.len() != s.lines.len()
                || rows.iter().collect::<std::collections::BTreeSet<_>>().len() != rows.len()
                || rows.iter().any(|r| !(0..s.rows).contains(r))
            {
                return Err(Error::Invalid);
            }
        } else if s.lines.len() != s.rows as usize {
            return Err(Error::Invalid);
        }
        for line in &s.lines {
            if line.cells.len() != s.columns as usize || !(0..=3).contains(&line.mode) {
                return Err(Error::Invalid);
            }
            for cell in &line.cells {
                if !(0..=2).contains(&cell.width)
                    || cell.text.len() > 1024
                    || cell.text.graphemes(true).count() > 1
                    || cell.foreground > 0xffffff
                    || cell.background > 0xffffff
                    || cell.underline.is_some_and(|c| c > 0xffffff)
                {
                    return Err(Error::Invalid);
                }
            }
        }
        Ok(())
    }
    pub fn applying(&self, previous: Option<&Frame>) -> Result<Self> {
        self.validate()?;
        let Some(rows) = &self.changed_rows else {
            return Ok(self.clone());
        };
        let previous = previous.ok_or(Error::Invalid)?;
        if previous.screen.columns != self.screen.columns
            || previous.screen.rows != self.screen.rows
            || previous.changed_rows.is_some()
        {
            return Err(Error::Invalid);
        }
        let mut result = self.clone();
        result.screen.lines = previous.screen.lines.clone();
        for (index, row) in rows.iter().enumerate() {
            result.screen.lines[*row as usize] = self.screen.lines[index].clone();
        }
        result.changed_rows = None;
        Ok(result)
    }
}
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct IndexEntry {
    pub time: f64,
    pub offset: u64,
}
#[derive(Clone, Copy, Debug, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "lowercase")]
pub enum Kind {
    Header,
    Output,
    Screen,
    End,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Event {
    pub kind: Kind,
    pub time: f64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub header: Option<Header>,
    #[serde(
        default,
        skip_serializing_if = "Option::is_none",
        with = "optional_data"
    )]
    pub output: Option<Vec<u8>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub frame: Option<Frame>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub index: Option<Vec<IndexEntry>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub reason: Option<String>,
}
impl Event {
    fn new(kind: Kind, time: f64) -> Self {
        Self {
            kind,
            time,
            header: None,
            output: None,
            frame: None,
            index: None,
            reason: None,
        }
    }
}
mod optional_data {
    use super::*;
    pub fn serialize<S: serde::Serializer>(
        data: &Option<Vec<u8>>,
        s: S,
    ) -> std::result::Result<S::Ok, S::Error> {
        match data {
            Some(b) => s.serialize_some(&STANDARD.encode(b)),
            None => s.serialize_none(),
        }
    }
    pub fn deserialize<'de, D: serde::Deserializer<'de>>(
        d: D,
    ) -> std::result::Result<Option<Vec<u8>>, D::Error> {
        Option::<String>::deserialize(d)?
            .map(|s| STANDARD.decode(s).map_err(serde::de::Error::custom))
            .transpose()
    }
}
pub fn encode_event(event: &Event) -> Result<Vec<u8>> {
    let raw = serde_json::to_vec(event)?;
    if raw.is_empty() || raw.len() > MAX_BLOCK {
        return Err(Error::TooLarge);
    }
    let mut packed = vec![];
    lzfse_rust::encode_bytes(&raw, &mut packed).map_err(|_| Error::Invalid)?;
    if packed.is_empty() || packed.len() > MAX_BLOCK {
        return Err(Error::TooLarge);
    }
    let mut out = Vec::with_capacity(40 + packed.len());
    out.extend_from_slice(&(packed.len() as u32).to_le_bytes());
    out.extend_from_slice(&(raw.len() as u32).to_le_bytes());
    out.extend_from_slice(&Sha256::digest(&packed));
    out.extend_from_slice(&packed);
    Ok(out)
}
struct BoundedOutput {
    bytes: Vec<u8>,
    limit: usize,
}
impl Write for BoundedOutput {
    fn write(&mut self, data: &[u8]) -> std::io::Result<usize> {
        if data.len() > self.limit - self.bytes.len() {
            return Err(std::io::Error::new(
                std::io::ErrorKind::InvalidData,
                "LZFSE output exceeds declared size",
            ));
        }
        self.bytes.extend_from_slice(data);
        Ok(data.len())
    }
    fn flush(&mut self) -> std::io::Result<()> {
        Ok(())
    }
}
pub fn read_event(reader: &mut impl Read) -> Result<Option<Event>> {
    let mut prefix = [0u8; 40];
    loop {
        match reader.read(&mut prefix[..1]) {
            Ok(0) => return Ok(None),
            Ok(_) => break,
            Err(e) if e.kind() == std::io::ErrorKind::Interrupted => continue,
            Err(e) => return Err(e.into()),
        }
    }
    reader.read_exact(&mut prefix[1..])?;
    let packed = u32::from_le_bytes(prefix[..4].try_into().unwrap()) as usize;
    let unpacked = u32::from_le_bytes(prefix[4..8].try_into().unwrap()) as usize;
    if !(1..=MAX_BLOCK).contains(&packed) || !(1..=MAX_BLOCK).contains(&unpacked) {
        return Err(Error::Invalid);
    }
    let mut data = vec![0; packed];
    reader.read_exact(&mut data)?;
    if Sha256::digest(&data)[..] != prefix[8..] {
        return Err(Error::Invalid);
    }
    // Ring decoding writes through a bounded sink. A forged length cannot make the
    // decoder reserve an unbounded expansion before the length check.
    let mut output = BoundedOutput {
        bytes: Vec::with_capacity(unpacked),
        limit: unpacked,
    };
    lzfse_rust::LzfseRingDecoder::default()
        .decode(&mut std::io::Cursor::new(&data), &mut output)
        .map_err(|_| Error::Invalid)?;
    if output.bytes.len() != unpacked {
        return Err(Error::Invalid);
    }
    Ok(Some(serde_json::from_slice(&output.bytes)?))
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Document {
    pub path: PathBuf,
    pub header: Header,
    pub duration: f64,
    pub index: Vec<IndexEntry>,
    pub valid_end: u64,
    pub complete: bool,
    pub interrupted: bool,
    pub has_images: bool,
    pub maximum_width: f64,
    pub maximum_height: f64,
}
impl Document {
    pub fn open(path: impl AsRef<Path>, allow_partial: bool) -> Result<Self> {
        Self::open_with_cancel(path, allow_partial, &CancellationToken::new())
    }
    pub fn open_with_cancel(
        path: impl AsRef<Path>,
        allow_partial: bool,
        cancel: &CancellationToken,
    ) -> Result<Self> {
        let mut file = File::open(&path)?;
        let mut magic = [0; 8];
        file.read_exact(&mut magic)?;
        if &magic != MAGIC {
            return Err(Error::Invalid);
        }
        let first = read_event(&mut file)?.ok_or(Error::Invalid)?;
        if first.kind != Kind::Header || first.time != 0.0 {
            return Err(Error::Invalid);
        }
        let header = first.header.ok_or(Error::Invalid)?;
        header.validate()?;
        let mut d = Self {
            path: path.as_ref().to_owned(),
            header,
            duration: 0.0,
            index: vec![],
            valid_end: file.stream_position()?,
            complete: false,
            interrupted: false,
            has_images: false,
            maximum_width: 1.0,
            maximum_height: 1.0,
        };
        let mut previous = None;
        let scan = (|| -> Result<()> {
            loop {
                if cancel.is_cancelled() {
                    return Err(Error::Cancelled);
                }
                let offset = file.stream_position()?;
                let Some(event) = read_event(&mut file)? else {
                    break;
                };
                validate_time(event.time, d.duration)?;
                match event.kind {
                    Kind::Header => return Err(Error::Invalid),
                    Kind::Output => {
                        if event.output.as_ref().is_none_or(|o| o.len() > 64 * 1024) {
                            return Err(Error::Invalid);
                        }
                    }
                    Kind::Screen => {
                        let frame = event.frame.ok_or(Error::Invalid)?;
                        previous = Some(frame.applying(previous.as_ref())?);
                        if frame.changed_rows.is_none() {
                            d.index.push(IndexEntry {
                                time: event.time,
                                offset,
                            });
                        }
                        if d.index.len() > 1_000_000 {
                            return Err(Error::TooLarge);
                        }
                        d.has_images |= frame.screen.has_images;
                        d.maximum_width = d
                            .maximum_width
                            .max(frame.screen.columns as f64 * frame.appearance.cell_width);
                        d.maximum_height = d
                            .maximum_height
                            .max(frame.screen.rows as f64 * frame.appearance.cell_height);
                        if d.maximum_width * d.maximum_height > 32_000_000.0 {
                            return Err(Error::TooLarge);
                        }
                    }
                    Kind::End => {
                        if d.index.is_empty()
                            || event.index.as_ref() != Some(&d.index)
                            || file.read(&mut [0; 1])? != 0
                        {
                            return Err(Error::Invalid);
                        }
                        d.complete = true;
                        d.interrupted = event.reason.as_deref() == Some("interrupted");
                    }
                }
                d.duration = event.time;
                d.valid_end = file.stream_position()?;
                if d.complete {
                    break;
                }
            }
            Ok(())
        })();
        if matches!(scan, Err(Error::Cancelled)) {
            return Err(Error::Cancelled);
        }
        if !allow_partial {
            scan?;
        }
        if d.index.is_empty() || (!d.complete && !allow_partial) {
            return Err(Error::Invalid);
        }
        Ok(d)
    }
    /// Recover into a new file; never truncate or overwrite the source. The source's
    /// valid prefix is rescanned so a stale Document cannot bless altered bytes.
    pub fn recover(&self, destination: impl AsRef<Path>) -> Result<Document> {
        let fresh = Self::open(&self.path, true)?;
        if fresh.valid_end != self.valid_end || fresh.index != self.index {
            return Err(Error::Changed);
        }
        let mut input = File::open(&self.path)?;
        let mut out = OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&destination)?;
        std::io::copy(&mut (&mut input).take(self.valid_end), &mut out)?;
        if !self.complete {
            let mut event = Event::new(Kind::End, self.duration);
            event.index = Some(self.index.clone());
            event.reason = Some("interrupted".into());
            out.write_all(&encode_event(&event)?)?;
        }
        out.sync_all()?;
        Self::open(destination, false)
    }
}
fn validate_time(time: f64, previous: f64) -> Result<()> {
    if !time.is_finite() || time < previous || time > 365.0 * 86400.0 {
        return Err(Error::Invalid);
    }
    Ok(())
}

/// Sequential, bounded-memory writer. A caller owning a recording task should use a
/// bounded input queue (32 MiB maximum); dropping this writer leaves recoverable blocks.
pub struct Writer<W: Write + Seek> {
    output: W,
    index: Vec<IndexEntry>,
    previous: Option<Frame>,
    time: f64,
}
impl Writer<File> {
    pub fn create(path: impl AsRef<Path>, header: Header) -> Result<Self> {
        Self::new(
            OpenOptions::new().write(true).create_new(true).open(path)?,
            header,
        )
    }
}
impl<W: Write + Seek> Writer<W> {
    pub fn new(mut output: W, header: Header) -> Result<Self> {
        header.validate()?;
        if output.stream_position()? != 0 {
            return Err(Error::Invalid);
        }
        output.write_all(MAGIC)?;
        let mut event = Event::new(Kind::Header, 0.0);
        event.header = Some(header);
        output.write_all(&encode_event(&event)?)?;
        Ok(Self {
            output,
            index: vec![],
            previous: None,
            time: 0.0,
        })
    }
    pub fn output(&mut self, time: f64, data: &[u8]) -> Result<()> {
        validate_time(time, self.time)?;
        if data.len() > 64 * 1024 {
            return Err(Error::TooLarge);
        }
        let mut event = Event::new(Kind::Output, time);
        event.output = Some(data.to_vec());
        self.output.write_all(&encode_event(&event)?)?;
        self.time = time;
        Ok(())
    }
    pub fn screen(&mut self, time: f64, frame: Frame) -> Result<()> {
        validate_time(time, self.time)?;
        let full = frame.applying(self.previous.as_ref())?;
        if frame.screen.columns as f64
            * frame.appearance.cell_width
            * frame.screen.rows as f64
            * frame.appearance.cell_height
            > 32_000_000.0
        {
            return Err(Error::TooLarge);
        }
        let offset = self.output.stream_position()?;
        let keyframe = frame.changed_rows.is_none();
        if keyframe && self.index.len() >= 1_000_000 {
            return Err(Error::TooLarge);
        }
        let mut event = Event::new(Kind::Screen, time);
        event.frame = Some(frame);
        self.output.write_all(&encode_event(&event)?)?;
        if keyframe {
            self.index.push(IndexEntry { time, offset });
        }
        self.previous = Some(full);
        self.time = time;
        Ok(())
    }
    pub fn flush(&mut self) -> Result<()> {
        self.output.flush()?;
        Ok(())
    }
    pub fn finish(mut self, time: f64, reason: Option<String>) -> Result<W> {
        validate_time(time, self.time)?;
        if self.index.is_empty() {
            return Err(Error::Invalid);
        }
        let mut event = Event::new(Kind::End, time);
        event.index = Some(self.index);
        event.reason = reason;
        self.output.write_all(&encode_event(&event)?)?;
        self.output.flush()?;
        Ok(self.output)
    }
}

pub struct Cursor {
    pub document: Document,
    file: File,
    pending: Option<Event>,
    frame: Option<Frame>,
    time: f64,
    last_event_time: f64,
}
impl Cursor {
    pub fn new(document: Document) -> Result<Self> {
        let file = File::open(&document.path)?;
        Ok(Self {
            document,
            file,
            pending: None,
            frame: None,
            time: -1.0,
            last_event_time: 0.0,
        })
    }
    pub fn seek(&mut self, requested: f64) -> Result<Frame> {
        self.seek_with_cancel(requested, &CancellationToken::new())
    }
    pub fn seek_with_cancel(
        &mut self,
        requested: f64,
        cancel: &CancellationToken,
    ) -> Result<Frame> {
        if !requested.is_finite() {
            return Err(Error::Invalid);
        }
        let target = requested.clamp(0.0, self.document.duration);
        if self.frame.is_none() || target < self.time || target - self.time > 5.0 {
            let pos = self
                .document
                .index
                .partition_point(|e| e.time <= target)
                .saturating_sub(1);
            let entry = &self.document.index[pos];
            self.file.seek(SeekFrom::Start(entry.offset))?;
            self.pending = None;
            self.frame = None;
            self.last_event_time = entry.time;
        }
        loop {
            if cancel.is_cancelled() {
                return Err(Error::Cancelled);
            }
            if self.pending.is_none() && self.file.stream_position()? < self.document.valid_end {
                self.pending = read_event(&mut self.file)?;
            }
            if self.pending.as_ref().is_none_or(|e| e.time > target) {
                break;
            }
            let next = self.pending.take().unwrap();
            validate_time(next.time, self.last_event_time)?;
            self.last_event_time = next.time;
            if next.kind == Kind::Screen {
                self.frame = Some(
                    next.frame
                        .ok_or(Error::Invalid)?
                        .applying(self.frame.as_ref())?,
                );
            }
        }
        self.time = target;
        self.frame.clone().ok_or(Error::Invalid)
    }
    pub fn next_activity(&mut self, target: f64) -> Result<Option<f64>> {
        let offset = self.file.stream_position()?;
        let result = (|| -> Result<Option<f64>> {
            if let Some(e) = &self.pending {
                if e.time > target && e.kind == Kind::Output {
                    return Ok(Some(e.time));
                }
            }
            while self.file.stream_position()? < self.document.valid_end {
                let Some(e) = read_event(&mut self.file)? else {
                    return Ok(None);
                };
                if e.kind == Kind::Output && e.time > target {
                    return Ok(Some(e.time));
                }
            }
            Ok(None)
        })();
        self.file.seek(SeekFrom::Start(offset))?;
        result
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn frame() -> Frame {
        Frame {
            appearance: Appearance {
                font_name: "Consolas".into(),
                font_size: 14.0,
                cell_width: 8.0,
                cell_height: 16.0,
            },
            changed_rows: None,
            screen: Snapshot {
                columns: 2,
                rows: 1,
                lines: vec![Line {
                    mode: 0,
                    cells: vec![
                        Cell {
                            text: "中".into(),
                            width: 2,
                            foreground: 0xffffff,
                            background: 0,
                            style: 0,
                            underline: None,
                        },
                        Cell {
                            text: "".into(),
                            width: 0,
                            foreground: 0xffffff,
                            background: 0,
                            style: 0,
                            underline: None,
                        },
                    ],
                }],
                cursor_column: 2,
                cursor_row: 0,
                cursor_visible: true,
                cursor_style: "steadyBlock".into(),
                foreground: 0xffffff,
                background: 0,
                has_images: false,
            },
        }
    }
    #[test]
    fn recording_roundtrip_and_read_only_seek() {
        let d = tempfile::tempdir().unwrap();
        let path = d.path().join("a.sdrec");
        let mut w = Writer::create(&path, Header::new("test".into())).unwrap();
        w.screen(0.0, frame()).unwrap();
        w.output(1.0, b"\x1b]52;c;YXR0YWNr\x07").unwrap();
        let mut delta = frame();
        delta.changed_rows = Some(vec![0]);
        delta.screen.lines[0].cells[0].text = "文".into();
        w.screen(2.0, delta).unwrap();
        w.finish(3.0, None).unwrap();
        let doc = Document::open(&path, false).unwrap();
        assert_eq!(doc.duration, 3.0);
        let mut cursor = Cursor::new(doc).unwrap();
        assert_eq!(
            cursor.seek(2.5).unwrap().screen.lines[0].cells[0].text,
            "文"
        );
        assert_eq!(cursor.seek(0.0).unwrap(), frame());
        assert_eq!(cursor.next_activity(0.0).unwrap(), Some(1.0));
    }
    #[test]
    fn partial_and_corruption_recovery() {
        let d = tempfile::tempdir().unwrap();
        let path = d.path().join("a.partial");
        {
            let mut w = Writer::create(&path, Header::new("test".into())).unwrap();
            w.screen(0.0, frame()).unwrap();
            w.flush().unwrap();
        }
        OpenOptions::new()
            .append(true)
            .open(&path)
            .unwrap()
            .write_all(b"incomplete")
            .unwrap();
        assert!(Document::open(&path, false).is_err());
        let doc = Document::open(&path, true).unwrap();
        assert!(!doc.complete);
        let recovered = doc.recover(d.path().join("a.sdrec")).unwrap();
        assert!(recovered.complete && recovered.interrupted);
    }
    #[test]
    fn invalid_dimensions_delta_and_bomb() {
        let mut f = frame();
        f.changed_rows = Some(vec![0]);
        assert!(f.applying(None).is_err());
        f.screen.columns = i32::MAX;
        assert!(f.validate().is_err());
        let mut e = Event::new(Kind::Output, 0.0);
        e.output = Some(vec![0; 1024]);
        let mut data = encode_event(&e).unwrap();
        data[4..8].copy_from_slice(&1u32.to_le_bytes());
        assert!(read_event(&mut std::io::Cursor::new(data)).is_err());
    }
}
