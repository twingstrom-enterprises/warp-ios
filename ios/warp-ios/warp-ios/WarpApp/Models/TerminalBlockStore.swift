import Foundation
import Observation

struct CommandExecutionMetadata: Decodable {
    enum Source: String, Decodable {
        case user
        case ai
    }

    var source: Source
    var action_id: String?
    var conversation_id: String?
    var request_id: String?
}

@MainActor
@Observable
final class TerminalBlockStore {
    var blocks: [TerminalBlock] = []
    var commandHistory: [String] = []
    var fallbackModeEnabled = false
    var isBootstrapped = false
    var activeBlockID: UInt64?
    var shellName = "unknown"
    var statusMessage: String?
    var currentWorkingDirectory = "~"
    var scrollTick = 0
    private var outputChunkCounter = 0
    private var syntheticBlockIDCursor: UInt64 = UInt64.max

    func reset() {
        blocks.removeAll()
        commandHistory.removeAll()
        fallbackModeEnabled = false
        isBootstrapped = false
        activeBlockID = nil
        shellName = "unknown"
        statusMessage = nil
        currentWorkingDirectory = "~"
        scrollTick = 0
        outputChunkCounter = 0
        syntheticBlockIDCursor = UInt64.max
    }

    func applyBootstrapped(shell: String, fallbackMode: Bool) {
        shellName = shell
        fallbackModeEnabled = fallbackMode
        isBootstrapped = true
    }

    func applyStatus(_ message: String) {
        statusMessage = message
    }

    func applyPreexec(command: String, blockId: UInt64) {
        applyPreexec(command: command, blockId: blockId, metadata: nil)
    }

    func applyPreexec(command: String, blockId: UInt64, metadata: CommandExecutionMetadata?) {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        commandHistory.append(trimmed)

        if shouldClearVisibleHistory(command: trimmed) {
            clearVisibleHistory()
            return
        }

        if let idx = blocks.firstIndex(where: { $0.id == blockId }) {
            blocks[idx].command = trimmed
            blocks[idx].isRunning = true
            blocks[idx].exitCode = nil
            blocks[idx].finishedAt = nil
            blocks[idx].renderStyle = .command
            if let metadata {
                blocks[idx].commandSource = metadata.source == .ai ? .ai : .user
                blocks[idx].aiActionID = metadata.action_id
                blocks[idx].aiConversationID = metadata.conversation_id
                blocks[idx].aiRequestID = metadata.request_id
            } else {
                blocks[idx].commandSource = .user
                blocks[idx].aiActionID = nil
                blocks[idx].aiConversationID = nil
                blocks[idx].aiRequestID = nil
            }
            activeBlockID = blockId
            scrollTick &+= 1
            return
        }

        blocks.append(
            TerminalBlock(
                id: blockId,
                command: trimmed,
                commandSource: metadata?.source == .ai ? .ai : .user,
                aiActionID: metadata?.action_id,
                aiConversationID: metadata?.conversation_id,
                aiRequestID: metadata?.request_id,
                renderStyle: .command
            )
        )
        activeBlockID = blockId
        scrollTick &+= 1
    }

    func appendAIDialogue(prompt: String, answer: String) {
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedAnswer = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedAnswer.isEmpty else { return }

        syntheticBlockIDCursor = syntheticBlockIDCursor &- 1
        blocks.append(
            TerminalBlock(
                id: syntheticBlockIDCursor,
                command: trimmedPrompt,
                output: trimmedAnswer,
                exitCode: nil,
                isRunning: false,
                createdAt: Date(),
                finishedAt: Date(),
                commandSource: .ai,
                renderStyle: .aiDialogue
            )
        )
        scrollTick &+= 1
    }

    func applyOutput(blockId: UInt64, data: [UInt8]) {
        guard let idx = blocks.firstIndex(where: { $0.id == blockId }) else { return }
        let chunk = sanitizeOutputChunk(String(decoding: data, as: UTF8.self))
        guard !chunk.isEmpty else { return }
        blocks[idx].output.append(chunk)
        outputChunkCounter &+= 1
        if chunk.contains("\n") || outputChunkCounter % 8 == 0 {
            scrollTick &+= 1
        }
    }

    func applyCommandFinished(exitCode: Int32, blockId: UInt64) {
        guard let idx = blocks.firstIndex(where: { $0.id == blockId }) else { return }
        blocks[idx].exitCode = exitCode
        blocks[idx].isRunning = false
        blocks[idx].finishedAt = Date()
        if activeBlockID == blockId {
            activeBlockID = nil
        }
        scrollTick &+= 1
    }

    func applyPrecmd(workingDirectory: String) {
        if !workingDirectory.isEmpty {
            currentWorkingDirectory = workingDirectory
        }
        guard let idx = blocks.indices.last else { return }
        blocks[idx].workingDirectory = workingDirectory
    }

    func copyText(for blockID: UInt64) -> String {
        guard let block = blocks.first(where: { $0.id == blockID }) else {
            return ""
        }

        var lines: [String] = []
        if block.renderStyle == .aiDialogue {
            lines.append("ai prompt: \(block.command)")
            lines.append("ai answer:")
            lines.append(block.output)
            return lines.joined(separator: "\n")
        }
        if !block.workingDirectory.isEmpty {
            lines.append("cwd: \(block.workingDirectory)")
        }
        if block.commandSource == .ai {
            lines.append("source: ai")
        }
        if let actionID = block.aiActionID {
            lines.append("action id: \(actionID)")
        }
        lines.append("$ \(block.command)")
        if !block.output.isEmpty {
            lines.append(block.output)
        }
        if let exitCode = block.exitCode {
            lines.append("exit code: \(exitCode)")
        }
        return lines.joined(separator: "\n")
    }

    private func sanitizeOutputChunk(_ raw: String) -> String {
        let esc = "\u{001B}"
        let bel = "\u{0007}"
        let ansiPatterns = [
            "\(esc)\\[[0-9;?]*[ -/]*[@-~]",
            "\(esc)\\][^\(bel)\(esc)]*(?:\(bel)|\(esc)\\\\)"
        ]

        var cleaned = raw
        for pattern in ansiPatterns {
            if let regex = try? NSRegularExpression(pattern: pattern) {
                let range = NSRange(cleaned.startIndex..<cleaned.endIndex, in: cleaned)
                cleaned = regex.stringByReplacingMatches(in: cleaned, range: range, withTemplate: "")
            }
        }

        cleaned = String(
            cleaned.unicodeScalars.filter { scalar in
                scalar == "\n" || scalar == "\r" || scalar == "\t" || scalar.value >= 0x20
            }
        )

        return cleaned
    }

    private func clearVisibleHistory() {
        blocks.removeAll()
        activeBlockID = nil
        scrollTick &+= 1
    }

    private func shouldClearVisibleHistory(command: String) -> Bool {
        // Treat leading `clear` as a UI clear request (supports flags like `clear -x`).
        // Intentionally scoped to clear-like first-token commands to avoid matching
        // strings such as `echo clear`.
        let firstToken = command
            .split(whereSeparator: \.isWhitespace)
            .first?
            .trimmingCharacters(in: CharacterSet(charactersIn: ";"))
            .lowercased()
        return firstToken == "clear"
    }
}
