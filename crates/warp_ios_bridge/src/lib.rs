uniffi::include_scaffolding!("warp_ios_bridge");

use ai_terminal_runtime::{CommandExecutionMetadata, CommandRegistry, ExecutionSource};
use async_trait::async_trait;
use once_cell::sync::Lazy;
use russh::client::{self, Handle};
use serde::Deserialize;
use std::borrow::Cow;
use std::collections::VecDeque;
use std::iter::Peekable;
use std::mem;
use std::str::Chars;
use std::sync::{Arc, Mutex as StdMutex};
use std::time::Duration;
use tokio::runtime::Runtime;
use tokio::sync::{mpsc, oneshot};

// Single global multi-thread Tokio runtime.  UniFFI 0.28's tokio feature only
// provides waker bridging — it does NOT start a reactor.  All async SSH work
// must be executed on this runtime so Tokio I/O primitives are available.
static RUNTIME: Lazy<Runtime> = Lazy::new(|| {
    tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .build()
        .expect("Failed to create Tokio runtime")
});

const ONE_OFF_SHELL_COMMAND_KEYWORDS: &[&str] =
    &["#", "echo", "man", "sudo", "claude", "codex", "gemini"];
const ONE_OFF_NATURAL_LANGUAGE_WORDS: &[&str] =
    &["hello", "hi", "hey", "hola", "thanks", "explain", "yes", "no", "what", "nice", "1. "];
const AGENT_FOLLOW_UP_INPUTS: &[&str] = &["yes", "continue", "do it", "approve"];

const DETECT_AS_COMMAND_THRESHOLD: f32 = 0.5;
const DETECT_AS_COMMAND_LOW_TOKEN_THRESHOLD: f32 = 0.7;
const MINIMUM_COMMAND_DETECTION_TOKEN_LENGTH: usize = 2;
const MINIMUM_NATURAL_LANGUAGE_DETECTION_TOKEN_LENGTH: usize = 2;
const DETECT_AS_NATURAL_LANGUAGE_THRESHOLD: f32 = 0.6;
const DETECT_AS_NATURAL_LANGUAGE_LOW_TOKEN_THRESHOLD: f32 = 0.8;

pub struct InputIntentClassification {
    pub mode: String,
    pub source: String,
    pub confidence: f32,
}

pub async fn classify_input_intent(
    buffer_text: String,
    current_mode: String,
    is_agent_follow_up: bool,
) -> InputIntentClassification {
    let trimmed = buffer_text.trim();
    if trimmed.is_empty() {
        return InputIntentClassification {
            mode: "shell".to_string(),
            source: "EmptyInput".to_string(),
            confidence: 1.0,
        };
    }

    let lower_trimmed = trimmed.to_lowercase();
    if is_agent_follow_up && AGENT_FOLLOW_UP_INPUTS.contains(&lower_trimmed.as_str()) {
        return InputIntentClassification {
            mode: "ai".to_string(),
            source: "AgentFollowUpAllowlist".to_string(),
            confidence: 1.0,
        };
    }

    let tokens = parse_query_into_tokens(trimmed);
    if tokens.is_empty() {
        return InputIntentClassification {
            mode: "shell".to_string(),
            source: "EmptyTokens".to_string(),
            confidence: 1.0,
        };
    }

    if tokens.len() == 1
        && is_one_off_natural_language_word_or_prefix(tokens[0].to_lowercase().as_str())
    {
        return InputIntentClassification {
            mode: "ai".to_string(),
            source: "NaturalLanguageOneOffAllowlist".to_string(),
            confidence: 1.0,
        };
    }

    if is_one_off_shell_keyword(tokens[0].to_lowercase().as_str()) {
        return InputIntentClassification {
            mode: "shell".to_string(),
            source: "ShellCommandAllowList".to_string(),
            confidence: 1.0,
        };
    }

    let current_mode_is_ai = current_mode.eq_ignore_ascii_case("ai");
    let shell_heuristic = shell_heuristic_score(&tokens);
    if shell_heuristic.is_shell {
        return InputIntentClassification {
            mode: "shell".to_string(),
            source: "ShellHeuristic".to_string(),
            confidence: shell_heuristic.confidence,
        };
    }

    let natural_language = natural_language_score(&tokens, current_mode_is_ai);
    let is_ai = natural_language.score >= natural_language.threshold;
    InputIntentClassification {
        mode: if is_ai {
            "ai".to_string()
        } else {
            "shell".to_string()
        },
        source: "InputClassifierFallbackHeuristic".to_string(),
        confidence: natural_language.confidence,
    }
}

struct ShellHeuristicResult {
    is_shell: bool,
    confidence: f32,
}

struct NaturalLanguageHeuristicResult {
    score: f32,
    threshold: f32,
    confidence: f32,
}

fn shell_heuristic_score(tokens: &[String]) -> ShellHeuristicResult {
    let total = tokens.len();
    if total == 0 {
        return ShellHeuristicResult {
            is_shell: true,
            confidence: 1.0,
        };
    }

    let first_is_command = is_probable_command_token(tokens[0].as_str());
    let command_like_count = tokens
        .iter()
        .filter(|token| {
            let lowered = token.to_lowercase();
            is_probable_command_token(lowered.as_str())
                || natural_language_detection::check_if_token_has_shell_syntax(lowered.as_str())
        })
        .count();
    let threshold = if total <= 2 {
        1.0
    } else if total <= 4 {
        DETECT_AS_COMMAND_LOW_TOKEN_THRESHOLD
    } else {
        DETECT_AS_COMMAND_THRESHOLD
    };
    let ratio = command_like_count as f32 / total as f32;
    let is_shell = command_like_count >= ((total as f32 * threshold).ceil() as usize)
        || (total < 3 && first_is_command);

    ShellHeuristicResult {
        is_shell,
        confidence: ratio.clamp(0.0, 1.0).max(if is_shell { 0.7 } else { 0.0 }),
    }
}

fn natural_language_score(
    tokens: &[String],
    current_mode_is_ai: bool,
) -> NaturalLanguageHeuristicResult {
    let total = tokens.len();
    if total == 0 {
        return NaturalLanguageHeuristicResult {
            score: 0.0,
            threshold: 1.0,
            confidence: 1.0,
        };
    }

    let min_token_length = if current_mode_is_ai {
        MINIMUM_COMMAND_DETECTION_TOKEN_LENGTH
    } else {
        MINIMUM_NATURAL_LANGUAGE_DETECTION_TOKEN_LENGTH
    };
    if total < min_token_length {
        return NaturalLanguageHeuristicResult {
            score: 0.0,
            threshold: 1.0,
            confidence: 1.0,
        };
    }

    let first_is_command = is_probable_command_token(tokens[0].as_str());
    let words = tokens
        .iter()
        .map(|token| Cow::Owned(token.to_lowercase()))
        .collect::<Vec<_>>();
    let nl_word_count = natural_language_detection::natural_language_words_score(words, first_is_command);
    let score = nl_word_count as f32 / total as f32;
    let threshold = if total <= 3 {
        1.0
    } else if total <= 4 {
        DETECT_AS_NATURAL_LANGUAGE_LOW_TOKEN_THRESHOLD
    } else {
        DETECT_AS_NATURAL_LANGUAGE_THRESHOLD
    };
    let confidence = if score >= threshold {
        score
    } else {
        (1.0 - score).clamp(0.0, 1.0)
    };

    NaturalLanguageHeuristicResult {
        score,
        threshold,
        confidence: confidence.clamp(0.0, 1.0),
    }
}

fn is_probable_command_token(token: &str) -> bool {
    let lowered = token.to_lowercase();
    natural_language_detection::is_word(
        lowered.trim_matches(|c: char| c.is_ascii_punctuation()),
        natural_language_detection::WordDb::Command,
    )
}

fn is_one_off_shell_keyword(word: &str) -> bool {
    ONE_OFF_SHELL_COMMAND_KEYWORDS.contains(&word)
}

fn is_one_off_natural_language_word_or_prefix(word: &str) -> bool {
    ONE_OFF_NATURAL_LANGUAGE_WORDS.contains(&word)
        || ONE_OFF_NATURAL_LANGUAGE_WORDS
            .iter()
            .any(|natural_word| natural_word.starts_with(word))
}

fn parse_query_into_tokens(query: &str) -> Vec<String> {
    let parser = SentenceParser {
        chars: query.chars().peekable(),
        active_delimiter: None,
        active_token: String::new(),
    };

    parser.collect()
}

#[derive(PartialEq, Eq)]
enum WordDelimiter {
    Separator,
    DoubleQuote,
    SingleQuote,
    Backtick,
    Whitespace,
}

fn convert_char_to_delimiter(c: char) -> Option<WordDelimiter> {
    match c {
        '\'' => Some(WordDelimiter::SingleQuote),
        '"' => Some(WordDelimiter::DoubleQuote),
        '`' => Some(WordDelimiter::Backtick),
        ',' | '.' | '!' | '?' => Some(WordDelimiter::Separator),
        c if c.is_whitespace() => Some(WordDelimiter::Whitespace),
        _ => None,
    }
}

struct SentenceParser<'a> {
    chars: Peekable<Chars<'a>>,
    active_delimiter: Option<WordDelimiter>,
    active_token: String,
}

impl Iterator for SentenceParser<'_> {
    type Item = String;

    fn next(&mut self) -> Option<Self::Item> {
        while let Some(c) = self.chars.next() {
            let delimiter = convert_char_to_delimiter(c);
            let next_delimiter = self.chars.peek().map(|next| convert_char_to_delimiter(*next));

            match delimiter {
                Some(WordDelimiter::Whitespace) if self.active_delimiter.is_none() => {
                    if self.active_token.is_empty() {
                        continue;
                    }
                    return Some(mem::take(&mut self.active_token));
                }
                Some(WordDelimiter::Separator) if self.active_delimiter.is_none() => {
                    if self.active_token.is_empty() {
                        continue;
                    }
                    if next_delimiter
                        .map(|delim| delim == Some(WordDelimiter::Whitespace))
                        .unwrap_or(true)
                    {
                        return Some(mem::take(&mut self.active_token));
                    }
                    self.active_token.push(c);
                }
                Some(WordDelimiter::DoubleQuote) => {
                    let complete = if self.active_delimiter == Some(WordDelimiter::DoubleQuote) {
                        self.active_delimiter = None;
                        true
                    } else if !self.active_token.is_empty() || self.active_delimiter.is_some() {
                        false
                    } else {
                        self.active_delimiter = Some(WordDelimiter::DoubleQuote);
                        false
                    };
                    self.active_token.push(c);
                    if complete {
                        let token = mem::take(&mut self.active_token);
                        if token == "\"\"" {
                            continue;
                        }
                        return Some(token);
                    }
                }
                Some(WordDelimiter::SingleQuote) => {
                    let complete = if self.active_delimiter == Some(WordDelimiter::SingleQuote) {
                        self.active_delimiter = None;
                        true
                    } else if !self.active_token.is_empty() || self.active_delimiter.is_some() {
                        false
                    } else {
                        self.active_delimiter = Some(WordDelimiter::SingleQuote);
                        false
                    };
                    self.active_token.push(c);
                    if complete {
                        let token = mem::take(&mut self.active_token);
                        if token == "''" {
                            continue;
                        }
                        return Some(token);
                    }
                }
                Some(WordDelimiter::Backtick) => {
                    let complete = if self.active_delimiter == Some(WordDelimiter::Backtick) {
                        self.active_delimiter = None;
                        true
                    } else if !self.active_token.is_empty() || self.active_delimiter.is_some() {
                        false
                    } else {
                        self.active_delimiter = Some(WordDelimiter::Backtick);
                        false
                    };
                    self.active_token.push(c);
                    if complete {
                        return Some(mem::take(&mut self.active_token));
                    }
                }
                _ => self.active_token.push(c),
            }
        }

        if self.active_token.is_empty() {
            None
        } else {
            Some(mem::take(&mut self.active_token))
        }
    }
}

/// Pre-warm the Tokio runtime so the first SSH connection doesn't pay the
/// lazy-init cost (~200ms of thread spawning).
pub fn initialize_bridge() {
    let _ = RUNTIME.handle();
}

pub async fn ssh_connect_with_password(
    host: String,
    port: u16,
    username: String,
    password: String,
) -> Result<Arc<SshSession>, SshError> {
    RUNTIME
        .spawn(SshSession::connect_with_password(
            host, port, username, password,
        ))
        .await
        .map_err(|e| SshError::ConnectionFailed(e.to_string()))?
}

pub async fn ssh_connect_with_key(
    host: String,
    port: u16,
    username: String,
    private_key_pem: String,
) -> Result<Arc<SshSession>, SshError> {
    RUNTIME
        .spawn(SshSession::connect_with_key(
            host,
            port,
            username,
            private_key_pem,
        ))
        .await
        .map_err(|e| SshError::ConnectionFailed(e.to_string()))?
}

#[derive(Debug, thiserror::Error)]
pub enum SshError {
    #[error("Connection failed: {0}")]
    ConnectionFailed(String),
    #[error("Authentication failed")]
    AuthFailed,
    #[error("Channel error: {0}")]
    ChannelError(String),
    #[error("Disconnected")]
    Disconnected,
    #[error("Invalid key")]
    InvalidKey,
}

pub trait DataReceiver: Send + Sync {
    fn on_data(&self, data: Vec<u8>);
    fn on_disconnect(&self, reason: String);
}

pub trait SessionEventReceiver: Send + Sync {
    fn on_bootstrapped(&self, shell: String, fallback_mode: bool);
    fn on_preexec(&self, command: String, block_id: u64);
    fn on_ai_preexec(&self, command: String, block_id: u64, metadata_json: String);
    fn on_command_finished(&self, exit_code: i32, block_id: u64);
    fn on_precmd(&self, working_directory: String);
    fn on_output_chunk(&self, block_id: u64, data: Vec<u8>);
    fn on_history_snapshot(&self, encoded: String);
    fn on_status(&self, message: String);
}

// Tracks whether a receiver has been registered yet.  Data that arrives
// before set_receiver() is called is buffered so the initial shell prompt
// is never lost.  Once on_disconnect fires the state moves to Disconnected
// so duplicate events don't call it twice.
enum ReceiverState {
    Pending(Vec<Vec<u8>>),
    Active(Arc<dyn DataReceiver>),
    Disconnected,
}

enum EventReceiverState {
    Pending(Vec<SessionEvent>),
    Active(Arc<dyn SessionEventReceiver>),
    Disconnected,
}

/// Commands sent from Swift → session_runner over an mpsc channel.
enum SessionCmd {
    Data(Vec<u8>),
    ExecuteCommand {
        command: String,
        metadata: CommandExecutionMetadata,
        response: oneshot::Sender<Result<u64, SshError>>,
    },
    WriteToRunningCommand {
        block_id: u64,
        data: Vec<u8>,
    },
    CancelRunningCommand {
        block_id: u64,
    },
    RequestHistory(u32),
    Resize(u16, u16),
    Disconnect,
}

pub struct SshSession {
    /// Sends outgoing commands to the runner task.
    cmd_tx: mpsc::UnboundedSender<SessionCmd>,
    /// Shared receiver state; also written by set_receiver() from Swift.
    data_state: Arc<StdMutex<ReceiverState>>,
    /// Shared event receiver state for block semantics updates.
    event_state: Arc<StdMutex<EventReceiverState>>,
    /// Command lifecycle model shared with iOS AI orchestration.
    command_registry: CommandRegistry,
}

/// Minimal handler — we only need to accept the server's host key.
/// Incoming data is delivered via channel.wait() inside session_runner,
/// so we don't need to implement data() here.
struct ClientHandler;

#[async_trait]
impl client::Handler for ClientHandler {
    type Error = russh::Error;

    async fn check_server_key(
        &mut self,
        _server_public_key: &russh_keys::key::PublicKey,
    ) -> Result<bool, Self::Error> {
        Ok(true)
    }
}

/// Runs on RUNTIME for the lifetime of one SSH session.
/// Owns the channel (so no mutex needed) and drives all I/O via a select loop:
///   • outgoing commands  (keypresses, resize, explicit disconnect)
///   • incoming messages  (data, EOF, close → detect remote exit)
async fn session_runner(
    mut channel: russh::Channel<client::Msg>,
    handle: Handle<ClientHandler>,
    mut cmd_rx: mpsc::UnboundedReceiver<SessionCmd>,
    data_state: Arc<StdMutex<ReceiverState>>,
    event_state: Arc<StdMutex<EventReceiverState>>,
    command_registry: CommandRegistry,
    suppress_passthrough_until_bootstrapped: bool,
) {
    let mut warp_state = WarpSessionState::default();
    warp_state.suppress_passthrough_until_bootstrapped = suppress_passthrough_until_bootstrapped;
    let mut remote_closed = false;

    loop {
        tokio::select! {
            biased; // check outgoing commands first for low-latency typing

            cmd = cmd_rx.recv() => {
                match cmd {
                    Some(SessionCmd::Data(data)) => {
                        if channel.data(data.as_slice()).await.is_err() {
                            // Send failed — channel is already closed by the server.
                            remote_closed = true;
                            break;
                        }
                    }
                    Some(SessionCmd::ExecuteCommand {
                        command,
                        metadata,
                        response,
                    }) => {
                        let command = command.trim().to_string();
                        if command.is_empty() {
                            let _ = response.send(Err(SshError::ChannelError(
                                "cannot execute empty command".to_string(),
                            )));
                            continue;
                        }
                        let mut bytes = command.clone().into_bytes();
                        bytes.push(b'\r');
                        if channel.data(bytes.as_slice()).await.is_err() {
                            let _ = response.send(Err(SshError::Disconnected));
                            remote_closed = true;
                            break;
                        }
                        warp_state.pending_ai_exec_requests.push_back(PendingAIExecution {
                            command,
                            metadata,
                            response,
                        });
                    }
                    Some(SessionCmd::WriteToRunningCommand { block_id, data }) => {
                        if warp_state.current_block_id == Some(block_id)
                            && channel.data(data.as_slice()).await.is_err()
                        {
                            remote_closed = true;
                            break;
                        }
                    }
                    Some(SessionCmd::CancelRunningCommand { block_id }) => {
                        if warp_state.current_block_id == Some(block_id)
                            && channel.data([0x03].as_slice()).await.is_err()
                        {
                            remote_closed = true;
                            break;
                        }
                    }
                    Some(SessionCmd::RequestHistory(limit)) => {
                        let request = history_request_command(limit);
                        if channel.data(request.as_bytes()).await.is_err() {
                            remote_closed = true;
                            break;
                        }
                    }
                    Some(SessionCmd::Resize(cols, rows)) => {
                        let _ = channel.window_change(cols as u32, rows as u32, 0, 0).await;
                    }
                    // Explicit disconnect from the UI — don't fire on_disconnect.
                    Some(SessionCmd::Disconnect) | None => break,
                }
            }

            msg = channel.wait() => {
                match msg {
                    // Channel closed by server or russh internal error.
                    None => {
                        remote_closed = true;
                        break;
                    }
                    Some(russh::ChannelMsg::Data { ref data }) => {
                        handle_incoming_bytes(
                            data.as_ref().to_vec(),
                            &data_state,
                            &event_state,
                            &mut warp_state,
                            &command_registry,
                        );
                    }
                    Some(russh::ChannelMsg::ExtendedData { ref data, .. }) => {
                        // Stderr uses the same parser path as stdout.
                        handle_incoming_bytes(
                            data.as_ref().to_vec(),
                            &data_state,
                            &event_state,
                            &mut warp_state,
                            &command_registry,
                        );
                    }
                    // Server signals that the shell exited cleanly (user typed `exit`).
                    Some(russh::ChannelMsg::Eof) => {
                        remote_closed = true;
                        break;
                    }
                    Some(russh::ChannelMsg::Close) => {
                        remote_closed = true;
                        break;
                    }
                    // ExitStatus, WindowAdjusted, Success, etc. — ignore.
                    Some(_) => {}
                }
            }
        }
    }

    while let Some(pending) = warp_state.pending_ai_exec_requests.pop_front() {
        let _ = pending.response.send(Err(SshError::Disconnected));
    }

    // If the remote side closed the channel, tell Swift to dismiss the terminal.
    if remote_closed {
        let mut st = data_state.lock().unwrap();
        if let ReceiverState::Active(rx) = &*st {
            rx.on_disconnect("session ended".to_string());
            *st = ReceiverState::Disconnected;
        } else {
            *st = ReceiverState::Disconnected;
        }

        let mut event_st = event_state.lock().unwrap();
        *event_st = EventReceiverState::Disconnected;
    }

    // Best-effort SSH-level disconnect (no-op if server already closed).
    let _ = handle
        .disconnect(russh::Disconnect::ByApplication, "", "English")
        .await;
}

// Terminal modes:
// - VERASE=0x08 so iOS backspace can use classic ^H semantics.
// - ECHO/ECHOE=1 so erased chars redraw immediately at an interactive prompt.
const PTY_MODES: &[(russh::Pty, u32)] = &[
    (russh::Pty::VERASE, 8),
    (russh::Pty::ECHO, 1),
    (russh::Pty::ECHOE, 1),
];

#[derive(Clone)]
enum SessionEvent {
    Bootstrapped { shell: String, fallback_mode: bool },
    Preexec { command: String, block_id: u64 },
    AIPreexec {
        command: String,
        block_id: u64,
        metadata_json: String,
    },
    CommandFinished { exit_code: i32, block_id: u64 },
    Precmd { working_directory: String },
    OutputChunk { block_id: u64, data: Vec<u8> },
    HistorySnapshot { encoded: String },
    Status { message: String },
}

impl SessionEvent {
    fn emit(self, receiver: &dyn SessionEventReceiver) {
        match self {
            SessionEvent::Bootstrapped {
                shell,
                fallback_mode,
            } => receiver.on_bootstrapped(shell, fallback_mode),
            SessionEvent::Preexec { command, block_id } => receiver.on_preexec(command, block_id),
            SessionEvent::AIPreexec {
                command,
                block_id,
                metadata_json,
            } => receiver.on_ai_preexec(command, block_id, metadata_json),
            SessionEvent::CommandFinished {
                exit_code,
                block_id,
            } => receiver.on_command_finished(exit_code, block_id),
            SessionEvent::Precmd { working_directory } => receiver.on_precmd(working_directory),
            SessionEvent::OutputChunk { block_id, data } => {
                receiver.on_output_chunk(block_id, data)
            }
            SessionEvent::HistorySnapshot { encoded } => receiver.on_history_snapshot(encoded),
            SessionEvent::Status { message } => receiver.on_status(message),
        }
    }
}

struct WarpSessionState {
    parser: OscHookParser,
    next_block_id: u64,
    current_block_id: Option<u64>,
    suppress_passthrough_until_bootstrapped: bool,
    pending_ai_exec_requests: VecDeque<PendingAIExecution>,
    active_metadata: Option<CommandExecutionMetadata>,
}

struct PendingAIExecution {
    command: String,
    metadata: CommandExecutionMetadata,
    response: oneshot::Sender<Result<u64, SshError>>,
}

impl Default for WarpSessionState {
    fn default() -> Self {
        Self {
            parser: OscHookParser::default(),
            next_block_id: 0,
            current_block_id: None,
            suppress_passthrough_until_bootstrapped: true,
            pending_ai_exec_requests: VecDeque::new(),
            active_metadata: None,
        }
    }
}

#[derive(Default)]
struct OscHookParser {
    state: OscParseState,
}

enum OscParseState {
    Normal,
    Esc,
    Osc { payload: Vec<u8>, esc_in_osc: bool },
}

impl Default for OscParseState {
    fn default() -> Self {
        Self::Normal
    }
}

#[derive(Debug, Deserialize, PartialEq, Eq)]
#[serde(tag = "hook")]
enum HookPayload {
    Preexec {
        command: String,
    },
    CommandFinished {
        exit_code: i32,
    },
    Precmd {
        #[serde(default)]
        pwd: Option<String>,
    },
    Bootstrapped {
        #[serde(default)]
        shell: Option<String>,
        #[serde(default)]
        fallback_mode: bool,
    },
    HistorySnapshot {
        encoded: String,
    },
    Status {
        message: String,
    },
}

impl OscHookParser {
    fn consume(&mut self, bytes: &[u8]) -> (Vec<u8>, Vec<HookPayload>) {
        let mut passthrough = Vec::with_capacity(bytes.len());
        let mut hooks = Vec::new();

        for byte in bytes {
            match &mut self.state {
                OscParseState::Normal => {
                    if *byte == 0x1B {
                        self.state = OscParseState::Esc;
                    } else {
                        passthrough.push(*byte);
                    }
                }
                OscParseState::Esc => {
                    if *byte == b']' {
                        self.state = OscParseState::Osc {
                            payload: Vec::new(),
                            esc_in_osc: false,
                        };
                    } else {
                        passthrough.push(0x1B);
                        passthrough.push(*byte);
                        self.state = OscParseState::Normal;
                    }
                }
                OscParseState::Osc {
                    payload,
                    esc_in_osc,
                } => {
                    if *esc_in_osc {
                        if *byte == b'\\' {
                            Self::finish_osc(payload, true, &mut passthrough, &mut hooks);
                            self.state = OscParseState::Normal;
                        } else {
                            payload.push(0x1B);
                            payload.push(*byte);
                            *esc_in_osc = *byte == 0x1B;
                        }
                    } else if *byte == 0x07 {
                        Self::finish_osc(payload, false, &mut passthrough, &mut hooks);
                        self.state = OscParseState::Normal;
                    } else if *byte == 0x1B {
                        *esc_in_osc = true;
                    } else {
                        payload.push(*byte);
                    }
                }
            }
        }

        (passthrough, hooks)
    }

    fn finish_osc(
        payload: &[u8],
        terminated_by_st: bool,
        passthrough: &mut Vec<u8>,
        hooks: &mut Vec<HookPayload>,
    ) {
        let Some(payload_string) = std::str::from_utf8(payload).ok() else {
            passthrough.extend_from_slice(&encode_original_osc(payload, terminated_by_st));
            return;
        };

        let Some(encoded_hook_payload) = payload_string.strip_prefix("9278;") else {
            passthrough.extend_from_slice(&encode_original_osc(payload, terminated_by_st));
            return;
        };

        if let Some(hook) = parse_hook_payload(encoded_hook_payload) {
            hooks.push(hook);
        }
    }
}

fn parse_hook_payload(payload: &str) -> Option<HookPayload> {
    let as_json_bytes = if is_hex_payload(payload) {
        hex::decode(payload).ok()?
    } else {
        payload.as_bytes().to_vec()
    };

    serde_json::from_slice::<HookPayload>(&as_json_bytes).ok()
}

fn is_hex_payload(payload: &str) -> bool {
    payload.len() % 2 == 0
        && payload
            .as_bytes()
            .iter()
            .all(|byte| byte.is_ascii_hexdigit())
}

fn encode_original_osc(payload: &[u8], terminated_by_st: bool) -> Vec<u8> {
    let mut encoded = Vec::with_capacity(payload.len() + 5);
    encoded.extend_from_slice(&[0x1B, b']']);
    encoded.extend_from_slice(payload);
    if terminated_by_st {
        encoded.extend_from_slice(&[0x1B, b'\\']);
    } else {
        encoded.push(0x07);
    }
    encoded
}

fn handle_incoming_bytes(
    data: Vec<u8>,
    data_state: &Arc<StdMutex<ReceiverState>>,
    event_state: &Arc<StdMutex<EventReceiverState>>,
    warp_state: &mut WarpSessionState,
    command_registry: &CommandRegistry,
) {
    let (passthrough, hooks) = warp_state.parser.consume(&data);

    for hook in hooks {
        match hook {
            HookPayload::Preexec { command } => {
                let block_id = warp_state.next_block_id;
                warp_state.next_block_id = warp_state.next_block_id.saturating_add(1);
                warp_state.current_block_id = Some(block_id);
                let mut metadata = CommandExecutionMetadata {
                    source: ExecutionSource::User,
                    ..CommandExecutionMetadata::default()
                };
                if let Some(pending_ai_exec) = warp_state.pending_ai_exec_requests.pop_front() {
                    metadata = pending_ai_exec.metadata;
                    // Register the command before notifying Swift of the block_id to avoid
                    // a race where await/read is called before the block exists.
                    command_registry.start_command(block_id, command.clone(), metadata.clone());
                    let metadata_json =
                        serde_json::to_string(&metadata).unwrap_or_else(|_| "{}".to_string());
                    dispatch_event(
                        event_state,
                        SessionEvent::AIPreexec {
                            command: pending_ai_exec.command,
                            block_id,
                            metadata_json,
                        },
                    );
                    let _ = pending_ai_exec.response.send(Ok(block_id));
                } else {
                    command_registry.start_command(block_id, command.clone(), metadata.clone());
                }
                warp_state.active_metadata = Some(metadata.clone());
                dispatch_event(event_state, SessionEvent::Preexec { command, block_id });
            }
            HookPayload::CommandFinished { exit_code } => {
                if let Some(block_id) = warp_state.current_block_id {
                    command_registry.finish_command(block_id, exit_code);
                    dispatch_event(
                        event_state,
                        SessionEvent::CommandFinished {
                            exit_code,
                            block_id,
                        },
                    );
                }
                warp_state.current_block_id = None;
                warp_state.active_metadata = None;
            }
            HookPayload::Precmd { pwd } => {
                dispatch_event(
                    event_state,
                    SessionEvent::Precmd {
                        working_directory: pwd.unwrap_or_default(),
                    },
                );
            }
            HookPayload::Bootstrapped {
                shell,
                fallback_mode,
            } => {
                warp_state.suppress_passthrough_until_bootstrapped = false;
                dispatch_event(
                    event_state,
                    SessionEvent::Bootstrapped {
                        shell: shell.unwrap_or_else(|| "unknown".to_string()),
                        fallback_mode,
                    },
                )
            }
            HookPayload::HistorySnapshot { encoded } => {
                dispatch_event(event_state, SessionEvent::HistorySnapshot { encoded });
            }
            HookPayload::Status { message } => {
                dispatch_event(event_state, SessionEvent::Status { message });
            }
        }
    }

    if let Some(block_id) = warp_state.current_block_id {
        if !passthrough.is_empty() {
            let output_text = String::from_utf8_lossy(&passthrough);
            command_registry.append_output(block_id, &output_text);
            dispatch_event(
                event_state,
                SessionEvent::OutputChunk {
                    block_id,
                    data: passthrough.clone(),
                },
            );
        }
    }

    let should_forward_to_prompt_terminal = !warp_state.suppress_passthrough_until_bootstrapped
        && warp_state.current_block_id.is_none();

    if passthrough.is_empty() || !should_forward_to_prompt_terminal {
        return;
    }

    let rx_opt = {
        let mut st = data_state.lock().unwrap();
        match &mut *st {
            ReceiverState::Active(rx) => Some(Arc::clone(rx)),
            ReceiverState::Pending(buf) => {
                buf.push(passthrough.clone());
                None
            }
            ReceiverState::Disconnected => None,
        }
    };

    if let Some(rx) = rx_opt {
        rx.on_data(passthrough);
    }
}

fn dispatch_event(event_state: &Arc<StdMutex<EventReceiverState>>, event: SessionEvent) {
    let event_for_buffer = event.clone();
    let receiver_opt = {
        let mut st = event_state.lock().unwrap();
        match &mut *st {
            EventReceiverState::Active(receiver) => Some(Arc::clone(receiver)),
            EventReceiverState::Pending(buffer) => {
                // Avoid unbounded memory growth if Swift is not yet attached.
                match event_for_buffer {
                    SessionEvent::OutputChunk { .. } => {}
                    _ => buffer.push(event_for_buffer),
                }
                None
            }
            EventReceiverState::Disconnected => None,
        }
    };

    if let Some(receiver) = receiver_opt {
        event.emit(receiver.as_ref());
    }
}

fn history_request_command(limit: u32) -> String {
    // Trailing carriage return executes in the interactive shell.
    format!("__warp_ios_request_history {}\r", limit.max(1))
}

fn parse_metadata_json(metadata_json: &str) -> Result<CommandExecutionMetadata, SshError> {
    if metadata_json.trim().is_empty() {
        return Ok(CommandExecutionMetadata::default());
    }
    serde_json::from_str::<CommandExecutionMetadata>(metadata_json)
        .map_err(|e| SshError::ChannelError(format!("invalid command metadata: {e}")))
}

fn normalize_private_key_pem(raw_key: &str) -> String {
    let mut key = raw_key.replace("\r\n", "\n").replace('\r', "\n");
    if key.contains("\\n") && !key.contains('\n') {
        key = key.replace("\\n", "\n");
    }
    let trimmed = key.trim().to_string();
    if trimmed.ends_with('\n') {
        trimmed
    } else {
        format!("{trimmed}\n")
    }
}

impl SshSession {
    async fn configure_interactive_tty(channel: &russh::Channel<client::Msg>) {
        // Some servers ignore PTY mode flags sent during request_pty. Force the
        // interactive shell to use ^H erase with immediate visual backspace.
        let _ = channel
            .data(b"stty erase '^H' echo echoe 2>/dev/null\r".as_slice())
            .await;
    }

    async fn install_warp_hooks(channel: &russh::Channel<client::Msg>) -> bool {
        channel
            .data(WARP_HOOK_BOOTSTRAP_SCRIPT.as_bytes())
            .await
            .is_ok()
    }

    async fn connect_with_password(
        host: String,
        port: u16,
        username: String,
        password: String,
    ) -> Result<Arc<Self>, SshError> {
        let config = Arc::new(russh::client::Config::default());
        let mut handle = client::connect(config, (host.as_str(), port), ClientHandler)
            .await
            .map_err(|e| SshError::ConnectionFailed(e.to_string()))?;

        let authenticated = handle
            .authenticate_password(username, password)
            .await
            .map_err(|e| SshError::ConnectionFailed(e.to_string()))?;
        if !authenticated {
            return Err(SshError::AuthFailed);
        }

        let channel = handle
            .channel_open_session()
            .await
            .map_err(|e| SshError::ChannelError(e.to_string()))?;

        channel
            .request_pty(false, "xterm-256color", 80, 24, 0, 0, PTY_MODES)
            .await
            .map_err(|e| SshError::ChannelError(e.to_string()))?;

        channel
            .request_shell(false)
            .await
            .map_err(|e| SshError::ChannelError(e.to_string()))?;

        Self::configure_interactive_tty(&channel).await;
        let data_state = Arc::new(StdMutex::new(ReceiverState::Pending(Vec::new())));
        let event_state = Arc::new(StdMutex::new(EventReceiverState::Pending(Vec::new())));
        let bootstrap_ok = Self::install_warp_hooks(&channel).await;
        let (cmd_tx, cmd_rx) = mpsc::unbounded_channel();

        let command_registry = CommandRegistry::new();
        RUNTIME.spawn(session_runner(
            channel,
            handle,
            cmd_rx,
            Arc::clone(&data_state),
            Arc::clone(&event_state),
            command_registry.clone(),
            bootstrap_ok,
        ));

        if !bootstrap_ok {
            dispatch_event(
                &event_state,
                SessionEvent::Status {
                    message: "failed to install warp shell hooks; using raw mode".to_string(),
                },
            );
            dispatch_event(
                &event_state,
                SessionEvent::Bootstrapped {
                    shell: "unknown".to_string(),
                    fallback_mode: true,
                },
            );
        }

        Ok(Arc::new(SshSession {
            cmd_tx,
            data_state,
            event_state,
            command_registry,
        }))
    }

    async fn connect_with_key(
        host: String,
        port: u16,
        username: String,
        private_key_pem: String,
    ) -> Result<Arc<Self>, SshError> {
        let config = Arc::new(russh::client::Config::default());
        let mut handle = client::connect(config, (host.as_str(), port), ClientHandler)
            .await
            .map_err(|e| SshError::ConnectionFailed(e.to_string()))?;

        let normalized_key = normalize_private_key_pem(&private_key_pem);
        let key_pair = russh_keys::decode_secret_key(&normalized_key, None)
            .map_err(|_| SshError::InvalidKey)?;

        let authenticated = handle
            .authenticate_publickey(username, Arc::new(key_pair))
            .await
            .map_err(|e| SshError::ConnectionFailed(e.to_string()))?;
        if !authenticated {
            return Err(SshError::AuthFailed);
        }

        let channel = handle
            .channel_open_session()
            .await
            .map_err(|e| SshError::ChannelError(e.to_string()))?;

        channel
            .request_pty(false, "xterm-256color", 80, 24, 0, 0, PTY_MODES)
            .await
            .map_err(|e| SshError::ChannelError(e.to_string()))?;

        channel
            .request_shell(false)
            .await
            .map_err(|e| SshError::ChannelError(e.to_string()))?;

        Self::configure_interactive_tty(&channel).await;
        let data_state = Arc::new(StdMutex::new(ReceiverState::Pending(Vec::new())));
        let event_state = Arc::new(StdMutex::new(EventReceiverState::Pending(Vec::new())));
        let bootstrap_ok = Self::install_warp_hooks(&channel).await;
        let (cmd_tx, cmd_rx) = mpsc::unbounded_channel();

        let command_registry = CommandRegistry::new();
        RUNTIME.spawn(session_runner(
            channel,
            handle,
            cmd_rx,
            Arc::clone(&data_state),
            Arc::clone(&event_state),
            command_registry.clone(),
            bootstrap_ok,
        ));

        if !bootstrap_ok {
            dispatch_event(
                &event_state,
                SessionEvent::Status {
                    message: "failed to install warp shell hooks; using raw mode".to_string(),
                },
            );
            dispatch_event(
                &event_state,
                SessionEvent::Bootstrapped {
                    shell: "unknown".to_string(),
                    fallback_mode: true,
                },
            );
        }

        Ok(Arc::new(SshSession {
            cmd_tx,
            data_state,
            event_state,
            command_registry,
        }))
    }

    // send_data / resize just push to the mpsc — they return instantly.
    // No RUNTIME.block_on() needed since there's no actual async work here.

    pub fn send_data(&self, data: Vec<u8>) {
        let _ = self.cmd_tx.send(SessionCmd::Data(data));
    }

    pub async fn execute_command(
        &self,
        command: String,
        metadata_json: String,
    ) -> Result<u64, SshError> {
        let metadata = parse_metadata_json(&metadata_json)?;
        let (response_tx, response_rx) = oneshot::channel();
        self.cmd_tx
            .send(SessionCmd::ExecuteCommand {
                command,
                metadata,
                response: response_tx,
            })
            .map_err(|_| SshError::Disconnected)?;
        response_rx.await.map_err(|_| SshError::Disconnected)?
    }

    pub async fn await_command_completion(
        &self,
        block_id: u64,
        timeout_ms: u32,
    ) -> Result<String, SshError> {
        let timeout = if timeout_ms == 0 {
            None
        } else {
            Some(Duration::from_millis(timeout_ms as u64))
        };
        let snapshot = self
            .command_registry
            .await_completion(block_id, timeout)
            .await
            .ok_or_else(|| SshError::ChannelError(format!("unknown block_id: {block_id}")))?;
        serde_json::to_string(&snapshot)
            .map_err(|e| SshError::ChannelError(format!("failed to encode completion: {e}")))
    }

    pub fn read_command_output(&self, block_id: u64) -> String {
        self.command_registry.read_output(block_id).unwrap_or_default()
    }

    pub fn write_to_running_command(&self, block_id: u64, data: Vec<u8>) {
        let _ = self
            .cmd_tx
            .send(SessionCmd::WriteToRunningCommand { block_id, data });
    }

    pub fn cancel_running_command(&self, block_id: u64) {
        let _ = self.cmd_tx.send(SessionCmd::CancelRunningCommand { block_id });
    }

    pub fn request_history(&self, limit: u32) {
        let _ = self.cmd_tx.send(SessionCmd::RequestHistory(limit));
    }

    pub fn resize(&self, cols: u16, rows: u16) {
        let _ = self.cmd_tx.send(SessionCmd::Resize(cols, rows));
    }

    pub fn set_receiver(&self, receiver: Box<dyn DataReceiver>) {
        let arc_receiver: Arc<dyn DataReceiver> = Arc::from(receiver);
        let mut state = self.data_state.lock().unwrap();
        // Atomically drain the pending buffer and activate the receiver so no
        // data packet falls into the gap between draining and activating.
        // If already Disconnected (e.g. instant server rejection), skip.
        match &*state {
            ReceiverState::Pending(buf) => {
                for chunk in buf.iter() {
                    arc_receiver.on_data(chunk.clone());
                }
                *state = ReceiverState::Active(arc_receiver);
            }
            ReceiverState::Active(_) => {
                *state = ReceiverState::Active(arc_receiver);
            }
            ReceiverState::Disconnected => {}
        }
    }

    pub fn set_event_receiver(&self, receiver: Box<dyn SessionEventReceiver>) {
        let arc_receiver: Arc<dyn SessionEventReceiver> = Arc::from(receiver);
        let mut state = self.event_state.lock().unwrap();
        match &*state {
            EventReceiverState::Pending(buffer) => {
                for event in buffer.iter().cloned() {
                    event.emit(arc_receiver.as_ref());
                }
                *state = EventReceiverState::Active(arc_receiver);
            }
            EventReceiverState::Active(_) => {
                *state = EventReceiverState::Active(arc_receiver);
            }
            EventReceiverState::Disconnected => {}
        }
    }

    pub async fn disconnect(&self) {
        // Mark Disconnected first so the runner doesn't also fire on_disconnect
        // if it happens to see remote EOF at the same moment.
        {
            let mut data_state = self.data_state.lock().unwrap();
            *data_state = ReceiverState::Disconnected;
        }
        {
            let mut event_state = self.event_state.lock().unwrap();
            *event_state = EventReceiverState::Disconnected;
        }
        // Signal the runner to close the SSH connection and exit.
        let _ = self.cmd_tx.send(SessionCmd::Disconnect);
    }
}

const WARP_HOOK_BOOTSTRAP_SCRIPT: &str = r#"__warp_ios_emit() { printf '\033]9278;%s\007' "$1"; }
__warp_ios_ready=0
__warp_ios_history_command_limit=200
__warp_ios_escape() {
  local value="$1"
  value=${value//\\/\\\\}
  value=${value//\"/\\\"}
  value=${value//$'\n'/\\n}
  value=${value//$'\r'/}
  printf '%s' "$value"
}
__warp_ios_emit_preexec() {
  [ "$__warp_ios_ready" = "1" ] || return
  local raw_cmd="$1"
  local escaped_cmd
  escaped_cmd="$(__warp_ios_escape "$raw_cmd")"
  [ -z "$escaped_cmd" ] && return
  __warp_ios_emit "{\"hook\":\"Preexec\",\"command\":\"$escaped_cmd\"}"
}
__warp_ios_emit_precmd() {
  [ "$__warp_ios_ready" = "1" ] || return
  local status="$1"
  local escaped_pwd
  escaped_pwd="$(__warp_ios_escape "$PWD")"
  __warp_ios_emit "{\"hook\":\"CommandFinished\",\"exit_code\":$status}"
  __warp_ios_emit "{\"hook\":\"Precmd\",\"pwd\":\"$escaped_pwd\"}"
}
__warp_ios_emit_history_snapshot() {
  local encoded="$1"
  __warp_ios_emit "{\"hook\":\"HistorySnapshot\",\"encoded\":\"$encoded\"}"
}
__warp_ios_collect_history_lines() {
  local limit="$1"
  if [ -z "$limit" ]; then
    limit="$__warp_ios_history_command_limit"
  fi
  if [ -n "${ZSH_VERSION:-}" ]; then
    {
      fc -ln -"$limit" 2>/dev/null
      if [ -n "${HISTFILE:-}" ] && [ -r "${HISTFILE:-}" ]; then
        tail -n "$limit" "$HISTFILE" 2>/dev/null | sed -E 's/^: [0-9]+:[0-9]+;//'
      fi
    } | sed 's/\r$//'
  elif [ -n "${BASH_VERSION:-}" ]; then
    history -a 2>/dev/null || true
    {
      history "$limit" 2>/dev/null | sed -E 's/^[[:space:]]*[0-9]+[[:space:]]+//'
      if [ -n "${HISTFILE:-}" ] && [ -r "${HISTFILE:-}" ]; then
        tail -n "$limit" "$HISTFILE" 2>/dev/null
      fi
    } | sed 's/\r$//'
  else
    return 0
  fi
}
__warp_ios_request_history() {
  local limit="$1"
  if [ -z "$limit" ]; then
    limit="$__warp_ios_history_command_limit"
  fi
  local encoded
  encoded="$(__warp_ios_collect_history_lines "$limit" \
    | sed '/^[[:space:]]*$/d' \
    | sed '/^__warp_ios_/d' \
    | sed '/__warp_ios_/d' \
    | sed '/PROMPT_COMMAND/d' \
    | sed '/add-zsh-hook/d' \
    | sed '/autoload -Uz add-zsh-hook/d' \
    | sed '/^stty erase '\''\^H'\'' echo echoe 2>\\/dev\\/null$/d' \
    | sed '/^if \[ -n "\${ZSH_VERSION:-}" \]; then/d' \
    | sed '/^elif \[ -n "\${BASH_VERSION:-}" \]; then/d' \
    | sed '/^else$/d' \
    | sed '/^fi$/d' \
    | sed '/^\[ -n "\${ZSH_VERSION:-}" \]$/d' \
    | sed '/^\[ -n "\${BASH_VERSION:-}" \]$/d' \
    | awk '!seen[$0]++' \
    | base64 \
    | tr -d '\r\n')"
  __warp_ios_emit_history_snapshot "$encoded"
}
if [ -n "${ZSH_VERSION:-}" ]; then
  __warp_ios_preexec_zsh() {
    case "$1" in
      __warp_ios_*) return ;;
    esac
    __warp_ios_emit_preexec "$1"
  }
  __warp_ios_precmd_zsh() {
    local status=$?
    __warp_ios_emit_precmd "$status"
  }
  autoload -Uz add-zsh-hook >/dev/null 2>&1 || true
  add-zsh-hook preexec __warp_ios_preexec_zsh >/dev/null 2>&1 || true
  add-zsh-hook precmd __warp_ios_precmd_zsh >/dev/null 2>&1 || true
  __warp_ios_emit '{"hook":"Bootstrapped","shell":"zsh"}'
  __warp_ios_ready=1
elif [ -n "${BASH_VERSION:-}" ]; then
  __warp_ios_in_prompt=0
  __warp_ios_preexec_bash() {
    [ "$__warp_ios_in_prompt" = "1" ] && return
    case "$BASH_COMMAND" in
      __warp_ios_*|history*|trap*|PROMPT_COMMAND*) return ;;
    esac
    __warp_ios_emit_preexec "$BASH_COMMAND"
  }
  __warp_ios_precmd_bash() {
    local status=$?
    __warp_ios_in_prompt=1
    __warp_ios_emit_precmd "$status"
    __warp_ios_in_prompt=0
  }
  trap '__warp_ios_preexec_bash' DEBUG
  case ";${PROMPT_COMMAND};" in
    *";__warp_ios_precmd_bash;"*) ;;
    *) PROMPT_COMMAND="__warp_ios_precmd_bash${PROMPT_COMMAND:+;${PROMPT_COMMAND}}" ;;
  esac
  __warp_ios_emit '{"hook":"Bootstrapped","shell":"bash"}'
  __warp_ios_ready=1
else
  __warp_ios_emit '{"hook":"Bootstrapped","shell":"unknown","fallback_mode":true}'
  __warp_ios_emit '{"hook":"Status","message":"warp hooks unavailable for current shell"}'
fi
"#;

#[cfg(test)]
mod tests {
    use super::{classify_input_intent, history_request_command, HookPayload, OscHookParser};

    #[test]
    fn parses_plain_osc_hook_and_keeps_display_bytes() {
        let mut parser = OscHookParser::default();
        let input = b"before\x1b]9278;{\"hook\":\"Preexec\",\"command\":\"ls -la\"}\x07after";

        let (display, hooks) = parser.consume(input);

        assert_eq!(display, b"beforeafter");
        assert_eq!(
            hooks,
            vec![HookPayload::Preexec {
                command: "ls -la".to_string()
            }]
        );
    }

    #[test]
    fn parses_hex_encoded_payload() {
        let mut parser = OscHookParser::default();
        let input = b"\x1b]9278;7b22686f6f6b223a22436f6d6d616e6446696e6973686564222c22657869745f636f6465223a317d\x07";

        let (_display, hooks) = parser.consume(input);

        assert_eq!(hooks, vec![HookPayload::CommandFinished { exit_code: 1 }]);
    }

    #[test]
    fn passes_through_non_warp_osc_sequences() {
        let mut parser = OscHookParser::default();
        let input = b"ab\x1b]0;title\x07cd";

        let (display, hooks) = parser.consume(input);

        assert_eq!(display, input);
        assert!(hooks.is_empty());
    }

    #[test]
    fn parses_history_snapshot_payload() {
        let mut parser = OscHookParser::default();
        let input = b"\x1b]9278;{\"hook\":\"HistorySnapshot\",\"encoded\":\"Y21kMQpjbWQy\"}\x07";

        let (_display, hooks) = parser.consume(input);

        assert_eq!(
            hooks,
            vec![HookPayload::HistorySnapshot {
                encoded: "Y21kMQpjbWQy".to_string()
            }]
        );
    }

    #[test]
    fn request_history_command_is_interactive() {
        assert_eq!(history_request_command(0), "__warp_ios_request_history 1\r");
        assert_eq!(
            history_request_command(250),
            "__warp_ios_request_history 250\r"
        );
    }

    #[tokio::test]
    async fn classify_shell_command_prefers_shell() {
        let result = classify_input_intent("git status".to_string(), "shell".to_string(), false).await;
        assert_eq!(result.mode, "shell");
    }

    #[tokio::test]
    async fn classify_natural_language_prefers_ai() {
        let result = classify_input_intent(
            "how do i list files recursively".to_string(),
            "shell".to_string(),
            false,
        )
        .await;
        assert_eq!(result.mode, "ai");
    }

    #[tokio::test]
    async fn classify_forced_shell_prefixes_as_shell() {
        let bang_result =
            classify_input_intent("!ls -la".to_string(), "ai".to_string(), false).await;
        let run_result = classify_input_intent(
            "run ls -la".to_string(),
            "ai".to_string(),
            false,
        )
        .await;
        assert_eq!(bang_result.mode, "shell");
        assert_eq!(run_result.mode, "shell");
    }

    #[tokio::test]
    async fn classify_agent_follow_up_as_ai() {
        let result = classify_input_intent("continue".to_string(), "shell".to_string(), true).await;
        assert_eq!(result.mode, "ai");
    }
}
