@testable import IMV2ServerApplication
@testable import IMV2ServerContracts
import Foundation
import IMV2Core
@testable import IMV2Server
@testable import IMV2ServerInfrastructure
import Testing

@Suite("V2 read receipt batcher")
struct V2ReadReceiptBatcherTests {
    @Test("concurrent receipts share one durable batch and keep individual outcomes")
    func batchesConcurrentReceipts() async throws {
        let store = ReadReceiptBatchStoreSpy()
        let batcher = V2ReadReceiptBatcher(
            store: store,
            configuration: .init(
                maximumBatchSize: 8,
                maximumDelay: .milliseconds(10),
                maximumInFlightBatches: 1,
                maximumPendingRequests: 32
            )
        )
        let requests = try (1 ... 8).map(makeReceiptRequest)

        let outcomes = try await withThrowingTaskGroup(
            of: V2ReadReceiptOutcome.self,
            returning: [V2ReadReceiptOutcome].self
        ) { group in
            for request in requests {
                group.addTask { try await batcher.accept(request) }
            }
            var values: [V2ReadReceiptOutcome] = []
            for try await value in group { values.append(value) }
            return values
        }

        #expect(outcomes.count == 8)
        #expect(await store.batchSizes() == [8])
        let snapshot = await batcher.snapshot()
        #expect(snapshot.pendingRequests == 0)
        #expect(snapshot.inFlightBatches == 0)
        #expect(snapshot.completedBatches == 1)
        #expect(snapshot.completedRequests == 8)
        #expect(snapshot.maximumObservedBatchSize == 8)
    }

    @Test("one domain rejection does not fail sibling receipts")
    func isolatesDomainFailure() async throws {
        let store = ReadReceiptBatchStoreSpy(failingSequence: 3)
        let batcher = V2ReadReceiptBatcher(
            store: store,
            configuration: .init(
                maximumBatchSize: 3,
                maximumDelay: .milliseconds(10),
                maximumInFlightBatches: 1,
                maximumPendingRequests: 16
            )
        )
        let requests = try (1 ... 3).map(makeReceiptRequest)
        let first = Task { try await batcher.accept(requests[0]) }
        let second = Task { try await batcher.accept(requests[1]) }
        let third = Task { try await batcher.accept(requests[2]) }

        _ = try await first.value
        _ = try await second.value
        await #expect(throws: V2ReadReceiptStoreError.roomSequenceNotFound) {
            _ = try await third.value
        }
        #expect(await store.batchSizes() == [3])
    }

    private func makeReceiptRequest(_ value: Int) throws -> V2ReadReceiptRecordRequest {
        let suffix = String(format: "%012d", value)
        return .init(
            command: try .init(
                roomID: .init("10000000-0000-0000-0000-000000000001"),
                actorUserID: .init("20000000-0000-0000-0000-000000000\(suffix.suffix(3))"),
                operationID: .init("30000000-0000-0000-0000-\(suffix)"),
                readThroughRoomSequence: UInt64(value)
            ),
            now: Date(timeIntervalSince1970: 1_800_000_000 + Double(value))
        )
    }
}

private actor ReadReceiptBatchStoreSpy: V2ReadReceiptBatchStore {
    private var sizes: [Int] = []
    private let failingSequence: UInt64?

    init(failingSequence: UInt64? = nil) {
        self.failingSequence = failingSequence
    }

    func recordBatch(
        _ requests: [V2ReadReceiptRecordRequest]
    ) -> [V2ReadReceiptRecordResult] {
        sizes.append(requests.count)
        return requests.map { request in
            if request.command.readThroughRoomSequence == failingSequence {
                return .failure(.roomSequenceNotFound)
            }
            do {
                return .success(.recorded(try .init(
                roomID: request.command.roomID,
                userID: request.command.actorUserID,
                readThroughRoomSequence: request.command.readThroughRoomSequence,
                recordedAt: request.now
                )))
            } catch { return .failure(.corruptPersistenceState) }
        }
    }

    func record(
        command _: V2RecordReadReceiptCommand,
        now _: Date
    ) throws -> V2ReadReceiptOutcome {
        throw V2ReadReceiptStoreError.corruptPersistenceState
    }

    func setPreferences(
        command _: V2SetReadReceiptPreferencesCommand,
        now _: Date
    ) throws -> V2SetReadReceiptPreferencesOutcome {
        throw V2ReadReceiptStoreError.corruptPersistenceState
    }

    func readers(
        roomID _: RoomID,
        messageID _: MessageID,
        actorUserID _: UserID,
        cursor _: String?,
        pageSize _: Int
    ) throws -> V2ReadReceiptReadersPage {
        throw V2ReadReceiptStoreError.corruptPersistenceState
    }

    func batchSizes() -> [Int] { sizes }
}
