import Foundation
import IMV2Core

public enum V2ClientRoomLatestVisibleResult: Equatable, Sendable {
    case snapshot(V2RoomLatestVisible)
    case unavailable
    case retry(afterSeconds: UInt32)
}

public protocol V2ClientRoomLatestVisibleTransport: Sendable {
    func latestVisible(roomIDs: [RoomID]) async throws -> [RoomID: V2ClientRoomLatestVisibleResult]
}

extension V2ProtobufSyncTransport: V2ClientRoomLatestVisibleTransport {
    public func latestVisible(roomIDs: [RoomID]) async throws -> [RoomID: V2ClientRoomLatestVisibleResult] {
        guard !roomIDs.isEmpty, roomIDs.count <= 100, roomIDs.allSatisfy({ $0.uuidValue != nil }) else {
            throw V2RealtimeTransportError.unexpectedResponse
        }
        let ids = Set(roomIDs)
        var request = IMV2Envelope()
        request.roomLatestVisibleBatch.roomIds = ids.map(\.rawValue).sorted()
        let response = try await requestEnvelope(request)
        guard case .roomLatestVisibleBatchResult(let batch)? = response.body else {
            try throwServerErrorIfPresent(response)
            throw V2RealtimeTransportError.unexpectedResponse
        }
        guard batch.rooms.count == ids.count else { throw V2RealtimeTransportError.unexpectedResponse }
        var result: [RoomID: V2ClientRoomLatestVisibleResult] = [:]
        for item in batch.rooms {
            let id = try RoomID(item.roomID)
            guard ids.contains(id), result[id] == nil else { throw V2RealtimeTransportError.unexpectedResponse }
            switch item.result {
            case .unavailable: result[id] = .unavailable
            case .retry(let retry): result[id] = .retry(afterSeconds: retry.retryAfterSeconds)
            case .snapshot(let wire):
                let latest: V2RoomLatestVisible.Message?
                if wire.hasLatest {
                    guard let messageID = UUID(uuidString: wire.latest.messageID),
                          let senderID = UUID(uuidString: wire.latest.senderUserID) else {
                        throw V2RealtimeTransportError.unexpectedResponse
                    }
                    latest = try .init(id: .init(uuid: messageID), senderID: .init(uuid: senderID),
                        sequence: wire.latest.roomSequence, revision: wire.latest.messageRevision,
                        preview: wire.latest.preview, mediaCount: Int(wire.latest.mediaCount),
                        createdAt: Date(timeIntervalSince1970: Double(wire.latest.createdAtMs) / 1000))
                } else { latest = nil }
                result[id] = .snapshot(try .init(roomID: id, ownerEpoch: wire.ownerEpoch,
                    membershipRevision: wire.viewerMembershipRevision, head: wire.head, latest: latest))
            case nil: throw V2RealtimeTransportError.unexpectedResponse
            }
        }
        return result
    }
}
