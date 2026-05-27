import Foundation
import Observation

@MainActor
@Observable
final class TerminalBlockStore {
    var blocks: [TerminalBlock] = []
    var fallbackModeEnabled = false
    var isBootstrapped = false
    var activeBlockID: UInt64?
    var shellName = "unknown"
    var statusMessage: String?
    var currentWorkingDirectory = "~"
    var scrollTick = 0
    private var outputChunkCounter = 0

    func reset() {
        blocks.removeAll()
        fallbackModeEnabled = false
        isBootstrapped = false
        activeBlockID = nil
        shellName = "unknown"
        statusMessage = nil
        currentWorkingDirectory = "~"
        scrollTick = 0
        outputChunkCounter = 0
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
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if let idx = blocks.firstIndex(where: { $0.id == blockId }) {
            blocks[idx].command = trimmed
            blocks[idx].isRunning = true
            blocks[idx].exitCode = nil
            activeBlockID = blockId
            scrollTick &+= 1
            return
        }

        blocks.append(TerminalBlock(id: blockId, command: trimmed))
        activeBlockID = blockId
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
        if !block.workingDirectory.isEmpty {
            lines.append("cwd: \(block.workingDirectory)")
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
}
