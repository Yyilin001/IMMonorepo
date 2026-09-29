import IMV2ServerContracts
import IMV2ActorContracts
import IMV2Core

public struct V2RoomMediaAuthorizationDomainExecutor: Sendable {
    private let token: V2RoomActivationToken
    private let store: any V2RoomMediaAuthorizationStoring

    package init(token: V2RoomActivationToken, store: any V2RoomMediaAuthorizationStoring) {
        self.token = token
        self.store = store
    }

    public func execute(_ query: V2RoomMediaAuthorizationQuery) async throws -> V2RoomMediaAuthorizationResult {
        guard query.roomID == token.roomID else {
            throw V2RoomActivationLeaseError.activationChanged
        }
        return try await store.execute(query)
    }

    package func executeProfileVisibilityBatch(_ requests: [V2ActorProfileVisibilityBatchWire]) async throws -> [V2RoomMediaAuthorizationResult] {
        guard !requests.isEmpty, requests.allSatisfy({ $0.roomID == token.roomID }) else {
            throw V2RoomCallFailure.notAccepted(.invalidRequest)
        }
        return try await store.executeProfileVisibilityBatch(requests)
    }
}
