import Foundation
import Observation
import SwiftTerm
import UIKit

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
    private enum PromptFeedState {
        case interactive
        case runningBlock
        case awaitingPrecmd
    }
    private var promptFeedState: PromptFeedState = .interactive

    func connect(host: SSHHost, password: String? = nil) async {
        blockStore.reset()
        promptFeedState = .interactive
        promptUsername = host.username
        promptHostname = host.hostname
        awaitingRemotePromptEcho = false
        trace("connect start host=\(host.hostname) user=\(host.username)")
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
        isConnected = false
        rustSession = nil
        warpSessionController = nil
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

    func resize(cols: UInt16, rows: UInt16) {
        guard cols > 0, rows > 0 else { return }
        pendingCols = cols
        pendingRows = rows
        rustSession?.resize(cols: cols, rows: rows)
    }

    func disconnect() async {
        await rustSession?.disconnect()
        isConnected = false
        rustSession = nil
        warpSessionController = nil
    }

    func handlePreexecEvent() {
        trace("hook preexec activeBlock=\(String(describing: blockStore.activeBlockID))")
        promptFeedState = .runningBlock
        awaitingRemotePromptEcho = false
        if blockStore.isBootstrapped, !blockStore.fallbackModeEnabled {
            clearPromptTerminal()
        }
    }

    func handleCommandFinishedEvent() {
        trace("hook command_finished activeBlock=\(String(describing: blockStore.activeBlockID))")
        // Keep suppressing stream bytes until precmd arrives so trailing output
        // does not leak into the prompt area.
        promptFeedState = .awaitingPrecmd
        if blockStore.isBootstrapped, !blockStore.fallbackModeEnabled {
            DispatchQueue.main.async { [weak terminalView] in
                _ = terminalView?.becomeFirstResponder()
            }
        }
    }

    func handleBootstrappedEvent() {
        promptFeedState = .interactive
        awaitingRemotePromptEcho = true
        renderSyntheticPromptInTerminal()
        trace("bootstrapped prompt primed")
    }

    func handlePrecmdEvent() {
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

    private func renderSyntheticPromptInTerminal() {
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

        let cwd = blockStore.currentWorkingDirectory
        let dir: String
        if cwd.isEmpty {
            dir = "~"
        } else if cwd == "/" {
            dir = "/"
        } else {
            dir = cwd.split(separator: "/").last.map(String.init) ?? cwd
        }
        let prompt = "\(promptUsername)@\(promptHostname):\(dir) $ "
        let bytes = Array(prompt.utf8)
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
