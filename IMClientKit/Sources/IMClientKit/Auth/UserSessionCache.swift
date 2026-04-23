import Foundation

public protocol UserSessionCache: Sendable {
    func save(_ user: AuthUser)
    func readUser() -> AuthUser?
    func clear()
}

public struct UserSessionCacheHandler: Sendable {
    public let saveUser: @Sendable (AuthUser) -> Void
    public let readCachedUser: @Sendable () -> AuthUser?
    public let clearUser: @Sendable () -> Void

    public init<Cache: UserSessionCache>(_ cache: Cache) {
        saveUser = { user in
            cache.save(user)
        }
        readCachedUser = {
            cache.readUser()
        }
        clearUser = {
            cache.clear()
        }
    }

    public func save(_ user: AuthUser) {
        saveUser(user)
    }

    public func readUser() -> AuthUser? {
        readCachedUser()
    }

    public func clear() {
        clearUser()
    }
}

public struct UserDefaultsSessionCache: UserSessionCache {
    private let userIDKey: String
    private let userEmailKey: String

    public init(
        userIDKey: String = "cached_auth_user_id",
        userEmailKey: String = "cached_auth_user_email"
    ) {
        self.userIDKey = userIDKey
        self.userEmailKey = userEmailKey
    }

    public func save(_ user: AuthUser) {
        UserDefaults.standard.set(user.id.uuidString, forKey: userIDKey)
        UserDefaults.standard.set(user.email, forKey: userEmailKey)
    }

    public func readUser() -> AuthUser? {
        guard let rawID = UserDefaults.standard.string(forKey: userIDKey),
              let id = UUID(uuidString: rawID),
              let email = UserDefaults.standard.string(forKey: userEmailKey)
        else {
            return nil
        }

        return AuthUser(id: id, email: email)
    }

    public func clear() {
        UserDefaults.standard.removeObject(forKey: userIDKey)
        UserDefaults.standard.removeObject(forKey: userEmailKey)
    }
}
