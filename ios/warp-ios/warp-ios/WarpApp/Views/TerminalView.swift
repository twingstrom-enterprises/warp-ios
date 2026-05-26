import SwiftUI
import SwiftTerm

struct TerminalView: UIViewRepresentable {
    var session: SSHSession
    var accessoryState: AccessoryState

    func makeUIView(context: Context) -> SwiftTerm.TerminalView {
        let tv = SwiftTerm.TerminalView(frame: .zero)
        tv.terminalDelegate = context.coordinator
        context.coordinator.terminalView = tv
        session.attachTerminalView(tv)

        // Disable iOS text-editing aids that corrupt terminal input.
        tv.autocorrectionType = .no
        tv.autocapitalizationType = .none
        tv.spellCheckingType = .no
        // Use an opaque terminal background so erased cells repaint cleanly.
        tv.backgroundColor = .black
        tv.nativeBackgroundColor = .black
        tv.inputAssistantItem.leadingBarButtonGroups = []
        tv.inputAssistantItem.trailingBarButtonGroups = []
        // SwiftTerm installs a default TerminalAccessory in setup(); disable it
        // because we render our own accessory bar via SwiftUI safeAreaInset.
        tv.inputAccessoryView = nil
        // Use ^H backspace for better readline compatibility on iOS.
        tv.backspaceSendsControlH = true

        // Grab keyboard focus immediately so the first keypress isn't lost.
        DispatchQueue.main.async {
            tv.reloadInputViews()
            _ = tv.becomeFirstResponder()
        }

        return tv
    }

    func updateUIView(_ uiView: SwiftTerm.TerminalView, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(session: session, accessoryState: accessoryState)
    }

    class Coordinator: NSObject, TerminalViewDelegate {
        let session: SSHSession
        weak var terminalView: SwiftTerm.TerminalView?
        let accessoryState: AccessoryState

        init(session: SSHSession, accessoryState: AccessoryState) {
            self.session = session
            self.accessoryState = accessoryState
        }

        private func normalizeInput(_ data: ArraySlice<UInt8>) -> [UInt8] {
            let bytes = Array(data)

            // Normalize backspace variants to BS (^H / 0x08).
            if bytes == [0x08] || bytes == [0x7F] {
                return [0x08]
            }

            // SwiftTerm may emit CSI-u enhanced keyboard sequences for backspace.
            // Example shape: ESC [ 127 ; ... u
            if bytes.count >= 6, bytes.first == 0x1B, bytes[1] == 0x5B, bytes.last == 0x75 {
                let body = String(decoding: bytes.dropFirst(2).dropLast(), as: UTF8.self)
                let keyCodePart = body.split(separator: ";", maxSplits: 1).first.map(String.init) ?? body
                if let keyCode = Int(keyCodePart), keyCode == 8 || keyCode == 127 {
                    return [0x08]
                }
            }

            return bytes
        }

        func send(source: SwiftTerm.TerminalView, data: ArraySlice<UInt8>) {
            let normalized = normalizeInput(data)

            // Treat Ctrl from the accessory as a one-shot modifier so normal typing
            // immediately resumes after the next keypress.
            let ctrlActive = accessoryState.ctrlActive
            if ctrlActive {
                accessoryState.ctrlActive = false
            }

            if ctrlActive, normalized.count == 1,
               let byte = normalized.first, byte >= 0x40 && byte <= 0x7E {
                session.send(Data([byte & 0x1F]))
                return
            }

            session.send(Data(normalized))
        }

        func scrolled(source: SwiftTerm.TerminalView, position: Double) {}
        func setTerminalTitle(source: SwiftTerm.TerminalView, title: String) {}
        func sizeChanged(source: SwiftTerm.TerminalView, newCols: Int, newRows: Int) {
            session.resize(cols: UInt16(newCols), rows: UInt16(newRows))
        }
        func hostCurrentDirectoryUpdate(source: SwiftTerm.TerminalView, directory: String?) {}
        func requestOpenLink(source: SwiftTerm.TerminalView, link: String, params: [String: String]) {}
        func bell(source: SwiftTerm.TerminalView) {}
        func clipboardCopy(source: SwiftTerm.TerminalView, content: Data) {
            UIPasteboard.general.string = String(data: content, encoding: .utf8)
        }
        func rangeChanged(source: SwiftTerm.TerminalView, startY: Int, endY: Int) {}
    }
}
