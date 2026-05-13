import Foundation

public struct CachedContactState: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let email: String
    public let displayName: String?
    public let avatarPreset: UserAvatarPreset?
    public let remark: String?
    public let createdAt: Date?

    public init(
        id: UUID,
        email: String,
        displayName: String? = nil,
        avatarPreset: UserAvatarPreset? = nil,
        remark: String?,
        createdAt: Date?
    ) {
        self.id = id
        self.email = email
        self.displayName = displayName
        self.avatarPreset = avatarPreset
        self.remark = remark
        self.createdAt = createdAt
    }

    public init(_ contact: ContactResponseBody) {
        self.init(
            id: contact.id,
            email: contact.email,
            displayName: contact.profileDisplayName,
            avatarPreset: contact.avatarPreset,
            remark: contact.remark,
            createdAt: contact.createdAt
        )
    }

    public var contact: ContactResponseBody {
        ContactResponseBody(
            id: id,
            email: email,
            displayName: displayName,
            avatarPreset: avatarPreset,
            remark: remark,
            createdAt: createdAt
        )
    }
}

public struct CachedContactRequestState: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let requester: AuthUser
    public let addressee: AuthUser
    public let status: ContactRequestStatus
    public let message: String?
    public let requesterRemark: String?
    public let addresseeRemark: String?
    public let createdAt: Date?
    public let updatedAt: Date?
    public let respondedAt: Date?

    public init(
        id: UUID,
        requester: AuthUser,
        addressee: AuthUser,
        status: ContactRequestStatus,
        message: String?,
        requesterRemark: String?,
        addresseeRemark: String?,
        createdAt: Date?,
        updatedAt: Date?,
        respondedAt: Date?
    ) {
        self.id = id
        self.requester = requester
        self.addressee = addressee
        self.status = status
        self.message = message
        self.requesterRemark = requesterRemark
        self.addresseeRemark = addresseeRemark
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.respondedAt = respondedAt
    }

    public init(_ request: ContactRequestResponseBody) {
        self.init(
            id: request.id,
            requester: request.requester,
            addressee: request.addressee,
            status: request.status,
            message: request.message,
            requesterRemark: request.requesterRemark,
            addresseeRemark: request.addresseeRemark,
            createdAt: request.createdAt,
            updatedAt: request.updatedAt,
            respondedAt: request.respondedAt
        )
    }

    public var request: ContactRequestResponseBody {
        ContactRequestResponseBody(
            id: id,
            requester: requester,
            addressee: addressee,
            status: status,
            message: message,
            requesterRemark: requesterRemark,
            addresseeRemark: addresseeRemark,
            createdAt: createdAt,
            updatedAt: updatedAt,
            respondedAt: respondedAt
        )
    }
}

public struct ContactStateCacheSnapshot: Sendable, Equatable {
    public let contacts: [CachedContactState]
    public let incomingRequests: [CachedContactRequestState]
    public let outgoingRequests: [CachedContactRequestState]
    public let resolvedRequests: [CachedContactRequestState]
    public let lastRefreshAt: Date?
    public let lastSeenIncomingContactRequestAt: Date?

    public static let empty = ContactStateCacheSnapshot(
        contacts: [],
        incomingRequests: [],
        outgoingRequests: [],
        resolvedRequests: [],
        lastRefreshAt: nil,
        lastSeenIncomingContactRequestAt: nil
    )

    public init(
        contacts: [CachedContactState],
        incomingRequests: [CachedContactRequestState],
        outgoingRequests: [CachedContactRequestState],
        resolvedRequests: [CachedContactRequestState],
        lastRefreshAt: Date?,
        lastSeenIncomingContactRequestAt: Date? = nil
    ) {
        self.contacts = contacts
        self.incomingRequests = incomingRequests
        self.outgoingRequests = outgoingRequests
        self.resolvedRequests = resolvedRequests
        self.lastRefreshAt = lastRefreshAt
        self.lastSeenIncomingContactRequestAt = lastSeenIncomingContactRequestAt
    }
}

public protocol ContactStateCaching: Sendable {
    func loadSnapshot(for ownerUserID: UUID) async throws -> ContactStateCacheSnapshot
    func saveSnapshot(_ snapshot: ContactStateCacheSnapshot, for ownerUserID: UUID) async throws
    func clearSnapshot(for ownerUserID: UUID) async throws
    func clearAll() async throws
}

public struct ContactStateCacheHandler: Sendable {
    private let loadSnapshotHandler: @Sendable (UUID) async throws -> ContactStateCacheSnapshot
    private let saveSnapshotHandler: @Sendable (ContactStateCacheSnapshot, UUID) async throws -> Void
    private let clearSnapshotHandler: @Sendable (UUID) async throws -> Void
    private let clearAllHandler: @Sendable () async throws -> Void

    public init<Cache: ContactStateCaching>(_ cache: Cache) {
        loadSnapshotHandler = { ownerUserID in
            try await cache.loadSnapshot(for: ownerUserID)
        }
        saveSnapshotHandler = { snapshot, ownerUserID in
            try await cache.saveSnapshot(snapshot, for: ownerUserID)
        }
        clearSnapshotHandler = { ownerUserID in
            try await cache.clearSnapshot(for: ownerUserID)
        }
        clearAllHandler = {
            try await cache.clearAll()
        }
    }

    public func loadSnapshot(for ownerUserID: UUID) async throws -> ContactStateCacheSnapshot {
        try await loadSnapshotHandler(ownerUserID)
    }

    public func saveSnapshot(_ snapshot: ContactStateCacheSnapshot, for ownerUserID: UUID) async throws {
        try await saveSnapshotHandler(snapshot, ownerUserID)
    }

    public func clearSnapshot(for ownerUserID: UUID) async throws {
        try await clearSnapshotHandler(ownerUserID)
    }

    public func clearAll() async throws {
        try await clearAllHandler()
    }
}

public struct NoopContactStateCache: ContactStateCaching {
    public init() { }

    public func loadSnapshot(for ownerUserID: UUID) async throws -> ContactStateCacheSnapshot {
        _ = ownerUserID
        return .empty
    }

    public func saveSnapshot(_ snapshot: ContactStateCacheSnapshot, for ownerUserID: UUID) async throws {
        _ = snapshot
        _ = ownerUserID
    }

    public func clearSnapshot(for ownerUserID: UUID) async throws {
        _ = ownerUserID
    }

    public func clearAll() async throws { }
}
