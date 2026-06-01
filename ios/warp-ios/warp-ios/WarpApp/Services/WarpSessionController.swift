import Foundation

final class WarpSessionController: SessionEventReceiver {
    private let store: TerminalBlockStore
    @MainActor private unowned let session: SSHSession
    private var outputChunkLogCounter = 0

    @MainActor
    init(store: TerminalBlockStore, session: SSHSession) {
        self.store = store
        self.session = session
    }

    func onBootstrapped(shell: String, fallbackMode: Bool) {
        DispatchQueue.main.async { [store, session] in
            session.trace("hook bootstrapped shell=\(shell) fallback=\(fallbackMode)")
            store.applyBootstrapped(shell: shell, fallbackMode: fallbackMode)
            session.handleBootstrappedEvent()
        }
    }

    func onPreexec(command: String, blockId: UInt64) {
        DispatchQueue.main.async { [store, session] in
            session.trace("hook preexec block=\(blockId) command='\(command)'")
            store.applyPreexec(command: command, blockId: blockId)
            session.handlePreexecEvent()
        }
    }

    func onAiPreexec(command: String, blockId: UInt64, metadataJson: String) {
        DispatchQueue.main.async { [store, session] in
            let metadata = Self.decodeMetadata(from: metadataJson)
            session.trace("hook ai_preexec block=\(blockId) command='\(command)' metadata=\(metadataJson)")
            store.applyPreexec(command: command, blockId: blockId, metadata: metadata)
            session.handlePreexecEvent()
        }
    }

    func onCommandFinished(exitCode: Int32, blockId: UInt64) {
        DispatchQueue.main.async { [store, session] in
            session.trace("hook command_finished block=\(blockId) exit=\(exitCode)")
            store.applyCommandFinished(exitCode: exitCode, blockId: blockId)
            session.handleCommandFinishedEvent()
        }
    }

    func onPrecmd(workingDirectory: String) {
        DispatchQueue.main.async { [store, session] in
            session.trace("hook precmd pwd='\(workingDirectory)'")
            store.applyPrecmd(workingDirectory: workingDirectory)
            session.handlePrecmdEvent()
        }
    }

    func onOutputChunk(blockId: UInt64, data: [UInt8]) {
        DispatchQueue.main.async { [store] in
            self.outputChunkLogCounter &+= 1
            if data.count >= 256 || self.outputChunkLogCounter % 20 == 0 {
                self.session.trace("hook output_chunk block=\(blockId) bytes=\(data.count)")
            }
            store.applyOutput(blockId: blockId, data: data)
        }
    }

    func onHistorySnapshot(encoded: String) {
        DispatchQueue.main.async { [session] in
            session.handleHistorySnapshot(encoded: encoded)
        }
    }

    func onStatus(message: String) {
        DispatchQueue.main.async { [store] in
            store.applyStatus(message)
        }
    }

    private static func decodeMetadata(from raw: String) -> CommandExecutionMetadata? {
        guard let data = raw.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(CommandExecutionMetadata.self, from: data)
    }
}
