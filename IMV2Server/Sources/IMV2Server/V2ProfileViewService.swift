import Foundation
import IMV2Core

/// Bounded request passed from the authenticated HTTP edge to profile storage.
/// The request contains stable IDs obtained from a direct room or an already
/// authorized room context; it is never a general identity-directory query.
public struct V2ProfileViewReadRequest: Equatable, Sendable {
    public static let maximumKeys = V2ProfileViewLookupLimits.maximumKeys

    public let actorUserID: UserID
    public let keys: [V2ProfileViewLookupKey]

    public init(actorUserID: UserID, keys: [V2ProfileViewLookupKey]) throws {
        guard !keys.isEmpty, keys.count <= Self.maximumKeys, Set(keys).count == keys.count else {
            throw V2ProfileViewReadError.invalidRequest
        }
        self.actorUserID = actorUserID
        self.keys = keys
    }
}

public protocol V2ProfileViewStore: Sendable {
    /// A result is returned for every requested key. Unauthorized, blocked,
    /// deleted, and absent objects are deliberately collapsed by the store.
    func read(_ request: V2ProfileViewReadRequest) async throws -> [V2ProfileViewLookupResult]
}

public struct V2ProfileViewService: Sendable {
    private let store: any V2ProfileViewStore

    public init(store: any V2ProfileViewStore) {
        self.store = store
    }

    public func read(_ request: V2ProfileViewReadRequest) async throws -> [V2ProfileViewLookupResult] {
        try await store.read(request)
    }
}

public enum V2ProfileViewReadError: Error, Equatable, Sendable {
    case invalidRequest
    case corruptPersistenceState
}
