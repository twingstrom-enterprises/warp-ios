import Foundation

struct TerminalBlock: Identifiable, Equatable {
    let id: UInt64
    var command: String
    var workingDirectory: String
    var output: String
    var exitCode: Int32?
    var isRunning: Bool
    var createdAt: Date

    init(
        id: UInt64,
        command: String,
        workingDirectory: String = "",
        output: String = "",
        exitCode: Int32? = nil,
        isRunning: Bool = true,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.command = command
        self.workingDirectory = workingDirectory
        self.output = output
        self.exitCode = exitCode
        self.isRunning = isRunning
        self.createdAt = createdAt
    }
}
