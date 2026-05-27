import SwiftUI

struct BlockRowView: View {
    let block: TerminalBlock
    let onCopy: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(block.command.isEmpty ? "(running command...)" : "$ \(block.command)")
                    .font(.system(.caption, design: .monospaced).weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)

                Spacer()

                Button("Copy", action: onCopy)
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.white.opacity(0.14), in: Capsule())
                    .foregroundStyle(.white)
            }

            Text(Self.timeFormatter.string(from: block.createdAt))
                .font(.caption2)
                .foregroundStyle(.secondary)

            if !block.workingDirectory.isEmpty {
                Text(block.workingDirectory)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            if !block.output.isEmpty {
                Text(block.output)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.9))
                    .textSelection(.enabled)
            }

            if block.isRunning {
                Text("Running")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.cyan)
            } else if let exitCode = block.exitCode {
                Text("Exit \(exitCode)")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(exitCode == 0 ? .green : .red)
            }
        }
        .padding(10)
        .background(Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()
}
