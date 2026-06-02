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
    @State private var measuredBarWidth: CGFloat = 0

    private let functionKeys: [(label: String, bytes: [UInt8])] = [
        ("Esc",  [0x1B]),
        ("Tab",  [0x09]),
        ("↑",    [0x1B, 0x5B, 0x41]),
        ("↓",    [0x1B, 0x5B, 0x42]),
        ("←",    [0x1B, 0x5B, 0x44]),
        ("→",    [0x1B, 0x5B, 0x43]),
    ]
    private var estimatedRequiredWidth: CGFloat {
        let horizontalPadding: CGFloat = 16
        let interItemSpacing: CGFloat = 2 * 10
        let pickerWidth: CGFloat = aiToolsEnabled ? 150 : 0
        let ctrlWidth: CGFloat = 44
        let dividerWidth: CGFloat = 1
        let functionKeysWidth: CGFloat = CGFloat(functionKeys.count) * 36
        let homeWidth: CGFloat = 36
        return horizontalPadding + interItemSpacing + pickerWidth + ctrlWidth + dividerWidth + functionKeysWidth + homeWidth
    }
    private var isOverflowing: Bool {
        aiToolsEnabled && measuredBarWidth > 0 && estimatedRequiredWidth > measuredBarWidth
    }
    private var modePickerWidth: CGFloat {
        isOverflowing ? 126 : 150
    }

    var body: some View {
        HStack(spacing: 2) {
            if aiToolsEnabled {
                Picker("Mode", selection: $inputRoutingMode) {
                    ForEach(InputRoutingMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: modePickerWidth)
                .fixedSize(horizontal: true, vertical: false)
                .layoutPriority(2)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
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

                    // Disconnect / back-to-server-list button on the far right.
                    Button(action: onDisconnect) {
                        Image(systemName: "house")
                            .frame(minWidth: 36)
                            .padding(.vertical, 8)
                            .background(Color(UIColor.systemGray5))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                }
                .fixedSize(horizontal: true, vertical: false)
                .padding(.leading, 2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .clipped()
        }
        .padding(.horizontal, 8)
        .background(Color(UIColor.systemGray6))
        .font(.system(.footnote, design: .monospaced))
        .foregroundStyle(.primary)
        .frame(height: 44)
        .background(
            GeometryReader { proxy in
                Color.clear
                    .onAppear {
                        measuredBarWidth = max(0, proxy.size.width)
                    }
                    .onChange(of: proxy.size.width) { _, newValue in
                        measuredBarWidth = max(0, newValue)
                    }
            }
        )
    }
}
