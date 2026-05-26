import Foundation
import Observation
import SwiftTerm
import UIKit

@MainActor
@Observable
class SSHSession {
    var isConnected = false
    var errorMessage: String?

    private var rustSession: SshSession?
    private weak var terminalView: SwiftTerm.TerminalView?
    // Last known terminal size; stored so we can sync it to the PTY right
    // after the connection is established (sizeChanged fires before connect).
    private var pendingCols: UInt16 = 0
    private var pendingRows: UInt16 = 0

    func connect(host: SSHHost, password: String? = nil) async {
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
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // Called by the Rust bridge when the remote session ends (channel EOF/close).
    func handleRemoteDisconnect() {
        isConnected = false
        rustSession = nil
    }

    func attachTerminalView(_ terminalView: SwiftTerm.TerminalView) {
        self.terminalView = terminalView
        if let session = rustSession {
            session.setReceiver(receiver: TerminalDataReceiver(terminalView: terminalView, session: self))
        }
    }

    func send(_ data: Data) {
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
        let containsEraseControl = data.contains(0x08) && data.contains(0x4B)

        let applyDataToTerminal = { [weak terminalView] in
            guard let terminalView else { return }
            // Feed the TerminalView (not bare Terminal) so SwiftTerm runs
            // feedPrepare/feedFinish and schedules display updates immediately.
            terminalView.feed(byteArray: data[...])

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
