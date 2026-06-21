import SwiftUI
import UIKit

struct HostListView: View {
    @State private var hosts: [SSHHost] = SSHHost.loadAll()
    @State private var showingAddHost = false
    @State private var selectedHost: SSHHost?

    private var deviceTypeName: String {
        switch UIDevice.current.userInterfaceIdiom {
        case .pad: return "iPad"
        case .phone: return "iPhone"
        default: return "iOS"
        }
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(hosts) { host in
                    Button {
                        selectedHost = host
                    } label: {
                        VStack(alignment: .leading) {
                            Text(host.label).font(.headline)
                            Text("\(host.username)@\(host.hostname):\(host.port)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .onDelete { indexSet in
                    hosts.remove(atOffsets: indexSet)
                    SSHHost.saveAll(hosts)
                }
            }
            .overlay {
                if hosts.isEmpty {
                    VStack(spacing: 12) {
                        Text("Welcome to Warp for \(deviceTypeName)")
                            .font(.headline)
                        Text("Tap + to add your first SSH host, then tap it to connect.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        Text("You'll get a full SSH terminal right on your \(deviceTypeName).")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(.horizontal, 32)
                    .allowsHitTesting(false)
                }
            }
            .navigationTitle("Warp")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { showingAddHost = true } label: { Image(systemName: "plus") }
                }
            }
            .sheet(isPresented: $showingAddHost) {
                AddHostView { newHost in
                    hosts.append(newHost)
                    SSHHost.saveAll(hosts)
                }
            }
            .fullScreenCover(item: $selectedHost) { host in
                ConnectedTerminalView(host: host)
            }
        }
    }
}
