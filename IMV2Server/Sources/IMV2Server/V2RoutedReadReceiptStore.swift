import Foundation
import IMV2Core

/// Keeps each group receipt in the same physical transaction domain as its
/// room sequence and membership history. User preference mutations and direct
/// receipt projections remain on the control/user path.
public struct V2RoutedReadReceiptStore: V2ReadReceiptBatchStore {
    private let router: any V2RoomShardRouting
    private let ownerStores: [String: any V2GroupReadReceiptOwnerStore]
    private let controlStore: any V2ReadReceiptControlStore
    private let physicalStoreKeyByShard: [String: String]

    public init(
        router: any V2RoomShardRouting,
        ownerStores: [String: any V2GroupReadReceiptOwnerStore],
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
            let shardID: String
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
                shardID: route.shardID
            ))
        }

        let ownerResults = try await withThrowingTaskGroup(
            of: [(Int, V2GroupReadReceiptBatchResult)].self,
            returning: [(Int, V2GroupReadReceiptBatchResult)].self
        ) { group in
            for batch in batches.values {
                guard let shardID = batch.first?.shardID,
                      let owner = ownerStores[shardID]
                else { throw V2RoomShardStorageRegistryError.unknownShardID }
                group.addTask {
                    let outcomes = try await owner.recordGroups(
                        batch.map(\.request)
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

    public func record(
        command: V2RecordReadReceiptCommand,
        now: Date
    ) async throws -> V2ReadReceiptOutcome {
        let route = try await router.route(for: command.roomID)
        guard let owner = ownerStores[route.shardID] else {
            throw V2RoomShardStorageRegistryError.unknownShardID
        }
        switch try await owner.recordGroup(command: command, now: now) {
        case .handled(let outcome): return outcome
        case .notGroup:
            return try await controlStore.record(command: command, now: now)
        }
    }

    public func setPreferences(
        command: V2SetReadReceiptPreferencesCommand,
        now: Date
    ) async throws -> V2SetReadReceiptPreferencesOutcome {
        try await controlStore.setPreferences(command: command, now: now)
    }

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
            let candidates = try await owner.readerCandidates(
                roomID: roomID,
                messageID: messageID,
                actorUserID: actorUserID,
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
