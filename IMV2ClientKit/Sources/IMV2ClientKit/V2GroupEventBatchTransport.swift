import Foundation
import IMV2Core

extension V2ProtobufSyncTransport {
    public func pullGroupEventPages(_ requests: [V2ClientGroupEventPull]) async throws -> [RoomID: V2ClientGroupEventPageResult] {
        guard (1...16).contains(requests.count), Set(requests.map(\.roomID)).count == requests.count,
              requests.allSatisfy({ $0.roomID.uuidValue != nil && (1...32).contains($0.pageSize)
                  && $0.afterRoomSequence <= UInt64(Int64.max) })
        else { throw V2RealtimeTransportError.unexpectedResponse }
        var envelope = IMV2Envelope()
        envelope.groupEventPullBatch.rooms = requests.map { request in
            var wire = IMV2GroupEventPull(); wire.roomID = request.roomID.rawValue
            wire.afterRoomSequence = request.afterRoomSequence; wire.pageSize = UInt32(request.pageSize)
            return wire
        }
        let response = try await requestEnvelope(envelope)
        guard case .groupEventPageBatch(let batch)? = response.body else {
            try throwServerErrorIfPresent(response); throw V2RealtimeTransportError.unexpectedResponse
        }
        guard batch.rooms.count == requests.count else { throw V2RealtimeTransportError.unexpectedResponse }
        let byRoom = Dictionary(uniqueKeysWithValues: requests.map { ($0.roomID, $0) })
        var result: [RoomID: V2ClientGroupEventPageResult] = [:]
        for item in batch.rooms {
            let room = try RoomID(item.roomID)
            guard let request = byRoom[room], result[room] == nil else { throw V2RealtimeTransportError.unexpectedResponse }
            switch item.result {
            case .page(let page):
                result[room] = .page(try decodeGroupEventPage(page, roomID: room,
                    afterRoomSequence: request.afterRoomSequence, pageSize: request.pageSize))
            case .error(let error):
                if error.code == "BATCH_PAGE_REQUIRES_SINGLE_PULL" {
                    // A large individual event uses the original frame budget.
                    // This is a size fallback, never an authorization fallback.
                    do { result[room] = .page(try await pullGroupEvents(roomID: room,
                        afterRoomSequence: request.afterRoomSequence, pageSize: request.pageSize)) }
                    catch let failure as V2RealtimeTransportError { result[room] = .failure(failure) }
                } else {
                    var failure = IMV2Envelope(); failure.error = error
                    do { try throwServerErrorIfPresent(failure); throw V2RealtimeTransportError.unexpectedResponse }
                    catch let failure as V2RealtimeTransportError { result[room] = .failure(failure) }
                }
            case nil: throw V2RealtimeTransportError.unexpectedResponse
            }
        }
        return result
    }
}
