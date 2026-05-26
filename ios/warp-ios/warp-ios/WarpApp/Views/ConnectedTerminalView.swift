import SwiftUI

struct ConnectedTerminalView: View {
    let host: SSHHost
    @State private var session = SSHSession()
    @State private var accessoryState = AccessoryState()
    @State private var showPasswordPrompt = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if session.isConnected {
                TerminalView(session: session, accessoryState: accessoryState)
                .ignoresSafeArea(edges: .bottom)
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    KeyAccessoryBar(session: session, accessoryState: accessoryState) {
                        Task { await session.disconnect(); dismiss() }
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
        .sheet(isPresented: $showPasswordPrompt) {
            PasswordPromptView(hostname: host.hostname, username: host.username) { pw in
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

    var body: some View {
        NavigationStack {
            Form {
                Section("\(username)@\(hostname)") {
                    SecureField("Password", text: $password)
                        .textContentType(.password)
                }
            }
            .navigationTitle("Connect")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Connect") {
                        dismiss()
                        onConnect(password)
                    }.disabled(password.isEmpty)
                }
            }
        }
    }
}
