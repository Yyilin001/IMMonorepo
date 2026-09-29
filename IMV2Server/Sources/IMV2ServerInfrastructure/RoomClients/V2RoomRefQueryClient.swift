import IMV2ServerApplication
import IMV2ServerContracts
import Foundation
import IMV2ActorContracts
import IMV2ActorRuntime
import IMV2Core

/// 房间所有者负责的回执、日志、目录和恢复操作。
/// 用户自有的回执偏好与用户房间枚举仍使用各自端口。
public struct V2RoomRefQueryClient: Sendable,
    V2GatewayRoomMembershipDirectoryHandling, V2GroupRolePolicyBaselineReading,
    V2RoomStateReading, V2RoomLatestVisibleReading {
    private let caller: V2RoomRefUserCaller
    private let maximumConcurrentRooms: Int

    public init(directory: V2RoomDirectory, callTimeout: Duration = .seconds(10),
                maximumConcurrentRooms: Int = 8) {
        precondition((1...100).contains(maximumConcurrentRooms))
        self.caller = .init(directory: directory, timeout: callTimeout)
        self.maximumConcurrentRooms = maximumConcurrentRooms
    }

    init(caller: V2RoomRefUserCaller, maximumConcurrentRooms: Int = 8) {
        precondition((1...100).contains(maximumConcurrentRooms))
        self.caller = caller
        self.maximumConcurrentRooms = maximumConcurrentRooms
    }

    public func recoverReadReceipt(_ request:V2ReadReceiptRecoveryRequest) async throws -> V2ReadReceiptRecoveryResult {
        guard case .receipt(let result) = try await caller.call(.receiptQuery(.recover(request)),actor:request.command.actorUserID),
              case .recovery(let value) = result else { throw V2RoomCallFailure.outcomeUnknown }
        switch value {
        case .originalReceipt(let receipt):guard receipt.validates(request.command) else { throw V2RoomCallFailure.outcomeUnknown }
        case .watermarkProof(let proof):guard proof.validates(request.command) else { throw V2RoomCallFailure.outcomeUnknown }
        default:break
        }
        return value
    }

    public func record(_ request: V2AuthenticatedReadReceipt) async throws -> V2ReadReceiptOutcome {
        let wire = try V2ActorRecordReadReceiptWire(request)
        guard case .receipt(let result) = try await caller.call(.receipt(.record(wire)), actor: request.actorUserID) else {
            throw V2RoomCallFailure.outcomeUnknown
        }
        switch result {
        case .record(let value):
            let outcome = try value.domainValue()
            switch outcome {
            case .recorded(let receipt), .idempotent(let receipt):
                guard receipt.roomID == request.roomID, receipt.userID == request.actorUserID else {
                    throw V2RoomCallFailure.outcomeUnknown
                }
            case .idempotencyConflict: break
            }
            return outcome
        case .recordFailure(.store(let failure)): throw failure.domainValue()
        case .recordFailure(.serverBusy): throw V2ReadReceiptBatcherError.serverBusy
        default: throw V2RoomCallFailure.outcomeUnknown
        }
    }

    var callTimeout: Duration { caller.timeout }

    func readerCandidates(roomID: RoomID, messageID: MessageID, actorUserID: UserID,
                          cursor: String?, pageSize: Int,
                          deadline: ContinuousClock.Instant) async throws -> V2GroupReadReceiptReaderCandidatePage {
        let query = try V2ActorReadReceiptReadersQueryWire(roomID: roomID, messageID: messageID,
            actorUserID: actorUserID, cursor: cursor, pageSize: pageSize)
        guard case .receipt(let result) = try await caller.call(
            .receiptQuery(.readerCandidates(query)), actor: actorUserID, deadline: deadline) else {
            throw V2ActorRoomReceiptWireError.invalidResult
        }
        switch result {
        case .readerCandidates(let value):
            guard value.roomID == roomID, value.messageID == messageID else { throw V2ActorRoomReceiptWireError.invalidResult }
            let page = try value.domainValue()
            guard page.candidates.count <= pageSize,
                  page.nextCursor == nil || (page.nextCursor != cursor && !page.candidates.isEmpty) else {
                throw V2ActorRoomReceiptWireError.invalidResult
            }
            return page
        case .readersFailure(let failure): throw failure.domainValue()
        default: throw V2ActorRoomReceiptWireError.invalidResult
        }
    }

    public func pull(roomID: RoomID, actorUserID: UserID,
                     afterRoomSequence: UInt64, pageSize: Int) async throws -> V2GroupEventLogPage {
        let query = try V2ActorRoomLogPullWire(roomID: roomID, actorUserID: actorUserID,
            afterRoomSequence: afterRoomSequence, pageSize: pageSize)
        guard case .roomLog(let result) = try await caller.call(.roomLog(.pull(query)), actor: actorUserID) else {
            throw V2GroupEventLogError.corruptPersistenceState
        }
        switch result {
        case .page(let value):
            guard value.roomID == roomID else { throw V2GroupEventLogError.corruptPersistenceState }
            return try value.domainValue()
        case .failure(let failure): throw failure.domainError()
        default: throw V2GroupEventLogError.corruptPersistenceState
        }
    }

    /// 订阅意向登记与通知投递属于独立的 Gateway 生命周期；
    /// 此处只证明资格并读取日志头。
    public func subscribeEligibility(roomID: RoomID, actorUserID: UserID) async throws -> V2GroupEventSubscription {
        let query = V2ActorRoomLogSubscribeWire(roomID: roomID, actorUserID: actorUserID)
        guard case .roomLog(let result) = try await caller.call(.roomLog(.subscribe(query)), actor: actorUserID) else {
            throw V2GroupEventLogError.corruptPersistenceState
        }
        switch result {
        case .subscription(let value):
            guard value.roomID == roomID else { throw V2GroupEventLogError.corruptPersistenceState }
            return try value.domainValue()
        case .failure(let failure): throw failure.domainError()
        default: throw V2GroupEventLogError.corruptPersistenceState
        }
    }

    public func list(_ request: V2RoomMembershipDirectoryRequest) async throws -> V2RoomMembershipDirectoryPage {
        let query = try V2ActorMembershipDirectoryQueryWire(request)
        guard case .directory(let result) = try await caller.call(.directory(.membership(query)), actor: request.actorUserID) else {
            throw V2RoomMembershipDirectoryError.corruptPersistenceState
        }
        switch result {
        case .membership(let value):
            guard value.roomID == request.roomID else { throw V2RoomMembershipDirectoryError.corruptPersistenceState }
            return try value.domainValue()
        case .membershipFailure(let failure): throw failure.domainValue()
        default: throw V2RoomMembershipDirectoryError.corruptPersistenceState
        }
    }

    public func readRolePolicyBaseline(roomID: RoomID, actorUserID: UserID) async throws -> V2GroupRolePolicyBaseline {
        let query = V2ActorRoleBaselineQueryWire(roomID: roomID, actorUserID: actorUserID)
        guard case .directory(let result) = try await caller.call(.directory(.roleBaseline(query)), actor: actorUserID) else {
            throw V2GroupRolePolicyBaselineError.corruptPersistenceState
        }
        switch result {
        case .roleBaseline(let value):
            guard value.roomID == roomID else { throw V2GroupRolePolicyBaselineError.corruptPersistenceState }
            return try value.domainValue()
        case .roleBaselineFailure(let failure): throw failure.domainValue()
        default: throw V2GroupRolePolicyBaselineError.corruptPersistenceState
        }
    }

    public func states(roomIDs: [RoomID], actorUserID: UserID) async throws -> [RoomID: V2RoomStateReadResult] {
        let values: [RoomID: V2RoomStateReadResult] = try await recovery(roomIDs: roomIDs, actorUserID: actorUserID, kind: .state,
                           onUnavailable: { .unavailable }, onRetry: { .retry }) { result in
            guard case .state(let value) = result else { throw V2ActorRoomRecoveryWireError.invalidResult }
            return try value.domainValue()
        }
        for (room, value) in values {
            if case .state(let snapshot) = value, snapshot.roomID != room {
                throw V2ActorRoomRecoveryWireError.invalidResult
            }
        }
        return values
    }

    public func latestVisible(roomIDs: [RoomID], actorUserID: UserID) async throws -> [RoomID: V2RoomLatestVisibleResult] {
        let values: [RoomID: V2RoomLatestVisibleResult] = try await recovery(roomIDs: roomIDs, actorUserID: actorUserID, kind: .latestVisible,
                           onUnavailable: { .unavailable }, onRetry: { .retry }) { result in
            guard case .latestVisible(let value) = result else { throw V2ActorRoomRecoveryWireError.invalidResult }
            return try value.domainValue()
        }
        for (room, value) in values {
            if case .snapshot(let snapshot) = value, snapshot.roomID != room {
                throw V2ActorRoomRecoveryWireError.invalidResult
            }
        }
        return values
    }

    private func recovery<Value: Sendable>(
        roomIDs: [RoomID], actorUserID: UserID, kind: V2ActorRoomRecoveryItemQuery.Kind,
        onUnavailable: @escaping @Sendable () -> Value,
        onRetry: @escaping @Sendable () -> Value,
        decode: @escaping @Sendable (V2ActorRoomRecoveryItemResult) throws -> Value
    ) async throws -> [RoomID: Value] {
        _ = try V2ActorRoomRecoveryBatchQueryWire(roomIDs: roomIDs, actorUserID: actorUserID)
        let deadline = ContinuousClock.now.advanced(by: caller.timeout)
        var values: [RoomID: Value] = [:]
        try await withThrowingTaskGroup(of: (RoomID, Value).self) { group in
            var next = 0
            func start(_ roomID: RoomID) {
                group.addTask {
                    let query = V2ActorRoomRecoveryItemQuery(roomID: roomID, actorUserID: actorUserID, kind: kind)
                    do {
                        let response = try await caller.call(.recovery(query), actor: actorUserID, deadline: deadline)
                        guard case .recovery(let result) = response else { throw V2ActorRoomRecoveryWireError.invalidResult }
                        if case .failure(let failure) = result { throw failure.domainValue() }
                        return (roomID, try decode(result))
                    } catch let failure as V2RoomCallFailure {
                        if case .notAccepted(.cancelled) = failure { throw CancellationError() }
                        switch failure {
                        case .notAccepted(.notFound), .notAccepted(.forbidden),
                             .rolledBack(.notFound), .rolledBack(.forbidden):
                            return (roomID, onUnavailable())
                        default: return (roomID, onRetry())
                        }
                    }
                }
            }
            while next < min(roomIDs.count, maximumConcurrentRooms) { start(roomIDs[next]); next += 1 }
            while let (roomID, value) = try await group.next() {
                values[roomID] = value
                if next < roomIDs.count { start(roomIDs[next]); next += 1 }
            }
        }
        guard values.count == roomIDs.count else { throw V2ActorRoomRecoveryWireError.invalidResult }
        return values
    }
}

/// 房间回执与用户偏好分别由不同物理节点负责。
public struct V2RoomRefReadReceiptClient: V2GatewayReadReceiptHandling {
    private let rooms: V2RoomRefQueryClient
    private let control: any V2ReadReceiptControlStore
    private let databaseWorkAdmission: V2DatabaseWorkAdmissionController?

    public init(rooms: V2RoomRefQueryClient, control: any V2ReadReceiptControlStore,
                databaseWorkAdmission: V2DatabaseWorkAdmissionController? = nil,
                now: @escaping @Sendable () -> Date = Date.init) {
        self.rooms = rooms
        self.control = control
        self.databaseWorkAdmission = databaseWorkAdmission
    }

    public func record(_ request: V2AuthenticatedReadReceipt) async throws -> V2ReadReceiptOutcome {
        try await rooms.record(request)
    }
    public func readers(roomID: RoomID, messageID: MessageID, actorUserID: UserID,
                 cursor: String?, pageSize: Int) async throws -> V2ReadReceiptReadersPage {
        guard (1...100).contains(pageSize) else { throw V2ReadReceiptStoreError.invalidRequest }
        let deadline = ContinuousClock.now.advanced(by: rooms.callTimeout)
        var scanCursor = cursor
        var readers: [V2ReadReceiptReader] = []
        var scanned = 0
        let maximumCandidates = max(100, pageSize * 10)
        repeat {
            try Task.checkCancellation()
            guard deadline > .now else { throw V2RoomCallFailure.notAccepted(.deadlineExceeded) }
            let batchSize = min(100, pageSize - readers.count, maximumCandidates - scanned)
            let page = try await rooms.readerCandidates(roomID: roomID, messageID: messageID,
                actorUserID: actorUserID, cursor: scanCursor,
                pageSize: batchSize, deadline: deadline)
            scanned += page.candidates.count
            try Task.checkCancellation()
            guard deadline > .now else { throw V2RoomCallFailure.notAccepted(.deadlineExceeded) }
            let candidateUserIDs = page.candidates.map(\.userID)
            let identities = try await v2WithAdmittedRoomDatabaseWork(databaseWorkAdmission,
                workClass: .interactiveRead, callerDeadline: deadline) {
                try await control.visibleReaderIdentities(actorUserID: actorUserID,
                    candidateUserIDs: candidateUserIDs)
            }
            try Task.checkCancellation()
            guard deadline > .now else { throw V2RoomCallFailure.notAccepted(.deadlineExceeded) }
            for candidate in page.candidates {
                if let identity = identities[candidate.userID] {
                    guard identity.userID == candidate.userID else {
                        throw V2ReadReceiptStoreError.corruptPersistenceState
                    }
                    readers.append(.init(userID: candidate.userID))
                }
            }
            scanCursor = page.nextCursor
        } while readers.count < pageSize && scanCursor != nil && scanned < maximumCandidates
        return try .init(roomID: roomID, messageID: messageID,
            readers: readers, nextCursor: scanCursor)
    }

}

extension V2RoomRefReadReceiptClient {
    // 物理宿主负责回执写入准入及其 SQL 批处理器。
    package var managesForegroundWriteAdmission: Bool { true }
}
