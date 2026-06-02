import Foundation

enum AuthMethod: Codable {
    case password
    case key(keychainTag: String)
}

struct SSHHost: Identifiable, Codable {
    let id: UUID
    var label: String
    var hostname: String
    var port: Int
    var username: String
    var authMethod: AuthMethod

    init(id: UUID = UUID(), label: String, hostname: String, port: Int = 22,
         username: String, authMethod: AuthMethod) {
        self.id = id
        self.label = label
        self.hostname = hostname
        self.port = port
        self.username = username
        self.authMethod = authMethod
    }
}

extension SSHHost {
    static func loadAll() -> [SSHHost] {
        guard let data = UserDefaults.standard.data(forKey: "ssh_hosts"),
              let hosts = try? JSONDecoder().decode([SSHHost].self, from: data)
        else { return [] }
        return hosts
    }

    static func saveAll(_ hosts: [SSHHost]) {
        let data = try? JSONEncoder().encode(hosts)
        UserDefaults.standard.set(data, forKey: "ssh_hosts")
    }
}
