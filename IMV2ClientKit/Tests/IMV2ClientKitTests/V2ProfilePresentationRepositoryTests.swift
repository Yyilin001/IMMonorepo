import Foundation
import IMV2Core
@testable import IMV2ClientKit
import Testing

@Suite("Profile presentation activation and context")
struct V2ProfilePresentationRepositoryTests {
    @Test func unavailableContextDoesNotRevokeAnotherContextAndPageReentryReauthorizes() async throws {
        let actorID = try UserID(UUID().uuidString), device = try DeviceID(UUID().uuidString), user = try UserID(UUID().uuidString)
        let allowed = V2ProfileViewLookupKey(userID: user, context: .relationship)
        let denied = V2ProfileViewLookupKey(userID: user, context: .room(try .init(UUID().uuidString)))
        let reader = PresentationReader(actorID: actorID, device: device, allowed: allowed)
        let repository = V2ProfilePresentationRepository(actorUserID: actorID, deviceID: device, reader: reader)
        let first = await repository.activate()
        async let visible = repository.presentation(for: allowed, activation: first)
        async let unavailable = repository.presentation(for: denied, activation: first)
        #expect(try await visible?.view.userID == user)
        #expect(try await unavailable == nil)
        #expect(await repository.cachedPresentation(for: allowed, activation: first) != nil)
        #expect(await reader.batches == 1)
        await repository.deactivate(first)
        #expect(await repository.cachedPresentation(for: allowed, activation: first) == nil)
        let second = await repository.activate()
        #expect(await repository.cachedPresentation(for: allowed, activation: second) == nil)
        #expect(try await repository.presentation(for: allowed, activation: second) != nil)
        #expect(await reader.batches == 2)
        await repository.endAllActivations()
        #expect(await repository.cachedPresentation(for: allowed, activation: second) == nil)
    }
}

private actor PresentationReader: V2ProfilePresentationReading {
    let actorID: UserID
    let device: DeviceID
    let allowed: V2ProfileViewLookupKey
    var batches = 0
    init(actorID: UserID, device: DeviceID, allowed: V2ProfileViewLookupKey) { self.actorID = actorID; self.device = device; self.allowed = allowed }
    func readPresentations(_ keys: [V2ProfileViewLookupKey]) async throws -> V2ProfilePresentationBatch {
        batches += 1
        let now = Date()
        let revision = V2ProfileRevision(rawValue: 1)!
        let view = try V2ProfileView(userID: allowed.userID, publicIdentity: .init(userID: allowed.userID, handle: .init("resource_test"), displayName: "Authorized", accountKind: .regular), avatar: nil, state: .active, revision: revision, visibilityRevision: revision)
        let lease = try V2PresentationAccessLease(actorUserID: actorID, deviceID: device, key: allowed, profileRevision: revision, visibilityRevision: revision, contextRevision: 1, observedAt: now, validUntil: now.addingTimeInterval(300))
        return .init(presentations: keys.contains(allowed) ? [allowed: try .init(view: view, lease: lease)] : [:], unavailable: Set(keys.filter { $0 != allowed }), serverNow: now)
    }
}
