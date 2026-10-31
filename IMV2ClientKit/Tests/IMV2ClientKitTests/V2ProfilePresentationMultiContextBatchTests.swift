import Foundation
import IMV2Core
import Testing
@testable import IMV2ClientKit

@Suite(.timeLimit(.minutes(1)))
struct V2ProfilePresentationMultiContextBatchTests {
    @Test func aLargeListReadsEveryContextWithinAuthorityBudgets() async throws {
        let user = UserID(uuid: UUID())
        let roomKeys = (0..<16).flatMap { _ -> [V2ProfileViewLookupKey] in
            let room = RoomID(uuid: UUID())
            return [.init(userID: user, context: .room(room)), .init(userID: user, context: .groupJoinReview(room))]
        }
        let direct = (0..<64).map { _ in V2ProfileViewLookupKey(userID: .init(uuid: UUID()), context: .directConversation) }
        let relations = (0..<32).map { _ in V2ProfileViewLookupKey(userID: .init(uuid: UUID()), context: .relationship) }
        let keys = roomKeys + direct + relations
        let reader = RecordingReader()
        let repository = V2ProfilePresentationRepository(actorUserID: .init(uuid: UUID()), deviceID: .init(uuid: UUID()), reader: reader)
        let page = await repository.activate()
        let completed = try await withThrowingTaskGroup(of: V2ProfileViewLookupKey.self) { group in
            for key in keys {
                group.addTask {
                    let value = try await repository.presentation(for: key, activation: page)
                    #expect(value == nil)
                    return key
                }
            }
            var finished = Set<V2ProfileViewLookupKey>()
            for try await key in group { finished.insert(key) }
            return finished
        }
        #expect(completed == Set(keys))
        let batches = await reader.batches
        #expect(batches.count >= 12)
        #expect(batches.flatMap { $0 }.count == keys.count)
        #expect(Set(batches.flatMap { $0 }) == Set(keys))
        #expect(await repository.diagnostics().pendingKeys == 0)
        #expect(await repository.diagnostics().waitingConsumers == 0)
        await repository.endAllActivations()
    }
}

private actor RecordingReader: V2ProfilePresentationReading {
    var batches: [[V2ProfileViewLookupKey]] = []
    func readPresentations(_ keys: [V2ProfileViewLookupKey]) async throws -> V2ProfilePresentationBatch {
        // Enforce the actual HTTP request contract, rather than accepting an
        // oversized fake response that hides scheduler failures.
        _ = try V2ProfilePresentationBatchRequest(keys: keys)
        batches.append(keys)
        return .init(presentations: [:], unavailable: Set(keys), serverNow: Date())
    }
}
