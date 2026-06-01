use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use serde::{Deserialize, Serialize};
use tokio::sync::Notify;

#[derive(Debug, Clone, Eq, PartialEq, Serialize, Deserialize, Default)]
pub struct CommandExecutionMetadata {
    pub action_id: Option<String>,
    pub conversation_id: Option<String>,
    pub request_id: Option<String>,
    pub source: ExecutionSource,
}

#[derive(Debug, Clone, Eq, PartialEq, Serialize, Deserialize, Default)]
pub enum ExecutionSource {
    #[default]
    User,
    AI,
}

#[derive(Debug, Clone, Eq, PartialEq, Serialize, Deserialize)]
pub enum RuntimeAction {
    RequestCommandOutput {
        command: String,
        wait_until_completion: bool,
        metadata: CommandExecutionMetadata,
    },
    ReadShellCommandOutput {
        block_id: u64,
    },
}

#[derive(Debug, Clone, Eq, PartialEq, Serialize, Deserialize)]
pub struct CommandLifecycleEvent {
    pub block_id: u64,
    pub command: String,
    pub metadata: CommandExecutionMetadata,
}

#[derive(Debug, Clone, Eq, PartialEq, Serialize, Deserialize)]
pub struct CommandSnapshot {
    pub block_id: u64,
    pub command: String,
    pub output: String,
    pub is_running: bool,
    pub exit_code: Option<i32>,
    pub started_at_millis: u128,
    pub finished_at_millis: Option<u128>,
    pub metadata: CommandExecutionMetadata,
}

struct CommandRecord {
    block_id: u64,
    command: String,
    output: String,
    is_running: bool,
    exit_code: Option<i32>,
    started_at: Instant,
    finished_at: Option<Instant>,
    metadata: CommandExecutionMetadata,
    notify: Arc<Notify>,
}

impl CommandRecord {
    fn snapshot(&self, created_at: Instant) -> CommandSnapshot {
        CommandSnapshot {
            block_id: self.block_id,
            command: self.command.clone(),
            output: self.output.clone(),
            is_running: self.is_running,
            exit_code: self.exit_code,
            started_at_millis: self.started_at.duration_since(created_at).as_millis(),
            finished_at_millis: self
                .finished_at
                .map(|finished_at| finished_at.duration_since(created_at).as_millis()),
            metadata: self.metadata.clone(),
        }
    }
}

#[derive(Default)]
struct CommandRegistryState {
    commands: HashMap<u64, CommandRecord>,
}

#[derive(Clone)]
pub struct CommandRegistry {
    created_at: Instant,
    state: Arc<Mutex<CommandRegistryState>>,
}

impl Default for CommandRegistry {
    fn default() -> Self {
        Self::new()
    }
}

impl CommandRegistry {
    pub fn new() -> Self {
        Self {
            created_at: Instant::now(),
            state: Arc::new(Mutex::new(CommandRegistryState::default())),
        }
    }

    pub fn start_command(
        &self,
        block_id: u64,
        command: String,
        metadata: CommandExecutionMetadata,
    ) -> CommandLifecycleEvent {
        let mut state = self.state.lock().expect("command registry mutex poisoned");
        let record = CommandRecord {
            block_id,
            command: command.clone(),
            output: String::new(),
            is_running: true,
            exit_code: None,
            started_at: Instant::now(),
            finished_at: None,
            metadata: metadata.clone(),
            notify: Arc::new(Notify::new()),
        };
        state.commands.insert(block_id, record);
        CommandLifecycleEvent {
            block_id,
            command,
            metadata,
        }
    }

    pub fn append_output(&self, block_id: u64, output_chunk: &str) {
        let mut state = self.state.lock().expect("command registry mutex poisoned");
        if let Some(record) = state.commands.get_mut(&block_id) {
            record.output.push_str(output_chunk);
        }
    }

    pub fn finish_command(&self, block_id: u64, exit_code: i32) {
        let mut state = self.state.lock().expect("command registry mutex poisoned");
        if let Some(record) = state.commands.get_mut(&block_id) {
            record.exit_code = Some(exit_code);
            record.is_running = false;
            record.finished_at = Some(Instant::now());
            record.notify.notify_waiters();
        }
    }

    pub fn read_output(&self, block_id: u64) -> Option<String> {
        let state = self.state.lock().expect("command registry mutex poisoned");
        state.commands.get(&block_id).map(|record| record.output.clone())
    }

    pub fn snapshot(&self, block_id: u64) -> Option<CommandSnapshot> {
        let state = self.state.lock().expect("command registry mutex poisoned");
        state
            .commands
            .get(&block_id)
            .map(|record| record.snapshot(self.created_at))
    }

    pub async fn await_completion(
        &self,
        block_id: u64,
        timeout: Option<Duration>,
    ) -> Option<CommandSnapshot> {
        if tokio::runtime::Handle::try_current().is_err() {
            return self.await_completion_without_reactor(block_id, timeout);
        }

        let deadline = timeout.map(|duration| Instant::now() + duration);
        loop {
            let (already_done, notify) = {
                let state = self.state.lock().expect("command registry mutex poisoned");
                let record = state.commands.get(&block_id)?;
                (!record.is_running, Arc::clone(&record.notify))
            };

            if already_done {
                return self.snapshot(block_id);
            }

            if let Some(deadline) = deadline {
                let now = Instant::now();
                if now >= deadline {
                    return self.snapshot(block_id);
                }
                let remaining = deadline.duration_since(now);
                if tokio::time::timeout(remaining, notify.notified())
                    .await
                    .is_err()
                {
                    return self.snapshot(block_id);
                }
            } else {
                notify.notified().await;
            }
        }
    }

    fn await_completion_without_reactor(
        &self,
        block_id: u64,
        timeout: Option<Duration>,
    ) -> Option<CommandSnapshot> {
        let deadline = timeout.map(|duration| Instant::now() + duration);
        loop {
            let snapshot = self.snapshot(block_id)?;
            if !snapshot.is_running {
                return Some(snapshot);
            }

            if let Some(deadline) = deadline {
                if Instant::now() >= deadline {
                    return Some(snapshot);
                }
            }

            // No Tokio reactor on this thread; short sleep polling avoids panics.
            std::thread::sleep(Duration::from_millis(25));
        }
    }
}

#[cfg(test)]
mod tests {
    use super::{CommandExecutionMetadata, CommandRegistry, ExecutionSource};
    use std::time::Duration;

    #[tokio::test]
    async fn tracks_command_lifecycle_and_completion() {
        let registry = CommandRegistry::new();
        registry.start_command(
            42,
            "ls -la".to_string(),
            CommandExecutionMetadata {
                action_id: Some("action-1".to_string()),
                conversation_id: Some("conversation-1".to_string()),
                request_id: Some("request-1".to_string()),
                source: ExecutionSource::AI,
            },
        );
        registry.append_output(42, "hello\n");
        registry.finish_command(42, 0);

        let snapshot = registry
            .await_completion(42, Some(Duration::from_millis(5)))
            .await
            .expect("snapshot exists");
        assert!(!snapshot.is_running);
        assert_eq!(snapshot.exit_code, Some(0));
        assert_eq!(snapshot.output, "hello\n");
        assert_eq!(snapshot.metadata.source, ExecutionSource::AI);
    }

    #[tokio::test]
    async fn returns_running_snapshot_when_timeout_hits() {
        let registry = CommandRegistry::new();
        registry.start_command(7, "sleep 10".to_string(), CommandExecutionMetadata::default());
        registry.append_output(7, "still running");

        let snapshot = registry
            .await_completion(7, Some(Duration::from_millis(1)))
            .await
            .expect("snapshot exists");
        assert!(snapshot.is_running);
        assert_eq!(snapshot.exit_code, None);
        assert_eq!(snapshot.output, "still running");
    }
}
