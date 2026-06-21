import Foundation
import Observation
import AuthenticationServices
import SwiftTerm
import UIKit

enum InputRoutingMode: String, CaseIterable, Identifiable {
    case shell
    case ai

    var id: String { rawValue }
    var title: String { rawValue.uppercased() }
}

private struct BridgeExecutionMetadata: Encodable {
    let source: String
    let action_id: String?
    let conversation_id: String?
    let request_id: String?

    static func ai(actionID: String, conversationID: String, requestID: String) -> Self {
        .init(
            source: "AI",
            action_id: actionID,
            conversation_id: conversationID,
            request_id: requestID
        )
    }
}

struct BridgeCommandCompletion: Decodable {
    let block_id: UInt64
    let is_running: Bool
    let exit_code: Int32?
    let output: String
}

struct PendingAICommandSuggestion: Identifiable {
    let id = UUID()
    let prompt: String
    let command: String
    let description: String
}

@MainActor
@Observable
class SSHSession {
    var isConnected = false
    var errorMessage: String?
    var blockStore = TerminalBlockStore()

    private var rustSession: SshSession?
    private var warpSessionController: WarpSessionController?
    private weak var terminalView: SwiftTerm.TerminalView?
    // Last known terminal size; stored so we can sync it to the PTY right
    // after the connection is established (sizeChanged fires before connect).
    private var pendingCols: UInt16 = 0
    private var pendingRows: UInt16 = 0
    private var promptUsername = ""
    private var promptHostname = ""
    private var awaitingRemotePromptEcho = false
    private var promptPrimeRetryPending = false
    private var lastSuppressState: Bool?
    private var suppressedBytes = 0
    private var fedBytes = 0
    private let maxHistoryItems = 250
    private var richHistoryOriginalBuffer = ""
    private var richHistoryRequested = false
    private(set) var richHistoryVisible = false
    private(set) var richHistoryIsLoading = false
    private(set) var richHistoryItems: [RichHistoryItem] = []
    private(set) var richHistorySelectionIndex = 0
    private(set) var currentInputBuffer = ""
    private var richHistoryNeedsRefresh = true
    private var localHistoryStorageKey: String?
    private var autoDetectedRoutingMode: InputRoutingMode = .shell
    private var manualRoutingOverrideMode: InputRoutingMode?
    private var classifyDraftTask: Task<Void, Never>?
    private let classifyDebounceNanoseconds: UInt64 = 120_000_000
    private(set) var inputRoutingMode: InputRoutingMode = .shell
    var isRoutingModeForced: Bool { manualRoutingOverrideMode != nil }
    var pendingAICommandSuggestion: PendingAICommandSuggestion?
    var aiIsThinking = false
    private(set) var aiToolsEnabled = true
    private(set) var isWarpLoggedIn = false
    private(set) var warpUserEmail: String?
    @ObservationIgnored private lazy var aiActionOrchestrator = IOSAIActionOrchestrator(session: self)
    @ObservationIgnored private let warpAuthService = WarpAuthService.shared
    @ObservationIgnored private lazy var warpAIBackendClient = WarpAIBackendClient(authService: warpAuthService)
    private enum PromptFeedState {
        case interactive
        case runningBlock
        case awaitingPrecmd
    }
    private var promptFeedState: PromptFeedState = .interactive

    init() {
        refreshWarpAuthState()
    }

    func setManualRoutingModeOverride(_ mode: InputRoutingMode) {
        manualRoutingOverrideMode = mode
        updateEffectiveRoutingMode()
    }

    func clearManualRoutingModeOverride() {
        manualRoutingOverrideMode = nil
        updateEffectiveRoutingMode()
    }

    func connect(host: SSHHost, password: String? = nil) async {
        classifyDraftTask?.cancel()
        autoDetectedRoutingMode = .shell
        manualRoutingOverrideMode = nil
        updateEffectiveRoutingMode()
        blockStore.reset()
        promptFeedState = .interactive
        resetRichHistoryState()
        localHistoryStorageKey = historyStorageKey(for: host)
        blockStore.commandHistory = loadPersistedTypingHistory()
        seedRichHistoryFromLocalTypingHistory()
        promptUsername = host.username
        promptHostname = host.hostname
        awaitingRemotePromptEcho = false
        trace("connect start host=\(host.hostname) user=\(host.username)")
        refreshWarpAuthState()
        do {
            switch host.authMethod {
            case .password:
                guard let pw = password else {
                    errorMessage = "Password required"
                    return
                }
                rustSession = try await sshConnectWithPassword(
                    host: host.hostname,
                    port: UInt16(host.port),
                    username: host.username,
                    password: pw
                )
            case .key(let tag):
                let pem = try KeychainService.loadKey(tag: tag)
                rustSession = try await sshConnectWithKey(
                    host: host.hostname,
                    port: UInt16(host.port),
                    username: host.username,
                    privateKeyPem: pem
                )
            }
            if let terminalView {
                rustSession?.setReceiver(receiver: TerminalDataReceiver(terminalView: terminalView, session: self))
            }
            let warpSessionController = WarpSessionController(store: blockStore, session: self)
            self.warpSessionController = warpSessionController
            rustSession?.setEventReceiver(receiver: warpSessionController)
            // Sync PTY size to what SwiftTerm actually rendered.
            // sizeChanged fires before the connection is up, so we apply the
            // stored dimensions now.  Fall back to terminal.cols/rows if
            // pendingCols was never set (e.g., first layout happened after connect).
            let terminal = terminalView?.getTerminal()
            let cols = pendingCols > 0 ? pendingCols : UInt16(terminal?.cols ?? 80)
            let rows = pendingRows > 0 ? pendingRows : UInt16(terminal?.rows ?? 24)
            if cols > 0 && rows > 0 {
                rustSession?.resize(cols: cols, rows: rows)
            }
            isConnected = true
            trace("connect success; session ready")
        } catch {
            errorMessage = error.localizedDescription
            trace("connect failed error=\(error.localizedDescription)")
        }
    }

    // Called by the Rust bridge when the remote session ends (channel EOF/close).
    func handleRemoteDisconnect() {
        classifyDraftTask?.cancel()
        persistTypingHistory()
        isConnected = false
        rustSession = nil
        warpSessionController = nil
        localHistoryStorageKey = nil
        resetRichHistoryState()
    }

    func attachTerminalView(_ terminalView: SwiftTerm.TerminalView) {
        self.terminalView = terminalView
        if let session = rustSession {
            session.setReceiver(receiver: TerminalDataReceiver(terminalView: terminalView, session: self))
        }
        // Bootstrapped can arrive before this TerminalView is attached in the
        // block-first layout path. Prime the prompt once attachment is ready.
        if blockStore.isBootstrapped,
           !blockStore.fallbackModeEnabled,
           blockStore.activeBlockID == nil {
            awaitingRemotePromptEcho = true
            renderSyntheticPromptInTerminal()
            trace("attachTerminalView primed prompt")
        }
    }

    func handleTerminalInput(bytes: [UInt8]) -> Bool {
        if richHistoryVisible,
           !isUpArrow(bytes),
           !isDownArrow(bytes),
           !isEscape(bytes),
           !isEnter(bytes) {
            closeRichHistory(restoreInput: true, reason: "typed-dismiss")
        }

        if isUpArrow(bytes), isRichHistoryEligible {
            openOrAdvanceRichHistory()
            return true
        }

        if isDownArrow(bytes), richHistoryVisible {
            moveRichHistorySelectionDown()
            return true
        }

        if isEscape(bytes), richHistoryVisible {
            closeRichHistory(restoreInput: true, reason: "escape")
            return true
        }

        if isEnter(bytes), richHistoryVisible {
            acceptRichHistorySelection()
            return true
        }

        if isEnter(bytes), shouldRouteCurrentInputToAI {
            let prompt = currentInputBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !prompt.isEmpty else {
                updateCurrentInputBuffer(for: bytes)
                return false
            }
            if aiIsThinking {
                blockStore.applyStatus("Warp AI is still processing your previous request.")
                return true
            }
            currentInputBuffer = ""
            renderSyntheticPromptInTerminal()
            submitPromptFromTerminal(prompt)
            return true
        }

        updateCurrentInputBuffer(for: bytes)
        return false
    }

    func send(_ data: Data) {
        if let text = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !text.isEmpty {
            trace("send text='\(text)' bytes=\(data.count)")
        } else if data.contains(0x0D) || data.contains(0x0A) {
            trace("send newline bytes=\(data.count)")
        }
        rustSession?.sendData(data: Array(data))
    }

    func submitAIPrompt() async {
        submitPromptFromTerminal(aiPromptTextForLegacyCall())
    }

    private func aiPromptTextForLegacyCall() -> String {
        currentInputBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var shouldRouteCurrentInputToAI: Bool {
        aiToolsEnabled && inputRoutingMode == .ai
    }

    private func submitPromptFromTerminal(_ prompt: String) {
        guard aiToolsEnabled else { return }
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrompt.isEmpty else { return }
        aiIsThinking = true
        let promptToSubmit = trimmedPrompt
        Task { [weak self] in
            guard let self else { return }
            await self.aiActionOrchestrator.handle(prompt: promptToSubmit)
            self.aiIsThinking = false
            self.clearManualRoutingModeOverride()
            self.scheduleInputModeAutoDetection()
        }
    }

    func approvePendingAICommandSuggestion() async {
        aiIsThinking = true
        defer { aiIsThinking = false }
        await aiActionOrchestrator.approvePendingSuggestion()
    }

    func dismissPendingAICommandSuggestion() {
        pendingAICommandSuggestion = nil
    }

    func loginToWarp() async {
        do {
            try await warpAuthService.beginInteractiveLogin()
            refreshWarpAuthState()
            blockStore.applyStatus("Warp login successful. AI requests will use your subscription.")
        } catch {
            blockStore.applyStatus("Warp login failed: \(error.localizedDescription)")
        }
    }

    func logoutFromWarp() {
        warpAuthService.logout()
        refreshWarpAuthState()
        blockStore.applyStatus("Logged out of Warp AI.")
    }

    func refreshWarpAuthState() {
        let session = warpAuthService.currentSession()
        isWarpLoggedIn = session != nil
        warpUserEmail = session?.email
    }

    func executeCommandForAI(command: String, actionID: String, conversationID: String) async throws -> UInt64 {
        guard let rustSession else {
            throw NSError(domain: "SSHSession", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "No active SSH session"
            ])
        }
        // Cancel any partially typed interactive line before injecting the AI command.
        // This avoids concatenating leaked draft prompt text with the generated command.
        rustSession.sendData(data: [0x03])
        let metadata = BridgeExecutionMetadata.ai(
            actionID: actionID,
            conversationID: conversationID,
            requestID: UUID().uuidString
        )
        let metadataData = try JSONEncoder().encode(metadata)
        let metadataJSON = String(decoding: metadataData, as: UTF8.self)
        return try await rustSession.executeCommand(command: command, metadataJson: metadataJSON)
    }

    func awaitCommandCompletionForAI(blockID: UInt64, timeoutMs: UInt32) async throws -> BridgeCommandCompletion {
        guard let rustSession else {
            throw NSError(domain: "SSHSession", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "No active SSH session"
            ])
        }
        let payload = try await rustSession.awaitCommandCompletion(blockId: blockID, timeoutMs: timeoutMs)
        guard let data = payload.data(using: .utf8) else {
            throw NSError(domain: "SSHSession", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Bridge returned non-UTF8 completion payload"
            ])
        }
        return try JSONDecoder().decode(BridgeCommandCompletion.self, from: data)
    }

    func readCommandOutputForAI(blockID: UInt64) -> String {
        rustSession?.readCommandOutput(blockId: blockID) ?? ""
    }

    func cancelAICommand(blockID: UInt64) {
        rustSession?.cancelRunningCommand(blockId: blockID)
    }

    func generateCommandFromWarpAI(prompt: String) async throws -> WarpGeneratedCommand {
        let command = try await warpAIBackendClient.generateCommand(from: prompt)
        return command
    }

    func generateDialogueFromWarpAI(prompt: String) async throws -> String {
        try await warpAIBackendClient.generateAgentReply(from: prompt)
    }

    func requestRichHistory() {
        guard !richHistoryIsLoading else { return }
        guard isRichHistoryEligible else { return }
        guard let rustSession else { return }
        richHistoryRequested = true
        richHistoryIsLoading = true
        trace("history-menu request limit=\(maxHistoryItems)")
        rustSession.requestHistory(limit: UInt32(maxHistoryItems))
    }

    func handleHistorySnapshot(encoded: String) {
        richHistoryIsLoading = false
        richHistoryNeedsRefresh = false
        let decoded = decodeHistoryCommands(encoded: encoded)
        let merged = mergeWithSessionCommands(remoteCommands: decoded)
        let oldestToNewest = merged.reversed()
        richHistoryItems = oldestToNewest.enumerated().map { RichHistoryItem(id: $0.offset, command: $0.element) }
        if richHistoryVisible {
            richHistorySelectionIndex = max(0, richHistoryItems.count - 1)
            previewCurrentHistorySelection()
        }
        trace("history-menu snapshot remoteItems=\(decoded.count) mergedItems=\(richHistoryItems.count)")
    }

    func resize(cols: UInt16, rows: UInt16) {
        guard cols > 0, rows > 0 else { return }
        pendingCols = cols
        pendingRows = rows
        rustSession?.resize(cols: cols, rows: rows)
    }

    func disconnect() async {
        classifyDraftTask?.cancel()
        persistTypingHistory()
        await rustSession?.disconnect()
        isConnected = false
        rustSession = nil
        warpSessionController = nil
        localHistoryStorageKey = nil
        resetRichHistoryState()
    }

    func handlePreexecEvent() {
        trace("hook preexec activeBlock=\(String(describing: blockStore.activeBlockID))")
        persistTypingHistory()
        richHistoryVisible = false
        currentInputBuffer = ""
        promptFeedState = .runningBlock
        awaitingRemotePromptEcho = false
        if blockStore.isBootstrapped, !blockStore.fallbackModeEnabled {
            clearPromptTerminal()
        }
    }

    func handleCommandFinishedEvent() {
        trace("hook command_finished activeBlock=\(String(describing: blockStore.activeBlockID))")
        richHistoryNeedsRefresh = true
        // Keep suppressing stream bytes until precmd arrives so trailing output
        // does not leak into the prompt area.
        promptFeedState = .awaitingPrecmd
        if blockStore.isBootstrapped, !blockStore.fallbackModeEnabled {
            focusTerminalIfNeeded()
        }
    }

    func handleBootstrappedEvent() {
        promptFeedState = .interactive
        awaitingRemotePromptEcho = true
        renderSyntheticPromptInTerminal()
        if !richHistoryRequested {
            requestRichHistory()
        }
        trace("bootstrapped prompt primed")
    }

    func handlePrecmdEvent() {
        currentInputBuffer = ""
        promptFeedState = .interactive
        awaitingRemotePromptEcho = true
        renderSyntheticPromptInTerminal()
        trace("hook precmd")
    }

    private func clearPromptTerminal() {
        guard let terminalView else { return }
        // Keep the bottom prompt zone fresh like desktop Warp's input area.
        terminalView.feed(byteArray: [0x1B, 0x5B, 0x33, 0x4A]) // CSI 3J
        terminalView.feed(byteArray: [0x1B, 0x5B, 0x32, 0x4A]) // CSI 2J
        terminalView.feed(byteArray: [0x1B, 0x5B, 0x48]) // CSI H
    }

    func shouldSuppressPromptOutput() -> Bool {
        blockStore.isBootstrapped
            && !blockStore.fallbackModeEnabled
            && promptFeedState != .interactive
    }

    func recordPromptOutputPath(dataCount: Int, suppressed: Bool) {
        if suppressed {
            suppressedBytes += dataCount
        } else {
            fedBytes += dataCount
        }

        if lastSuppressState != suppressed {
            trace(
                "prompt-output suppressed=\(suppressed) activeBlock=\(String(describing: blockStore.activeBlockID)) " +
                "fedBytes=\(fedBytes) suppressedBytes=\(suppressedBytes)"
            )
            lastSuppressState = suppressed
        }
    }

    func trace(_ message: String) {
        #if DEBUG
        print("[WarpTrace] \(message)")
        #endif
    }

    func focusTerminalIfNeeded() {
        DispatchQueue.main.async { [weak terminalView] in
            _ = terminalView?.becomeFirstResponder()
        }
    }

    func relinquishTerminalFocusForAI() {
        DispatchQueue.main.async { [weak terminalView] in
            _ = terminalView?.resignFirstResponder()
        }
    }

    private func renderSyntheticPromptInTerminal() {
        renderPromptWithInput(currentInputBuffer)
    }

    private var isRichHistoryEligible: Bool {
        blockStore.isBootstrapped && !blockStore.fallbackModeEnabled
    }

    private var isAgentFollowUpForAutoDetection: Bool {
        blockStore.blocks.last?.commandSource == .ai
    }

    private func updateEffectiveRoutingMode() {
        inputRoutingMode = manualRoutingOverrideMode ?? autoDetectedRoutingMode
    }

    private func scheduleInputModeAutoDetection() {
        guard aiToolsEnabled else {
            autoDetectedRoutingMode = .shell
            updateEffectiveRoutingMode()
            return
        }

        classifyDraftTask?.cancel()
        let draft = currentInputBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
        if draft.isEmpty {
            autoDetectedRoutingMode = .shell
            updateEffectiveRoutingMode()
            return
        }

        let currentMode = autoDetectedRoutingMode.rawValue
        let isAgentFollowUp = isAgentFollowUpForAutoDetection
        classifyDraftTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(nanoseconds: self.classifyDebounceNanoseconds)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            let result = await classifyInputIntent(
                bufferText: draft,
                currentMode: currentMode,
                isAgentFollowUp: isAgentFollowUp
            )
            guard !Task.isCancelled else { return }
            self.autoDetectedRoutingMode = result.mode.lowercased() == "ai" ? .ai : .shell
            self.updateEffectiveRoutingMode()
        }
    }

    private func resetRichHistoryState() {
        classifyDraftTask?.cancel()
        autoDetectedRoutingMode = .shell
        manualRoutingOverrideMode = nil
        updateEffectiveRoutingMode()
        richHistoryVisible = false
        richHistoryIsLoading = false
        richHistoryRequested = false
        richHistoryNeedsRefresh = true
        richHistoryItems = []
        richHistorySelectionIndex = 0
        richHistoryOriginalBuffer = ""
        currentInputBuffer = ""
    }

    private func openOrAdvanceRichHistory() {
        if !richHistoryVisible {
            richHistoryVisible = true
            richHistoryOriginalBuffer = currentInputBuffer
            richHistorySelectionIndex = max(0, richHistoryItems.count - 1)
            if !richHistoryRequested || richHistoryNeedsRefresh || richHistoryItems.isEmpty {
                requestRichHistory()
            }
            previewCurrentHistorySelection()
            trace("history-menu open original='\(richHistoryOriginalBuffer)'")
            return
        }

        guard !richHistoryItems.isEmpty else { return }
        let nextIndex = max(0, richHistorySelectionIndex - 1)
        richHistorySelectionIndex = nextIndex
        previewCurrentHistorySelection()
        trace("history-menu navigate direction=up index=\(richHistorySelectionIndex)")
    }

    private func moveRichHistorySelectionDown() {
        guard !richHistoryItems.isEmpty else {
            closeRichHistory(restoreInput: true, reason: "down-empty")
            return
        }

        let nextIndex = richHistorySelectionIndex + 1
        if nextIndex >= richHistoryItems.count {
            closeRichHistory(restoreInput: true, reason: "down-end")
            return
        }

        richHistorySelectionIndex = nextIndex
        previewCurrentHistorySelection()
        trace("history-menu navigate direction=down index=\(richHistorySelectionIndex)")
    }

    private func previewCurrentHistorySelection() {
        guard richHistoryVisible else { return }
        guard richHistoryItems.indices.contains(richHistorySelectionIndex) else {
            if richHistoryVisible {
                renderPromptWithInput(richHistoryOriginalBuffer)
            }
            return
        }
        let selected = richHistoryItems[richHistorySelectionIndex].command
        currentInputBuffer = selected
        renderPromptWithInput(selected)
        trace("history-menu preview index=\(richHistorySelectionIndex)")
    }

    private func acceptRichHistorySelection() {
        guard richHistoryItems.indices.contains(richHistorySelectionIndex) else {
            closeRichHistory(restoreInput: true, reason: "accept-empty")
            return
        }
        let command = richHistoryItems[richHistorySelectionIndex].command
        closeRichHistory(restoreInput: false, reason: "accept")
        trace("history-menu accept command='\(command)'")
        executeHistorySelection(command)
    }

    private func executeHistorySelection(_ command: String) {
        let bytes = [UInt8(0x15)] + Array(command.utf8) + [UInt8(0x0D)]
        currentInputBuffer = ""
        send(Data(bytes))
    }

    private func closeRichHistory(restoreInput: Bool, reason: String) {
        guard richHistoryVisible else { return }
        richHistoryVisible = false
        if restoreInput {
            currentInputBuffer = richHistoryOriginalBuffer
            renderPromptWithInput(richHistoryOriginalBuffer)
        }
        trace("history-menu close reason=\(reason)")
    }

    private func updateCurrentInputBuffer(for bytes: [UInt8]) {
        guard !bytes.isEmpty else { return }

        if isEnter(bytes) {
            currentInputBuffer = ""
            scheduleInputModeAutoDetection()
            return
        }

        if isBackspace(bytes) {
            if !currentInputBuffer.isEmpty {
                currentInputBuffer.removeLast()
            }
            scheduleInputModeAutoDetection()
            return
        }

        if bytes.first == 0x1B {
            return
        }

        if let typed = String(bytes: bytes, encoding: .utf8), !typed.isEmpty {
            currentInputBuffer.append(typed)
            scheduleInputModeAutoDetection()
        }
    }

    private func decodeHistoryCommands(encoded: String) -> [String] {
        guard let decodedData = Data(base64Encoded: encoded),
              let text = String(data: decodedData, encoding: .utf8)
        else {
            return []
        }

        let lines = text
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !isInternalHistoryCommand($0) }

        var seen = Set<String>()
        var result: [String] = []
        for command in lines.reversed() {
            if seen.insert(command).inserted {
                result.append(command)
            }
        }
        return result
    }

    private func mergeWithSessionCommands(remoteCommands: [String]) -> [String] {
        var merged: [String] = []
        var seen = Set<String>()

        for command in remoteCommands {
            let normalized = normalizeHistoryCommand(command)
            guard !normalized.isEmpty else { continue }
            if seen.insert(normalized).inserted {
                merged.append(normalized)
            }
        }

        let sessionCommands = blockStore.commandHistory
            .reversed()
            .map(normalizeHistoryCommand)
            .filter { !$0.isEmpty && !isInternalHistoryCommand($0) }

        for command in sessionCommands where seen.insert(command).inserted {
            merged.append(command)
        }

        return merged
    }

    private func seedRichHistoryFromLocalTypingHistory() {
        let localHistory = compactedHistory(commands: blockStore.commandHistory)
        richHistoryItems = localHistory.enumerated().map { RichHistoryItem(id: $0.offset, command: $0.element) }
    }

    private func persistTypingHistory() {
        guard let key = localHistoryStorageKey else { return }
        let compacted = compactedHistory(commands: blockStore.commandHistory)
        blockStore.commandHistory = compacted
        guard let encoded = try? JSONEncoder().encode(compacted) else { return }
        UserDefaults.standard.set(encoded, forKey: key)
    }

    private func loadPersistedTypingHistory() -> [String] {
        guard let key = localHistoryStorageKey,
              let encoded = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([String].self, from: encoded)
        else {
            return []
        }
        return compactedHistory(commands: decoded)
    }

    private func historyStorageKey(for host: SSHHost) -> String {
        let scope = "\(host.username.lowercased())@\(host.hostname.lowercased()):\(host.port)"
        return "ssh_local_typing_history_\(scope)"
    }

    private func compactedHistory(commands: [String]) -> [String] {
        var seen = Set<String>()
        var newestFirst: [String] = []

        for command in commands.reversed() {
            let normalized = normalizeHistoryCommand(command)
            guard !normalized.isEmpty, !isInternalHistoryCommand(normalized) else { continue }
            if seen.insert(normalized).inserted {
                newestFirst.append(normalized)
            }
            if newestFirst.count >= maxHistoryItems {
                break
            }
        }

        return newestFirst.reversed()
    }

    private func normalizeHistoryCommand(_ command: String) -> String {
        var normalized = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return "" }

        // Bash preexec reports alias-expanded `ls --color=auto`, sometimes duplicated
        // when replayed. Normalize history entries back to what users expect to recall.
        if normalized == "ls --color=auto" {
            return "ls"
        }
        if normalized.hasPrefix("ls ") {
            let tokens = normalized.split(whereSeparator: \.isWhitespace)
            if tokens.first == "ls" {
                let filtered = tokens.filter { $0 != "--color=auto" }
                if filtered.count == 1 {
                    return "ls"
                }
                normalized = filtered.joined(separator: " ")
            }
        }

        return normalized
    }

    private func isInternalHistoryCommand(_ command: String) -> Bool {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()

        // Shell startup/teardown probes from distro profile scripts can leak
        // into remote history snapshots; keep recall focused on user commands.
        if lower.hasPrefix("/usr/bin/clear_console")
            || lower.hasPrefix("clear_console")
            || lower.contains("clear_console -q") {
            return true
        }

        if lower.hasPrefix("["),
           lower.hasSuffix("]"),
           (lower.contains("shlvl") || lower.contains("clear_console")) {
            return true
        }

        let internalNeedles = [
            "__warp_ios_",
            "PROMPT_COMMAND",
            "add-zsh-hook",
            "autoload -Uz add-zsh-hook",
            "stty erase '^H' echo echoe",
            "[ -n \"${ZSH_VERSION:-}\" ]",
            "[ -n \"${BASH_VERSION:-}\" ]",
            "case \";${PROMPT_COMMAND};\" in"
        ]
        return internalNeedles.contains { command.contains($0) }
    }

    private func isBackspace(_ bytes: [UInt8]) -> Bool {
        bytes == [0x08] || bytes == [0x7F]
    }

    private func isEscape(_ bytes: [UInt8]) -> Bool {
        bytes == [0x1B]
    }

    private func isEnter(_ bytes: [UInt8]) -> Bool {
        bytes == [0x0D] || bytes == [0x0A]
    }

    private func isUpArrow(_ bytes: [UInt8]) -> Bool {
        bytes == [0x1B, 0x5B, 0x41] || csiUKeyCode(bytes) == 65
    }

    private func isDownArrow(_ bytes: [UInt8]) -> Bool {
        bytes == [0x1B, 0x5B, 0x42] || csiUKeyCode(bytes) == 66
    }

    private func csiUKeyCode(_ bytes: [UInt8]) -> Int? {
        guard bytes.count >= 6, bytes.first == 0x1B, bytes[1] == 0x5B, bytes.last == 0x75 else {
            return nil
        }
        let body = String(decoding: bytes.dropFirst(2).dropLast(), as: UTF8.self)
        let keyCodePart = body.split(separator: ";", maxSplits: 1).first.map(String.init) ?? body
        return Int(keyCodePart)
    }

    private func promptPrefix() -> String {
        let cwd = blockStore.currentWorkingDirectory
        let dir: String
        if cwd.isEmpty {
            dir = "~"
        } else if cwd == "/" {
            dir = "/"
        } else {
            dir = cwd.split(separator: "/").last.map(String.init) ?? cwd
        }
        return "\(promptUsername)@\(promptHostname):\(dir) $ "
    }

    private func renderPromptWithInput(_ input: String) {
        guard blockStore.isBootstrapped, !blockStore.fallbackModeEnabled else { return }
        guard let terminalView else { return }
        let cols = terminalView.getTerminal().cols
        // TerminalView can attach before layout and briefly report tiny widths
        // (e.g. 1 col), which would wrap prompt text vertically.
        if cols < 20 {
            if !promptPrimeRetryPending {
                promptPrimeRetryPending = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { [weak self] in
                    guard let self else { return }
                    self.promptPrimeRetryPending = false
                    self.renderSyntheticPromptInTerminal()
                }
            }
            trace("defer synthetic prompt until layout settles cols=\(cols)")
            return
        }

        let fullPrompt = promptPrefix() + input
        let bytes = Array(fullPrompt.utf8)
        terminalView.feed(byteArray: [0x1B, 0x5B, 0x32, 0x4A]) // CSI 2J
        terminalView.feed(byteArray: [0x1B, 0x5B, 0x48]) // CSI H
        terminalView.feed(byteArray: [0x0D, 0x1B, 0x5B, 0x32, 0x4B]) // CR + CSI 2K
        terminalView.feed(byteArray: bytes[...])
    }

    private func looksLikePromptLine(_ text: String) -> Bool {
        let ansiPattern = "\u{001B}\\[[0-9;?]*[ -/]*[@-~]"
        let cleaned: String
        if let regex = try? NSRegularExpression(pattern: ansiPattern) {
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            cleaned = regex.stringByReplacingMatches(in: text, range: range, withTemplate: "")
        } else {
            cleaned = text
        }
        let line = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return false }
        return line.contains("@")
            && line.contains(":")
            && (line.hasSuffix("$") || line.hasSuffix("$ ") || line.hasSuffix("%") || line.hasSuffix("% "))
    }

    func filterIdlePromptEcho(_ data: [UInt8]) -> [UInt8] {
        guard awaitingRemotePromptEcho else { return data }
        guard let text = String(bytes: data, encoding: .utf8) else { return data }
        if looksLikePromptLine(text) {
            awaitingRemotePromptEcho = false
            trace("dropped remote prompt echo (using synthetic prompt)")
            return []
        }
        return data
    }
}

@MainActor
final class IOSAIActionOrchestrator {
    private weak var session: SSHSession?
    private let completionTimeoutMs: UInt32 = 30_000

    init(session: SSHSession) {
        self.session = session
    }

    func handle(prompt: String) async {
        guard let session else { return }
        if let explicitCommand = parseRequestedCommand(from: prompt) {
            session.pendingAICommandSuggestion = nil
            await executeCommand(
                explicitCommand,
                description: "Explicit user-requested command",
                sourcePrompt: prompt
            )
        } else {
            guard session.isWarpLoggedIn else {
                session.blockStore.applyStatus("Log in to Warp AI first, or use `run <shell command>` / `!<shell command>`.")
                return
            }
            let dialoguePath = shouldUseDialogue(for: prompt)
            if dialoguePath {
                do {
                    let answer = try await session.generateDialogueFromWarpAI(prompt: prompt)
                    if isProgrammingOnlyGuardrail(answer) {
                        session.trace("ai backend dialogue returned programming-only guardrail")
                        session.blockStore.applyStatus(
                            "Warp AI responded with a programming-only guardrail for this prompt. " +
                            "Desktop `/agent` uses a different backend path; iOS needs that integration for parity."
                        )
                        return
                    }
                    session.pendingAICommandSuggestion = nil
                    session.blockStore.appendAIDialogue(prompt: prompt, answer: answer)
                    session.trace("ai backend dialogue answered chars=\(answer.count)")
                } catch {
                    session.trace("ai backend dialogue failed error=\(error.localizedDescription)")
                    let lower = error.localizedDescription.lowercased()
                    if lower.contains("not ready") || lower.contains("timed out") || lower.contains("pending") {
                        session.blockStore.applyStatus(
                            "Warp agent is still spinning up. Please retry in a few seconds."
                        )
                    } else if lower.contains("oz harness") || lower.contains("agent run failed") {
                        session.blockStore.applyStatus(
                            "Warp agent hit a backend error and could not answer. " +
                            "Please retry — a fresh agent session will start automatically."
                        )
                    } else {
                        session.blockStore.applyStatus("Warp AI dialogue failed: \(error.localizedDescription)")
                    }
                }
                return
            }
            do {
                let generated = try await session.generateCommandFromWarpAI(prompt: prompt)
                let hydratedCommand = hydrateTemplateCommandIfNeeded(generated.command, prompt: prompt)
                let optimizedCommand = optimizeFileSearchCommandIfNeeded(hydratedCommand, prompt: prompt)
                if isLowSignalEchoCommand(optimizedCommand, prompt: prompt) {
                    session.trace("ai backend returned low-signal echo command; skipping execution")
                    session.blockStore.applyStatus(
                        "AI suggested a placeholder echo command instead of a useful action. " +
                        "Try a more specific prompt, or use `run <shell command>` / `!<shell command>`."
                    )
                    return
                }
                session.pendingAICommandSuggestion = PendingAICommandSuggestion(
                    prompt: prompt,
                    command: optimizedCommand,
                    description: generated.description
                )
                session.trace(
                    "ai backend generated command='\(optimizedCommand)' description='\(generated.description)'"
                )
                session.blockStore.applyStatus(
                    "AI suggested `\(optimizedCommand)`. Review and tap Run to execute. Nothing has run yet."
                )
            } catch {
                session.trace("ai backend request failed error=\(error.localizedDescription)")
                session.blockStore.applyStatus("Warp AI request failed: \(error.localizedDescription)")
            }
        }
    }

    func approvePendingSuggestion() async {
        guard let session else { return }
        guard let pending = session.pendingAICommandSuggestion else { return }
        session.pendingAICommandSuggestion = nil
        await executeCommand(
            pending.command,
            description: pending.description,
            sourcePrompt: pending.prompt
        )
    }

    private func executeCommand(_ command: String, description: String, sourcePrompt: String) async {
        guard let session else { return }
        session.trace("ai execute command='\(command)' prompt='\(sourcePrompt)'")
        let actionID = "ios-ai-action-\(UUID().uuidString)"
        let conversationID = "ios-ai-conversation-\(UUID().uuidString)"

        do {
            let blockID = try await session.executeCommandForAI(
                command: command,
                actionID: actionID,
                conversationID: conversationID
            )
            let completion = try await session.awaitCommandCompletionForAI(
                blockID: blockID,
                timeoutMs: completionTimeoutMs
            )

            if completion.is_running {
                session.blockStore.applyStatus("AI command is still running (block \(blockID)).")
            } else {
                let output = session.readCommandOutputForAI(blockID: blockID)
                let preview = output
                    .split(separator: "\n", omittingEmptySubsequences: true)
                    .prefix(3)
                    .joined(separator: "\n")
                let renderedPreview = preview.isEmpty ? "(no output)" : preview
                session.blockStore.applyStatus(
                    "AI ran `\(command)` (exit \(completion.exit_code ?? -1)).\n\(renderedPreview)"
                )
            }
        } catch {
            session.trace("ai command execution failed error=\(error.localizedDescription)")
            session.blockStore.applyStatus("AI command failed: \(error.localizedDescription)")
        }
    }

    private func parseRequestedCommand(from prompt: String) -> String? {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("!") {
            let command = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
            return command.isEmpty ? nil : command
        }
        if trimmed.lowercased().hasPrefix("run ") {
            let command = String(trimmed.dropFirst(4)).trimmingCharacters(in: .whitespacesAndNewlines)
            return command.isEmpty ? nil : command
        }
        return nil
    }

    private func isLowSignalEchoCommand(_ command: String, prompt: String) -> Bool {
        guard let echoed = echoedText(from: command) else { return false }
        let normalizedEcho = normalizeLowSignalText(echoed)
        let normalizedPrompt = normalizeLowSignalText(prompt)
        return normalizedEcho == normalizedPrompt
    }

    private func echoedText(from command: String) -> String? {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.lowercased().hasPrefix("echo ") else { return nil }
        let argument = String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !argument.isEmpty else { return nil }

        if argument.count >= 2 {
            if argument.hasPrefix("'"), argument.hasSuffix("'") {
                return String(argument.dropFirst().dropLast())
            }
            if argument.hasPrefix("\""), argument.hasSuffix("\"") {
                return String(argument.dropFirst().dropLast())
            }
        }
        return argument
    }

    private func normalizeLowSignalText(_ text: String) -> String {
        text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .lowercased()
    }

    private func shouldUseDialogue(for prompt: String) -> Bool {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = trimmed.lowercased()
        if normalized.isEmpty {
            return false
        }

        if looksLikeFileSearchPrompt(prompt) {
            return false
        }

        // If the request looks like shell intent, prefer command generation path.
        let shellIntentNeedles = [
            "command", "shell", "terminal", "bash", "zsh", "linux", "ssh",
            "script", "run ", "execute ", "cli", "git ", "docker ", "kubectl ",
            "ls ", "pwd", "cd ", "chmod", "chown", "apt ", "brew ", "npm ", "cargo ", "python "
        ]
        if shellIntentNeedles.contains(where: { normalized.contains($0) }) {
            return false
        }
        // Default AI mode behavior should be conversational unless command intent is explicit.
        return true
    }

    private func looksLikeFileSearchPrompt(_ prompt: String) -> Bool {
        let normalized = prompt.lowercased()
        let hasFileScope = normalized.contains(" file")
            || normalized.contains("files ")
            || normalized.contains("filename")
            || normalized.contains("repo")
            || normalized.contains("project")
            || normalized.contains("directory")
            || normalized.contains("folder")
        let hasSearchIntent = normalized.contains("find ")
            || normalized.contains("look for")
            || normalized.contains("search")
            || normalized.contains("contain")
            || normalized.contains("contains")
            || normalized.contains("named ")
            || normalized.contains("name ")
            || normalized.contains("string ")
        return hasFileScope && hasSearchIntent
    }

    private func hydrateTemplateCommandIfNeeded(_ command: String, prompt: String) -> String {
        var hydrated = command
        let searchTerm = extractSearchTerm(from: prompt)
        if let searchTerm {
            let quotedSearchTerm = shellQuote(searchTerm)
            hydrated = hydrated.replacingOccurrences(of: "'{{search_string}}'", with: quotedSearchTerm)
            hydrated = hydrated.replacingOccurrences(of: "\"{{search_string}}\"", with: quotedSearchTerm)
            hydrated = hydrated.replacingOccurrences(of: "{{search_string}}", with: quotedSearchTerm)
            hydrated = hydrated.replacingOccurrences(of: "{{query}}", with: quotedSearchTerm)
            hydrated = hydrated.replacingOccurrences(of: "{{pattern}}", with: quotedSearchTerm)
        }
        hydrated = hydrated.replacingOccurrences(of: "{{directory}}", with: ".")
        hydrated = hydrated.replacingOccurrences(of: "{{path}}", with: ".")
        return hydrated
    }

    private func containsTemplatePlaceholders(_ command: String) -> Bool {
        command.contains("{{") && command.contains("}}")
    }

    private func optimizeFileSearchCommandIfNeeded(_ command: String, prompt: String) -> String {
        guard looksLikeFileSearchPrompt(prompt) else { return command }
        let normalized = command.lowercased()
        guard normalized.contains("grep -r"), normalized.contains(" -l ") || normalized.contains("-rl") else {
            return command
        }
        guard let searchTerm = extractSearchTerm(from: prompt) else { return command }
        let quotedSearchTerm = shellQuote(searchTerm)
        // Prefer ripgrep for significantly faster recursive content search.
        return "rg -l --fixed-strings \(quotedSearchTerm) ."
    }

    private func extractSearchTerm(from prompt: String) -> String? {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let quotePatterns = ["\"([^\"]+)\"", "'([^']+)'"]
        for pattern in quotePatterns {
            if let regex = try? NSRegularExpression(pattern: pattern),
               let match = regex.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)),
               match.numberOfRanges >= 2,
               let range = Range(match.range(at: 1), in: trimmed) {
                let captured = String(trimmed[range]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !captured.isEmpty {
                    return captured
                }
            }
        }

        let tokenPatterns = [
            "(?:string|name|named)\\s+([A-Za-z0-9._-]+)",
            "find\\s+([A-Za-z0-9._-]+)"
        ]
        for pattern in tokenPatterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
               let match = regex.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)),
               match.numberOfRanges >= 2,
               let range = Range(match.range(at: 1), in: trimmed) {
                let captured = String(trimmed[range]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !captured.isEmpty {
                    return captured
                }
            }
        }

        return nil
    }

    private func shellQuote(_ value: String) -> String {
        let escaped = value.replacingOccurrences(of: "'", with: "'\"'\"'")
        return "'\(escaped)'"
    }

    private func isProgrammingOnlyGuardrail(_ answer: String) -> Bool {
        WarpAIDialogueQuality.isProgrammingOnlyGuardrail(answer)
    }
}

struct WarpGeneratedCommand {
    let command: String
    let description: String
}

private enum WarpAIDialogueQuality {
    static func isProgrammingOnlyGuardrail(_ answer: String) -> Bool {
        let normalized = answer.lowercased()
        let needles = [
            "programming-related questions",
            "computer programming questions",
            "questions in that domain",
            "if you have any queries related to that",
            "queries related to coding",
            "feel free to ask",
            "i'm here to help with programming",
            "i'm here to provide information and assistance related to computer programming",
            "if you have any questions in that domain"
        ]
        return needles.contains(where: { normalized.contains($0) })
    }
}

private struct WarpRequestContext: Encodable {
    let clientContext: ClientContext
    let osContext: OSContext

    struct ClientContext: Encodable {
        let version: String?
    }

    struct OSContext: Encodable {
        let category: String?
        let linuxKernelVersion: String?
        let name: String?
        let version: String?
    }

    static func current() -> Self {
        .init(
            clientContext: .init(version: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String),
            osContext: .init(
                category: "iOS",
                linuxKernelVersion: nil,
                name: UIDevice.current.systemName,
                version: UIDevice.current.systemVersion
            )
        )
    }
}

@MainActor
@Observable
final class WarpAuthService: NSObject, ASWebAuthenticationPresentationContextProviding {
    static let shared = WarpAuthService()

    private let serverRoot = "https://app.warp.dev"
    private let firebaseApiKey = "AIzaSyBdy3O3S9hrdayLJxJ7mriBR4qgUaUygAs"
    // Warp login flow is desktop-first and reliably supports `warp` redirects.
    // We still register `warpios` in Info.plist for compatibility.
    private let callbackScheme = "warp"
    private let keychainService = "warp-ios-auth"
    private let keychainAccount = "firebase-session"
    @ObservationIgnored private var webAuthSession: ASWebAuthenticationSession?
    @ObservationIgnored private var pendingAuthState: String?
    private var storedSession: StoredWarpAuthSession?

    var isAuthenticated: Bool { storedSession != nil }

    override init() {
        super.init()
        storedSession = loadSessionFromKeychain()
    }

    func currentSession() -> StoredWarpAuthSession? {
        storedSession
    }

    func beginInteractiveLogin() async throws {
        let authState = UUID().uuidString
        pendingAuthState = authState
        guard let loginURL = URL(string: "\(serverRoot)/login/remote?scheme=\(callbackScheme)&state=\(authState)") else {
            throw WarpAuthError.invalidURL
        }

        let refreshToken = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            let continuationLock = NSLock()
            var didResume = false

            func resumeOnce(_ block: () -> Void) {
                continuationLock.lock()
                defer { continuationLock.unlock() }
                guard !didResume else { return }
                didResume = true
                block()
            }

            let session = ASWebAuthenticationSession(url: loginURL, callbackURLScheme: callbackScheme) { [weak self] callbackURL, error in
                guard let self else {
                    resumeOnce { continuation.resume(throwing: WarpAuthError.cancelled) }
                    return
                }
                defer {
                    self.pendingAuthState = nil
                    self.webAuthSession = nil
                }
                if let error {
                    resumeOnce { continuation.resume(throwing: error) }
                    return
                }
                guard let callbackURL else {
                    resumeOnce { continuation.resume(throwing: WarpAuthError.cancelled) }
                    return
                }
                do {
                    let parsed = try self.parseRefreshToken(from: callbackURL)
                    resumeOnce { continuation.resume(returning: parsed) }
                } catch {
                    resumeOnce { continuation.resume(throwing: error) }
                }
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            webAuthSession = session
            if !session.start() {
                resumeOnce { continuation.resume(throwing: WarpAuthError.cancelled) }
            }
        }

        let refreshedSession = try await exchangeRefreshToken(refreshToken: refreshToken)
        storedSession = refreshedSession
        saveSessionToKeychain(refreshedSession)
    }

    func validBearerToken() async throws -> String {
        guard var session = storedSession else {
            throw WarpAuthError.notLoggedIn
        }
        let refreshLeadTime: TimeInterval = 5 * 60
        if Date().addingTimeInterval(refreshLeadTime) >= session.expirationTime {
            session = try await exchangeRefreshToken(refreshToken: session.refreshToken)
            storedSession = session
            saveSessionToKeychain(session)
        }
        return session.idToken
    }

    func logout() {
        storedSession = nil
        KeychainService.deleteData(account: keychainAccount, service: keychainService)
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow) ?? ASPresentationAnchor()
    }

    private func parseRefreshToken(from callbackURL: URL) throws -> String {
        guard callbackURL.host == "auth" else {
            throw WarpAuthError.invalidCallback("unexpected callback host")
        }
        let params = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?
            .queryItems?
            .reduce(into: [String: String]()) { partialResult, item in
                partialResult[item.name] = item.value
            } ?? [:]
        if let expectedState = pendingAuthState, params["state"] != expectedState {
            throw WarpAuthError.invalidCallback("state mismatch")
        }
        guard let refreshToken = params["refresh_token"], !refreshToken.isEmpty else {
            throw WarpAuthError.invalidCallback("missing refresh token")
        }
        return refreshToken
    }

    private func exchangeRefreshToken(refreshToken: String) async throws -> StoredWarpAuthSession {
        let body = "grant_type=refresh_token&refresh_token=\(refreshToken.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? refreshToken)"
        let primary = URL(string: "https://securetoken.googleapis.com/v1/token?key=\(firebaseApiKey)")
        let fallback = URL(string: "\(serverRoot)/proxy/token?key=\(firebaseApiKey)")
        guard let primary else { throw WarpAuthError.invalidURL }
        let response: FirebaseTokenResponse?
        if let primaryResponse = try await performTokenExchange(url: primary, body: body) {
            response = primaryResponse
        } else if let fallback {
            response = try await performTokenExchange(url: fallback, body: body)
        } else {
            throw WarpAuthError.invalidURL
        }
        guard let tokenResponse = response else {
            throw WarpAuthError.tokenExchangeFailed("no response from token exchange")
        }
        let expirationSeconds = TimeInterval(tokenResponse.expiresIn) ?? 3600
        return StoredWarpAuthSession(
            refreshToken: tokenResponse.refreshToken,
            idToken: tokenResponse.idToken,
            expirationTime: Date().addingTimeInterval(expirationSeconds),
            email: nil
        )
    }

    private func performTokenExchange(url: URL, body: String) async throws -> FirebaseTokenResponse? {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = Data(body.utf8)
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw WarpAuthError.tokenExchangeFailed("invalid response")
        }
        if !(200...299).contains(http.statusCode) {
            return nil
        }
        return try JSONDecoder().decode(FirebaseTokenResponse.self, from: data)
    }

    private func saveSessionToKeychain(_ session: StoredWarpAuthSession) {
        guard let data = try? JSONEncoder().encode(session) else { return }
        try? KeychainService.saveData(data, account: keychainAccount, service: keychainService)
    }

    private func loadSessionFromKeychain() -> StoredWarpAuthSession? {
        guard let data = try? KeychainService.loadData(account: keychainAccount, service: keychainService) else {
            return nil
        }
        return try? JSONDecoder().decode(StoredWarpAuthSession.self, from: data)
    }
}

struct StoredWarpAuthSession: Codable {
    let refreshToken: String
    let idToken: String
    let expirationTime: Date
    let email: String?
}

private struct FirebaseTokenResponse: Decodable {
    let expiresIn: String
    let idToken: String
    let refreshToken: String

    private enum CodingKeys: String, CodingKey {
        case expiresIn
        case expires_in
        case idToken
        case id_token
        case refreshToken
        case refresh_token
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        expiresIn = try container.decodeIfPresent(String.self, forKey: .expiresIn)
            ?? container.decode(String.self, forKey: .expires_in)
        idToken = try container.decodeIfPresent(String.self, forKey: .idToken)
            ?? container.decode(String.self, forKey: .id_token)
        refreshToken = try container.decodeIfPresent(String.self, forKey: .refreshToken)
            ?? container.decode(String.self, forKey: .refresh_token)
    }
}

final class WarpAIBackendClient {
    private let authService: WarpAuthService
    private let serverRoot = "https://app.warp.dev"
    private var agentRunID: String?
    private var agentTaskID: String?
    private var lastAgentAssistantFingerprint: String?
    private var lastAgentMessageID: String?
    private var lastConversationPayloadByteCount: Int?
    private var pendingAgentPrompt: String?

    init(authService: WarpAuthService) {
        self.authService = authService
    }

    func generateAgentReply(from prompt: String) async throws -> String {
        let token = try await authService.validBearerToken()
        let promptPreview = preview(prompt)
        trace("AgentRun reply start prompt_chars=\(prompt.count) prompt_preview='\(promptPreview)'")

        let runID: String
        if let existing = agentRunID {
            runID = existing
            if let pending = pendingAgentPrompt {
                trace("AgentRun pending prompt exists; fetching before new followup pending_preview='\(preview(pending))'")
                let pendingReply = try await pollAgentAssistantReply(
                    runID: runID,
                    token: token,
                    expectedPrompt: pending
                )
                pendingAgentPrompt = nil

                // If user retried the same prompt while pending, return resolved reply.
                if normalizePromptForMatching(pending) == normalizePromptForMatching(prompt) {
                    trace("AgentRun pending prompt matched current prompt; returning pending reply")
                    return pendingReply
                }
            }
            try await submitAgentFollowup(runID: runID, prompt: prompt, token: token)
            pendingAgentPrompt = prompt
        } else {
            runID = try await spawnAgentRun(prompt: prompt, token: token)
            agentRunID = runID
            pendingAgentPrompt = prompt
        }

        let reply = try await pollAgentAssistantReply(
            runID: runID,
            token: token,
            expectedPrompt: prompt
        )
        pendingAgentPrompt = nil
        trace("AgentRun reply success run_id=\(runID) answer_chars=\(reply.count)")
        return reply
    }

    func generateCommand(from prompt: String) async throws -> WarpGeneratedCommand {
        let token = try await authService.validBearerToken()
        trace("GenerateCommands start prompt_chars=\(prompt.count) prompt_preview='\(preview(prompt))'")
        let requestLimitInfo = try await fetchRequestLimitInfo(token: token)
        if let requestLimitInfo,
           !requestLimitInfo.isUnlimited,
           requestLimitInfo.requestsUsedSinceLastRefresh >= requestLimitInfo.requestLimit {
            throw WarpAuthError.subscriptionLimited("request limit reached for current plan")
        }

        let query = """
        mutation GenerateCommands($input: GenerateCommandsInput!, $requestContext: RequestContext!) {
          generateCommands(input: $input, requestContext: $requestContext) {
            __typename
            ... on GenerateCommandsOutput {
              status {
                __typename
                ... on GenerateCommandsSuccess {
                  commands {
                    command
                    description
                  }
                }
                ... on GenerateCommandsFailure {
                  type
                }
              }
            }
            ... on UserFacingError {
              error { message }
            }
          }
        }
        """

        let variables = [
            "input": ["prompt": prompt],
            "requestContext": requestContextJSON()
        ] as [String: Any]
        let payload = try await sendGraphQL(op: "GenerateCommands", query: query, variables: variables, token: token)
        let decoded = try JSONDecoder().decode(GenerateCommandsEnvelope.self, from: payload)
        guard let result = decoded.data?.generateCommands else {
            throw WarpAuthError.aiRequestFailed("missing generateCommands response")
        }
        trace("GenerateCommands result_typename=\(result.__typename) status_typename=\(result.status?.__typename ?? "nil")")

        if result.__typename == "UserFacingError" {
            throw WarpAuthError.aiRequestFailed(result.error?.message ?? "user-facing error")
        }

        guard result.status?.__typename == "GenerateCommandsSuccess",
              let command = result.status?.commands?.first else {
            let failureType = result.status?.type ?? "Unknown"
            throw WarpAuthError.aiRequestFailed("generateCommands failed: \(failureType)")
        }
        trace("GenerateCommands first_command='\(command.command)' description='\(command.description)' model=unavailable")
        return WarpGeneratedCommand(command: command.command, description: command.description)
    }

    func generateDialogue(from prompt: String) async throws -> String {
        let token = try await authService.validBearerToken()
        trace("GenerateDialogue start prompt_chars=\(prompt.count) prompt_preview='\(preview(prompt))'")
        let firstAnswer = try await generateDialogueOnce(prompt: prompt, token: token)
        if WarpAIDialogueQuality.isProgrammingOnlyGuardrail(firstAnswer) {
            let reframedPrompt =
                """
                Please answer the user's question directly and helpfully in plain language.
                Do not respond with policy boilerplate unless there is an actual safety issue.
                User question: \(prompt)
                """
            trace("GenerateDialogue retry due_to=low_quality first_answer_preview='\(preview(firstAnswer))'")
            let retried = try await generateDialogueOnce(prompt: reframedPrompt, token: token)
            if WarpAIDialogueQuality.isProgrammingOnlyGuardrail(retried) {
                throw WarpAuthError.aiRequestFailed("legacy dialogue endpoint returned programming-only guardrail")
            }
            return retried
        }
        return firstAnswer
    }

    private func generateDialogueOnce(prompt: String, token: String) async throws -> String {
        let query = """
        mutation GenerateDialogue($input: GenerateDialogueInput!, $requestContext: RequestContext!) {
          generateDialogue(input: $input, requestContext: $requestContext) {
            __typename
            ... on GenerateDialogueOutput {
              status {
                __typename
                ... on GenerateDialogueSuccess {
                  answer
                  truncated
                }
                ... on GenerateDialogueFailure {
                  requestLimitInfo {
                    isUnlimited
                  }
                }
              }
            }
            ... on UserFacingError {
              error { message }
            }
          }
        }
        """
        let variables: [String: Any] = [
            "input": [
                "prompt": prompt,
                "transcript": []
            ],
            "requestContext": requestContextJSON()
        ]
        let payload = try await sendGraphQL(op: "GenerateDialogue", query: query, variables: variables, token: token)
        let decoded = try JSONDecoder().decode(GenerateDialogueEnvelope.self, from: payload)
        guard let result = decoded.data?.generateDialogue else {
            throw WarpAuthError.aiRequestFailed("missing generateDialogue response")
        }
        trace("GenerateDialogue result_typename=\(result.__typename) status_typename=\(result.status?.__typename ?? "nil")")
        if result.__typename == "UserFacingError" {
            throw WarpAuthError.aiRequestFailed(result.error?.message ?? "user-facing error")
        }
        guard result.status?.__typename == "GenerateDialogueSuccess",
              let answer = result.status?.answer else {
            throw WarpAuthError.aiRequestFailed("generateDialogue failed")
        }
        trace("GenerateDialogue answer_chars=\(answer.count) truncated=\(result.status?.truncated ?? false) model=unavailable")
        return answer
    }

    private func resetAgentSession(reason: String) {
        agentRunID = nil
        agentTaskID = nil
        pendingAgentPrompt = nil
        lastAgentAssistantFingerprint = nil
        lastAgentMessageID = nil
        lastConversationPayloadByteCount = nil
        trace("AgentRun session reset reason=\(reason)")
    }

    private func fetchRequestLimitInfo(token: String) async throws -> RequestLimitInfoResponse? {
        let query = """
        query GetRequestLimitInfo($requestContext: RequestContext!) {
          user(requestContext: $requestContext) {
            __typename
            ... on UserOutput {
              user {
                requestLimitInfo {
                  isUnlimited
                  requestsUsedSinceLastRefresh
                  requestLimit
                }
              }
            }
          }
        }
        """
        let variables = ["requestContext": requestContextJSON()]
        let data = try await sendGraphQL(op: "GetRequestLimitInfo", query: query, variables: variables, token: token)
        let decoded = try JSONDecoder().decode(RequestLimitEnvelope.self, from: data)
        return decoded.data?.user?.user?.requestLimitInfo
    }

    private func sendGraphQL(op: String, query: String, variables: [String: Any], token: String) async throws -> Data {
        guard let url = URL(string: "\(serverRoot)/graphql/v2?op=\(op)") else {
            throw WarpAuthError.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0", forHTTPHeaderField: "X-Warp-Client-Version")
        request.setValue("iOS", forHTTPHeaderField: "X-Warp-OS-Category")
        request.setValue(UIDevice.current.systemName, forHTTPHeaderField: "X-Warp-OS-Name")
        request.setValue(UIDevice.current.systemVersion, forHTTPHeaderField: "X-Warp-OS-Version")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "query": query,
            "variables": variables
        ])
        trace("GraphQL request op=\(op) body_bytes=\(request.httpBody?.count ?? 0)")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw WarpAuthError.aiRequestFailed("request failed: invalid HTTP response")
        }
        let requestID = http.value(forHTTPHeaderField: "x-request-id")
            ?? http.value(forHTTPHeaderField: "X-Request-Id")
            ?? "none"
        trace("GraphQL response op=\(op) status=\(http.statusCode) bytes=\(data.count) request_id=\(requestID)")
        guard (200...299).contains(http.statusCode) else {
            throw WarpAuthError.aiRequestFailed("request failed with status \(http.statusCode)")
        }
        return data
    }

    private func spawnAgentRun(prompt: String, token: String) async throws -> String {
        let payload: [String: Any] = [
            "prompt": prompt,
            "mode": "normal",
            "interactive": true
        ]
        let data = try await sendPublicAPIRequest(
            method: "POST",
            path: "agent/run",
            body: payload,
            token: token
        )
        let decoded = try JSONDecoder().decode(AgentRunSpawnResponse.self, from: data)
        agentTaskID = decoded.task_id
        trace("AgentRun spawn run_id=\(decoded.run_id) task_id=\(decoded.task_id)")
        return decoded.run_id
    }

    private func submitAgentFollowup(runID: String, prompt: String, token: String) async throws {
        let body = ["message": prompt]
        _ = try await sendPublicAPIRequest(
            method: "POST",
            path: "agent/runs/\(runID)/followups",
            body: body,
            token: token
        )
        trace("AgentRun followup submitted run_id=\(runID) prompt_chars=\(prompt.count)")
    }

    private func pollAgentAssistantReply(
        runID: String,
        token: String,
        expectedPrompt: String
    ) async throws -> String {
        let timeoutNs: UInt64 = 45 * 1_000_000_000
        let pollNs: UInt64 = 750_000_000
        let start = DispatchTime.now().uptimeNanoseconds
        var attempts = 0

        while DispatchTime.now().uptimeNanoseconds - start < timeoutNs {
            attempts += 1
            let data = try await fetchRunConversation(runID: runID, token: token, attempt: attempts)
            if let data,
               let conversation = try? JSONSerialization.jsonObject(with: data),
               let candidate = extractLatestAssistantMessage(from: conversation, expectedPrompt: expectedPrompt) {
                let fingerprint = "\(candidate.id ?? "no-id"):\(candidate.text)"
                if fingerprint != lastAgentAssistantFingerprint {
                    lastAgentAssistantFingerprint = fingerprint
                    trace(
                        "AgentRun conversation reply_found run_id=\(runID) attempt=\(attempts) " +
                        "message_id=\(candidate.id ?? "none") answer_chars=\(candidate.text.count)"
                    )
                    return candidate.text
                }
            } else if let data {
                if lastConversationPayloadByteCount != data.count {
                    lastConversationPayloadByteCount = data.count
                    let preview = String(decoding: data.prefix(260), as: UTF8.self)
                        .replacingOccurrences(of: "\n", with: " ")
                    trace("AgentRun conversation parse_miss bytes=\(data.count) preview='\(preview)'")
                }
            }

            if let metadataConversationReply = try await pollConversationViaRunMetadata(
                runID: runID,
                token: token,
                attempt: attempts,
                expectedPrompt: expectedPrompt
            ) {
                return metadataConversationReply
            }

            if let messageReply = try await pollAgentMessageChannel(runID: runID, token: token, attempt: attempts) {
                return messageReply
            }

            try await Task.sleep(nanoseconds: pollNs)
        }

        resetAgentSession(reason: "poll_timeout")
        throw WarpAuthError.aiRequestFailed("agent run timed out waiting for assistant reply")
    }

    private func pollConversationViaRunMetadata(
        runID: String,
        token: String,
        attempt: Int,
        expectedPrompt: String
    ) async throws -> String? {
        let runData = try await sendPublicAPIRequest(
            method: "GET",
            path: "agent/runs/\(runID)",
            body: nil,
            token: token
        )
        guard let runJSON = try? JSONSerialization.jsonObject(with: runData),
              let conversationID = extractConversationID(from: runJSON)
        else {
            if let runJSON = try? JSONSerialization.jsonObject(with: runData),
               let runStatus = parseRunStatus(from: runJSON) {
                trace(
                    "AgentRun status run_id=\(runID) attempt=\(attempt) " +
                    "state=\(runStatus.state ?? "unknown") " +
                    "status_message='\(runStatus.statusMessage ?? "none")'"
                )
                if runStatus.isTerminalFailure {
                    resetAgentSession(reason: "terminal_failure")
                    throw WarpAuthError.aiRequestFailed(
                        "agent run failed: \(runStatus.statusMessage ?? "terminal state without response")"
                    )
                }
            }

            // Some environments key conversation routes by run id directly.
            if let directConversation = try await fetchConversationByID(
                conversationID: runID,
                token: token,
                runID: runID,
                attempt: attempt,
                expectedPrompt: expectedPrompt
            ) {
                return directConversation
            }
            return nil
        }

        return try await fetchConversationByID(
            conversationID: conversationID,
            token: token,
            runID: runID,
            attempt: attempt,
            expectedPrompt: expectedPrompt
        )
    }

    private func fetchConversationByID(
        conversationID: String,
        token: String,
        runID: String,
        attempt: Int,
        expectedPrompt: String
    ) async throws -> String? {
        let conversationData: Data
        do {
            conversationData = try await sendPublicAPIRequest(
                method: "GET",
                path: "agent/conversations/\(conversationID)",
                body: nil,
                token: token
            )
        } catch {
            let description = (error as NSError).localizedDescription.lowercased()
            if description.contains("status 404") {
                return nil
            }
            throw error
        }
        guard let conversationJSON = try? JSONSerialization.jsonObject(with: conversationData),
              let candidate = extractLatestAssistantMessage(from: conversationJSON, expectedPrompt: expectedPrompt)
        else {
            return nil
        }
        let normalizedExpected = normalizePromptForMatching(expectedPrompt)
        let normalizedCandidate = normalizePromptForMatching(candidate.text)

        let fingerprint = "\(candidate.id ?? "no-id"):\(candidate.text)"
        guard fingerprint != lastAgentAssistantFingerprint else {
            return nil
        }
        lastAgentAssistantFingerprint = fingerprint
        trace(
            "AgentRun metadata conversation reply_found run_id=\(runID) attempt=\(attempt) " +
            "conversation_id=\(conversationID) message_id=\(candidate.id ?? "none") answer_chars=\(candidate.text.count)"
        )
        return candidate.text
    }

    private func fetchRunConversation(runID: String, token: String, attempt: Int) async throws -> Data? {
        do {
            return try await sendPublicAPIRequest(
                method: "GET",
                path: "agent/runs/\(runID)/conversation",
                body: nil,
                token: token
            )
        } catch {
            let description = (error as NSError).localizedDescription.lowercased()
            if description.contains("status 404") {
                trace("AgentRun conversation not_ready run_id=\(runID) attempt=\(attempt)")
                return nil
            }
            if let taskID = agentTaskID, taskID != runID {
                do {
                    return try await sendPublicAPIRequest(
                        method: "GET",
                        path: "agent/runs/\(taskID)/conversation",
                        body: nil,
                        token: token
                    )
                } catch {
                    let fallbackDescription = (error as NSError).localizedDescription.lowercased()
                    if fallbackDescription.contains("status 404") {
                        trace("AgentRun task conversation not_ready task_id=\(taskID) attempt=\(attempt)")
                        return nil
                    }
                    throw error
                }
            }
            throw error
        }
    }

    private func sendPublicAPIRequest(
        method: String,
        path: String,
        body: [String: Any]?,
        token: String
    ) async throws -> Data {
        guard let url = URL(string: "\(serverRoot)/api/v1/\(path)") else {
            throw WarpAuthError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0", forHTTPHeaderField: "X-Warp-Client-Version")
        request.setValue("iOS", forHTTPHeaderField: "X-Warp-OS-Category")
        request.setValue(UIDevice.current.systemName, forHTTPHeaderField: "X-Warp-OS-Name")
        request.setValue(UIDevice.current.systemVersion, forHTTPHeaderField: "X-Warp-OS-Version")

        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        trace("PublicAPI request method=\(method) path=\(path) body_bytes=\(request.httpBody?.count ?? 0)")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw WarpAuthError.aiRequestFailed("public api request failed: invalid HTTP response")
        }
        let requestID = http.value(forHTTPHeaderField: "x-request-id")
            ?? http.value(forHTTPHeaderField: "X-Request-Id")
            ?? "none"
        trace(
            "PublicAPI response method=\(method) path=\(path) status=\(http.statusCode) " +
            "bytes=\(data.count) request_id=\(requestID)"
        )
        guard (200...299).contains(http.statusCode) else {
            throw WarpAuthError.aiRequestFailed("public api request failed with status \(http.statusCode)")
        }
        return data
    }

    private struct AssistantMessageCandidate {
        let id: String?
        let text: String
    }

    private struct AgentMessageHeaderDTO: Decodable {
        let message_id: String
        let sender_run_id: String
        let subject: String
        let sent_at: String
        let delivered_at: String?
        let read_at: String?
    }

    private struct ReadAgentMessageResponseDTO: Decodable {
        let message_id: String
        let sender_run_id: String
        let subject: String
        let body: String
        let sent_at: String
        let delivered_at: String?
        let read_at: String?
    }

    private func extractLatestAssistantMessage(
        from json: Any,
        expectedPrompt: String? = nil
    ) -> AssistantMessageCandidate? {
        if let dict = json as? [String: Any] {
            if let steps = dict["steps"] as? [Any],
               let candidate = extractLatestAssistantMessage(fromStepsArray: steps, expectedPrompt: expectedPrompt) {
                return candidate
            }
            // Preferred shape: conversation/messages arrays
            if let messages = dict["messages"] as? [Any],
               let candidate = extractLatestAssistantMessage(fromMessagesArray: messages) {
                return candidate
            }
            if let conversation = dict["conversation"] as? [String: Any],
               let messages = conversation["messages"] as? [Any],
               let candidate = extractLatestAssistantMessage(fromMessagesArray: messages) {
                return candidate
            }
            // Fallback: recursively search nested structures.
            for value in dict.values {
                if let candidate = extractLatestAssistantMessage(from: value, expectedPrompt: expectedPrompt) {
                    return candidate
                }
            }
            return nil
        }
        if let array = json as? [Any] {
            return extractLatestAssistantMessage(fromMessagesArray: array)
        }
        return nil
    }

    private func extractConversationID(from json: Any) -> String? {
        if let dict = json as? [String: Any] {
            if let direct = dict["conversation_id"] as? String, !direct.isEmpty {
                return direct
            }
            if let directCamel = dict["conversationId"] as? String, !directCamel.isEmpty {
                return directCamel
            }
            if let agentConversation = dict["agent_conversation_id"] as? String, !agentConversation.isEmpty {
                return agentConversation
            }
            if let conversationToken = dict["server_conversation_token"] as? String, !conversationToken.isEmpty {
                return conversationToken
            }
            if let conversation = dict["conversation"] as? [String: Any] {
                if let nested = conversation["id"] as? String, !nested.isEmpty {
                    return nested
                }
                if let nestedToken = conversation["conversation_id"] as? String, !nestedToken.isEmpty {
                    return nestedToken
                }
            }
            for value in dict.values {
                if let nested = extractConversationID(from: value) {
                    return nested
                }
            }
            return nil
        }
        if let array = json as? [Any] {
            for value in array {
                if let nested = extractConversationID(from: value) {
                    return nested
                }
            }
        }
        return nil
    }

    private struct ParsedRunStatus {
        let state: String?
        let statusMessage: String?
        let isTerminalFailure: Bool
    }

    private func parseRunStatus(from json: Any) -> ParsedRunStatus? {
        guard let dict = json as? [String: Any] else { return nil }
        let state = (dict["state"] as? String)?.uppercased()

        var statusMessage: String?
        if let statusDict = dict["status_message"] as? [String: Any] {
            statusMessage = statusDict["message"] as? String
        } else if let status = dict["status_message"] as? String {
            statusMessage = status
        }

        let terminalStates: Set<String> = ["FAILED", "CANCELLED", "TIMED_OUT", "BLOCKED", "ERROR"]
        let isTerminalFailure = state.map { terminalStates.contains($0) } ?? false
        return ParsedRunStatus(state: state, statusMessage: statusMessage, isTerminalFailure: isTerminalFailure)
    }

    private func extractLatestAssistantMessage(
        fromStepsArray steps: [Any],
        expectedPrompt: String?
    ) -> AssistantMessageCandidate? {
        if let expectedPrompt, !expectedPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            for step in steps.reversed() {
                guard let stepDict = step as? [String: Any] else { continue }
                guard stepLikelyMatchesPrompt(stepDict, expectedPrompt: expectedPrompt) else { continue }
                guard let messages = stepDict["messages"] as? [Any] else { continue }
                if let candidate = extractLatestAssistantMessage(fromMessagesArray: messages) {
                    return candidate
                }
            }
        }

        for step in steps.reversed() {
            guard let stepDict = step as? [String: Any] else { continue }
            guard let messages = stepDict["messages"] as? [Any] else { continue }
            if let candidate = extractLatestAssistantMessage(fromMessagesArray: messages) {
                return candidate
            }
        }
        return nil
    }

    private func stepLikelyMatchesPrompt(_ step: [String: Any], expectedPrompt: String) -> Bool {
        let normalizedPrompt = normalizePromptForMatching(expectedPrompt)
        guard !normalizedPrompt.isEmpty else { return false }

        let stepDescription = (step["description"] as? String ?? "").lowercased()
        let descriptionMatch = !stepDescription.isEmpty
            && (stepDescription.contains(normalizedPrompt) || normalizedPrompt.contains(stepDescription))
        if descriptionMatch {
            return true
        }

        let stepText = flattenText(step).lowercased()
        let textContainsPrompt = stepText.contains(normalizedPrompt)
        if textContainsPrompt {
            return true
        }

        let promptTokens = Set(normalizedPrompt.split(whereSeparator: \.isWhitespace).map(String.init))
        guard !promptTokens.isEmpty else { return false }
        let stepTokens = Set(stepText.split(whereSeparator: \.isWhitespace).map(String.init))
        let overlap = promptTokens.intersection(stepTokens).count
        let threshold = min(3, max(1, promptTokens.count / 2))
        return overlap >= threshold
    }

    private func normalizePromptForMatching(_ prompt: String) -> String {
        prompt
            .lowercased()
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .components(separatedBy: .alphanumerics.inverted)
            .filter { !$0.isEmpty && $0.count > 2 }
            .joined(separator: " ")
    }

    private func extractLatestAssistantMessage(fromMessagesArray messages: [Any]) -> AssistantMessageCandidate? {
        for item in messages.reversed() {
            guard let dict = item as? [String: Any] else { continue }
            let roleLike = [
                dict["role"] as? String,
                dict["sender_role"] as? String,
                dict["sender"] as? String,
                dict["author"] as? String,
                dict["actor"] as? String,
                dict["source"] as? String,
                dict["kind"] as? String,
                dict["type"] as? String,
                dict["message_type"] as? String
            ]
            .compactMap { $0?.lowercased() }
            .joined(separator: " ")
            let isAssistantLike = roleLike.contains("assistant")
                || roleLike.contains("agent")
                || roleLike.contains("ai")
                || roleLike.contains("model")
            if let text = assistantText(from: dict) {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                // If role metadata explicitly exists and is not assistant-like,
                // skip this message to avoid selecting user echoes as replies.
                if !isAssistantLike {
                    if !roleLike.isEmpty {
                        continue
                    }

                    // If role metadata is absent, accept long non-question outputs
                    // to avoid dropping valid assistant content from run conversation payloads.
                    if trimmed.hasSuffix("?") || trimmed.count < 24 {
                        continue
                    }
                }
                let id = dict["message_id"] as? String
                    ?? dict["id"] as? String
                    ?? ((dict["content"] as? [[String: Any]])?.first?["message_id"] as? String)
                return AssistantMessageCandidate(id: id, text: text)
            }
        }
        return nil
    }

    private func assistantText(from dict: [String: Any]) -> String? {
        let directKeys = ["body", "text", "answer", "content", "message", "response", "output", "markdown", "value"]
        for key in directKeys {
            if let value = dict[key] as? String {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
        }

        if let contentArray = dict["content"] as? [Any] {
            let flattened = flattenText(contentArray).trimmingCharacters(in: .whitespacesAndNewlines)
            if !flattened.isEmpty {
                return flattened
            }
        }

        // Some payloads wrap text in nested parts/content arrays.
        if let parts = dict["parts"] as? [Any] {
            let flattened = flattenText(parts).trimmingCharacters(in: .whitespacesAndNewlines)
            if !flattened.isEmpty {
                return flattened
            }
        }

        return nil
    }

    private func flattenText(_ value: Any) -> String {
        if let s = value as? String { return s }
        if let number = value as? NSNumber { return number.stringValue }
        if let array = value as? [Any] {
            return array.map(flattenText).filter { !$0.isEmpty }.joined(separator: "\n")
        }
        if let dict = value as? [String: Any] {
            let preferredOrder = ["text", "content", "body", "message", "response", "output", "markdown", "value"]
            var chunks: [String] = []
            for key in preferredOrder {
                if let nested = dict[key] {
                    let text = flattenText(nested)
                    if !text.isEmpty { chunks.append(text) }
                }
            }
            return chunks.joined(separator: "\n")
        }
        return ""
    }

    private func pollAgentMessageChannel(runID: String, token: String, attempt: Int) async throws -> String? {
        let headersData = try await sendPublicAPIRequest(
            method: "GET",
            path: "agent/messages/\(runID)?limit=20",
            body: nil,
            token: token
        )
        guard let headers = try? JSONDecoder().decode([AgentMessageHeaderDTO].self, from: headersData) else {
            return nil
        }

        guard let newest = headers.first(where: { $0.message_id != lastAgentMessageID }) else {
            return nil
        }

        let messageData = try await sendPublicAPIRequest(
            method: "POST",
            path: "agent/messages/\(newest.message_id)/read",
            body: [:],
            token: token
        )
        guard let read = try? JSONDecoder().decode(ReadAgentMessageResponseDTO.self, from: messageData) else {
            return nil
        }

        let body = read.body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return nil }

        lastAgentMessageID = newest.message_id
        trace(
            "AgentRun message reply_found run_id=\(runID) attempt=\(attempt) " +
            "message_id=\(newest.message_id) answer_chars=\(body.count)"
        )
        return body
    }

    private func requestContextJSON() -> [String: Any] {
        let context = WarpRequestContext.current()
        return [
            "clientContext": ["version": jsonScalar(context.clientContext.version)],
            "osContext": [
                "category": jsonScalar(context.osContext.category),
                "linuxKernelVersion": jsonScalar(context.osContext.linuxKernelVersion),
                "name": jsonScalar(context.osContext.name),
                "version": jsonScalar(context.osContext.version)
            ]
        ]
    }

    private func jsonScalar(_ value: String?) -> Any {
        value ?? NSNull()
    }

    private func trace(_ message: String) {
        #if DEBUG
        print("[WarpTrace][Backend] \(message)")
        #endif
    }

    private func preview(_ text: String) -> String {
        let singleLine = text
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if singleLine.count <= 120 {
            return singleLine
        }
        let end = singleLine.index(singleLine.startIndex, offsetBy: 120)
        return String(singleLine[..<end]) + "..."
    }
}

private struct GenerateCommandsEnvelope: Decodable {
    struct Payload: Decodable {
        let generateCommands: GenerateCommandsResult
    }
    let data: Payload?
}

private struct GenerateDialogueEnvelope: Decodable {
    struct Payload: Decodable {
        let generateDialogue: GenerateDialogueResult
    }
    let data: Payload?
}

private struct GenerateDialogueResult: Decodable {
    struct Status: Decodable {
        let __typename: String
        let answer: String?
        let truncated: Bool?
    }

    struct UserFacingError: Decodable {
        let message: String
    }

    let __typename: String
    let status: Status?
    let error: UserFacingError?
}

private struct AgentRunSpawnResponse: Decodable {
    let task_id: String?
    let run_id: String
}

private struct GenerateCommandsResult: Decodable {
    struct Status: Decodable {
        struct Command: Decodable {
            let command: String
            let description: String
        }
        let __typename: String
        let commands: [Command]?
        let type: String?
    }

    struct UserFacingError: Decodable {
        let message: String
    }

    let __typename: String
    let status: Status?
    let error: UserFacingError?
}

private struct RequestLimitEnvelope: Decodable {
    struct DataNode: Decodable {
        struct UserNode: Decodable {
            struct NestedUser: Decodable {
                let requestLimitInfo: RequestLimitInfoResponse?
            }
            let user: NestedUser?
        }
        let user: UserNode?
    }
    let data: DataNode?
}

private struct RequestLimitInfoResponse: Decodable {
    let isUnlimited: Bool
    let requestsUsedSinceLastRefresh: Int
    let requestLimit: Int
}

enum WarpAuthError: LocalizedError {
    case invalidURL
    case cancelled
    case notLoggedIn
    case invalidCallback(String)
    case tokenExchangeFailed(String)
    case aiRequestFailed(String)
    case subscriptionLimited(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid URL"
        case .cancelled:
            return "Login was cancelled"
        case .notLoggedIn:
            return "You must be logged in to Warp AI"
        case .invalidCallback(let details):
            return "Invalid login callback: \(details)"
        case .tokenExchangeFailed(let details):
            return "Unable to exchange auth token: \(details)"
        case .aiRequestFailed(let details):
            return "AI request failed: \(details)"
        case .subscriptionLimited(let details):
            return "Subscription limit reached: \(details)"
        }
    }
}

class TerminalDataReceiver: DataReceiver {
    weak var terminalView: SwiftTerm.TerminalView?
    weak var session: SSHSession?

    init(terminalView: SwiftTerm.TerminalView?, session: SSHSession) {
        self.terminalView = terminalView
        self.session = session
    }

    func onData(data: [UInt8]) {
        guard let session else { return }
        // Once warp blocks are live, keep SwiftTerm focused on interactive prompt/input.
        // Command output flows through block events instead of terminal scrollback.
        let suppressed = session.shouldSuppressPromptOutput()
        session.recordPromptOutputPath(dataCount: data.count, suppressed: suppressed)
        if suppressed {
            return
        }
        let filtered = session.filterIdlePromptEcho(data)
        if filtered.isEmpty {
            return
        }

        let containsEraseControl = data.contains(0x08) && data.contains(0x4B)

        let applyDataToTerminal = { [weak terminalView] in
            guard let terminalView else { return }
            // Feed the TerminalView (not bare Terminal) so SwiftTerm runs
            // feedPrepare/feedFinish and schedules display updates immediately.
            terminalView.feed(byteArray: filtered[...])

            // Force a repaint when we receive erase-to-end-of-line traffic so
            // stale glyphs do not linger visually after backspace.
            if containsEraseControl {
                terminalView.setNeedsDisplay(terminalView.bounds)
            }
        }

        // Rust callbacks arrive on a Tokio worker thread. SwiftTerm mutates
        // UIKit state during feed(), so updates must run on main.
        //
        // SwiftTerm's iOS scroller can snap back to bottom when feed() runs
        // while the user is actively dragging (UITrackingRunLoopMode). By
        // scheduling feeds in .default mode, we let swipe scrollback win.
        if Thread.isMainThread {
            RunLoop.main.perform(inModes: [.default], block: applyDataToTerminal)
        } else {
            DispatchQueue.main.async {
                RunLoop.main.perform(inModes: [.default], block: applyDataToTerminal)
            }
        }
    }

    func onDisconnect(reason: String) {
        // Rust drops the Arc<DataReceiver> immediately after this call returns,
        // which deallocates TerminalDataReceiver.  A [weak self] capture would
        // therefore always resolve to nil.  Capture session strongly instead so
        // handleRemoteDisconnect() is guaranteed to fire even after self is gone.
        guard let session = session else { return }
        DispatchQueue.main.async {
            session.handleRemoteDisconnect()
        }
    }
}
