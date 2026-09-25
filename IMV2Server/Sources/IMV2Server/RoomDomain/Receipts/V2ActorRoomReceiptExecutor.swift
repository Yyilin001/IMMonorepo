import FluentKit
import Foundation
import IMV2ActorContracts
import IMV2Core

/// 房间侧回执适配器。物理 RoomActor 轮次只能调用
/// 受激活围栏保护的入口；用户偏好仍属控制侧。
public struct V2ActorRoomReceiptExecutor: Sendable {
    private let database: any Database
    private let projectionDelivery: any V2UserShardProjectionDelivering
    private let timeouts: V2RoomActivationSQLTimeouts

    public init(database: any Database, projectionDelivery: any V2UserShardProjectionDelivering,
                timeouts: V2RoomActivationSQLTimeouts = .default) {
        self.database = database
        self.projectionDelivery = projectionDelivery
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
                // 优化后的回执存储报告逐项所有者错误。
                // 在此逐条房间边界，它表示激活权限已过期，
                // 因此目录必须让位置失效并重新解析。
                throw V2RoomActivationLeaseError.activationChanged
            } catch let error as V2ReadReceiptStoreError {
                return .recordFailure(.init(error))
            }
        }
    }

    public func recordBatch(_ batch: V2ActorReadReceiptRecordBatchWire,
                            scope: V2RoomActivationWriteScope, ingressTimes: [Date]) async throws -> V2ActorReadReceiptRecordBatchResultWire {
        guard ingressTimes.count == batch.requests.count,
              ingressTimes.allSatisfy({ $0.timeIntervalSince1970.isFinite }) else {
            throw V2ActorRoomReceiptWireError.invalidRequest
        }
        let requests = try zip(batch.requests, ingressTimes).map { wire, ingressAt in
            try V2ReadReceiptRecordRequest(command: wire.commandValue(), now: ingressAt)
        }
        let results = try await store(database).recordBatchActivationValidated(requests,
            scope: scope, timeouts: timeouts)
        return try .init(results, expectedCount: requests.count)
    }

    public func recordBatch(_ batch: V2ActorReadReceiptRecordBatchWire,
                            scope: V2RoomActivationWriteScope, ingressAt: Date) async throws -> V2ActorReadReceiptRecordBatchResultWire {
        try await recordBatch(batch, scope: scope,
            ingressTimes: Array(repeating: ingressAt, count: batch.requests.count))
    }

    public func query(_ query: V2RoomReceiptQuery, token: V2RoomActivationToken) async throws -> V2RoomReceiptResult {
        let reader = V2ActorRoomQueryExecutor(database: database, timeouts: timeouts)
        return try await reader.withFencedRead(roomIDs: [query.roomID], tokens: [token]) { transaction in
            switch query {
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
        .init(database: database, projectionDelivery: projectionDelivery)
    }
}
