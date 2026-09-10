import Foundation
import IMV2Core

/// 把每条群已读回执保留在与其房间序号、成员历史相同的物理事务域内。
///
/// 用户偏好变更与私聊回执投影仍走控制面与用户路径，不进入房间归属存储。
public struct V2RoutedReadReceiptStore: V2ReadReceiptBatchStore {
    private let router: any V2RoomShardRouting
    private let ownerStores: [String: any V2OwnerValidatedReadReceiptStore]
    private let controlStore: any V2ReadReceiptControlStore
    private let physicalStoreKeyByShard: [String: String]

    /// 组合归属路由、各归属回执存储与控制面存储。
    ///
    /// - Parameters:
    ///   - router: 房间归属路由来源。
    ///   - ownerStores: 逻辑分片标识到已读回执存储的映射。
    ///   - controlStore: 处理私聊与偏好变更的控制面存储。
    ///   - physicalStoreKeyByShard: 逻辑分片到物理存储键的映射；为 `nil` 时按标识自身映射。
    /// - Throws: 归属存储为空、含空白标识，或物理键与逻辑标识不匹配时抛出
    ///   ``V2RoomShardStorageRegistryError/invalidLocation``。
    public init(
        router: any V2RoomShardRouting,
        ownerStores: [String: any V2OwnerValidatedReadReceiptStore],
        controlStore: any V2ReadReceiptControlStore,
        physicalStoreKeyByShard: [String: String]? = nil
    ) throws {
        guard !ownerStores.isEmpty,
              ownerStores.keys.allSatisfy({
                  !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
              })
        else { throw V2RoomShardStorageRegistryError.invalidLocation }
        self.router = router
        self.ownerStores = ownerStores
        self.controlStore = controlStore
        self.physicalStoreKeyByShard = physicalStoreKeyByShard
            ?? Dictionary(uniqueKeysWithValues: ownerStores.keys.map { ($0, $0) })
        guard Set(self.physicalStoreKeyByShard.keys) == Set(ownerStores.keys),
              self.physicalStoreKeyByShard.values.allSatisfy({ !$0.isEmpty })
        else { throw V2RoomShardStorageRegistryError.invalidLocation }
    }

    /// 批量记录已读回执。
    ///
    /// 请求按物理存储键分组后并发提交，同组内由归属存储原子处理；归属判定为非群聊的条目
    /// 回落到控制面存储。结果按原始请求顺序回填，任一归属返回值数量不符即视为状态损坏。
    ///
    /// - Parameter requests: 待记录的回执请求列表，数量需落在 `1...128`。
    /// - Returns: 与输入顺序对应的结果；单条失败以失败结果返回而非整体抛出。
    /// - Throws: 数量为空或超限时抛出
    ///   ``V2ReadReceiptStoreError/invalidRequest``；房间归属未配置时抛出
    ///   ``V2RoomShardStorageRegistryError/unknownShardID``；归属返回数量不符或存在未回填结果时抛出
    ///   ``V2ReadReceiptStoreError/corruptPersistenceState``。
    public func recordBatch(
        _ requests: [V2ReadReceiptRecordRequest]
    ) async throws -> [V2ReadReceiptRecordResult] {
        guard !requests.isEmpty, requests.count <= 128 else {
            throw V2ReadReceiptStoreError.invalidRequest
        }
        let routes = try await router.routes(
            for: requests.map { $0.command.roomID }
        )
        struct RoutedRequest: Sendable {
            let index: Int
            let request: V2ReadReceiptRecordRequest
            let route: V2RoomShardRoute
        }
        var batches: [String: [RoutedRequest]] = [:]
        for (index, request) in requests.enumerated() {
            guard let route = routes[request.command.roomID],
                  ownerStores[route.shardID] != nil,
                  let physicalKey = physicalStoreKeyByShard[route.shardID]
            else { throw V2RoomShardStorageRegistryError.unknownShardID }
            batches[physicalKey, default: []].append(.init(
                index: index,
                request: request,
                route: route
            ))
        }

        let ownerResults = try await withThrowingTaskGroup(
            of: [(Int, V2GroupReadReceiptBatchResult)].self,
            returning: [(Int, V2GroupReadReceiptBatchResult)].self
        ) { group in
            for batch in batches.values {
                guard let shardID = batch.first?.route.shardID,
                      let owner = ownerStores[shardID]
                else { throw V2RoomShardStorageRegistryError.unknownShardID }
                group.addTask {
                    let outcomes = try await owner.recordGroupsOwnerValidated(
                        batch.map { .init(request: $0.request, ownerRoute: $0.route) }
                    )
                    guard outcomes.count == batch.count else {
                        throw V2ReadReceiptStoreError.corruptPersistenceState
                    }
                    return zip(batch, outcomes).map { ($0.index, $1) }
                }
            }
            var flattened: [(Int, V2GroupReadReceiptBatchResult)] = []
            flattened.reserveCapacity(requests.count)
            for try await batch in group { flattened.append(contentsOf: batch) }
            return flattened
        }

        var results = Array<V2ReadReceiptRecordResult?>(
            repeating: nil,
            count: requests.count
        )
        for (index, ownerResult) in ownerResults {
            switch ownerResult {
            case .success(.handled(let outcome)):
                results[index] = .success(outcome)
            case .success(.notGroup):
                do {
                    results[index] = .success(try await controlStore.record(
                        command: requests[index].command,
                        now: requests[index].now
                    ))
                } catch let error as V2ReadReceiptStoreError {
                    results[index] = .failure(error)
                }
            case .failure(let error):
                results[index] = .failure(error)
            }
        }
        return try results.map {
            guard let result = $0 else {
                throw V2ReadReceiptStoreError.corruptPersistenceState
            }
            return result
        }
    }

    /// 记录单条已读回执。
    ///
    /// - Parameters:
    ///   - command: 已读回执命令。
    ///   - now: 服务端统一授时时刻。
    /// - Returns: 回执记录结果。
    /// - Throws: 归属未配置时抛出
    ///   ``V2RoomShardStorageRegistryError/unknownShardID``；其余错误来自归属或控制面存储。
    public func record(
        command: V2RecordReadReceiptCommand,
        now: Date
    ) async throws -> V2ReadReceiptOutcome {
        let route = try await router.route(for: command.roomID)
        guard let owner = ownerStores[route.shardID] else {
            throw V2RoomShardStorageRegistryError.unknownShardID
        }
        switch try await owner.recordGroupOwnerValidated(command: command, ownerRoute: route, now: now) {
        case .handled(let outcome): return outcome
        case .notGroup:
            return try await controlStore.record(command: command, now: now)
        }
    }

    /// 设置当前用户的已读回执偏好。
    ///
    /// 偏好属于用户维度，因此始终由控制面存储处理。
    ///
    /// - Parameters:
    ///   - command: 偏好变更命令。
    ///   - now: 服务端统一授时时刻。
    /// - Returns: 变更结果。
    /// - Throws: 控制面存储抛出的错误。
    public func setPreferences(
        command: V2SetReadReceiptPreferencesCommand,
        now: Date
    ) async throws -> V2SetReadReceiptPreferencesOutcome {
        try await controlStore.setPreferences(command: command, now: now)
    }

    /// 分页读取某条消息的读者列表。
    ///
    /// 候选分页由房间归属负责，是否披露身份由用户维度决定：这里限定扫描的候选总量，
    /// 避免大量选择不披露的用户把一次公开请求放大成无界的跨库查询。
    ///
    /// - Parameters:
    ///   - roomID: 目标房间。
    ///   - messageID: 目标消息。
    ///   - actorUserID: 发起查询的用户。
    ///   - cursor: 上一页游标。
    ///   - pageSize: 本页条数，需落在 `1...100`。
    /// - Returns: 读者分页。
    /// - Throws: 条数越界时抛出 ``V2ReadReceiptStoreError/invalidRequest``；
    ///   归属未配置时抛出 ``V2RoomShardStorageRegistryError/unknownShardID``；
    ///   其余错误来自归属或控制面存储。
    public func readers(
        roomID: RoomID,
        messageID: MessageID,
        actorUserID: UserID,
        cursor: String?,
        pageSize: Int
    ) async throws -> V2ReadReceiptReadersPage {
        guard (1 ... 100).contains(pageSize) else {
            throw V2ReadReceiptStoreError.invalidRequest
        }
        let route = try await router.route(for: roomID)
        guard let owner = ownerStores[route.shardID] else {
            throw V2RoomShardStorageRegistryError.unknownShardID
        }

        // Candidate pagination is room-owned; disclosure is user-owned. Scan
        // a bounded number of owner pages so a large opted-out population
        // cannot turn one public request into unbounded cross-database work.
        var scanCursor = cursor
        var readers: [V2ReadReceiptReader] = []
        var nextCursor: String?
        var scanned = 0
        let maximumCandidates = max(100, pageSize * 10)
        repeat {
            let remaining = pageSize - readers.count
            let batchSize = min(100, remaining)
            let candidates = try await owner.readerCandidatesOwnerValidated(
                roomID: roomID,
                messageID: messageID,
                actorUserID: actorUserID,
                ownerRoute: route,
                cursor: scanCursor,
                pageSize: batchSize
            )
            scanned += candidates.candidates.count
            let identities = try await controlStore.visibleReaderIdentities(
                actorUserID: actorUserID,
                candidateUserIDs: candidates.candidates.map(\.userID)
            )
            for candidate in candidates.candidates {
                if let identity = identities[candidate.userID] {
                    readers.append(.init(
                        userID: candidate.userID,
                        publicIdentity: identity
                    ))
                }
            }
            nextCursor = candidates.nextCursor
            scanCursor = candidates.nextCursor
        } while readers.count < pageSize
            && nextCursor != nil
            && scanned < maximumCandidates

        return try .init(
            roomID: roomID,
            messageID: messageID,
            readers: readers,
            nextCursor: nextCursor
        )
    }
}
