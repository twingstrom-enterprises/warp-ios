uniffi::include_scaffolding!("warp_ios_bridge");

use async_trait::async_trait;
use once_cell::sync::Lazy;
use russh::client::{self, Handle};
use std::sync::{Arc, Mutex as StdMutex};
use tokio::runtime::Runtime;
use tokio::sync::mpsc;

// Single global multi-thread Tokio runtime.  UniFFI 0.28's tokio feature only
// provides waker bridging — it does NOT start a reactor.  All async SSH work
// must be executed on this runtime so Tokio I/O primitives are available.
static RUNTIME: Lazy<Runtime> = Lazy::new(|| {
    tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .build()
        .expect("Failed to create Tokio runtime")
});

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
        .spawn(SshSession::connect_with_password(host, port, username, password))
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
        .spawn(SshSession::connect_with_key(host, port, username, private_key_pem))
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

// Tracks whether a receiver has been registered yet.  Data that arrives
// before set_receiver() is called is buffered so the initial shell prompt
// is never lost.  Once on_disconnect fires the state moves to Disconnected
// so duplicate events don't call it twice.
enum ReceiverState {
    Pending(Vec<Vec<u8>>),
    Active(Arc<dyn DataReceiver>),
    Disconnected,
}

/// Commands sent from Swift → session_runner over an mpsc channel.
enum SessionCmd {
    Data(Vec<u8>),
    Resize(u16, u16),
    Disconnect,
}

pub struct SshSession {
    /// Sends outgoing commands to the runner task.
    cmd_tx: mpsc::UnboundedSender<SessionCmd>,
    /// Shared receiver state; also written by set_receiver() from Swift.
    state: Arc<StdMutex<ReceiverState>>,
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
    state: Arc<StdMutex<ReceiverState>>,
) {
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
                        // Acquire lock only long enough to clone the receiver Arc.
                        let data_vec = data.as_ref().to_vec();
                        let rx_opt = {
                            let mut st = state.lock().unwrap();
                            match &mut *st {
                                ReceiverState::Active(rx) => Some(Arc::clone(rx)),
                                ReceiverState::Pending(buf) => {
                                    buf.push(data_vec.clone());
                                    None
                                }
                                ReceiverState::Disconnected => None,
                            }
                        };
                        if let Some(rx) = rx_opt {
                            rx.on_data(data_vec);
                        }
                    }
                    Some(russh::ChannelMsg::ExtendedData { ref data, .. }) => {
                        // Stderr — surface it the same way as stdout.
                        let data_vec = data.as_ref().to_vec();
                        let rx_opt = {
                            let mut st = state.lock().unwrap();
                            match &mut *st {
                                ReceiverState::Active(rx) => Some(Arc::clone(rx)),
                                ReceiverState::Pending(buf) => {
                                    buf.push(data_vec.clone());
                                    None
                                }
                                ReceiverState::Disconnected => None,
                            }
                        };
                        if let Some(rx) = rx_opt {
                            rx.on_data(data_vec);
                        }
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

    // If the remote side closed the channel, tell Swift to dismiss the terminal.
    if remote_closed {
        let mut st = state.lock().unwrap();
        if let ReceiverState::Active(rx) = &*st {
            rx.on_disconnect("session ended".to_string());
            *st = ReceiverState::Disconnected;
        } else {
            *st = ReceiverState::Disconnected;
        }
    }

    // Best-effort SSH-level disconnect (no-op if server already closed).
    let _ = handle.disconnect(russh::Disconnect::ByApplication, "", "English").await;
}

// Terminal modes:
// - VERASE=0x08 so iOS backspace can use classic ^H semantics.
// - ECHO/ECHOE=1 so erased chars redraw immediately at an interactive prompt.
const PTY_MODES: &[(russh::Pty, u32)] = &[
    (russh::Pty::VERASE, 8),
    (russh::Pty::ECHO, 1),
    (russh::Pty::ECHOE, 1),
];

impl SshSession {
    async fn configure_interactive_tty(channel: &russh::Channel<client::Msg>) {
        // Some servers ignore PTY mode flags sent during request_pty. Force the
        // interactive shell to use ^H erase with immediate visual backspace.
        let _ = channel
            .data(b"stty erase '^H' echo echoe 2>/dev/null\r".as_slice())
            .await;
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

        let state = Arc::new(StdMutex::new(ReceiverState::Pending(Vec::new())));
        let (cmd_tx, cmd_rx) = mpsc::unbounded_channel();

        RUNTIME.spawn(session_runner(channel, handle, cmd_rx, Arc::clone(&state)));

        Ok(Arc::new(SshSession { cmd_tx, state }))
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

        let key_pair = russh_keys::decode_secret_key(&private_key_pem, None)
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

        let state = Arc::new(StdMutex::new(ReceiverState::Pending(Vec::new())));
        let (cmd_tx, cmd_rx) = mpsc::unbounded_channel();

        RUNTIME.spawn(session_runner(channel, handle, cmd_rx, Arc::clone(&state)));

        Ok(Arc::new(SshSession { cmd_tx, state }))
    }

    // send_data / resize just push to the mpsc — they return instantly.
    // No RUNTIME.block_on() needed since there's no actual async work here.

    pub fn send_data(&self, data: Vec<u8>) {
        let _ = self.cmd_tx.send(SessionCmd::Data(data));
    }

    pub fn resize(&self, cols: u16, rows: u16) {
        let _ = self.cmd_tx.send(SessionCmd::Resize(cols, rows));
    }

    pub fn set_receiver(&self, receiver: Box<dyn DataReceiver>) {
        let arc_receiver: Arc<dyn DataReceiver> = Arc::from(receiver);
        let mut state = self.state.lock().unwrap();
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

    pub async fn disconnect(&self) {
        // Mark Disconnected first so the runner doesn't also fire on_disconnect
        // if it happens to see remote EOF at the same moment.
        {
            let mut state = self.state.lock().unwrap();
            *state = ReceiverState::Disconnected;
        }
        // Signal the runner to close the SSH connection and exit.
        let _ = self.cmd_tx.send(SessionCmd::Disconnect);
    }
}
