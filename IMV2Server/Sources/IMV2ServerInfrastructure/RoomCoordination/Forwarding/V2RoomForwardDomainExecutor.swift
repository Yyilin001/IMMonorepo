import IMV2ServerApplication
import IMV2ServerContracts
import FluentKit
import Foundation
import IMV2ActorContracts
import IMV2Core

/// 在已授权的房间执行轮次内处理封闭的来源／目标工作流命令。
/// 同一所有者上的房间对只能通过双房间预留执行器进入。
public struct V2RoomForwardDomainExecutor: Sendable {
    private let token: V2RoomActivationToken
    private let exports: PostgresV2ForwardExportStore
    private let receipts: PostgresV2ForwardReceiptStore
    private let importExport: @Sendable (V2ForwardExport, V2RoomActivationToken, Date) async throws -> V2ForwardImportOutcome
    private let now: @Sendable () -> Date

    public init(database: any Database, token: V2RoomActivationToken,
                importExport: @escaping @Sendable (V2ForwardExport, V2RoomActivationToken, Date) async throws -> V2ForwardImportOutcome,
                now: @escaping @Sendable () -> Date = Date.init) throws {
        self.token = token
        self.exports = try PostgresV2ForwardExportStore(database: database).usingActivationToken(token)
        self.receipts = try PostgresV2ForwardReceiptStore(database: database).usingActivationToken(token)
        self.importExport = importExport
        self.now = now
    }

    /// 生产环境的导入绑定：写入存储将接收、重放、准入、接受和完成
    /// 全部限定到这个确切的目标激活。
    public init(database: any Database, token: V2RoomActivationToken,
                write: PostgresV2RoomWriteStore, capacityProfile: V2CapacityProfile,
                limits: V2MessageCommandLimits,
                acceptanceIDs: V2AcceptanceIDFactory = .init(),
                now: @escaping @Sendable () -> Date = Date.init) throws {
        try self.init(database: database, token: token, importExport: { export, token, instant in
            try await write.importForwardExport(export, activationToken: token,
                capacityProfile: capacityProfile, limits: limits,
                identifiers: try acceptanceIDs.make(at: instant), now: instant)
        }, now: now)
    }

    public func execute(_ command: V2RoomForwardCommand) async throws -> V2RoomForwardResult {
        guard command.roomID == token.roomID else { throw V2RoomActivationLeaseError.activationChanged }
        switch command {
        case .sameOwnerPair:
            throw V2RoomCallFailure.notAccepted(.invalidRequest)
        case .recoverExport(let pair,let action):
            if let outcome=try await exports.recover(pair,action:action) { return .terminalExport(.init(domain:outcome)) }
            return .unresolvedExport
        case .prepareExport(let request):
            let sourceRoute = try V2RoomShardRoute(shardID: token.owner.shardID,
                                                   epoch: token.owner.epoch)
            let targetRoute = try V2RoomShardRoute(shardID: request.targetShardID,
                                                   epoch: request.targetEpoch)
            switch try await exports.prepareForDelivery(actorUserID: request.actorUserID,
                operationID: request.operationID, source: request.source,
                sourceRoute: sourceRoute, targetRoomID: request.targetRoomID,
                targetRoute: targetRoute, now: now()) {
            case .export(let value): return .preparedExport(.init(domain: value))
            case .terminal(let value): return .terminalExport(.init(domain: value))
            }
        case .recordReceipt(let request):
            let value = try V2ForwardTerminalReceipt(exportID: request.exportID,
                payloadDigest: request.payloadDigest, outcome: request.outcome.toDomain())
            try await receipts.record(value, now: now())
            return .receiptRecorded
        case .importExport(let request):
            let value = try request.toDomain()
            guard value.intent.targetRoomID == token.roomID.uuidValue,
                  value.intent.targetShardID == token.owner.shardID,
                  value.intent.targetEpoch == token.owner.epoch else {
                throw V2RoomActivationLeaseError.activationChanged
            }
            return .imported(.init(domain: try await importExport(value, token, now())))
        }
    }
}
