import Foundation
import SwiftData

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

@Model
public final class ContactCacheMetadataEntity {
    @Attribute(.unique) var recordID: String
    public var ownerUserID: String
    public var lastRefreshAt: Date?
    public var lastSeenIncomingContactRequestAt: Date?

    init(
        recordID: String,
        ownerUserID: String,
        lastRefreshAt: Date?,
        lastSeenIncomingContactRequestAt: Date?
    ) {
        self.recordID = recordID
        self.ownerUserID = ownerUserID
        self.lastRefreshAt = lastRefreshAt
        self.lastSeenIncomingContactRequestAt = lastSeenIncomingContactRequestAt
    }
}

@Model
public final class CachedContactEntity {
    @Attribute(.unique) var recordID: String
    public var ownerUserID: String
    public var contactUserID: String
    public var email: String
    public var displayName: String?
    public var avatarPresetRawValue: String?
    public var remark: String?
    public var createdAt: Date?

    init(
        recordID: String,
        ownerUserID: String,
        contactUserID: String,
        email: String,
        displayName: String?,
        avatarPresetRawValue: String?,
        remark: String?,
        createdAt: Date?
    ) {
        self.recordID = recordID
        self.ownerUserID = ownerUserID
        self.contactUserID = contactUserID
        self.email = email
        self.displayName = displayName
        self.avatarPresetRawValue = avatarPresetRawValue
        self.remark = remark
        self.createdAt = createdAt
    }
}

@Model
public final class CachedContactRequestEntity {
    @Attribute(.unique) var recordID: String
    public var ownerUserID: String
    public var requestID: String
    public var boxRawValue: String
    public var requesterUserID: String
    public var requesterEmail: String
    public var requesterDisplayName: String?
    public var requesterAvatarPresetRawValue: String?
    public var addresseeUserID: String
    public var addresseeEmail: String
    public var addresseeDisplayName: String?
    public var addresseeAvatarPresetRawValue: String?
    public var statusRawValue: String
    public var message: String?
    public var requesterRemark: String?
    public var addresseeRemark: String?
    public var createdAt: Date?
    public var updatedAt: Date?
    public var respondedAt: Date?

    init(
        recordID: String,
        ownerUserID: String,
        requestID: String,
        boxRawValue: String,
        requesterUserID: String,
        requesterEmail: String,
        requesterDisplayName: String?,
        requesterAvatarPresetRawValue: String?,
        addresseeUserID: String,
        addresseeEmail: String,
        addresseeDisplayName: String?,
        addresseeAvatarPresetRawValue: String?,
        statusRawValue: String,
        message: String?,
        requesterRemark: String?,
        addresseeRemark: String?,
        createdAt: Date?,
        updatedAt: Date?,
        respondedAt: Date?
    ) {
        self.recordID = recordID
        self.ownerUserID = ownerUserID
        self.requestID = requestID
        self.boxRawValue = boxRawValue
        self.requesterUserID = requesterUserID
        self.requesterEmail = requesterEmail
        self.requesterDisplayName = requesterDisplayName
        self.requesterAvatarPresetRawValue = requesterAvatarPresetRawValue
        self.addresseeUserID = addresseeUserID
        self.addresseeEmail = addresseeEmail
        self.addresseeDisplayName = addresseeDisplayName
        self.addresseeAvatarPresetRawValue = addresseeAvatarPresetRawValue
        self.statusRawValue = statusRawValue
        self.message = message
        self.requesterRemark = requesterRemark
        self.addresseeRemark = addresseeRemark
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.respondedAt = respondedAt
    }
}

@ModelActor
public actor ContactStateCacheModelActor {
    private enum RequestBucket: String {
        case incoming
        case outgoing
        case resolved
    }

    public func loadSnapshot(for ownerUserID: String) throws -> ContactStateCacheSnapshot {
        let metadata = try modelContext.fetch(
            FetchDescriptor<ContactCacheMetadataEntity>(
                predicate: #Predicate { $0.ownerUserID == ownerUserID }
            )
        ).first
        let contacts = try modelContext.fetch(
            FetchDescriptor<CachedContactEntity>(
                predicate: #Predicate { $0.ownerUserID == ownerUserID }
            )
        )
        let requests = try modelContext.fetch(
            FetchDescriptor<CachedContactRequestEntity>(
                predicate: #Predicate { $0.ownerUserID == ownerUserID }
            )
        )

        let mappedContacts = contacts.compactMap(Self.cachedContactState(from:)).sorted { $0.email < $1.email }
        let mappedRequests = requests.compactMap(Self.cachedContactRequestState(from:))
        let incoming = mappedRequests
            .filter { entity, _ in entity.boxRawValue == RequestBucket.incoming.rawValue }
            .map(\.1)
            .sorted(by: Self.pendingContactRequestComparator)
        let outgoing = mappedRequests
            .filter { entity, _ in entity.boxRawValue == RequestBucket.outgoing.rawValue }
            .map(\.1)
            .sorted(by: Self.pendingContactRequestComparator)
        let resolved = mappedRequests
            .filter { entity, _ in entity.boxRawValue == RequestBucket.resolved.rawValue }
            .map(\.1)
            .sorted(by: Self.resolvedContactRequestComparator)

        return ContactStateCacheSnapshot(
            contacts: mappedContacts,
            incomingRequests: incoming,
            outgoingRequests: outgoing,
            resolvedRequests: resolved,
            lastRefreshAt: metadata?.lastRefreshAt,
            lastSeenIncomingContactRequestAt: metadata?.lastSeenIncomingContactRequestAt
        )
    }

    public func saveSnapshot(_ snapshot: ContactStateCacheSnapshot, for ownerUserID: String) throws {
        try deleteMetadata(for: ownerUserID)
        try deleteContacts(for: ownerUserID)
        try deleteRequests(for: ownerUserID)

        modelContext.insert(
            ContactCacheMetadataEntity(
                recordID: Self.metadataRecordID(ownerUserID: ownerUserID),
                ownerUserID: ownerUserID,
                lastRefreshAt: snapshot.lastRefreshAt,
                lastSeenIncomingContactRequestAt: snapshot.lastSeenIncomingContactRequestAt
            )
        )

        for contact in snapshot.contacts {
            modelContext.insert(
                CachedContactEntity(
                    recordID: Self.contactRecordID(ownerUserID: ownerUserID, contactUserID: contact.id.uuidString),
                    ownerUserID: ownerUserID,
                    contactUserID: contact.id.uuidString,
                    email: contact.email,
                    displayName: contact.displayName,
                    avatarPresetRawValue: contact.avatarPreset?.rawValue,
                    remark: contact.remark,
                    createdAt: contact.createdAt
                )
            )
        }

        for request in snapshot.incomingRequests {
            modelContext.insert(Self.requestEntity(
                from: request,
                ownerUserID: ownerUserID,
                bucket: .incoming
            ))
        }

        for request in snapshot.outgoingRequests {
            modelContext.insert(Self.requestEntity(
                from: request,
                ownerUserID: ownerUserID,
                bucket: .outgoing
            ))
        }

        for request in snapshot.resolvedRequests {
            modelContext.insert(Self.requestEntity(
                from: request,
                ownerUserID: ownerUserID,
                bucket: .resolved
            ))
        }

        try modelContext.save()
    }

    public func clearSnapshot(for ownerUserID: String) throws {
        try deleteMetadata(for: ownerUserID)
        try deleteContacts(for: ownerUserID)
        try deleteRequests(for: ownerUserID)
        try modelContext.save()
    }

    public func clearAll() throws {
        try modelContext.fetch(FetchDescriptor<ContactCacheMetadataEntity>()).forEach(modelContext.delete)
        try modelContext.fetch(FetchDescriptor<CachedContactEntity>()).forEach(modelContext.delete)
        try modelContext.fetch(FetchDescriptor<CachedContactRequestEntity>()).forEach(modelContext.delete)
        try modelContext.save()
    }

    private func deleteMetadata(for ownerUserID: String) throws {
        let descriptor = FetchDescriptor<ContactCacheMetadataEntity>(
            predicate: #Predicate { $0.ownerUserID == ownerUserID }
        )
        try modelContext.fetch(descriptor).forEach(modelContext.delete)
    }

    private func deleteContacts(for ownerUserID: String) throws {
        let descriptor = FetchDescriptor<CachedContactEntity>(
            predicate: #Predicate { $0.ownerUserID == ownerUserID }
        )
        try modelContext.fetch(descriptor).forEach(modelContext.delete)
    }

    private func deleteRequests(for ownerUserID: String) throws {
        let descriptor = FetchDescriptor<CachedContactRequestEntity>(
            predicate: #Predicate { $0.ownerUserID == ownerUserID }
        )
        try modelContext.fetch(descriptor).forEach(modelContext.delete)
    }

    private static func cachedContactState(from entity: CachedContactEntity) -> CachedContactState? {
        guard let id = UUID(uuidString: entity.contactUserID) else {
            return nil
        }

        return CachedContactState(
            id: id,
            email: entity.email,
            displayName: entity.displayName,
            avatarPreset: entity.avatarPresetRawValue.flatMap(UserAvatarPreset.init(rawValue:)),
            remark: entity.remark,
            createdAt: entity.createdAt
        )
    }

    private static func cachedContactRequestState(
        from entity: CachedContactRequestEntity
    ) -> (CachedContactRequestEntity, CachedContactRequestState)? {
        guard let requestID = UUID(uuidString: entity.requestID),
              let requesterID = UUID(uuidString: entity.requesterUserID),
              let addresseeID = UUID(uuidString: entity.addresseeUserID),
              let status = ContactRequestStatus(rawValue: entity.statusRawValue)
        else {
            return nil
        }

        return (
            entity,
            CachedContactRequestState(
                id: requestID,
                requester: AuthUser(
                    id: requesterID,
                    email: entity.requesterEmail,
                    displayName: entity.requesterDisplayName,
                    avatarPreset: entity.requesterAvatarPresetRawValue.flatMap(UserAvatarPreset.init(rawValue:))
                ),
                addressee: AuthUser(
                    id: addresseeID,
                    email: entity.addresseeEmail,
                    displayName: entity.addresseeDisplayName,
                    avatarPreset: entity.addresseeAvatarPresetRawValue.flatMap(UserAvatarPreset.init(rawValue:))
                ),
                status: status,
                message: entity.message,
                requesterRemark: entity.requesterRemark,
                addresseeRemark: entity.addresseeRemark,
                createdAt: entity.createdAt,
                updatedAt: entity.updatedAt,
                respondedAt: entity.respondedAt
            )
        )
    }

    private static func requestEntity(
        from request: CachedContactRequestState,
        ownerUserID: String,
        bucket: RequestBucket
    ) -> CachedContactRequestEntity {
        CachedContactRequestEntity(
            recordID: requestRecordID(
                ownerUserID: ownerUserID,
                requestID: request.id.uuidString,
                bucket: bucket.rawValue
            ),
            ownerUserID: ownerUserID,
            requestID: request.id.uuidString,
            boxRawValue: bucket.rawValue,
            requesterUserID: request.requester.id.uuidString,
            requesterEmail: request.requester.email,
            requesterDisplayName: request.requester.displayName,
            requesterAvatarPresetRawValue: request.requester.avatarPreset?.rawValue,
            addresseeUserID: request.addressee.id.uuidString,
            addresseeEmail: request.addressee.email,
            addresseeDisplayName: request.addressee.displayName,
            addresseeAvatarPresetRawValue: request.addressee.avatarPreset?.rawValue,
            statusRawValue: request.status.rawValue,
            message: request.message,
            requesterRemark: request.requesterRemark,
            addresseeRemark: request.addresseeRemark,
            createdAt: request.createdAt,
            updatedAt: request.updatedAt,
            respondedAt: request.respondedAt
        )
    }

    private static func metadataRecordID(ownerUserID: String) -> String {
        "contact-cache-metadata-\(ownerUserID)"
    }

    private static func contactRecordID(ownerUserID: String, contactUserID: String) -> String {
        "contact-\(ownerUserID)-\(contactUserID)"
    }

    private static func requestRecordID(ownerUserID: String, requestID: String, bucket: String) -> String {
        "contact-request-\(ownerUserID)-\(bucket)-\(requestID)"
    }

    private static func pendingContactRequestComparator(
        _ left: CachedContactRequestState,
        _ right: CachedContactRequestState
    ) -> Bool {
        switch (left.createdAt, right.createdAt) {
        case let (leftDate?, rightDate?):
            return leftDate > rightDate
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        case (nil, nil):
            return left.id.uuidString > right.id.uuidString
        }
    }

    private static func resolvedContactRequestComparator(
        _ left: CachedContactRequestState,
        _ right: CachedContactRequestState
    ) -> Bool {
        switch (left.respondedAt, right.respondedAt) {
        case let (leftDate?, rightDate?):
            if leftDate != rightDate {
                return leftDate > rightDate
            }
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        case (nil, nil):
            break
        }

        switch (left.updatedAt, right.updatedAt) {
        case let (leftDate?, rightDate?):
            if leftDate != rightDate {
                return leftDate > rightDate
            }
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        case (nil, nil):
            break
        }

        return left.id.uuidString > right.id.uuidString
    }
}

public final class SwiftDataContactStateCache: ContactStateCaching, @unchecked Sendable {
    private let modelActor: ContactStateCacheModelActor

    init(modelContainer: ModelContainer) {
        self.modelActor = ContactStateCacheModelActor(modelContainer: modelContainer)
    }

    public func loadSnapshot(for ownerUserID: UUID) async throws -> ContactStateCacheSnapshot {
        try await modelActor.loadSnapshot(for: ownerUserID.uuidString)
    }

    public func saveSnapshot(_ snapshot: ContactStateCacheSnapshot, for ownerUserID: UUID) async throws {
        try await modelActor.saveSnapshot(snapshot, for: ownerUserID.uuidString)
    }

    public func clearSnapshot(for ownerUserID: UUID) async throws {
        try await modelActor.clearSnapshot(for: ownerUserID.uuidString)
    }

    public func clearAll() async throws {
        try await modelActor.clearAll()
    }

    public static func makeDefaultHandler() -> ContactStateCacheHandler {
        do {
            let container = try ModelContainer(
                for: ContactCacheMetadataEntity.self,
                CachedContactEntity.self,
                CachedContactRequestEntity.self
            )
            return ContactStateCacheHandler(
                SwiftDataContactStateCache(modelContainer: container)
            )
        } catch {
            return ContactStateCacheHandler(NoopContactStateCache())
        }
    }
}
