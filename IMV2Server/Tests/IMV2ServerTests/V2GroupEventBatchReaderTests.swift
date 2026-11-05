import Foundation
import IMV2Core
@testable import IMV2ServerGateway
import Testing

@Suite("Bounded authorized room log batches")
struct V2GroupEventBatchReaderTests {
    @Test(arguments: [0, 17, -1, -2, -3])
    func invalidRequestsNeverRead(value: Int) async throws {
        var request = batch(max(1, value))
        if value == 0 { request.rooms = [] }
        if value == -1 { request.rooms += request.rooms }
        if value == -2 { request.rooms[0].pageSize = 33 }
        if value == -3 { request.rooms[0].afterRoomSequence = UInt64.max }
        let response = try await V2GroupEventBatchReader.read(request, maximumPayloadBytes: 49152) { _ in
            Issue.record("Invalid batch reached room authority"); return .init()
        }
        #expect(response.error.code == "INVALID_ARGUMENT")
    }

    @Test(arguments: [300, 1500, 4000])
    func byteBudgetPreservesCursorAndLargeEventFallback(payloadBytes: Int) async throws {
        let request = batch(16)
        let response = try await V2GroupEventBatchReader.read(request, maximumPayloadBytes: 49152) { pull in
            var response = IMV2Envelope()
            response.groupEventPage.roomID = pull.roomID
            response.groupEventPage.logTrimmedThroughRoomSequence = 4
            response.groupEventPage.nextRoomSequence = 12
            response.groupEventPage.events = (11...12).map { sequence in
                var event = IMV2GroupEvent(); event.sourceEventID = UUID().uuidString
                event.roomSequence = UInt64(sequence); event.projectionKind = "message"
                event.payload = Data(repeating: 1, count: payloadBytes); return event
            }
            return response
        }
        #expect(try response.serializedData().count <= 49152)
        #expect(response.groupEventPageBatch.rooms.count == 16)
        for result in response.groupEventPageBatch.rooms {
            if payloadBytes == 4000 {
                #expect(result.error.code == "BATCH_PAGE_REQUIRES_SINGLE_PULL")
            } else {
                let page = result.page
                #expect(page.logTrimmedThroughRoomSequence == 4)
                #expect(page.events.count == (payloadBytes == 1500 ? 1 : 2))
                #expect(page.nextRoomSequence == page.events.last?.roomSequence)
                #expect(page.hasMore_p == (payloadBytes == 1500))
            }
        }
    }

    @Test func authorizationFailuresStayPerRoomAndFanoutIsBounded() async throws {
        let request = batch(16), denied = request.rooms[0].roomID
        let probe = BatchReadProbe()
        let response = try await V2GroupEventBatchReader.read(request, maximumPayloadBytes: 49152) { pull in
            await probe.enter()
            try await Task.sleep(for: .milliseconds(10))
            await probe.leave()
            var response = IMV2Envelope()
            if pull.roomID == denied { response.error.code = "FORBIDDEN" }
            else { response.groupEventPage.roomID = pull.roomID; response.groupEventPage.nextRoomSequence = 10 }
            return response
        }
        #expect(await probe.maximum == 4)
        #expect(response.groupEventPageBatch.rooms.map(\.roomID) == request.rooms.map(\.roomID))
        #expect(response.groupEventPageBatch.rooms[0].error.code == "FORBIDDEN")
        #expect(response.groupEventPageBatch.rooms.dropFirst().allSatisfy { $0.page.nextRoomSequence == 10 })
    }

    private func batch(_ count: Int) -> IMV2GroupEventPullBatch {
        var result = IMV2GroupEventPullBatch()
        result.rooms = (0..<count).map { _ in
            var request = IMV2GroupEventPull(); request.roomID = UUID().uuidString
            request.afterRoomSequence = 10; request.pageSize = 2; return request
        }
        return result
    }
}
private actor BatchReadProbe {
    var active = 0; var maximum = 0
    func enter() { active += 1; maximum = max(maximum, active) }
    func leave() { active -= 1 }
}
