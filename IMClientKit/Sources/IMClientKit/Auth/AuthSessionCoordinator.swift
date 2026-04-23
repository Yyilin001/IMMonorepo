import Foundation

public actor AuthSessionCoordinator {
    public enum RestoreResult: Sendable {
        case signedOut
        case signedIn(AuthUser)
        case signedInOffline(AuthUser, message: String)
    }

    private struct RefreshState {
        let id: UInt64
        let task: Task<Void, Error>
    }

    private let authAPI: AuthAPI
    private let tokenStore: TokenStoreHandler
    private let userCache: UserSessionCacheHandler
    private let refreshTokenKey = "refresh_token"

    private var accessToken: String?
    private var accessTokenExpiry: Date?
    private var refreshState: RefreshState?
    private var nextRefreshID: UInt64 = 0
    private var sessionGeneration: UInt64 = 0

    init(
        authAPI: AuthAPI,
        tokenStore: TokenStoreHandler,
        userCache: UserSessionCacheHandler
    ) {
        self.authAPI = authAPI
        self.tokenStore = tokenStore
        self.userCache = userCache
    }

    public func login(email: String, password: String, device: DeviceMetadataPayload?) async throws -> AuthUser {
        let response = try await authAPI.login(email: email, password: password, device: device)
        try persist(response)
        return response.user
    }

    public func register(email: String, password: String, device: DeviceMetadataPayload?) async throws -> AuthUser {
        let response = try await authAPI.register(email: email, password: password, device: device)
        try persist(response)
        return response.user
    }

    public func restoreSession() async -> RestoreResult {
        do {
            guard let refreshToken = try tokenStore.readString(for: refreshTokenKey) else {
                return .signedOut
            }

            let response = try await refresh(using: refreshToken)
            try persist(response)
            return .signedIn(response.user)
        } catch {
            if shouldPreserveSession(for: error), let cachedUser = userCache.readUser() {
                return .signedInOffline(cachedUser, message: error.localizedDescription)
            }

            clearSession()
            return .signedOut
        }
    }

    public func clearSession() {
        sessionGeneration &+= 1
        let refreshTask = refreshState?.task
        refreshState = nil
        refreshTask?.cancel()
        accessToken = nil
        accessTokenExpiry = nil
        tokenStore.delete(refreshTokenKey)
        userCache.clear()
    }

    public func validAccessToken(forceRefresh: Bool) async throws -> String {
        if !forceRefresh,
           let accessToken,
           let accessTokenExpiry,
           accessTokenExpiry.timeIntervalSinceNow > 60
        {
            return accessToken
        }

        if let refreshState {
            try await refreshState.task.value
            guard let accessToken else {
                throw APIError.unauthorized("缺少访问令牌，请重新登录。")
            }
            return accessToken
        }

        guard let refreshToken = try tokenStore.readString(for: refreshTokenKey) else {
            throw APIError.unauthorized("请重新登录。")
        }

        let refreshID = nextRefreshID
        nextRefreshID &+= 1
        let generation = sessionGeneration
        let task = Task {
            let response = try await self.refresh(using: refreshToken)
            try self.persist(response, ifGenerationMatches: generation)
        }

        refreshState = RefreshState(
            id: refreshID,
            task: task
        )
        defer {
            if refreshState?.id == refreshID {
                refreshState = nil
            }
        }

        try await task.value

        guard let accessToken else {
            throw APIError.unauthorized("缺少访问令牌，请重新登录。")
        }
        return accessToken
    }

    public func shouldPreserveSession(for error: Error) -> Bool {
        guard let apiError = error as? APIError else {
            return false
        }
        return apiError.shouldPreserveSession
    }

    public func shouldMarkServerOffline(for error: Error) -> Bool {
        guard let apiError = error as? APIError else {
            return false
        }
        return apiError.shouldMarkServerOffline
    }

    private func refresh(using refreshToken: String) async throws -> AuthResponseBody {
        try await authAPI.refresh(refreshToken: refreshToken)
    }

    private func persist(_ response: AuthResponseBody, ifGenerationMatches generation: UInt64) throws {
        guard sessionGeneration == generation else {
            return
        }
        try persist(response)
    }

    private func persist(_ response: AuthResponseBody) throws {
        accessToken = response.accessToken
        accessTokenExpiry = Date().addingTimeInterval(TimeInterval(response.expiresIn))
        try tokenStore.save(response.refreshToken, for: refreshTokenKey)
        userCache.save(response.user)
    }
}
