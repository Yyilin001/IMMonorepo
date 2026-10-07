import IMV2ServerApplication
import IMV2ServerContracts
import FluentKit
import Foundation
import IMV2ActorContracts
import IMV2Core
import SQLKit

/// Actor 的持久化位置位于房间实际所有者数据库中。
/// 解析器必须提供该数据库；此存储绝不经控制数据库路由，
/// 也不把宿主进程当作数据所有者。
public struct PostgresV2RoomActivationStore: V2RoomActivationLeaseStore {
    private let database: any Database
    private let schema: String
    private let timeouts: V2RoomActivationSQLTimeouts
    private let lifecycle: V2RoomActivationLifecycleBatcher
    private let renewals: V2RoomActivationRenewalBatcher

    public init(database: any Database, schema: String = "im_v2", timeouts: V2RoomActivationSQLTimeouts = .default,
                renewalDatabase: (any Database)? = nil, sqlContinuationMetrics: V2SendOperationBatchMetrics? = nil) {
        v2PreconditionSQLSchema(schema)
        let balanced = database as? V2EventLoopBalancedDatabase
        // These facades share the existing physical gate and selection cursor.
        // Build them once per Store: lifecycle recovery has a bounded ordinary
        // sublimit, while lease renewal retains its reserved loan class.
        let activation = balanced?.usingLoanClass(.activation) ?? database
        self.database = activation
        self.lifecycle = V2RoomActivationLifecycleBatcher(database: activation, schema: schema, timeouts: timeouts, sqlContinuationMetrics: sqlContinuationMetrics)
        self.schema = schema
        self.timeouts = timeouts
        let renewal = renewalDatabase ?? balanced?.usingLoanClass(.renewal) ?? database
        self.renewals = V2RoomActivationRenewalBatcher(database: renewal, schema: schema, timeouts: timeouts)
    }

    public func locate(roomID: RoomID, owner: V2RoomDataOwner) async throws -> V2RoomActivationLease? {
        _ = try uuid(roomID)
        let value = try await lifecycle.execute(.init(roomID: roomID, operation: .locate(owner: owner)))
        guard case .located(let lease) = value else { throw V2RoomActivationLeaseError.outcomeUnknown }
        return lease
    }

    public func acquire(roomID: RoomID, owner: V2RoomDataOwner, host: V2ActorHostIdentity,
                        duration: V2ActorMilliseconds) async throws -> V2RoomActivationAcquisition {
        _ = try uuid(roomID)
        let value = try await lifecycle.execute(.init(roomID: roomID,
            operation: .acquire(owner: owner, host: host, duration: duration)))
        guard case .acquired(let acquisition) = value else { throw V2RoomActivationLeaseError.outcomeUnknown }
        return acquisition
    }

    /// Restoration uses the same physical collector as lifecycle mutations.
    /// Success is returned only after the locked database check actually settles.
    public func validate(token: V2RoomActivationToken) async throws {
        _ = try uuid(token.roomID)
        let value = try await lifecycle.execute(.init(roomID: token.roomID, operation: .validate(token: token)))
        guard case .validated = value else { throw V2RoomActivationLeaseError.outcomeUnknown }
    }

    public func renew(token: V2RoomActivationToken, duration: V2ActorMilliseconds) async throws -> V2RoomActivationLease {
        _ = try uuid(token.roomID)
        return try await renewals.renew(token: token, duration: duration)
    }

    public func shutdownRenewals() async { await renewals.shutdown() }

    /// Application-owner shutdown, after all Hosts finish release. Host.stop
    /// must not close this shared collector: a successor may reuse the Store.
    public func shutdownLifecycle() async { await lifecycle.shutdown() }
    var renewalBatcherIdentity: ObjectIdentifier { ObjectIdentifier(renewals) }
    var lifecycleBatcherIdentity: ObjectIdentifier { ObjectIdentifier(lifecycle) }

    public func release(token: V2RoomActivationToken) async throws -> Bool {
        _ = try uuid(token.roomID)
        let value = try await lifecycle.execute(.init(roomID: token.roomID, operation: .release(token: token)))
        guard case .released(let released) = value else { throw V2RoomActivationLeaseError.outcomeUnknown }
        return released
    }

    private func uuid(_ roomID: RoomID) throws -> UUID {
        guard let value = roomID.uuidValue else { throw V2CoreError.invalidIdentifier }
        return value
    }

}
