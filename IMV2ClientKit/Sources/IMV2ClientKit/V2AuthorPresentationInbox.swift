import Foundation
import IMV2Core

/// The connection owns one foreground view and one bounded, disposable inbox.
/// Queued values keep their original monotonic deadlines; dequeue never renews
/// authority. A consumer must recheck those deadlines before display/download.
struct V2AuthorPresentationInbox: Sendable {
    static let maximumFrames = 8
    static let maximumBytes = 64 * 1_024
    let streamID: UUID
    let actorUserID: UserID
    let deviceID: DeviceID
    private var receiver: V2AuthorPresentationReceivingState
    private(set) var view: V2AuthorPresentationView?
    private var subscribed = false
    private var queue: [(value: V2ReceivedAuthorPresentationDelta, bytes: Int)] = []
    private(set) var queuedBytes = 0

    init(streamID: UUID, actorUserID: UserID, deviceID: DeviceID) {
        self.streamID = streamID; self.actorUserID = actorUserID; self.deviceID = deviceID
        receiver = .init(actorUserID: actorUserID, deviceID: deviceID)
    }

    mutating func begin(messageRoomIDs: [RoomID]) throws -> V2AuthorPresentationView {
        let next = try receiver.beginView(streamID: streamID, messageRoomIDs: messageRoomIDs)
        view = next; subscribed = false; clearQueue()
        return next
    }

    mutating func end(_ ending: V2AuthorPresentationView) {
        guard view == ending else { return }
        receiver.endView(ending); view = nil; subscribed = false; clearQueue()
    }

    /// Capture the exact local view at request registration, before any socket
    /// suspension. Arbitrary callers cannot supply a nonce with no causal start.
    func requestedView(_ request: IMV2AuthorPresentationStart) throws -> V2AuthorPresentationView {
        guard let view, view.renewBy > .now, request.streamID == view.streamID.uuidString, request.messageRoomIds == view.messageRoomIDs.map(\.rawValue),
              UUID(uuidString: request.viewID) == view.viewID else {
            throw V2TLSFrameConnectionError.unexpectedResponse
        }
        return view
    }

    mutating func confirm(_ requested: V2AuthorPresentationView, response: IMV2AuthorPresentationStart) throws {
        guard response.streamID == requested.streamID.uuidString, response.messageRoomIds == requested.messageRoomIDs.map(\.rawValue),
              UUID(uuidString: response.viewID) == requested.viewID else {
            throw V2TLSFrameConnectionError.unexpectedResponse
        }
        // An older response is correlated but cannot reactivate a departed page.
        guard view == requested, requested.renewBy > .now else { return }
        subscribed = true
    }

    mutating func accept(_ payload: Data) throws {
        let decoded = try V2AuthorPresentationDelta.decode(payload)
        guard decoded.streamID == streamID, decoded.actorUserID == actorUserID,
              decoded.deviceID == deviceID else { throw V2TLSFrameConnectionError.unexpectedResponse }
        guard subscribed, let view, decoded.viewID == view.viewID,
              let value = try receiver.receive(decoded, for: view, at: .now), !value.entries.isEmpty else { return }
        while !queue.isEmpty && (queue.count >= Self.maximumFrames || queuedBytes + payload.count > Self.maximumBytes) {
            queuedBytes -= queue.removeFirst().bytes
        }
        queue.append((value, payload.count)); queuedBytes += payload.count
    }

    mutating func next(for expected: V2AuthorPresentationView) throws -> V2ReceivedAuthorPresentationDelta? {
        guard view == expected, expected.renewBy > .now else { throw V2ProfilePresentationError.inactive }
        guard !queue.isEmpty else { return nil }
        let item = queue.removeFirst(); queuedBytes -= item.bytes
        return item.value
    }

    private mutating func clearQueue() { queue.removeAll(keepingCapacity: false); queuedBytes = 0 }
}

/// Only an explicitly opted-in foreground owner consumes supplements. The owner
/// renews the nonce before `renewBy` and ends it on privacy/lifecycle changes.
public protocol V2AuthorPresentationSource: Sendable {
    func beginAuthorPresentationView(messageRoomIDs: [RoomID]) async throws -> V2AuthorPresentationView
    /// Clears local delivery immediately. The page owner separately drains the
    /// matching remote `stopAuthorPresentation` on its original connection.
    func endAuthorPresentationView(_ view: V2AuthorPresentationView) async
    func nextAuthorPresentationDelta(for view: V2AuthorPresentationView) async throws -> V2ReceivedAuthorPresentationDelta
}

/// An optional supplement on a normally authorized room subscription. A nonce
/// never creates room access by itself and does not change the durable cursor.
public protocol V2ClientAuthorPresentationSubscriptionTransport: Sendable {
    func startAuthorPresentation(_ view: V2AuthorPresentationView) async throws
    /// Stops only this nonce on its original connection; preserves room events.
    func stopAuthorPresentation(_ view: V2AuthorPresentationView) async throws
    func acknowledgeAuthorPresentation(_ receipt: V2AuthorPresentationReceipt) async throws
    func replaceAuthorPresentationInterests(_ interests: V2AuthorPresentationInterests) async throws
}

extension V2ProtobufSyncTransport: V2ClientAuthorPresentationSubscriptionTransport {}
