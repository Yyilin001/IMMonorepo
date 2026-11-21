import Foundation
import IMV2Core
import IMV2ClientRuntime

public enum V2ContactListScope: Sendable { case friends, incomingRequests, outgoingRequests }
public struct V2BlockedContactPage: Sendable {
    public let items: [V2ClientUserBlockProjection]
    public let nextCursor: V2ClientRelationshipCursor?
}

/// Account-owned contact queries, relationship commands and durable direct conversation opening.
/// Pagination belongs to each caller/window; no selected contact or shared UI cursor lives here.
public final class V2ContactService: Sendable, V2PublicIdentityResolving, V2PublicIdentityPresentationResolving {
    public let accountID: UserID
    public let relationships: V2RelationshipService
    public let directConversations: V2DirectConversationService
    private let store: GRDBV2LocalSyncStore
    private let directory: any V2PublicIdentityResolving & V2PublicIdentityPresentationResolving
    private let lifetime = V2DirectoryLifetime()

    public init(accountID: UserID, store: GRDBV2LocalSyncStore, social: V2SocialOperationService,
                direct: V2DirectRoomOperationService,
                directory: any V2PublicIdentityResolving & V2PublicIdentityPresentationResolving) {
        self.accountID = accountID; self.store = store; self.directory = directory
        relationships = .init(service: social, lifetime: lifetime)
        directConversations = .init(service: direct, lifetime: lifetime)
    }
    private func projectionScope(_ scope: V2ContactListScope) -> V2ClientRelationshipPageScope {
        switch scope {
        case .friends: .accepted
        case .incomingRequests: .incomingRequests(currentUserID: accountID)
        case .outgoingRequests: .outgoingRequests(currentUserID: accountID)
        }
    }
    public func page(scope: V2ContactListScope, matching query: String? = nil,
                     before cursor: V2ClientRelationshipCursor? = nil, limit: Int = 50,
                     includeTotalCount: Bool = false) async throws -> V2ClientRelationshipPage {
        let scope = projectionScope(scope)
        return try await lifetime.run { [store] in
            try await store.relationshipPage(scope: scope, matching: query, before: cursor, limit: limit, includeTotalCount: includeTotalCount)
        }
    }
    public func window(scope: V2ContactListScope, matching query: String? = nil,
                       around anchor: V2ClientRelationshipCursor, limit: Int = 200,
                       precedingCount: Int = 50) async throws -> V2ClientRelationshipWindow {
        let scope = projectionScope(scope)
        return try await lifetime.run { [store] in
            try await store.relationshipWindow(scope: scope, matching: query, around: anchor, limit: limit, precedingCount: precedingCount)
        }
    }
    public func blockProjections() async throws -> [V2ClientUserBlockProjection] {
        try await lifetime.run { [store] in try await store.blocks() }
    }
    public func blocked(before cursor: V2ClientRelationshipCursor? = nil, limit: Int = 50) async throws -> V2BlockedContactPage {
        try await lifetime.run { [store] in
            guard (1...100).contains(limit) else { throw V2DirectoryServiceError.invalidInput }
            let rows = try await store.blocks().filter(\.isBlocked)
                .sorted { $0.targetUserID.rawValue < $1.targetUserID.rawValue }
                .filter { cursor == nil || $0.targetUserID.rawValue > cursor!.targetUserID.rawValue }
            let page = Array(rows.prefix(limit))
            return .init(items: page, nextCursor: rows.count > limit ? page.last.map { .init(updatedAt: $0.updatedAt, targetUserID: $0.targetUserID) } : nil)
        }
    }
    public func resolve(handle: String) async throws -> V2PublicIdentity {
        try await lifetime.run { [directory] in try await directory.resolve(handle: handle) }
    }
    public func resolveForPresentation(handle: String) async throws -> V2PublicIdentityLookupSnapshot {
        try await lifetime.run { [directory] in try await directory.resolveForPresentation(handle: handle) }
    }
    public func handlers() -> [V2OperationWorkDispatcher.Handler] {
        [.init(kind: .relationship) { [relationships] in try await relationships.execute($0) },
         .init(kind: .userBlock) { [relationships] in try await relationships.execute($0) },
         .init(kind: .directRoom) { [directConversations] in try await directConversations.execute($0) }]
    }
    public func close() async { await lifetime.close() }
}
