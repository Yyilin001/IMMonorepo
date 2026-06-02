import OSLog

enum IMClientLog {
    static let conversationStore = Logger(
        subsystem: "com.stskcxfz.imclientkit",
        category: "conversation-store"
    )

    static let timeline = Logger(
        subsystem: "com.stskcxfz.imclientkit",
        category: "timeline"
    )
}
