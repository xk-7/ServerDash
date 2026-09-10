//! Provider translation compatible with AIProviderAdapter.swift. Keys remain in request
//! headers, redirects are disabled, and hidden reasoning is never emitted to the caller.
use crate::{Error, Result};
use futures_util::StreamExt;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::time::Duration;
use tokio_util::sync::CancellationToken;
use url::Url;

pub const EVENT_LIMIT: usize = 256 * 1024;
pub const RESPONSE_LIMIT: usize = 2 * 1024 * 1024;

#[derive(Clone, Copy, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub enum Provider {
    #[serde(rename = "openAI")]
    OpenAI,
    #[serde(rename = "anthropic")]
    Anthropic,
    #[serde(rename = "gemini")]
    Gemini,
    #[serde(rename = "deepSeek")]
    DeepSeek,
    #[serde(rename = "qwen")]
    Qwen,
    #[serde(rename = "volcengine")]
    Volcengine,
    #[serde(rename = "ollama")]
    Ollama,
    #[serde(rename = "custom")]
    Custom,
}
impl Provider {
    pub const ALL: [Self; 8] = [
        Self::OpenAI,
        Self::Anthropic,
        Self::Gemini,
        Self::DeepSeek,
        Self::Qwen,
        Self::Volcengine,
        Self::Ollama,
        Self::Custom,
    ];
    pub fn default_url(self) -> &'static str {
        match self {
            Self::OpenAI => "https://api.openai.com/v1",
            Self::Anthropic => "https://api.anthropic.com/v1",
            Self::Gemini => "https://generativelanguage.googleapis.com/v1beta",
            Self::DeepSeek => "https://api.deepseek.com/v1",
            Self::Qwen => "https://dashscope.aliyuncs.com/compatible-mode/v1",
            Self::Volcengine => "https://ark.cn-beijing.volces.com/api/v3",
            Self::Ollama => "http://localhost:11434",
            Self::Custom => "https://api.example.com/v1",
        }
    }
    pub fn requires_key(self) -> bool {
        !matches!(self, Self::Ollama | Self::Custom)
    }
}
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Options {
    pub temperature: Option<f64>,
    pub max_tokens: Option<u32>,
    pub history_messages: usize,
}
impl Default for Options {
    fn default() -> Self {
        Self {
            temperature: None,
            max_tokens: Some(4096),
            history_messages: 20,
        }
    }
}
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Profile {
    pub provider: Provider,
    #[serde(rename = "baseURL")]
    pub base_url: String,
    pub model: String,
    #[serde(default)]
    pub options: Options,
}
impl Profile {
    pub fn new(provider: Provider) -> Self {
        Self {
            provider,
            base_url: provider.default_url().into(),
            model: String::new(),
            options: Options::default(),
        }
    }
    pub fn base_url(&self) -> Result<Url> {
        let text = self.base_url.trim();
        if text.chars().any(char::is_control) {
            return Err(Error::Configuration);
        }
        let url = Url::parse(text).map_err(|_| Error::Configuration)?;
        let local = matches!(
            url.host_str(),
            Some("localhost" | "127.0.0.1" | "[::1]" | "::1")
        );
        if url.host_str().is_none()
            || !url.username().is_empty()
            || url.password().is_some()
            || url.query().is_some()
            || url.fragment().is_some()
            || !(url.scheme() == "https" || (url.scheme() == "http" && local))
        {
            return Err(Error::Configuration);
        }
        Ok(url)
    }
    pub fn temperature_maximum(&self) -> Option<f64> {
        let model = self.model.to_lowercase();
        if self.provider == Provider::OpenAI
            && ["o1", "o3", "o4", "gpt-5", "gpt-6"]
                .iter()
                .any(|p| model.starts_with(p))
        {
            return None;
        }
        if self.provider == Provider::DeepSeek
            && (model.contains("reasoner") || model.contains("thinking"))
        {
            return None;
        }
        if self.provider == Provider::Anthropic {
            let legacy = [
                "claude-3",
                "claude-sonnet-4-",
                "claude-opus-4-",
                "claude-haiku-4-",
                "claude-sonnet-4",
                "claude-opus-4",
            ]
            .iter()
            .any(|p| model.starts_with(p));
            let newer = [
                "-4-6", "-4-7", "-4-8", "-4-9", "-4.6", "-4.7", "-4.8", "-4.9",
            ]
            .iter()
            .any(|p| {
                model.match_indices(p).any(|(i, _)| {
                    model
                        .as_bytes()
                        .get(i + p.len())
                        .is_none_or(|c| !c.is_ascii_digit())
                })
            });
            return if legacy && !newer { Some(1.0) } else { None };
        }
        Some(2.0)
    }
    pub fn validate(&self, require_model: bool) -> Result<()> {
        self.base_url()?;
        if require_model
            && (self.model.trim().is_empty()
                || self.model.len() > 256
                || self.model.chars().any(char::is_control))
        {
            return Err(Error::Configuration);
        }
        if !(1..=50).contains(&self.options.history_messages)
            || self
                .options
                .max_tokens
                .is_some_and(|n| n == 0 || n > i32::MAX as u32)
            || (self.provider == Provider::Anthropic && self.options.max_tokens.is_none())
        {
            return Err(Error::Configuration);
        }
        if let Some(t) = self.options.temperature {
            if !t.is_finite() || t < 0.0 || self.temperature_maximum().is_none_or(|m| t > m) {
                return Err(Error::Configuration);
            }
        }
        Ok(())
    }
}
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Message {
    pub role: String,
    pub content: String,
}
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub enum FinishReason {
    Complete,
    OutputLimit,
    Refused,
    Unsupported,
}
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
#[serde(tag = "type", content = "value", rename_all = "camelCase")]
pub enum StreamEvent {
    Text(String),
    Finished(FinishReason),
}

fn client() -> Result<reqwest::Client> {
    reqwest::Client::builder()
        .redirect(reqwest::redirect::Policy::none())
        .connect_timeout(Duration::from_secs(30))
        .read_timeout(Duration::from_secs(60))
        .timeout(Duration::from_secs(300))
        .build()
        .map_err(|_| Error::Network)
}
fn append_path(mut url: Url, path: &str) -> Url {
    url.set_path(&format!("{}/{}", url.path().trim_end_matches('/'), path));
    url
}
fn authorize(
    request: reqwest::RequestBuilder,
    provider: Provider,
    key: &str,
) -> Result<reqwest::RequestBuilder> {
    if key.chars().any(char::is_control) || (provider.requires_key() && key.is_empty()) {
        return Err(Error::Configuration);
    }
    let request = if provider == Provider::Anthropic {
        request.header("anthropic-version", "2023-06-01")
    } else {
        request
    };
    if key.is_empty() {
        return Ok(request);
    }
    Ok(match provider {
        Provider::Anthropic => request.header("x-api-key", key),
        Provider::Gemini => request.header("x-goog-api-key", key),
        _ => request.bearer_auth(key),
    })
}
pub fn build_request(
    profile: &Profile,
    key: &str,
    messages: &[Message],
) -> Result<reqwest::Request> {
    profile.validate(true)?;
    if messages
        .iter()
        .any(|m| !["user", "system", "assistant"].contains(&m.role.as_str()))
    {
        return Err(Error::Configuration);
    }
    let provider = profile.provider;
    let system = messages
        .iter()
        .filter(|m| m.role == "system")
        .map(|m| m.content.as_str())
        .collect::<Vec<_>>()
        .join("\n");
    let conversation: Vec<_> = messages.iter().filter(|m| m.role != "system").collect();
    let mut url = profile.base_url()?;
    let mut payload = match provider {
        Provider::Anthropic => {
            url = append_path(url, "messages");
            let mut p = json!({"model":profile.model,"messages":conversation,"stream":true,"max_tokens":profile.options.max_tokens.unwrap_or(4096)});
            if !system.is_empty() {
                p["system"] = json!(system);
            }
            if let Some(t) = profile.options.temperature {
                p["temperature"] = json!(t);
            }
            p
        }
        Provider::Gemini => {
            let model = profile
                .model
                .strip_prefix("models/")
                .unwrap_or(&profile.model);
            if model.is_empty()
                || !model
                    .bytes()
                    .all(|b| b.is_ascii_alphanumeric() || b"-_.".contains(&b))
            {
                return Err(Error::Configuration);
            }
            url = append_path(url, &format!("models/{model}:streamGenerateContent"));
            url.set_query(Some("alt=sse"));
            let contents: Vec<_>=conversation.iter().map(|m| json!({"role":if m.role=="assistant" {"model"} else {"user"},"parts":[{"text":m.content}]})).collect();
            let mut p = json!({"contents":contents});
            if !system.is_empty() {
                p["systemInstruction"] = json!({"parts":[{"text":system}]});
            }
            let mut options = serde_json::Map::new();
            if let Some(t) = profile.options.temperature {
                options.insert("temperature".into(), json!(t));
            }
            if let Some(n) = profile.options.max_tokens {
                options.insert("maxOutputTokens".into(), json!(n));
            }
            if !options.is_empty() {
                p["generationConfig"] = Value::Object(options);
            }
            p
        }
        Provider::Ollama => {
            url = append_path(url, "api/chat");
            let mut p = json!({"model":profile.model,"messages":messages,"stream":true});
            let mut options = serde_json::Map::new();
            if let Some(t) = profile.options.temperature {
                options.insert("temperature".into(), json!(t));
            }
            if let Some(n) = profile.options.max_tokens {
                options.insert("num_predict".into(), json!(n));
            }
            if !options.is_empty() {
                p["options"] = Value::Object(options);
            }
            p
        }
        _ => {
            url = append_path(url, "chat/completions");
            let reasoning = provider == Provider::OpenAI && profile.temperature_maximum().is_none();
            let m: Vec<_>=messages.iter().map(|m|json!({"role":if reasoning && m.role=="system" {"developer"} else {&m.role},"content":m.content})).collect();
            let mut p = json!({"model":profile.model,"messages":m,"stream":true});
            if provider == Provider::OpenAI {
                p["store"] = json!(false);
            }
            if let Some(t) = profile.options.temperature {
                p["temperature"] = json!(t);
            }
            if let Some(n) = profile.options.max_tokens {
                p[if provider == Provider::OpenAI {
                    "max_completion_tokens"
                } else {
                    "max_tokens"
                }] = json!(n);
            }
            p
        }
    };
    let body = serde_json::to_vec(&payload)?;
    // Do not retain a second copy of the conversation in the request builder.
    payload = Value::Null;
    drop(payload);
    if body.len() > EVENT_LIMIT {
        return Err(Error::TooLarge);
    }
    authorize(client()?.post(url), provider, key)?
        .header("Content-Type", "application/json")
        .header(
            "Accept",
            if provider == Provider::Ollama {
                "application/x-ndjson"
            } else {
                "text/event-stream"
            },
        )
        .body(body)
        .build()
        .map_err(|_| Error::Configuration)
}

/// The callback runs synchronously for each chunk and can fail to cancel delivery, e.g.
/// when its original connection generation or conversation destination has changed.
pub async fn stream_chat(
    profile: &Profile,
    key: &str,
    messages: &[Message],
    cancel: &CancellationToken,
    mut emit: impl FnMut(StreamEvent) -> Result<()> + Send,
) -> Result<()> {
    let request = build_request(profile, key, messages)?;
    let response = tokio::select! {biased; _=cancel.cancelled()=>return Err(Error::Cancelled), r=client()?.execute(request)=>r.map_err(|_|Error::Network)?};
    if !response.status().is_success() {
        return Err(Error::Http(response.status().as_u16()));
    }
    if response
        .content_length()
        .is_some_and(|n| n > RESPONSE_LIMIT as u64)
    {
        return Err(Error::TooLarge);
    }
    let mut stream = response.bytes_stream();
    let mut decoder = StreamDecoder::new(profile.provider);
    while !decoder.done() {
        let chunk = tokio::select! {biased; _=cancel.cancelled()=>return Err(Error::Cancelled), c=stream.next()=>c};
        match chunk {
            Some(Ok(bytes)) => {
                for event in decoder.receive(&bytes)? {
                    emit(event)?;
                }
            }
            Some(Err(_)) => return Err(Error::Network),
            None => break,
        }
    }
    for event in decoder.finish()? {
        emit(event)?;
    }
    Ok(())
}

pub struct StreamDecoder {
    provider: Provider,
    line: Vec<u8>,
    event: Vec<u8>,
    total: usize,
    reason: Option<FinishReason>,
    text_received: bool,
    done: bool,
}
impl StreamDecoder {
    pub fn new(provider: Provider) -> Self {
        Self {
            provider,
            line: vec![],
            event: vec![],
            total: 0,
            reason: None,
            text_received: false,
            done: false,
        }
    }
    pub fn done(&self) -> bool {
        self.done
    }
    pub fn receive(&mut self, bytes: &[u8]) -> Result<Vec<StreamEvent>> {
        self.total = self.total.checked_add(bytes.len()).ok_or(Error::TooLarge)?;
        if self.total > RESPONSE_LIMIT {
            return Err(Error::TooLarge);
        }
        let mut events = vec![];
        for &b in bytes {
            if self.done {
                break;
            }
            if b == b'\n' {
                if self.line.last() == Some(&b'\r') {
                    self.line.pop();
                }
                if self.provider == Provider::Ollama {
                    if !self.line.is_empty() {
                        let data = std::mem::take(&mut self.line);
                        self.consume(&data, &mut events)?;
                    }
                } else if self.line.is_empty() {
                    if !self.event.is_empty() {
                        let data = std::mem::take(&mut self.event);
                        self.consume(&data, &mut events)?;
                    }
                } else if let Some(data) = self.line.strip_prefix(b"data:") {
                    let data = data.strip_prefix(b" ").unwrap_or(data);
                    if !self.event.is_empty() {
                        self.event.push(b'\n');
                    }
                    self.event.extend_from_slice(data);
                    if self.event.len() > EVENT_LIMIT {
                        return Err(Error::TooLarge);
                    }
                }
                self.line.clear();
            } else {
                self.line.push(b);
                if self.line.len() > EVENT_LIMIT {
                    return Err(Error::TooLarge);
                }
            }
        }
        Ok(events)
    }
    pub fn finish(&mut self) -> Result<Vec<StreamEvent>> {
        let mut events = vec![];
        if self.provider == Provider::Ollama && !self.done && !self.line.is_empty() {
            let data = std::mem::take(&mut self.line);
            self.consume(&data, &mut events)?;
        }
        if !self.done {
            return Err(Error::IncompleteStream);
        }
        Ok(events)
    }
    fn complete(&mut self, events: &mut Vec<StreamEvent>) -> Result<()> {
        let reason = self.reason.clone().ok_or(Error::IncompleteStream)?;
        if !self.text_received && reason == FinishReason::Complete {
            return Err(Error::IncompleteStream);
        }
        self.done = true;
        events.push(StreamEvent::Finished(reason));
        Ok(())
    }
    fn consume(&mut self, data: &[u8], events: &mut Vec<StreamEvent>) -> Result<()> {
        if data == b"[DONE]" {
            if matches!(
                self.provider,
                Provider::Anthropic | Provider::Gemini | Provider::Ollama
            ) {
                return Err(Error::IncompleteStream);
            }
            return self.complete(events);
        }
        let j: Value = serde_json::from_slice(data)?;
        if !j.is_object() || j.get("error").is_some() {
            return Err(Error::Invalid);
        }
        let mut text = None;
        let mut terminal = false;
        match self.provider {
            Provider::Anthropic => {
                let t = j["type"].as_str().ok_or(Error::Invalid)?;
                if t == "error" {
                    return Err(Error::Invalid);
                }
                if t == "content_block_delta" && j["delta"]["type"] == "text_delta" {
                    text = j["delta"]["text"].as_str().map(str::to_owned);
                }
                if t == "message_delta" {
                    if let Some(s) = j["delta"]["stop_reason"].as_str() {
                        self.reason = Some(map_reason(s));
                    }
                }
                terminal = t == "message_stop";
            }
            Provider::Gemini => {
                if j["promptFeedback"].get("blockReason").is_some() {
                    self.reason = Some(FinishReason::Refused);
                    terminal = true;
                }
                if let Some(c) = j["candidates"]
                    .as_array()
                    .and_then(|cs| cs.iter().find(|c| c["index"].as_i64().unwrap_or(0) == 0))
                {
                    text = c["content"]["parts"].as_array().map(|ps| {
                        ps.iter()
                            .filter(|p| p["thought"] != true)
                            .filter_map(|p| p["text"].as_str())
                            .collect::<String>()
                    });
                    if let Some(s) = c["finishReason"].as_str() {
                        self.reason = Some(map_reason(s));
                        terminal = true;
                    }
                }
            }
            Provider::Ollama => {
                text = j["message"]["content"].as_str().map(str::to_owned);
                if j["done"] == true {
                    self.reason = Some(map_reason(j["done_reason"].as_str().unwrap_or("stop")));
                    terminal = true;
                }
            }
            _ => {
                let choices = j["choices"].as_array().ok_or(Error::Invalid)?;
                if let Some(c) = choices.iter().find(|c| c["index"].as_i64() == Some(0)) {
                    text = c["delta"]["content"].as_str().map(str::to_owned);
                    if let Some(r) = c["delta"]["refusal"].as_str().filter(|s| !s.is_empty()) {
                        text = Some(r.to_owned());
                        self.reason = Some(FinishReason::Refused);
                    }
                    if self.reason != Some(FinishReason::Refused) {
                        if let Some(s) = c["finish_reason"].as_str() {
                            self.reason = Some(map_reason(s));
                        }
                    }
                }
            }
        }
        if let Some(t) = text.filter(|s| !s.is_empty()) {
            self.text_received = true;
            events.push(StreamEvent::Text(t));
        }
        if terminal {
            self.complete(events)?;
        }
        Ok(())
    }
}
fn map_reason(s: &str) -> FinishReason {
    match s {
        "stop" | "end_turn" | "stop_sequence" | "STOP" => FinishReason::Complete,
        "length" | "max_tokens" | "MAX_TOKENS" => FinishReason::OutputLimit,
        "content_filter" | "refusal" | "SAFETY" | "RECITATION" | "BLOCKLIST"
        | "PROHIBITED_CONTENT" | "SPII" => FinishReason::Refused,
        _ => FinishReason::Unsupported,
    }
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Model {
    pub id: String,
    pub name: String,
    pub max_output_tokens: Option<u32>,
    pub max_temperature: Option<f64>,
}
pub fn decode_models(provider: Provider, data: &[u8]) -> Result<(Vec<Model>, Option<String>)> {
    if data.len() > 4 * 1024 * 1024 {
        return Err(Error::TooLarge);
    }
    let j: Value = serde_json::from_slice(data)?;
    let records = match provider {
        Provider::Ollama | Provider::Gemini => &j["models"],
        Provider::Qwen => &j["output"]["models"],
        _ => &j["data"],
    }
    .as_array()
    .ok_or(Error::Invalid)?;
    if records.len() > 10_000 {
        return Err(Error::TooLarge);
    }
    let mut models = vec![];
    for item in records {
        if provider == Provider::Gemini
            && !item["supportedGenerationMethods"]
                .as_array()
                .is_some_and(|a| a.contains(&json!("generateContent")))
        {
            continue;
        }
        if provider == Provider::Qwen
            && item["capabilities"]
                .as_array()
                .is_some_and(|a| !a.contains(&json!("TG")))
        {
            continue;
        }
        let id = item[match provider {
            Provider::Gemini | Provider::Ollama => "name",
            Provider::Qwen => "model",
            _ => "id",
        }]
        .as_str()
        .unwrap_or("");
        let id = if provider == Provider::Gemini {
            id.strip_prefix("models/").unwrap_or(id)
        } else {
            id
        };
        if id.is_empty() || id.len() > 256 || id.chars().any(char::is_control) {
            continue;
        }
        let name = ["display_name", "displayName", "name"]
            .iter()
            .find_map(|k| item[*k].as_str())
            .unwrap_or(id)
            .chars()
            .take(256)
            .collect();
        models.push(Model {
            id: id.to_owned(),
            name,
            max_output_tokens: item["max_tokens"]
                .as_u64()
                .or_else(|| item["outputTokenLimit"].as_u64())
                .filter(|n| *n > 0 && *n <= u32::MAX as u64)
                .map(|n| n as u32),
            max_temperature: item["maxTemperature"].as_f64(),
        });
    }
    let mut next = None;
    if provider == Provider::Anthropic && j["has_more"] == true {
        next = Some(j["last_id"].as_str().ok_or(Error::Invalid)?.to_owned());
    }
    if provider == Provider::Gemini {
        next = j["nextPageToken"].as_str().map(str::to_owned);
    }
    if provider == Provider::Qwen {
        if let (Some(p), Some(s), Some(t)) = (
            j["output"]["page_no"].as_u64(),
            j["output"]["page_size"].as_u64(),
            j["output"]["total"].as_u64(),
        ) {
            if p > 0 && p < 100 && s > 0 && s <= 10_000 && t > p * s {
                next = Some((p + 1).to_string());
            }
        }
    }
    Ok((models, next))
}
pub async fn list_models(
    profile: &Profile,
    key: &str,
    cancel: &CancellationToken,
) -> Result<Vec<Model>> {
    use std::collections::{BTreeMap, BTreeSet};
    profile.validate(false)?;
    if profile.provider == Provider::Volcengine {
        return Err(Error::Configuration);
    }
    let client = client()?;
    let mut models = BTreeMap::new();
    let mut visited = BTreeSet::new();
    let mut cursor: Option<String> = None;
    for _ in 0..100 {
        let mut url = profile.base_url()?;
        match profile.provider {
            Provider::Ollama => url = append_path(url, "api/tags"),
            Provider::Qwen => {
                if !url
                    .path()
                    .trim_end_matches('/')
                    .ends_with("/compatible-mode/v1")
                {
                    return Err(Error::Configuration);
                }
                url.set_path(&format!(
                    "{}/api/v1/models",
                    url.path()
                        .trim_end_matches('/')
                        .trim_end_matches("/compatible-mode/v1")
                ));
                url.query_pairs_mut()
                    .append_pair("page_size", "100")
                    .append_pair("page_no", cursor.as_deref().unwrap_or("1"))
                    .append_pair("capabilities", "TG");
            }
            Provider::Anthropic => {
                url = append_path(url, "models");
                url.query_pairs_mut().append_pair("limit", "100");
                if let Some(c) = &cursor {
                    url.query_pairs_mut().append_pair("after_id", c);
                }
            }
            Provider::Gemini => {
                url = append_path(url, "models");
                url.query_pairs_mut().append_pair("pageSize", "100");
                if let Some(c) = &cursor {
                    url.query_pairs_mut().append_pair("pageToken", c);
                }
            }
            _ => url = append_path(url, "models"),
        }
        let request =
            authorize(client.get(url), profile.provider, key)?.header("Accept", "application/json");
        let response = tokio::select! {biased;_=cancel.cancelled()=>return Err(Error::Cancelled),r=request.send()=>r.map_err(|_|Error::Network)?};
        if !response.status().is_success() {
            return Err(Error::Http(response.status().as_u16()));
        }
        let mut stream = response.bytes_stream();
        let mut data = vec![];
        loop {
            let chunk = tokio::select! {biased;_=cancel.cancelled()=>return Err(Error::Cancelled),r=stream.next()=>r};
            match chunk {
                Some(Ok(c)) if data.len() + c.len() <= 4 * 1024 * 1024 => {
                    data.extend_from_slice(&c)
                }
                Some(Ok(_)) => return Err(Error::TooLarge),
                Some(Err(_)) => return Err(Error::Network),
                None => break,
            }
        }
        let (page, next) = decode_models(profile.provider, &data)?;
        for model in page {
            models.insert(model.id.clone(), model);
        }
        if models.len() > 10_000 {
            return Err(Error::TooLarge);
        }
        match next.filter(|s| !s.is_empty()) {
            None => return Ok(models.into_values().collect()),
            Some(n) => {
                if n.len() > 2048 || !visited.insert(n.clone()) {
                    return Err(Error::Invalid);
                }
                cursor = Some(n);
            }
        }
    }
    Err(Error::TooLarge)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn fragmented_utf8_and_reasoning_are_safe() {
        let mut d = StreamDecoder::new(Provider::OpenAI);
        let wire="data: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\"你好\",\"reasoning_content\":\"secret\"},\"finish_reason\":null}]}\r\n\r\ndata: {\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"stop\"}]}\n\ndata: [DONE]\n\n";
        let mut out = vec![];
        for b in wire.as_bytes() {
            out.extend(d.receive(&[*b]).unwrap());
        }
        d.finish().unwrap();
        assert_eq!(
            out,
            vec![
                StreamEvent::Text("你好".into()),
                StreamEvent::Finished(FinishReason::Complete)
            ]
        );
    }
    #[test]
    fn incomplete_and_limits() {
        let mut d = StreamDecoder::new(Provider::Custom);
        assert!(d.receive(b"data: [DONE]\n\n").is_err());
        let mut d = StreamDecoder::new(Provider::Ollama);
        assert!(d.receive(&vec![b'x'; EVENT_LIMIT + 1]).is_err());
    }
    #[test]
    fn native_provider_finishes() {
        for (p,data) in [(Provider::Anthropic,"data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"max_tokens\"}}\n\ndata: {\"type\":\"message_stop\"}\n\n"),(Provider::Gemini,"data: {\"promptFeedback\":{\"blockReason\":\"SAFETY\"}}\n\n"),(Provider::Ollama,"{\"message\":{\"content\":\"ok\"},\"done\":true}\n")]{let mut d=StreamDecoder::new(p);assert!(!d.receive(data.as_bytes()).unwrap().is_empty());d.finish().unwrap();}
    }
    #[test]
    fn all_requests_match_protocols() {
        for provider in Provider::ALL {
            let mut p = Profile::new(provider);
            p.model = "test-model".into();
            let r = build_request(
                &p,
                "test-key",
                &[
                    Message {
                        role: "system".into(),
                        content: "help".into(),
                    },
                    Message {
                        role: "user".into(),
                        content: "hi".into(),
                    },
                ],
            )
            .unwrap();
            assert_eq!(r.method(), reqwest::Method::POST);
            assert!(!r.url().as_str().contains("test-key"));
            assert!(r.body().unwrap().as_bytes().unwrap().len() < EVENT_LIMIT);
        }
    }
    #[test]
    fn endpoint_validation() {
        let mut p = Profile::new(Provider::Custom);
        p.model = "x".into();
        for url in [
            "http://example.com/v1",
            "https://u:p@example.com",
            "https://example.com?key=x",
            "https://example.com/#x",
        ] {
            p.base_url = url.into();
            assert!(p.validate(true).is_err());
        }
        p.base_url = "http://[::1]:11434".into();
        p.validate(true).unwrap();
    }
}
