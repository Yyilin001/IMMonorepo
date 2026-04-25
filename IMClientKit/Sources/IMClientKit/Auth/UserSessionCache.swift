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
    private let userDisplayNameKey: String
    private let userAvatarPresetKey: String

    public init(
        userIDKey: String = "cached_auth_user_id",
        userEmailKey: String = "cached_auth_user_email",
        userDisplayNameKey: String = "cached_auth_user_display_name",
        userAvatarPresetKey: String = "cached_auth_user_avatar_preset"
    ) {
        self.userIDKey = userIDKey
        self.userEmailKey = userEmailKey
        self.userDisplayNameKey = userDisplayNameKey
        self.userAvatarPresetKey = userAvatarPresetKey
    }

    public func save(_ user: AuthUser) {
        UserDefaults.standard.set(user.id.uuidString, forKey: userIDKey)
        UserDefaults.standard.set(user.email, forKey: userEmailKey)
        UserDefaults.standard.set(user.displayName, forKey: userDisplayNameKey)
        UserDefaults.standard.set(user.avatarPreset?.rawValue, forKey: userAvatarPresetKey)
    }

    public func readUser() -> AuthUser? {
        guard let rawID = UserDefaults.standard.string(forKey: userIDKey),
              let id = UUID(uuidString: rawID),
              let email = UserDefaults.standard.string(forKey: userEmailKey)
        else {
            return nil
        }

        return AuthUser(
            id: id,
            email: email,
            displayName: UserDefaults.standard.string(forKey: userDisplayNameKey),
            avatarPreset: UserDefaults.standard.string(forKey: userAvatarPresetKey)
                .flatMap(UserAvatarPreset.init(rawValue:))
        )
    }

    public func clear() {
        UserDefaults.standard.removeObject(forKey: userIDKey)
        UserDefaults.standard.removeObject(forKey: userEmailKey)
        UserDefaults.standard.removeObject(forKey: userDisplayNameKey)
        UserDefaults.standard.removeObject(forKey: userAvatarPresetKey)
    }
}
