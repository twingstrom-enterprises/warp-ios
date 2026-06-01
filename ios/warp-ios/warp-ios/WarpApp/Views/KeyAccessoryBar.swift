import SwiftUI

// Shared mutable state for the Ctrl key, owned by TerminalView.Coordinator
// and read by both the SwiftUI bar and the terminal's key-send handler.
@Observable
class AccessoryState {
    var ctrlActive = false
}

struct KeyAccessoryBar: View {
    var session: SSHSession
    var accessoryState: AccessoryState
    @Binding var inputRoutingMode: InputRoutingMode
    var aiToolsEnabled: Bool
    /// Called when the user taps the disconnect (home) button.
    var onDisconnect: () -> Void

    private let functionKeys: [(label: String, bytes: [UInt8])] = [
        ("Esc",  [0x1B]),
        ("Tab",  [0x09]),
        ("↑",    [0x1B, 0x5B, 0x41]),
        ("↓",    [0x1B, 0x5B, 0x42]),
        ("←",    [0x1B, 0x5B, 0x44]),
        ("→",    [0x1B, 0x5B, 0x43]),
    ]

    var body: some View {
        HStack(spacing: 2) {
            if aiToolsEnabled {
                Picker("Mode", selection: $inputRoutingMode) {
                    ForEach(InputRoutingMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 150)
            }

            Button {
                accessoryState.ctrlActive.toggle()
            } label: {
                Text("Ctrl")
                    .frame(minWidth: 44)
                    .padding(.vertical, 8)
                    .background(accessoryState.ctrlActive ? Color.accentColor : Color(UIColor.systemGray5))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }

            Divider().frame(height: 28)

            ForEach(functionKeys, id: \.label) { key in
                Button {
                    if session.handleTerminalInput(bytes: key.bytes) {
                        return
                    }
                    session.send(Data(key.bytes))
                } label: {
                    Text(key.label)
                        .frame(minWidth: 36)
                        .padding(.vertical, 8)
                        .background(Color(UIColor.systemGray5))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
            }

            Spacer()

            // Disconnect / back-to-server-list button on the far right.
            Button(action: onDisconnect) {
                Image(systemName: "house")
                    .frame(minWidth: 36)
                    .padding(.vertical, 8)
                    .background(Color(UIColor.systemGray5))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        }
        .padding(.horizontal, 8)
        .background(Color(UIColor.systemGray6))
        .font(.system(.footnote, design: .monospaced))
        .foregroundStyle(.primary)
        .frame(height: 44)
    }
}
