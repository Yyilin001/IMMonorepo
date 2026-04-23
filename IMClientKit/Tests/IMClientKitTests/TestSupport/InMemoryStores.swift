import Foundation
import IMClientKit
@testable import IMClientKit

final class InMemoryTokenStore: TokenStore, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: String] = [:]

    func save(_ value: String, for key: String) throws {
        lock.lock()
        defer { lock.unlock() }
        storage[key] = value
    }

    func readString(for key: String) throws -> String? {
        lock.lock()
        defer { lock.unlock() }
        return storage[key]
    }

    func delete(_ key: String) {
        lock.lock()
        defer { lock.unlock() }
        storage.removeValue(forKey: key)
    }
}

final class InMemoryUserSessionCache: UserSessionCache, @unchecked Sendable {
    private let lock = NSLock()
    private var user: AuthUser?

    func save(_ user: AuthUser) {
        lock.lock()
        defer { lock.unlock() }
        self.user = user
    }

    func readUser() -> AuthUser? {
        lock.lock()
        defer { lock.unlock() }
        return user
    }

    func clear() {
        lock.lock()
        defer { lock.unlock() }
        user = nil
    }
}
