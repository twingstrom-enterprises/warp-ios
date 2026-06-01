import Foundation

enum TerminalCommandSource: String, Equatable, Codable {
    case user
    case ai
}

enum TerminalBlockRenderStyle: String, Equatable, Codable {
    case command
    case aiDialogue
}

struct TerminalBlock: Identifiable, Equatable {
    let id: UInt64
    var command: String
    var workingDirectory: String
    var output: String
    var exitCode: Int32?
    var isRunning: Bool
    var createdAt: Date
    var finishedAt: Date?
    var commandSource: TerminalCommandSource
    var aiActionID: String?
    var aiConversationID: String?
    var aiRequestID: String?
    var renderStyle: TerminalBlockRenderStyle

    init(
        id: UInt64,
        command: String,
        workingDirectory: String = "",
        output: String = "",
        exitCode: Int32? = nil,
        isRunning: Bool = true,
        createdAt: Date = Date(),
        finishedAt: Date? = nil,
        commandSource: TerminalCommandSource = .user,
        aiActionID: String? = nil,
        aiConversationID: String? = nil,
        aiRequestID: String? = nil,
        renderStyle: TerminalBlockRenderStyle = .command
    ) {
        self.id = id
        self.command = command
        self.workingDirectory = workingDirectory
        self.output = output
        self.exitCode = exitCode
        self.isRunning = isRunning
        self.createdAt = createdAt
        self.finishedAt = finishedAt
        self.commandSource = commandSource
        self.aiActionID = aiActionID
        self.aiConversationID = aiConversationID
        self.aiRequestID = aiRequestID
        self.renderStyle = renderStyle
    }
}
