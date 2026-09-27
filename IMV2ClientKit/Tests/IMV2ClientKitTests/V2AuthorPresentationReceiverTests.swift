import Foundation
import IMV2Core
@testable import IMV2ClientKit
import Testing

@Suite("Pushed author presentation causal deadlines and page generations")
struct V2AuthorPresentationReceiverTests {
    @Test("all time since subscription start is deducted without consulting the device wall clock")
    func causalDeadline() async throws {
        let fixture = Fixture(), start = ContinuousClock.now
        let view = try await fixture.receiver.beginView(streamID: UUID(), roomID: fixture.room, at: start)
        let bytes = try fixture.delta(view: view, displaySeconds: 120).encoded()
        let result = try #require(await fixture.receiver.receive(bytes, for: view, at: start + .seconds(20)))
        guard case .presentation(_, _, let deadline, _) = result.entries.first else { throw Failure.missingEntry }
        #expect(deadline == start + .seconds(120))
        #expect(try await fixture.receiver.receive(bytes, for: view, at: start + .seconds(21)) == nil)
        let expired = try fixture.delta(view: view, sequence: 2, displaySeconds: 10).encoded()
        #expect(try await fixture.receiver.receive(expired, for: view, at: start + .seconds(22))?.entries.isEmpty == true)
    }

    @Test("same socket and room re-entry rejects the previous view nonce and stale cleanup")
    func pageReplacement() async throws {
        let fixture = Fixture(), stream = UUID(), start = ContinuousClock.now
        let first = try await fixture.receiver.beginView(streamID: stream, roomID: fixture.room, at: start)
        let old = try fixture.delta(view: first).encoded()
        await fixture.receiver.endView(first)
        let next = try await fixture.receiver.beginView(streamID: stream, roomID: fixture.room, at: start + .seconds(1))
        #expect(next.viewID != first.viewID)
        await fixture.receiver.endView(first)
        #expect(try await fixture.receiver.receive(old, for: first, at: start + .seconds(2)) == nil)
        await #expect(throws: V2ProfilePresentationError.invalidResponse) {
            _ = try await fixture.receiver.receive(old, for: next, at: start + .seconds(2))
        }
        let fresh = try fixture.delta(view: next).encoded()
        #expect(try await fixture.receiver.receive(fresh, for: next, at: start + .seconds(2)) != nil)
    }

    @Test("wrong accounts, devices and streams cannot advance the sequence")
    func recipientIsolation() async throws {
        let fixture = Fixture(), start = ContinuousClock.now
        let view = try await fixture.receiver.beginView(streamID: UUID(), roomID: fixture.room, at: start)
        let wrongAccount = Fixture(room: fixture.room)
        let foreign = try wrongAccount.delta(view: view, sequence: 100).encoded()
        await #expect(throws: V2ProfilePresentationError.invalidResponse) {
            _ = try await fixture.receiver.receive(foreign, for: view, at: start)
        }
        let wrongDevice = Fixture(actor: fixture.actor, room: fixture.room)
        let deviceBytes = try wrongDevice.delta(view: view, sequence: 100).encoded()
        await #expect(throws: V2ProfilePresentationError.invalidResponse) {
            _ = try await fixture.receiver.receive(deviceBytes, for: view, at: start)
        }
        let good = try fixture.delta(view: view).encoded()
        #expect(try await fixture.receiver.receive(good, for: view, at: start) != nil)
        await fixture.receiver.close()
        #expect(try await fixture.receiver.receive(good, for: view, at: start) == nil)
        await #expect(throws: V2ProfilePresentationError.inactive) {
            _ = try await fixture.receiver.beginView(streamID: UUID(), roomID: fixture.room)
        }
    }

    @Test("old timing anchors require renewal and retryable never becomes a negative cache result")
    func renewalAndPending() async throws {
        let fixture = Fixture(), start = ContinuousClock.now
        let view = try await fixture.receiver.beginView(streamID: UUID(), roomID: fixture.room, at: start)
        let pending = try V2AuthorPresentationDelta(streamID: view.streamID, viewID: view.viewID, sequence: 1,
            actorUserID: fixture.actor, deviceID: fixture.device, roomID: fixture.room,
            batch: .init(serverNowUnixMilliseconds: 2_000_000_000_000, results: [.retryable(fixture.key)]), retryAfterMilliseconds: 2_000)
        let result = try #require(await fixture.receiver.receive(pending.encoded(), for: view, at: start + .seconds(20)))
        guard case .retryable(let key, let deadline) = result.entries.first else { throw Failure.missingEntry }
        #expect(key == fixture.key && deadline == start + .seconds(22))
        let freshData = try fixture.delta(view: view, sequence: 2).encoded()
        #expect(try await fixture.receiver.receive(freshData, for: view, at: view.renewBy) == nil)
        let newView = try await fixture.receiver.beginView(streamID: view.streamID, roomID: fixture.room, at: view.renewBy)
        #expect(try await fixture.receiver.receive(fixture.delta(view: newView).encoded(), for: newView, at: view.renewBy) != nil)
    }

    @Test("raw payload budget is enforced before decoding")
    func oversized() async throws {
        let fixture = Fixture(), start = ContinuousClock.now
        let view = try await fixture.receiver.beginView(streamID: UUID(), roomID: fixture.room, at: start)
        await #expect(throws: V2ResourceValidationError.invalidPresentationLease) {
            _ = try await fixture.receiver.receive(Data(repeating: 32, count: 32_769), for: view, at: start)
        }
    }

    @Test("an expired byte capability is removed while a still-valid name retains its shorter causal deadline")
    func independentAvatarDeadline() async throws {
        let fixture = Fixture(), start = ContinuousClock.now
        let view = try await fixture.receiver.beginView(streamID: UUID(), roomID: fixture.room, at: start)
        let original = try fixture.delta(view: view)
        guard case .presentation(let authorized, _) = original.batch.results[0] else { throw Failure.missingEntry }
        let media = MediaID(uuid: UUID())
        let profile = try V2ProfileView(userID: fixture.author,
            publicIdentity: .init(userID: fixture.author, handle: .init("author"), displayName: "Author", accountKind: .regular),
            avatar: .init(mediaID: media), state: .active,
            revision: authorized.view.revision, visibilityRevision: authorized.view.visibilityRevision)
        let checksum = try V2ResourceChecksum(value: String(repeating: "a", count: 64))
        let url = try #require(URL(string: "https://objects.invalid/avatar"))
        let avatar = try V2ResourceAvatarAccess(mediaID: media, variantID: .init(uuid: UUID()), version: 1, checksum: checksum,
            plan: .init(mode: .httpGet, url: url, expiresAt: Date(timeIntervalSince1970: 2_000_000_010),
                        expectedByteCount: 10, checksum: checksum))
        let delta = try V2AuthorPresentationDelta(streamID: view.streamID, viewID: view.viewID, sequence: 1,
            actorUserID: fixture.actor, deviceID: fixture.device, roomID: fixture.room,
            batch: .init(serverNowUnixMilliseconds: 2_000_000_000_000,
                results: [.presentation(.init(view: profile, lease: authorized.lease), avatar: avatar)]))
        let result = try #require(await fixture.receiver.receive(delta.encoded(), for: view, at: start + .seconds(20)))
        guard case .presentation(_, let receivedAvatar, let deadline, let avatarDeadline) = result.entries.first else {
            throw Failure.missingEntry
        }
        #expect(receivedAvatar == nil && avatarDeadline == nil)
        #expect(deadline == start + .seconds(120))
    }

    private enum Failure: Error { case missingEntry }
    private struct Fixture {
        let actor: UserID; let device: DeviceID; let room: RoomID; let receiver: V2AuthorPresentationReceiver
        let author = UserID(uuid: UUID())
        var key: V2ProfileViewLookupKey { .init(userID: author, context: .room(room)) }
        init(actor: UserID = .init(uuid: UUID()), device: DeviceID = .init(uuid: UUID()), room: RoomID = .init(uuid: UUID())) {
            self.actor = actor; self.device = device; self.room = room
            receiver = .init(actorUserID: actor, deviceID: device)
        }
        func delta(view: V2AuthorPresentationView, sequence: UInt64 = 1, displaySeconds: TimeInterval = 120) throws -> V2AuthorPresentationDelta {
            let now = Date(timeIntervalSince1970: 2_000_000_000), revision = try #require(V2ProfileRevision(rawValue: 1))
            let profile = try V2ProfileView(userID: author, publicIdentity: nil, avatar: nil, state: .hidden,
                revision: revision, visibilityRevision: revision)
            let lease = try V2PresentationAccessLease(actorUserID: actor, deviceID: device, key: key,
                profileRevision: revision, visibilityRevision: revision, contextRevision: 3,
                observedAt: now, validUntil: now.addingTimeInterval(displaySeconds))
            return try .init(streamID: view.streamID, viewID: view.viewID, sequence: sequence,
                actorUserID: actor, deviceID: device, roomID: room,
                batch: .init(serverNowUnixMilliseconds: 2_000_000_000_000,
                    results: [.presentation(.init(view: profile, lease: lease), avatar: nil)]))
        }
    }
}
