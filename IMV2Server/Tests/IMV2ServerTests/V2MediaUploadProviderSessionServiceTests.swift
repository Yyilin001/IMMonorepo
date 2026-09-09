import Foundation
import IMV2Core
@testable import IMV2Server
import Testing
import Synchronization

@Suite("V2 media upload provider session")
struct V2MediaUploadProviderSessionServiceTests {
    @Test("a device-bound upload session becomes one exact-byte provider target")
    func exchangesAndConsumesClaim() async throws {
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        let claim = try makeClaim(expiresAt: now.addingTimeInterval(30))
        let store = RecordingUploadSessionStore(claim: claim)
        let target = V2MediaProviderObjectTarget(
            url: try #require(URL(string: "https://media.invalid/upload")),
            headers: ["x-oss-meta-provider": "opaque"],
            expiresAt: now.addingTimeInterval(20),
            expectedByteCount: 42
        )
        let service = try V2MediaUploadProviderSessionService(store: store, provider: FixedUploadProvider(target: target), now: { now })

        let result = try await service.exchangeUpload(actorUserID: .init("user"), deviceID: .init("device"), uploadSessionID: claim.uploadSessionID)

        #expect(result == target)
        #expect(await store.completedClaims() == [claim])
        #expect(await store.releasedClaims().isEmpty)
    }

    @Test("provider failure releases the upload claim for a bounded retry")
    func providerFailureReleasesClaim() async throws {
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        let claim = try makeClaim(expiresAt: now.addingTimeInterval(30))
        let store = RecordingUploadSessionStore(claim: claim)
        let service = try V2MediaUploadProviderSessionService(store: store, provider: FailingUploadProvider(), now: { now })

        await #expect(throws: UploadProviderFailure.failed) {
            _ = try await service.exchangeUpload(actorUserID: .init("user"), deviceID: .init("device"), uploadSessionID: claim.uploadSessionID)
        }
        #expect(await store.completedClaims().isEmpty)
        #expect(await store.releasedClaims() == [claim])
    }

    @Test("a provider cannot issue an upload target with an unspecified or mismatched byte count")
    func rejectsMismatchedProviderTarget() async throws {
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        let claim = try makeClaim(expiresAt: now.addingTimeInterval(30))
        let store = RecordingUploadSessionStore(claim: claim)
        let target = V2MediaProviderObjectTarget(url: try #require(URL(string: "https://media.invalid/upload")), expiresAt: now.addingTimeInterval(20))
        let service = try V2MediaUploadProviderSessionService(store: store, provider: FixedUploadProvider(target: target), now: { now })

        await #expect(throws: V2MediaUploadProviderSessionError.invalidProviderTarget) {
            _ = try await service.exchangeUpload(actorUserID: .init("user"), deviceID: .init("device"), uploadSessionID: claim.uploadSessionID)
        }
        #expect(await store.releasedClaims() == [claim])
    }

    @Test("upload targets reject credential headers even when byte count matches")
    func rejectsCredentialHeaderInjection() async throws {
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        let claim = try makeClaim(expiresAt: now.addingTimeInterval(30))
        let store = RecordingUploadSessionStore(claim: claim)
        let target = V2MediaProviderObjectTarget(
            url: try #require(URL(string: "https://media.invalid/upload")),
            headers: ["Cookie": "provider-secret"],
            expiresAt: now.addingTimeInterval(20),
            expectedByteCount: 42
        )
        let service = try V2MediaUploadProviderSessionService(store: store, provider: FixedUploadProvider(target: target), now: { now })

        await #expect(throws: V2MediaUploadProviderSessionError.invalidProviderTarget) {
            _ = try await service.exchangeUpload(actorUserID: .init("user"), deviceID: .init("device"), uploadSessionID: claim.uploadSessionID)
        }
        #expect(await store.releasedClaims() == [claim])
    }

    @Test("upload return rechecks expiry and cancellation after every wait", arguments: ["claim-expired", "provider-expired", "completion-expired", "claim-cancelled", "provider-cancelled", "completion-cancelled"])
    func uploadReturnBoundary(_ stage: String) async throws {
        let base = Date(timeIntervalSince1970: 1_750_000_000)
        let clock = UploadBoundaryClock(base)
        let claim = try makeClaim(expiresAt: base.addingTimeInterval(30))
        @Sendable func transition(_ boundary: String) {
            if stage == boundary + "-expired" { clock.set(base.addingTimeInterval(boundary == "claim" ? 30 : 20)) }
            if stage == boundary + "-cancelled" { withUnsafeCurrentTask { $0?.cancel() } }
        }
        let store = RecordingUploadSessionStore(claim: claim, onClaim: { transition("claim") }, onComplete: { transition("completion") })
        let target = V2MediaProviderObjectTarget(url: URL(string: "https://media.invalid/upload")!, expiresAt: base.addingTimeInterval(20), expectedByteCount: 42)
        let provider = BoundaryUploadProvider(target: target) { transition("provider") }
        let service = try V2MediaUploadProviderSessionService(store: store, provider: provider, now: { clock.now() })
        let task = Task { try await service.exchangeUpload(actorUserID: .init("user"), deviceID: .init("device"), uploadSessionID: claim.uploadSessionID) }
        if stage.hasSuffix("cancelled") {
            await #expect(throws: CancellationError.self) { _ = try await task.value }
        } else if stage == "provider-expired" {
            await #expect(throws: V2MediaUploadProviderSessionError.invalidProviderTarget) { _ = try await task.value }
        } else {
            await #expect(throws: V2MediaUploadProviderSessionError.expiredSession) { _ = try await task.value }
        }
        #expect(await store.completedClaims() == (stage.hasPrefix("completion") ? [claim] : []))
        #expect(await store.releasedClaims() == [claim])
        #expect(await provider.calls == (stage.hasPrefix("claim") ? 0 : 1))
    }

    @Test("upload exchange rejects invalid clocks at each asynchronous boundary", arguments: ["start", "claim", "provider", "completion"])
    func invalidClockBoundary(_ stage: String) async throws {
        let base = Date(timeIntervalSince1970: 1_750_000_000)
        let claim = try makeClaim(expiresAt: base.addingTimeInterval(30))
        for seconds in [Double.nan, .infinity, -.infinity, .greatestFiniteMagnitude, -.greatestFiniteMagnitude, 1e14, -1e14, -1e12] {
            let invalid = Date(timeIntervalSince1970: seconds)
            let clock = UploadBoundaryClock(stage == "start" ? invalid : base)
            let store = RecordingUploadSessionStore(claim: claim, onClaim: {
                if stage == "claim" { clock.set(invalid) }
            }, onComplete: {
                if stage == "completion" { clock.set(invalid) }
            })
            let target = V2MediaProviderObjectTarget(url: URL(string: "https://media.invalid/upload")!, expiresAt: base.addingTimeInterval(20), expectedByteCount: 42)
            let provider = BoundaryUploadProvider(target: target) {
                if stage == "provider" { clock.set(invalid) }
            }
            let service = try V2MediaUploadProviderSessionService(store: store, provider: provider, now: { clock.now() })
            await #expect(throws: V2RoomWriteStoreError.corruptPersistenceState) {
                try await service.exchangeUpload(actorUserID: .init("user"), deviceID: .init("device"), uploadSessionID: claim.uploadSessionID)
            }
            #expect(await store.claimCalls == (stage == "start" ? 0 : 1))
            #expect(await store.completedClaims() == (stage == "completion" ? [claim] : []))
            #expect(await store.releasedClaims() == (stage == "start" ? [] : [claim]))
            #expect(await provider.calls == (stage == "start" || stage == "claim" ? 0 : 1))
        }
    }

    @Test("upload exchange requires a finite positive lease")
    func invalidLeaseDuration() async throws {
        let base = Date(timeIntervalSince1970: 1_750_000_000)
        let store = RecordingUploadSessionStore(claim: try makeClaim(expiresAt: base.addingTimeInterval(30)))
        for duration in [Double.nan, .infinity, -.infinity, 0, -1] {
            #expect(throws: V2MediaUploadProviderSessionError.invalidLeaseDuration) {
                try V2MediaUploadProviderSessionService(store: store, provider: FailingUploadProvider(), leaseDuration: duration)
            }
        }
    }

    private func makeClaim(expiresAt: Date) throws -> V2ClaimedMediaUpload {
        try .init(
            mediaID: .init("media"),
            uploadSessionID: .init("session"),
            contentType: "image/png",
            byteCount: 42,
            expiresAt: expiresAt,
            claimToken: UUID(uuidString: "00000000-0000-0000-0000-000000000401")!
        )
    }
}

private actor RecordingUploadSessionStore: V2MediaUploadSessionStore {
    private let claim: V2ClaimedMediaUpload
    private var completed: [V2ClaimedMediaUpload] = []
    private var released: [V2ClaimedMediaUpload] = []

    private let onClaim: @Sendable () -> Void
    private let onComplete: @Sendable () -> Void
    private(set) var claimCalls = 0
    init(claim: V2ClaimedMediaUpload, onClaim: @escaping @Sendable () -> Void = {}, onComplete: @escaping @Sendable () -> Void = {}) {
        self.claim = claim; self.onClaim = onClaim; self.onComplete = onComplete
    }

    func claimUpload(ownerUserID _: UserID, deviceID _: DeviceID, uploadSessionID _: MediaUploadSessionID, now _: Date, leaseDuration _: TimeInterval) -> V2ClaimedMediaUpload { claimCalls += 1; onClaim(); return claim }
    func completeUploadTarget(_ claim: V2ClaimedMediaUpload, now _: Date) { completed.append(claim); onComplete() }
    func releaseUploadTarget(_ claim: V2ClaimedMediaUpload) { released.append(claim) }
    func completedClaims() -> [V2ClaimedMediaUpload] { completed }
    func releasedClaims() -> [V2ClaimedMediaUpload] { released }
}

private struct FixedUploadProvider: V2MediaUploadObjectProvider {
    let target: V2MediaProviderObjectTarget
    func issueUploadTarget(mediaID _: MediaID, contentType _: String, byteCount _: Int64, expiresAt _: Date) -> V2MediaProviderObjectTarget { target }
}

private struct FailingUploadProvider: V2MediaUploadObjectProvider {
    func issueUploadTarget(mediaID _: MediaID, contentType _: String, byteCount _: Int64, expiresAt _: Date) throws -> V2MediaProviderObjectTarget { throw UploadProviderFailure.failed }
}

private enum UploadProviderFailure: Error { case failed }

private final class UploadBoundaryClock: Sendable {
    private let value: Mutex<Date>
    init(_ now: Date) { value = Mutex(now) }
    func now() -> Date { value.withLock { $0 } }
    func set(_ now: Date) { value.withLock { $0 = now } }
}

private actor BoundaryUploadProvider: V2MediaUploadObjectProvider {
    let target: V2MediaProviderObjectTarget
    let transition: @Sendable () -> Void
    private(set) var calls = 0
    init(target: V2MediaProviderObjectTarget, transition: @escaping @Sendable () -> Void) {
        self.target = target; self.transition = transition
    }
    func issueUploadTarget(mediaID: MediaID, contentType: String, byteCount: Int64, expiresAt: Date) -> V2MediaProviderObjectTarget {
        calls += 1; transition(); return target
    }
}
