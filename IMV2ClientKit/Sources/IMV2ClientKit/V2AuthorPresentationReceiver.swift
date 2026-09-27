import Foundation
import IMV2Core

/// One foreground subscription generation. Send `viewID` when subscribing,
/// and renew before `renewBy`; an old page nonce cannot authorize a new page.
public struct V2AuthorPresentationView: Equatable, Sendable {
    public let streamID: UUID
    public let viewID: UUID
    public let roomID: RoomID
    public let renewBy: ContinuousClock.Instant
    let started: ContinuousClock.Instant
}

/// Deliberately not Codable: neither presentation access nor object capability
/// belongs in a durable message projection. Consumers must preserve deadlines.
public enum V2ReceivedAuthorPresentationEntry: Sendable {
    case presentation(V2AuthorizedProfilePresentation, avatar: V2ResourceAvatarAccess?,
                      presentationDeadline: ContinuousClock.Instant, avatarDeadline: ContinuousClock.Instant?)
    case unavailable(V2ProfileViewLookupKey, until: ContinuousClock.Instant)
    case retryable(V2ProfileViewLookupKey, notBefore: ContinuousClock.Instant)
}

public struct V2ReceivedAuthorPresentationDelta: Sendable {
    public let view: V2AuthorPresentationView
    public let entries: [V2ReceivedAuthorPresentationEntry]
}

/// Account/device-local receiver. The transport must bind a negotiated stream
/// ID to its authenticated connection, create a view before subscribing, and
/// stop that view on background, unsubscribe, privacy invalidation or logout.
/// Receiving a delta does not mutate message storage or start image downloads.
struct V2AuthorPresentationReceivingState: Sendable {
    private let actorUserID: UserID
    private let deviceID: DeviceID
    private var current: V2AuthorPresentationView?
    private var lastSequence: UInt64 = 0
    private var closed = false

    init(actorUserID: UserID, deviceID: DeviceID) {
        self.actorUserID = actorUserID; self.deviceID = deviceID
    }

    mutating func beginView(streamID: UUID, roomID: RoomID) throws -> V2AuthorPresentationView {
        try beginView(streamID: streamID, roomID: roomID, at: .now)
    }

    mutating func endView(_ view: V2AuthorPresentationView) {
        guard current == view else { return }
        current = nil; lastSequence = 0
    }

    mutating func close() { closed = true; current = nil; lastSequence = 0 }

    mutating func receive(_ bytes: Data, for view: V2AuthorPresentationView) throws -> V2ReceivedAuthorPresentationDelta? {
        try receive(bytes, for: view, at: .now)
    }

    mutating func beginView(streamID: UUID, roomID: RoomID, at instant: ContinuousClock.Instant) throws -> V2AuthorPresentationView {
        guard !closed else { throw V2ProfilePresentationError.inactive }
        guard roomID.uuidValue != nil else { throw V2ProfilePresentationError.invalidResponse }
        let view = V2AuthorPresentationView(streamID: streamID, viewID: UUID(), roomID: roomID,
            renewBy: instant + .milliseconds(V2AuthorPresentationDelta.maximumViewAgeMilliseconds), started: instant)
        current = view; lastSequence = 0
        return view
    }

    mutating func receive(_ bytes: Data, for view: V2AuthorPresentationView,
                 at instant: ContinuousClock.Instant) throws -> V2ReceivedAuthorPresentationDelta? {
        guard current == view, instant >= view.started, instant < view.renewBy else { return nil }
        let delta = try V2AuthorPresentationDelta.decode(bytes)
        guard delta.streamID == view.streamID, delta.viewID == view.viewID, delta.roomID == view.roomID,
              delta.actorUserID == actorUserID, delta.deviceID == deviceID else {
            throw V2ProfilePresentationError.invalidResponse
        }
        guard delta.sequence > lastSequence else { return nil }
        // The server cannot know this random view nonce until after the local
        // subscription starts. Its authority reads for this view occur later.
        // Subtract the ENTIRE time since that causal boundary, including server
        // queues and network stalls. An unsolicited server timestamp alone
        // cannot tell us how long a pushed frame spent in flight.
        let age = view.started.duration(to: instant)
        var entries: [V2ReceivedAuthorPresentationEntry] = []
        for result in delta.batch.results {
            switch result {
            case .presentation(let value, let avatar):
                guard let presentationDeadline = deadline(value.lease.validUntilUnixMilliseconds,
                    serverNow: delta.batch.serverNowUnixMilliseconds, age: age, at: instant) else { continue }
                let avatarDeadline = avatar.flatMap { deadline($0.plan.expiresAtUnixMilliseconds,
                    serverNow: delta.batch.serverNowUnixMilliseconds, age: age, at: instant) }
                entries.append(.presentation(value, avatar: avatarDeadline == nil ? nil : avatar,
                    presentationDeadline: presentationDeadline, avatarDeadline: avatarDeadline))
            case .unavailable(let key):
                let remaining = Duration.seconds(30) - age
                if remaining > .zero { entries.append(.unavailable(key, until: instant + remaining)) }
            case .retryable(let key):
                guard let delay = delta.retryAfterMilliseconds else { throw V2ProfilePresentationError.invalidResponse }
                // Traffic backoff may be longer than necessary; unlike a lease,
                // waiting the full interval cannot extend any display authority.
                entries.append(.retryable(key, notBefore: instant + .milliseconds(delay)))
            }
        }
        lastSequence = delta.sequence
        return .init(view: view, entries: entries)
    }

    private func deadline(_ expires: Int64, serverNow: Int64, age: Duration,
                          at instant: ContinuousClock.Instant) -> ContinuousClock.Instant? {
        let delta = expires.subtractingReportingOverflow(serverNow)
        guard !delta.overflow, (1...V2PresentationAccessLease.maximumLifetimeMilliseconds).contains(delta.partialValue) else { return nil }
        let remaining = Duration.milliseconds(delta.partialValue) - age
        return remaining > .zero ? instant + remaining : nil
    }
}

/// Standalone account-scoped receiver. The TLS reader uses the same validation
/// state synchronously, so parsing never suspends its connection lifecycle.
public actor V2AuthorPresentationReceiver {
    private var state: V2AuthorPresentationReceivingState
    public init(actorUserID: UserID, deviceID: DeviceID) {
        state = .init(actorUserID: actorUserID, deviceID: deviceID)
    }
    public func beginView(streamID: UUID, roomID: RoomID) throws -> V2AuthorPresentationView {
        try state.beginView(streamID: streamID, roomID: roomID)
    }
    public func endView(_ view: V2AuthorPresentationView) { state.endView(view) }
    public func close() { state.close() }
    public func receive(_ bytes: Data, for view: V2AuthorPresentationView) throws -> V2ReceivedAuthorPresentationDelta? {
        try state.receive(bytes, for: view)
    }
    func beginView(streamID: UUID, roomID: RoomID, at instant: ContinuousClock.Instant) throws -> V2AuthorPresentationView {
        try state.beginView(streamID: streamID, roomID: roomID, at: instant)
    }
    func receive(_ bytes: Data, for view: V2AuthorPresentationView,
                 at instant: ContinuousClock.Instant) throws -> V2ReceivedAuthorPresentationDelta? {
        try state.receive(bytes, for: view, at: instant)
    }
}
