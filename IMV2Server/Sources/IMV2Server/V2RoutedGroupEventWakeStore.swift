import Foundation
import IMV2Core

/// 把持久化混合大群唤醒发件箱复用到各个独立的房间归属数据库上。
///
/// 网关可以在每个副本上运行该存储：每个底层 PostgreSQL 存储仍负责其行的租约栅栏，
/// 而本 actor 记下在途租约由哪个物理归属签发，使完成与重试路径无需再查控制面路由。
///
/// 该映射刻意只存在于进程内：进程重启后 PostgreSQL 租约自然过期，后续认领会重建映射，
/// 因此唤醒的正确性不依赖该 actor 是否存活。
public actor V2RoutedGroupEventWakeStore: V2GroupEventWakeStore {
    /// 单个物理归属的存储句柄。
    private struct Owner: Sendable {
        let store: any V2GroupEventWakeStore
    }

    /// 在途租约的进程内索引。
    private struct LeaseKey: Hashable, Sendable {
        /// 目标房间。
        let roomID: RoomID
        /// 唤醒修订。
        let revision: UInt64
        /// 认领令牌。
        let claimToken: UUID

        /// 从租约派生索引。
        ///
        /// - Parameter lease: 本次唤醒租约。
        init(_ lease: V2GroupEventWakeLease) {
            roomID = lease.wake.roomID
            revision = lease.revision
            claimToken = lease.claimToken
        }
    }

    /// 在途租约记录的归属与过期时刻。
    private struct LeaseOwner: Sendable {
        /// 签发该租约的物理归属下标。
        let ownerIndex: Int
        /// 本次认领的过期时刻，用于清理进程内映射。
        let expiresAt: Date
    }

    /// 单次归属认领的结果。
    private enum ClaimResult: Sendable {
        /// 该归属认领成功。
        case success(ownerIndex: Int, leases: [V2GroupEventWakeLease])
        /// 该归属认领失败。
        case failure(any Error)
    }

    private let owners: [Owner]
    private var nextOwnerIndex = 0
    private var leaseOwners: [LeaseKey: LeaseOwner] = [:]

    /// 以物理归属存储构造路由存储。
    ///
    /// `ownerStores` 必须按物理 PostgreSQL 位置各一项，而不是按逻辑分片各一项。
    /// 键只用于确定性启动顺序与诊断，不会进入客户端载荷或消息代理载荷。
    ///
    /// - Parameter ownerStores: 物理位置标识到唤醒存储的映射。
    /// - Throws: 映射为空或含纯空白标识时抛出
    ///   ``V2RoomShardStorageRegistryError/invalidLocation``。
    public init(ownerStores: [String: any V2GroupEventWakeStore]) throws {
        guard !ownerStores.isEmpty,
              ownerStores.keys.allSatisfy({
                  !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
              })
        else { throw V2RoomShardStorageRegistryError.invalidLocation }
        owners = ownerStores.keys.sorted().map { key in
            Owner(store: ownerStores[key]!)
        }
    }

    /// 轮转各物理归属并按配额认领待发布唤醒。
    ///
    /// 每次调用把起始归属推进一位，并按商与余数把限额精确分配到各归属，避免固定顺序饿死后者。
    /// 单个归属故障时仍返回健康归属已认领的租约；仅当全部归属都失败才抛出首个错误。
    ///
    /// - Parameters:
    ///   - now: 本次认领时刻。
    ///   - leaseDuration: 租约时长秒数。
    ///   - limit: 本批最多认领的唤醒数。
    /// - Returns: 本批唤醒租约，数量不会超过 `limit`。
    /// - Throws: 上限非正或租约到期时刻不可编码时抛出
    ///   ``V2GroupEventWakeStoreError/corruptPersistenceState``；
    ///   全部归属都失败时抛出首个归属错误。
    public func claimPending(
        now: Date,
        leaseDuration: TimeInterval,
        limit: Int
    ) async throws -> [V2GroupEventWakeLease] {
        guard limit > 0,
              let expiry = v2PostgresFutureTimestamp(now: now, interval: leaseDuration) else {
            throw V2GroupEventWakeStoreError.corruptPersistenceState
        }
        leaseOwners = leaseOwners.filter { $0.value.expiresAt > now }

        let startIndex = nextOwnerIndex
        nextOwnerIndex = (nextOwnerIndex + 1) % owners.count
        let baseQuota = limit / owners.count
        let remainder = limit % owners.count
        var work: [(ownerIndex: Int, quota: Int)] = []
        work.reserveCapacity(min(limit, owners.count))
        for offset in owners.indices {
            let quota = baseQuota + (offset < remainder ? 1 : 0)
            guard quota > 0 else { continue }
            work.append(((startIndex + offset) % owners.count, quota))
        }

        let results = await withTaskGroup(
            of: ClaimResult.self,
            returning: [ClaimResult].self
        ) { group in
            for item in work {
                let store = owners[item.ownerIndex].store
                group.addTask {
                    do {
                        return .success(
                            ownerIndex: item.ownerIndex,
                            leases: try await store.claimPending(
                                now: now,
                                leaseDuration: leaseDuration,
                                limit: item.quota
                            )
                        )
                    } catch {
                        return .failure(error)
                    }
                }
            }
            var collected: [ClaimResult] = []
            collected.reserveCapacity(work.count)
            for await result in group { collected.append(result) }
            return collected
        }

        var leases: [V2GroupEventWakeLease] = []
        var firstError: (any Error)?
        var successfulOwnerCount = 0
        for result in results {
            switch result {
            case .success(let ownerIndex, let claimed):
                successfulOwnerCount += 1
                for lease in claimed {
                    leaseOwners[LeaseKey(lease)] = .init(
                        ownerIndex: ownerIndex,
                        expiresAt: expiry
                    )
                    leases.append(lease)
                }
            case .failure(let error):
                if firstError == nil { firstError = error }
            }
        }
        // 部分所有者故障不能阻滞从健康所有者取得的租约。立即返回这些租约；
        // 下一轮会移动轮询起点，而故障所有者的状态仍独立持久保存。
        if successfulOwnerCount == 0, let firstError { throw firstError }
        guard leases.count <= limit else {
            throw V2GroupEventWakeStoreError.corruptPersistenceState
        }
        return leases
    }

    /// 标记唤醒已发布并清除进程内映射。
    ///
    /// - Parameter lease: 本次唤醒租约。
    /// - Throws: 进程内不存在该在途租约，或底层存储失败时抛出
    ///   ``V2GroupEventWakeStoreError/corruptPersistenceState``。
    public func markPublished(_ lease: V2GroupEventWakeLease) async throws {
        let key = LeaseKey(lease)
        guard let owner = leaseOwners[key] else {
            throw V2GroupEventWakeStoreError.corruptPersistenceState
        }
        try await owners[owner.ownerIndex].store.markPublished(lease)
        leaseOwners.removeValue(forKey: key)
    }

    /// 安排租约稍后重试并清除进程内映射。
    ///
    /// - Parameters:
    ///   - lease: 本次唤醒租约。
    ///   - nextAttemptAt: 下次尝试时刻。
    /// - Throws: 时刻不可编码、进程内不存在该在途租约，或底层存储失败时抛出
    ///   ``V2GroupEventWakeStoreError/corruptPersistenceState``。
    public func scheduleRetry(
        _ lease: V2GroupEventWakeLease,
        nextAttemptAt: Date
    ) async throws {
        guard v2PostgresTimestampCanEncode(nextAttemptAt) else {
            throw V2GroupEventWakeStoreError.corruptPersistenceState
        }
        let key = LeaseKey(lease)
        guard let owner = leaseOwners[key] else {
            throw V2GroupEventWakeStoreError.corruptPersistenceState
        }
        try await owners[owner.ownerIndex].store.scheduleRetry(
            lease,
            nextAttemptAt: nextAttemptAt
        )
        leaseOwners.removeValue(forKey: key)
    }
}
