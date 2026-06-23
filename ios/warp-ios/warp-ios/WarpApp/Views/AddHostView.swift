import SwiftUI

struct AddHostView: View {
    var hostToEdit: SSHHost?
    var onSave: (SSHHost) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var label = ""
    @State private var hostname = ""
    @State private var port = "22"
    @State private var username = ""
    @State private var useKey = false
    @State private var keyPEM = ""
    @State private var password = ""

    private var isEditing: Bool { hostToEdit != nil }

    private var existingKeyTag: String? {
        guard let hostToEdit, case .key(let tag) = hostToEdit.authMethod else { return nil }
        return tag
    }

    private var canSave: Bool {
        guard !label.isEmpty, !hostname.isEmpty, !username.isEmpty else { return false }
        if useKey {
            return !keyPEM.isEmpty || existingKeyTag != nil
        }
        return true
    }

    init(host: SSHHost? = nil, onSave: @escaping (SSHHost) -> Void) {
        self.hostToEdit = host
        self.onSave = onSave
        if let host {
            _label = State(initialValue: host.label)
            _hostname = State(initialValue: host.hostname)
            _port = State(initialValue: String(host.port))
            _username = State(initialValue: host.username)
            switch host.authMethod {
            case .password:
                _useKey = State(initialValue: false)
            case .key:
                _useKey = State(initialValue: true)
            }
        }
    }

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
                        if existingKeyTag != nil {
                            Text("A private key is saved. Paste below to replace it.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        TextEditor(text: $keyPEM)
                            .frame(minHeight: 120)
                            .font(.system(.caption, design: .monospaced))
                            .overlay(
                                Group {
                                    if keyPEM.isEmpty {
                                        Text(existingKeyTag != nil
                                             ? "Leave empty to keep existing key"
                                             : "Paste private key PEM here")
                                            .foregroundStyle(.secondary)
                                            .padding(8)
                                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                                    }
                                }
                            )
                    } else {
                        SecureField(
                            isEditing ? "Password (leave blank to keep)" : "Password",
                            text: $password
                        )
                    }
                }
            }
            .navigationTitle(isEditing ? "Edit Host" : "New Host")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }.disabled(!canSave)
                }
            }
        }
    }

    private func save() {
        let portNum = Int(port) ?? 22
        let hostID = hostToEdit?.id ?? UUID()
        let auth = saveAuthMethod(hostID: hostID)
        let host = SSHHost(
            id: hostID,
            label: label,
            hostname: hostname,
            port: portNum,
            username: username,
            authMethod: auth
        )
        onSave(host)
        dismiss()
    }

    private func saveAuthMethod(hostID: UUID) -> AuthMethod {
        if useKey {
            if let existingKeyTag {
                if keyPEM.isEmpty {
                    return .key(keychainTag: existingKeyTag)
                }
                try? KeychainService.saveKey(keyPEM, tag: existingKeyTag)
                return .key(keychainTag: existingKeyTag)
            }
            if case .password = hostToEdit?.authMethod {
                KeychainService.deletePassword(hostID: hostID)
            }
            let tag = UUID().uuidString
            try? KeychainService.saveKey(keyPEM, tag: tag)
            return .key(keychainTag: tag)
        }

        if let existingKeyTag {
            KeychainService.deleteKey(tag: existingKeyTag)
        }
        if !password.isEmpty {
            try? KeychainService.savePassword(password, hostID: hostID)
        }
        return .password
    }
}
