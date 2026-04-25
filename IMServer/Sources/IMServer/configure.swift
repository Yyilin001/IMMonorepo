import Foundation
import Fluent
import FluentPostgresDriver
import FluentSQLiteDriver
import JWTKit
import Vapor

// 配置你的应用程序
public func configure(_ app: Application) async throws {
    // 本地开发从 .env.local 读取数据库和密钥配置，避免 Xcode 直接运行时丢环境变量。
    loadLocalEnvironmentIfNeeded(environment: app.environment)

    // 从 /Public 目录提供静态文件服务
    app.middleware.use(FileMiddleware(publicDirectory: app.directory.publicDirectory))

    let authConfiguration = try AuthConfiguration.load(from: app.environment)
    let imTCPConfiguration = IMTCPConfiguration.load(from: app.environment)
    app.authClientIPResolver = AuthClientIPResolver.load(from: app.environment)

    // 测试环境使用内存 SQLite，保证测试隔离和速度；开发/生产统一使用 PostgreSQL。
    if app.environment == .testing {
        app.databases.use(.sqlite(.memory), as: .sqlite)
    } else {
        app.databases.use(.postgres(configuration: databaseConfiguration(for: app.environment)), as: .psql)
    }
    app.authConfiguration = authConfiguration
    app.imTCPConfiguration = imTCPConfiguration
    _ = app.imConnectionRegistry
    app.lifecycle.use(IMTCPServerLifecycle())
    await app.jwtKeys.add(hmac: HMACKey(from: authConfiguration.jwtSecret), digestAlgorithm: .sha256)

    // 认证链路依赖 users + auth_sessions 两张表，以及后续的索引/约束迁移。
    app.migrations.add(CreateUser())
    app.migrations.add(AddUserProfileFields())
    app.migrations.add(CreateUserContact())
    app.migrations.add(AddUserContactRemark())
    app.migrations.add(BackfillReciprocalUserContacts())
    app.migrations.add(CreateFriendRequest())
    app.migrations.add(CreateAuthSession())
    app.migrations.add(AddAuthIndexes())
    app.migrations.add(EnforceSingleActiveDeviceSession())
    app.migrations.add(CreateConversation())
    app.migrations.add(AddConversationLastMessageSequence())
    app.migrations.add(CreateConversationMember())
    app.migrations.add(AddConversationMemberLastReadSequence())
    app.migrations.add(AddConversationKind())
    app.migrations.add(AddConversationDirectMessagingState())
    app.migrations.add(AddConversationMemberRole())
    app.migrations.add(AddConversationMetadataAndPreferences())
    app.migrations.add(CreateConversationMessage())
    app.migrations.add(AddConversationMessageClientMessageID())
    app.migrations.add(AddConversationMessageClientMessageIDUniqueIndex())
    app.migrations.add(CreateConversationUserSummary())
    app.migrations.add(AddConversationUserSummaryDirectPeerProfileFields())
    app.migrations.add(AddConversationUserSummaryIndexes())
    try await app.autoMigrate()
    try FileStorageService(app: app).prepareStorage()
    try await seedDevelopmentUserIfNeeded(in: app)

    // 统一注册各组路由
    try routes(app)
}

private func databaseConfiguration(for environment: Environment) -> SQLPostgresConfiguration {
    let isProduction = environment == .production
    let defaultUsername = isProduction ? "vapor" : NSUserName()
    let defaultPassword = isProduction ? "vapor_password" : ""

    return SQLPostgresConfiguration(
        hostname: Environment.get("DATABASE_HOST") ?? (isProduction ? "db" : "127.0.0.1"),
        port: Environment.get("DATABASE_PORT").flatMap(Int.init(_:)) ?? 5432,
        username: Environment.get("DATABASE_USERNAME") ?? defaultUsername,
        password: Environment.get("DATABASE_PASSWORD") ?? defaultPassword,
        database: Environment.get("DATABASE_NAME") ?? "vapor_auth",
        tls: .disable
    )
}

private func loadLocalEnvironmentIfNeeded(environment: Environment) {
    guard environment != .production, environment != .testing else {
        return
    }

    // 优先读取 .env.local，其次兜底 .env，且不会覆盖已经注入的环境变量。
    let candidates = [
        packageRoot.appendingPathComponent(".env.local"),
        packageRoot.appendingPathComponent(".env")
    ]

    for fileURL in candidates where FileManager.default.fileExists(atPath: fileURL.path) {
        loadEnvironmentFile(at: fileURL)
        return
    }
}

private func loadEnvironmentFile(at fileURL: URL) {
    guard let contents = try? String(contentsOf: fileURL, encoding: .utf8) else {
        return
    }

    for rawLine in contents.components(separatedBy: .newlines) {
        let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !line.isEmpty, !line.hasPrefix("#"), let separator = line.firstIndex(of: "=") else {
            continue
        }

        let key = String(line[..<separator]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, Environment.get(key) == nil else {
            continue
        }

        let valueStart = line.index(after: separator)
        let rawValue = String(line[valueStart...]).trimmingCharacters(in: .whitespacesAndNewlines)
        let value = unquote(rawValue)

        setenv(key, value, 0)
    }
}

private func unquote(_ value: String) -> String {
    guard value.count >= 2 else {
        return value
    }

    if (value.hasPrefix("\"") && value.hasSuffix("\"")) || (value.hasPrefix("'") && value.hasSuffix("'")) {
        return String(value.dropFirst().dropLast())
    }

    return value
}

private var packageRoot: URL {
    let sourceFileURL = URL(fileURLWithPath: #filePath)
    return sourceFileURL
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
}

private func seedDevelopmentUserIfNeeded(in app: Application) async throws {
    guard app.environment != .production else {
        return
    }

    // 本地开发自动补一个演示账号，减少第一次联调成本。
    let email = Environment.get("SEED_USER_EMAIL") ?? "demo@example.com"
    let password = Environment.get("SEED_USER_PASSWORD") ?? "password1234"
    let normalizedEmail = User.normalize(email)

    guard try await User.query(on: app.db)
        .filter(\.$email == normalizedEmail)
        .first() == nil
    else {
        return
    }

    let user = User(
        email: normalizedEmail,
        passwordHash: try Bcrypt.hash(password),
        status: .active
    )
    try await user.create(on: app.db)

    app.logger.notice(
        "Seeded development login",
        metadata: [
            "email": .string(email),
            "password": .string(password)
        ]
    )
}
