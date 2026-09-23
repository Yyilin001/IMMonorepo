import FluentKit
import Foundation
import IMV2ActorContracts
import IMV2Core

/// The room-side receipt adapter. Only its activation-fenced entry points may
/// be called by a physical RoomActor turn; user preferences remain control-side.
public struct V2ActorRoomReceiptExecutor: Sendable {
    private let database: any Database
    private let shadowForwarder: any V2UserShardProjectionShadowing
    private let timeouts: V2RoomActivationSQLTimeouts

    public init(database: any Database, shadowForwarder: any V2UserShardProjectionShadowing,
                timeouts: V2RoomActivationSQLTimeouts = .default) {
        self.database = database
        self.shadowForwarder = shadowForwarder
        self.timeouts = timeouts
    }

    public func command(_ command: V2RoomReceiptCommand, token: V2RoomActivationToken,
                        ingressAt: Date) async throws -> V2RoomReceiptResult {
        guard token.roomID == command.roomID else { throw V2RoomActivationLeaseError.activationChanged }
        switch command {
        case .record(let wire):
            do {
                let outcome = try await store(database).recordActivationValidated(
                    command: wire.commandValue(), token: token, now: ingressAt, timeouts: timeouts)
                return .record(.init(outcome))
            } catch V2ReadReceiptStoreError.ownerChanged {
                // The optimized receipt store reports a per-item owner error.
                // At this scalar room boundary it is stale activation authority,
                // so the directory must invalidate and resolve the location.
                throw V2RoomActivationLeaseError.activationChanged
            } catch let error as V2ReadReceiptStoreError {
                return .recordFailure(.init(error))
            }
        }
    }

    public func recordBatch(_ batch: V2ActorReadReceiptRecordBatchWire,
                            scope: V2RoomActivationWriteScope, ingressAt: Date) async throws -> V2ActorReadReceiptRecordBatchResultWire {
        let requests = try batch.recordRequests(now: ingressAt)
        let results = try await store(database).recordBatchActivationValidated(requests,
            scope: scope, timeouts: timeouts)
        return try .init(results, expectedCount: requests.count)
    }

    public func query(_ query: V2RoomReceiptQuery, token: V2RoomActivationToken) async throws -> V2RoomReceiptResult {
        let reader = V2ActorRoomQueryExecutor(database: database, timeouts: timeouts)
        return try await reader.withFencedRead(roomIDs: [query.roomID], tokens: [token]) { transaction in
            switch query {
            case .readers:
                throw V2RoomCallFailure.notAccepted(.invalidRequest)
            case .readerCandidates(let wire):
                do {
                    let page = try await store(transaction).readerCandidates(roomID: wire.roomID,
                        messageID: wire.messageID, actorUserID: wire.actorUserID,
                        cursor: wire.cursor, pageSize: wire.pageSize)
                    return .readerCandidates(.init(page))
                } catch let error as V2ReadReceiptStoreError {
                    return .readersFailure(.init(error))
                }
            }
        }
    }

    private func store(_ database: any Database) -> PostgresV2ReadReceiptStore {
        .init(database: database, shadowForwarder: shadowForwarder)
    }
}
