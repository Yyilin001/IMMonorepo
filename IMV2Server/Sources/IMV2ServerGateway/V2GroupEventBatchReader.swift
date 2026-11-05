import Foundation
import IMV2Core
import IMV2ServerContracts

/// Only aggregates authorized reads; the injected single-room handler owns
/// authorization, Owner routing, visibility and domain error mapping.
struct V2GroupEventBatchReader {
    static func read(_ request: IMV2GroupEventPullBatch, maximumPayloadBytes: Int,
        pull: @escaping @Sendable (IMV2GroupEventPull) async throws -> IMV2Envelope
    ) async throws -> IMV2Envelope {
        guard (1...16).contains(request.rooms.count),
              request.rooms.allSatisfy({ UUID(uuidString: $0.roomID) != nil && (1...32).contains($0.pageSize)
                  && $0.afterRoomSequence <= UInt64(Int64.max) }),
              Set(request.rooms.compactMap { UUID(uuidString: $0.roomID) }).count == request.rooms.count
        else { return v2GatewayErrorEnvelope(code: "INVALID_ARGUMENT", retryable: false) }
        // Include envelope/result overhead in the fixed total page budget.
        let pageBudget = max(0, maximumPayloadBytes / request.rooms.count - 256)
        let results = try await withThrowingTaskGroup(of: (Int, IMV2GroupEventPageResult).self) { group in
            func submit(_ index: Int) {
                group.addTask {
                    try Task.checkCancellation()
                    let response = try await pull(request.rooms[index])
                    var result = IMV2GroupEventPageResult(); result.roomID = request.rooms[index].roomID
                    switch response.body {
                    case .groupEventPage(var page):
                        // Large events use the ordinary bounded single-room path;
                        // they never disappear or advance the batch cursor.
                        while try page.serializedData().count > pageBudget, !page.events.isEmpty {
                            page.events.removeLast()
                            page.nextRoomSequence = page.events.last?.roomSequence ?? request.rooms[index].afterRoomSequence
                            page.hasMore_p = true
                        }
                        if page.hasMore_p && page.nextRoomSequence == request.rooms[index].afterRoomSequence {
                            result.error.code = "BATCH_PAGE_REQUIRES_SINGLE_PULL"
                        } else { result.page = page }
                    case .error(let error): result.error = error
                    default: throw V2GroupEventLogError.corruptPersistenceState
                    }
                    return (index, result)
                }
            }
            var next = 0
            while next < min(4, request.rooms.count) { submit(next); next += 1 }
            var results: [Int: IMV2GroupEventPageResult] = [:]
            while let (index, result) = try await group.next() {
                results[index] = result
                if next < request.rooms.count { submit(next); next += 1 }
            }
            return request.rooms.indices.map { results[$0]! }
        }
        var response = IMV2Envelope(); response.groupEventPageBatch.rooms = results
        return response
    }
}
