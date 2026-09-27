import Foundation
import IMV2Core
@testable import IMV2Server
import Testing
import Synchronization

@Suite("V2 media provider session")
struct V2MediaProviderSessionServiceTests {
    @Test("structured resource plans carry separately classified object authorization")
    func exchangesValidatedResourcePlan() async throws {
        let now=Date(timeIntervalSince1970:1_750_000_000)
        let claim=try makeClaim(expiresAt:now.addingTimeInterval(30))
        let store=RecordingDownloadSessionStore(claim:claim)
        let plan=try V2ResourceTransferPlan(mode:.httpGet,url:#require(URL(string:"https://independent.invalid/object")),
            headers:[.init(name:"Authorization",value:"Bearer object-only",kind:.objectCapability),.init(name:"X-Independent-Token",value:"short-lived")],
            expiresAt:now.addingTimeInterval(20),expectedByteCount:3,checksum:.init(value:String(repeating:"a",count:64)))
        let target = plan
        let service=try V2MediaProviderSessionService(store:store,provider:FixedMediaProvider(target:target),now:{now})
        let value=try await service.exchangeDownload(actorUserID:.init("user"),deviceID:.init("device"),downloadSessionID:claim.downloadSessionID)
        #expect(value == plan)
        #expect(await store.completedClaims()==[claim])
    }
    @Test("a claimed opaque download session becomes one bounded provider target")
    func exchangesAndConsumesClaim() async throws {
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        let claim = try makeClaim(expiresAt: now.addingTimeInterval(30))
        let store = RecordingDownloadSessionStore(claim: claim)
        let target = try resourceDownloadTestPlan(url: try #require(URL(string: "https://media.invalid/object")), headers: ["x-oss-meta-test": "opaque"], expiresAt: now.addingTimeInterval(20))
        let service = try V2MediaProviderSessionService(store: store, provider: FixedMediaProvider(target: target), now: { now })

        let result = try await service.exchangeDownload(actorUserID: .init("user"), deviceID: .init("device"), downloadSessionID: claim.downloadSessionID)

        #expect(result == target)
        #expect(await store.completedClaims() == [claim])
        #expect(await store.releasedClaims().isEmpty)
    }

    @Test("provider failure releases the fenced session for retry")
    func providerFailureReleasesClaim() async throws {
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        let claim = try makeClaim(expiresAt: now.addingTimeInterval(30))
        let store = RecordingDownloadSessionStore(claim: claim)
        let service = try V2MediaProviderSessionService(store: store, provider: FailingMediaProvider(), now: { now })

        await #expect(throws: ProviderFailure.failed) {
            _ = try await service.exchangeDownload(actorUserID: .init("user"), deviceID: .init("device"), downloadSessionID: claim.downloadSessionID)
        }
        #expect(await store.completedClaims().isEmpty)
        #expect(await store.releasedClaims() == [claim])
    }

    @Test("a provider target may not outlive the IM authorization session")
    func rejectsOverlongProviderTarget() async throws {
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        let claim = try makeClaim(expiresAt: now.addingTimeInterval(30))
        let store = RecordingDownloadSessionStore(claim: claim)
        let target = try resourceDownloadTestPlan(url: try #require(URL(string: "https://media.invalid/object")), expiresAt: now.addingTimeInterval(31))
        let service = try V2MediaProviderSessionService(store: store, provider: FixedMediaProvider(target: target), now: { now })

        await #expect(throws: V2MediaProviderSessionError.invalidProviderTarget) {
            _ = try await service.exchangeDownload(actorUserID: .init("user"), deviceID: .init("device"), downloadSessionID: claim.downloadSessionID)
        }
        #expect(await store.releasedClaims() == [claim])
    }

    @Test("download sessions reject upload plans and missing checksums before consuming the claim", arguments: [false, true])
    func rejectsInvalidDownloadPlan(upload: Bool) async throws {
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        let claim = try makeClaim(expiresAt: now.addingTimeInterval(30))
        let store = RecordingDownloadSessionStore(claim: claim)
        let target = try V2ResourceTransferPlan(mode: upload ? .httpPut : .httpGet,
            url: #require(URL(string: "https://media.invalid/object")), expiresAt: now.addingTimeInterval(20),
            expectedByteCount: 42, checksum: upload ? .init(value: String(repeating: "a", count: 64)) : nil)
        let service = try V2MediaProviderSessionService(store: store, provider: FixedMediaProvider(target: target), now: { now })
        await #expect(throws: V2MediaProviderSessionError.invalidProviderTarget) {
            _ = try await service.exchangeDownload(actorUserID: .init("user"), deviceID: .init("device"), downloadSessionID: claim.downloadSessionID)
        }
        #expect(await store.completedClaims().isEmpty)
        #expect(await store.releasedClaims() == [claim])
    }

    @Test("provider return rechecks cancellation and actual target expiry", arguments: ["expired", "cancelled", "completion-expired", "completion-cancelled", "claim-expired", "claim-cancelled"])
    func providerReturnBoundary(_ mode: String) async throws {
        let instant = Date(timeIntervalSince1970: 1_750_000_000)
        let clock = ProviderBoundaryClock(instant)
        let claim = try makeClaim(expiresAt: instant.addingTimeInterval(30))
        let store = RecordingDownloadSessionStore(claim: claim, onClaim: {
            if mode == "claim-expired" { clock.advance(by: 31) }
            else if mode == "claim-cancelled" { withUnsafeCurrentTask { $0?.cancel() } }
        }) {
            if mode == "completion-expired" { clock.advance() }
            else if mode == "completion-cancelled" { withUnsafeCurrentTask { $0?.cancel() } }
        }
        let target = try resourceDownloadTestPlan(url: URL(string: "https://media.invalid/object")!, expiresAt: instant.addingTimeInterval(20))
        let provider = BoundaryTransitionProvider(target: target) {
            if mode == "expired" { clock.advance() }
            else if mode == "cancelled" { withUnsafeCurrentTask { $0?.cancel() } }
        }
        let service = try V2MediaProviderSessionService(store: store, provider: provider, now: { clock.now() })
        let task = Task { try await service.exchangeDownload(actorUserID: .init("user"), deviceID: .init("device"), downloadSessionID: claim.downloadSessionID) }
        if mode.contains("cancelled") {
            await #expect(throws: CancellationError.self) { _ = try await task.value }
        } else if mode == "expired" {
            await #expect(throws: V2MediaProviderSessionError.invalidProviderTarget) { _ = try await task.value }
        } else {
            await #expect(throws: V2MediaProviderSessionError.expiredSession) { _ = try await task.value }
        }
        #expect(await store.completedClaims() == (mode.hasPrefix("completion") ? [claim] : []))
        #expect(await store.releasedClaims() == [claim])
        #expect(await provider.calls == (mode.hasPrefix("claim") ? 0 : 1))
    }

    @Test("download exchange rejects invalid clocks at each asynchronous boundary", arguments: ["start", "claim", "provider", "completion"])
    func invalidClockBoundary(_ stage: String) async throws {
        let base = Date(timeIntervalSince1970: 1_750_000_000)
        let claim = try makeClaim(expiresAt: base.addingTimeInterval(30))
        for seconds in [Double.nan, .infinity, -.infinity, .greatestFiniteMagnitude, -.greatestFiniteMagnitude, 1e14, -1e14, -1e12] {
            let invalid = Date(timeIntervalSince1970: seconds)
            let clock = ProviderBoundaryClock(stage == "start" ? invalid : base)
            let store = RecordingDownloadSessionStore(claim: claim, onClaim: {
                if stage == "claim" { clock.set(invalid) }
            }, onComplete: {
                if stage == "completion" { clock.set(invalid) }
            })
            let target = try resourceDownloadTestPlan(url: URL(string: "https://media.invalid/upload")!, expiresAt: base.addingTimeInterval(20), expectedByteCount: 42)
            let provider = BoundaryTransitionProvider(target: target) {
                if stage == "provider" { clock.set(invalid) }
            }
            let service = try V2MediaProviderSessionService(store: store, provider: provider, now: { clock.now() })
            await #expect(throws: V2RoomWriteStoreError.corruptPersistenceState) {
                try await service.exchangeDownload(actorUserID: .init("user"), deviceID: .init("device"), downloadSessionID: claim.downloadSessionID)
            }
            #expect(await store.claimCalls == (stage == "start" ? 0 : 1))
            #expect(await store.completedClaims() == (stage == "completion" ? [claim] : []))
            #expect(await store.releasedClaims() == (stage == "start" ? [] : [claim]))
            #expect(await provider.calls == (stage == "start" || stage == "claim" ? 0 : 1))
        }
    }

    @Test("download exchange requires a finite positive lease")
    func invalidLeaseDuration() async throws {
        let base = Date(timeIntervalSince1970: 1_750_000_000)
        let store = RecordingDownloadSessionStore(claim: try makeClaim(expiresAt: base.addingTimeInterval(30)))
        for duration in [Double.nan, .infinity, -.infinity, 0, -1] {
            #expect(throws: V2MediaProviderSessionError.invalidLeaseDuration) {
                try V2MediaProviderSessionService(store: store, provider: FailingMediaProvider(), leaseDuration: duration)
            }
        }
    }

    private func makeClaim(expiresAt: Date) throws -> V2ClaimedMediaDownload {
        try .init(mediaID: .init("media"), downloadSessionID: .init("session"), expiresAt: expiresAt, claimToken: UUID(uuidString: "00000000-0000-0000-0000-000000000401")!)
    }
}

private actor RecordingDownloadSessionStore: V2MediaDownloadSessionStore {
    private let claim: V2ClaimedMediaDownload
    private var completed: [V2ClaimedMediaDownload] = []
    private var released: [V2ClaimedMediaDownload] = []

    private(set) var claimCalls = 0
    private let onClaim: @Sendable () -> Void
    private let onComplete: @Sendable () -> Void
    init(claim: V2ClaimedMediaDownload, onClaim: @escaping @Sendable () -> Void = {}, onComplete: @escaping @Sendable () -> Void = {}) {
        self.claim = claim; self.onClaim = onClaim; self.onComplete = onComplete
    }

    func claimDownload(requesterUserID _: UserID, deviceID _: DeviceID, downloadSessionID _: MediaDownloadSessionID, now _: Date, leaseDuration _: TimeInterval) -> V2ClaimedMediaDownload { claimCalls += 1; onClaim(); return claim }
    func completeDownload(_ claim: V2ClaimedMediaDownload, now _: Date) { completed.append(claim); onComplete() }
    func releaseDownload(_ claim: V2ClaimedMediaDownload) { released.append(claim) }
    func completedClaims() -> [V2ClaimedMediaDownload] { completed }
    func releasedClaims() -> [V2ClaimedMediaDownload] { released }
}

private struct FixedMediaProvider: V2MediaObjectProvider {
    let target: V2ResourceTransferPlan
    func issueDownloadTarget(mediaID _: MediaID, expiresAt _: Date) -> V2ResourceTransferPlan { target }
}

private struct FailingMediaProvider: V2MediaObjectProvider {
    func issueDownloadTarget(mediaID _: MediaID, expiresAt _: Date) throws -> V2ResourceTransferPlan { throw ProviderFailure.failed }
}

private enum ProviderFailure: Error { case failed }

private final class ProviderBoundaryClock: Sendable {
    private let value: Mutex<Date>
    init(_ now: Date) { value = Mutex(now) }
    func now() -> Date { value.withLock { $0 } }
    func set(_ now: Date) { value.withLock { $0 = now } }
    func advance(by seconds: TimeInterval = 21) { value.withLock { $0 = $0.addingTimeInterval(seconds) } }
}
private actor BoundaryTransitionProvider: V2MediaObjectProvider {
    let target: V2ResourceTransferPlan
    let transition: @Sendable () -> Void
    private(set) var calls = 0
    init(target: V2ResourceTransferPlan, transition: @escaping @Sendable () -> Void) {
        self.target = target; self.transition = transition
    }
    func issueDownloadTarget(mediaID: MediaID, expiresAt: Date) -> V2ResourceTransferPlan { calls += 1; transition(); return target }
}

/// Metadata-only provider fixture. Byte-transfer tests use the digest of their actual bytes.
func resourceDownloadTestPlan(url: URL, headers: [String: String] = [:], expiresAt: Date,
                              expectedByteCount: Int64 = 42) throws -> V2ResourceTransferPlan {
    try .init(mode: .httpGet, url: url,
              headers: headers.map { try .init(name: $0.key, value: $0.value) },
              expiresAt: expiresAt, expectedByteCount: expectedByteCount,
              checksum: .init(value: String(repeating: "a", count: 64)))
}
