import SwiftUI
import UIKit

struct ConnectedTerminalView: View {
    let host: SSHHost
    @State private var session = SSHSession()
    @State private var accessoryState = AccessoryState()
    @State private var jumpToBottomRequest = 0
    @State private var showPasswordPrompt = false
    @State private var didSubmitPassword = false
    @Environment(\.dismiss) private var dismiss
    
    private var deviceTypeName: String {
        switch UIDevice.current.userInterfaceIdiom {
        case .pad:
            return "iPad"
        case .phone:
            return "iPhone"
        default:
            return "iOS"
        }
    }


    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if session.isConnected {
                if session.blockStore.fallbackModeEnabled || !session.blockStore.isBootstrapped {
                    TerminalView(
                        session: session,
                        accessoryState: accessoryState,
                        showsJumpToBottom: .constant(false),
                        jumpToBottomRequest: 0
                    )
                    .safeAreaInset(edge: .bottom, spacing: 0) {
                        KeyAccessoryBar(session: session, accessoryState: accessoryState) {
                            Task { await session.disconnect(); dismiss() }
                        }
                    }
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            VStack(alignment: .leading, spacing: 10) {
                                if let status = session.blockStore.statusMessage {
                                    Text(status)
                                        .font(.caption)
                                        .foregroundStyle(.yellow)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }

                                if session.blockStore.blocks.isEmpty {
                                    Text("Welcome to Warp for \(deviceTypeName)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                } else {
                                    ForEach(session.blockStore.blocks) { block in
                                        BlockRowView(block: block) {
                                            UIPasteboard.general.string = session.blockStore.copyText(for: block.id)
                                        }
                                        .id(block.id)
                                    }
                                }

                                TerminalView(
                                    session: session,
                                    accessoryState: accessoryState,
                                    showsJumpToBottom: .constant(false),
                                    jumpToBottomRequest: 0
                                )
                                .frame(height: 120)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                                .id("promptAnchor")
                            }
                            .padding(12)
                        }
                        .onChange(of: jumpToBottomRequest) { _, _ in
                            withAnimation {
                                proxy.scrollTo("promptAnchor", anchor: .bottom)
                            }
                        }
                        .onChange(of: session.blockStore.scrollTick) { _, _ in
                            withAnimation(.linear(duration: 0.06)) {
                                proxy.scrollTo("promptAnchor", anchor: .bottom)
                            }
                        }
                        .overlay(alignment: .bottomTrailing) {
                            Button {
                                jumpToBottomRequest &+= 1
                            } label: {
                                Label("Bottom", systemImage: "arrow.down.to.line.compact")
                                    .font(.caption.weight(.semibold))
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                            }
                            .foregroundStyle(.white)
                            .background(Color.white.opacity(0.16), in: Capsule())
                            .padding(.trailing, 10)
                            .padding(.bottom, 8)
                        }
                    }
                    .safeAreaInset(edge: .bottom, spacing: 0) {
                        KeyAccessoryBar(session: session, accessoryState: accessoryState) {
                            Task { await session.disconnect(); dismiss() }
                        }
                    }
                }
            } else if let error = session.errorMessage {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                        .foregroundStyle(.yellow)
                    Text(error).foregroundStyle(.white).multilineTextAlignment(.center)
                    Button("Dismiss") { dismiss() }.foregroundStyle(.white)
                }
                .padding()
            } else {
                ProgressView("Connecting…").tint(.white).foregroundStyle(.white)
            }
        }
        .navigationBarBackButtonHidden()
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Disconnect") {
                    Task { await session.disconnect(); dismiss() }
                }
                .foregroundStyle(.white)
            }
        }
        .sheet(isPresented: $showPasswordPrompt, onDismiss: {
            // If the password sheet was cancelled (not submitted), leave this screen
            // so we do not show an indefinite "Connecting…" spinner.
            if case .password = host.authMethod, !didSubmitPassword {
                dismiss()
            }
        }) {
            PasswordPromptView(hostname: host.hostname, username: host.username) { pw in
                didSubmitPassword = true
                Task { await session.connect(host: host, password: pw) }
            }
        }
        .onChange(of: session.isConnected) { wasConnected, isNowConnected in
            // When a live session drops (exit, disconnect, server close),
            // automatically navigate back to the host list.
            if wasConnected && !isNowConnected {
                dismiss()
            }
        }
        .task {
            if case .password = host.authMethod {
                didSubmitPassword = false
                showPasswordPrompt = true
            } else {
                await session.connect(host: host)
            }
        }
    }
}

struct PasswordPromptView: View {
    let hostname: String
    let username: String
    let onConnect: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var password = ""
    @FocusState private var isPasswordFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section("\(username)@\(hostname)") {
                    SecureField("Password", text: $password)
                        .textContentType(.password)
                        .submitLabel(.go)
                        .onSubmit(connect)
                        .focused($isPasswordFocused)
                }
            }
            .navigationTitle("Connect")
            .onAppear {
                // Sheet presentation can steal first responder; queue focus for next run loop.
                DispatchQueue.main.async {
                    isPasswordFocused = true
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Connect", action: connect)
                        .disabled(password.isEmpty)
                }
            }
        }
    }

    private func connect() {
        guard !password.isEmpty else { return }
        dismiss()
        onConnect(password)
    }
}
