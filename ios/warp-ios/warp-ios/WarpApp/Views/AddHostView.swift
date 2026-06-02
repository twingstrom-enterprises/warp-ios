import SwiftUI

struct AddHostView: View {
    var onSave: (SSHHost) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var label = ""
    @State private var hostname = ""
    @State private var port = "22"
    @State private var username = ""
    @State private var useKey = false
    @State private var keyPEM = ""
    @State private var password = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Host") {
                    TextField("Label (e.g. My Server)", text: $label)
                    TextField("Hostname or IP", text: $hostname)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    TextField("Port", text: $port).keyboardType(.numberPad)
                    TextField("Username", text: $username)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }
                Section("Authentication") {
                    Toggle("Use SSH Key", isOn: $useKey)
                    if useKey {
                        TextEditor(text: $keyPEM)
                            .frame(minHeight: 120)
                            .font(.system(.caption, design: .monospaced))
                            .overlay(
                                Group {
                                    if keyPEM.isEmpty {
                                        Text("Paste private key PEM here")
                                            .foregroundStyle(.secondary)
                                            .padding(8)
                                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                                    }
                                }
                            )
                    } else {
                        SecureField("Password", text: $password)
                    }
                }
            }
            .navigationTitle("New Host")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }.disabled(label.isEmpty || hostname.isEmpty || username.isEmpty)
                }
            }
        }
    }

    private func save() {
        let portNum = Int(port) ?? 22
        let auth: AuthMethod
        let hostID = UUID()
        if useKey {
            let tag = UUID().uuidString
            try? KeychainService.saveKey(keyPEM, tag: tag)
            auth = .key(keychainTag: tag)
        } else {
            if !password.isEmpty {
                try? KeychainService.savePassword(password, hostID: hostID)
            }
            auth = .password
        }
        let host = SSHHost(id: hostID, label: label, hostname: hostname, port: portNum,
                           username: username, authMethod: auth)
        onSave(host)
        dismiss()
    }
}
