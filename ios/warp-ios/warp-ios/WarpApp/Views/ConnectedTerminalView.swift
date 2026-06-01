import SwiftUI
import UIKit

struct ConnectedTerminalView: View {
    let host: SSHHost
    @State private var session = SSHSession()
    @State private var accessoryState = AccessoryState()
    @State private var jumpToBottomRequest = 0
    @State private var showPasswordPrompt = false
    @State private var didSubmitPassword = false
    @FocusState private var isAIPromptFocused: Bool
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
                        accessoryArea
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
                        accessoryArea
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
        .onChange(of: session.inputRoutingMode) { _, mode in
            guard session.aiToolsEnabled else { return }
            if mode == .ai {
                session.relinquishTerminalFocusForAI()
                DispatchQueue.main.async {
                    isAIPromptFocused = true
                }
            } else {
                isAIPromptFocused = false
                session.focusTerminalIfNeeded()
            }
        }
        .onChange(of: session.isConnected) { _, isNowConnected in
            guard isNowConnected, session.aiToolsEnabled, session.inputRoutingMode == .ai else { return }
            session.relinquishTerminalFocusForAI()
            DispatchQueue.main.async {
                isAIPromptFocused = true
            }
        }
    }

    @ViewBuilder
    private var accessoryArea: some View {
        VStack(spacing: 0) {
            if session.aiToolsEnabled, session.inputRoutingMode == .ai {
                VStack(spacing: 6) {
                    if session.aiIsThinking {
                        TimelineView(.animation(minimumInterval: 0.35)) { timeline in
                            let phase = Int(timeline.date.timeIntervalSinceReferenceDate * 2.85) % 4
                            let dots = String(repeating: ".", count: phase)
                            HStack {
                                HStack(spacing: 8) {
                                    Image(systemName: "sparkles")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(Color.purple.opacity(0.95))
                                    Text("Warping\(dots)")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(Color.purple.opacity(0.95))
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(
                                    Capsule()
                                        .fill(Color.purple.opacity(0.16))
                                )

                                Text("thinking through your prompt")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)

                                Spacer()
                            }
                        }
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    }

                    if let pending = session.pendingAICommandSuggestion {
                        HStack(spacing: 8) {
                            Text("AI suggests: `\(pending.command)`")
                                .font(.caption)
                                .lineLimit(2)
                                .frame(maxWidth: .infinity, alignment: .leading)

                            Button("Cancel") {
                                session.dismissPendingAICommandSuggestion()
                            }
                            .font(.caption.weight(.semibold))

                            Button("Run") {
                                Task { await session.approvePendingAICommandSuggestion() }
                            }
                            .font(.caption.weight(.semibold))
                            .disabled(session.aiIsThinking)
                        }
                    }

                    HStack(spacing: 8) {
                        TextField("Ask AI or use run <command> / !<command>", text: $session.aiPromptDraft)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.callout, design: .monospaced))
                            .submitLabel(.send)
                            .focused($isAIPromptFocused)
                            .onSubmit {
                                Task { await session.submitAIPrompt() }
                            }
                            .disabled(session.aiIsThinking)

                        if session.isWarpLoggedIn {
                            Button("Logout") {
                                session.logoutFromWarp()
                            }
                            .font(.caption.weight(.semibold))
                        } else {
                            Button("Login") {
                                Task { await session.loginToWarp() }
                            }
                            .font(.caption.weight(.semibold))
                        }

                        Button("Send") {
                            Task { await session.submitAIPrompt() }
                        }
                        .disabled(
                            session.aiIsThinking
                                || session.aiPromptDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        )
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(Color(UIColor.systemGray6))
            }

            if session.richHistoryVisible {
                RichHistoryMenuView(
                    items: session.richHistoryItems,
                    selectionIndex: session.richHistorySelectionIndex,
                    isLoading: session.richHistoryIsLoading
                )
            }

            KeyAccessoryBar(
                session: session,
                accessoryState: accessoryState,
                inputRoutingMode: $session.inputRoutingMode,
                aiToolsEnabled: session.aiToolsEnabled
            ) {
                Task { await session.disconnect(); dismiss() }
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
