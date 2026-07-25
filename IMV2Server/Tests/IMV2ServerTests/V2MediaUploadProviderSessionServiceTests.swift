import Foundation
import IMV2Core
@testable import IMV2Server
import Testing

@Suite("V2 media upload provider session")
struct V2MediaUploadProviderSessionServiceTests {
    @Test("a device-bound upload session becomes one exact-byte provider target")
    func exchangesAndConsumesClaim() async throws {
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        let claim = try makeClaim(expiresAt: now.addingTimeInterval(30))
        let store = RecordingUploadSessionStore(claim: claim)
        let target = V2MediaProviderObjectTarget(
            url: try #require(URL(string: "https://media.invalid/upload")),
            headers: ["x-provider": "opaque"],
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

    init(claim: V2ClaimedMediaUpload) { self.claim = claim }

    func claimUpload(ownerUserID _: UserID, deviceID _: DeviceID, uploadSessionID _: MediaUploadSessionID, now _: Date, leaseDuration _: TimeInterval) -> V2ClaimedMediaUpload { claim }
    func completeUploadTarget(_ claim: V2ClaimedMediaUpload, now _: Date) { completed.append(claim) }
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
