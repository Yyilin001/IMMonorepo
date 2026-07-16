import Fluent
import Vapor

enum IMDevelopmentSeed {
    static func seedUserIfNeeded(in app: Application) async throws {
        guard app.environment != .production else {
            return
        }

        let defaultPassword = Environment.get("SEED_USER_PASSWORD") ?? "password1234"
        let configuredEmails = (Environment.get("SEED_USER_EMAILS") ?? "")
            .split(separator: ",")
            .map { User.normalize(String($0)) }
            .filter { !$0.isEmpty }
        let seedEmails = configuredEmails.isEmpty
            ? [
                Environment.get("SEED_USER_EMAIL") ?? "demo@example.com",
                "alice@example.com",
                "bob@example.com",
                "carol@example.com",
                "dave@example.com"
            ].map(User.normalize)
            : configuredEmails

        var seededEmails: [String] = []
        var updatedEmails: [String] = []
        for normalizedEmail in Array(Set(seedEmails)).sorted() {
            if let existingUser = try await User.query(on: app.db)
                .filter(\.$email == normalizedEmail)
                .first() {
                if (existingUser.displayName ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    existingUser.displayName = defaultDisplayName(for: normalizedEmail)
                    try await existingUser.update(on: app.imWriteDB)
                    updatedEmails.append(normalizedEmail)
                }
                continue
            }

            let user = User(
                email: normalizedEmail,
                passwordHash: try Bcrypt.hash(defaultPassword),
                status: .active,
                displayName: defaultDisplayName(for: normalizedEmail),
                emailVerifiedAt: Date()
            )
            try await user.create(on: app.imWriteDB)
            seededEmails.append(normalizedEmail)
        }

        if !seededEmails.isEmpty {
            app.logger.notice(
                "Seeded development logins",
                metadata: [
                    "emails": .array(seededEmails.map { .string($0) }),
                    "password": .string(defaultPassword)
                ]
            )
        }
        if !updatedEmails.isEmpty {
            app.logger.notice(
                "Updated development login display names",
                metadata: [
                    "emails": .array(updatedEmails.map { .string($0) })
                ]
            )
        }
    }

    private static func defaultDisplayName(for email: String) -> String {
        switch email {
        case "demo@example.com":
            return "Demo"
        case "alice@example.com":
            return "Alice"
        case "bob@example.com":
            return "Bob"
        case "carol@example.com":
            return "Carol"
        case "dave@example.com":
            return "Dave"
        default:
            return email.split(separator: "@").first.map(String.init) ?? email
        }
    }
}
