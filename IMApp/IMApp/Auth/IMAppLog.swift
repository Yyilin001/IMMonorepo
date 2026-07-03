import OSLog

enum IMAppLog {
    static let imRuntime = Logger(
        subsystem: "com.stskcxfz.imapp",
        category: "im-runtime"
    )

    static let imUI = Logger(
        subsystem: "com.stskcxfz.imapp",
        category: "im-ui"
    )

    static let performance = Logger(
        subsystem: "com.stskcxfz.imapp",
        category: "performance"
    )
}
