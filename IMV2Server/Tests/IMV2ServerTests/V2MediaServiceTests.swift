import Foundation
import IMV2Core
@testable import IMV2Server
import Testing
import Synchronization

@Suite("V2 media service")
struct V2MediaServiceTests {
    @Test("download grants recheck the clock after persistence")
    func grantReturnClockBoundary() async throws {
        let base = Date(timeIntervalSince1970: 1_750_000_000)
        for seconds in [Double.nan, .infinity, -.infinity, .greatestFiniteMagnitude, -.greatestFiniteMagnitude, 1e14, -1e14, -1e12, base.timeIntervalSince1970 + 60] {
            let clock = MediaGrantClock(base)
            let store = RecordingMediaStore(onGrant: { clock.set(Date(timeIntervalSince1970: seconds)) })
            let service = V2MediaService(store: store, downloadLimits: try .init(grantLifetime: 60), now: { clock.now() })
            await #expect(throws: V2MediaServiceError.invalidGrant) {
                _ = try await service.requestDownload(actorUserID: .init("user"), deviceID: .init("device"), mediaID: .init("media"))
            }
            #expect(await store.events() == ["downloaded"])
        }
    }

    @Test("download grant creation rejects invalid or overflowing clocks before persistence")
    func downloadDeadlineBounds() async throws {
        let dates = [Double.nan, .infinity, -.infinity, .greatestFiniteMagnitude, -.greatestFiniteMagnitude, 1e14, -1e14, -1e12, 946_684_800 + 9_223_371_331_200 - 10]
        for seconds in dates {
            let store = RecordingMediaStore()
            let service = V2MediaService(store: store, now: { Date(timeIntervalSince1970: seconds) })
            await #expect(throws: V2RoomWriteStoreError.corruptPersistenceState) {
                try await service.requestDownload(actorUserID: .init("user"), deviceID: .init("device"), mediaID: .init("media"))
            }
            #expect(await store.events().isEmpty)
        }
    }

    @Test("an authenticated download receives only a short-lived opaque grant")
    func requestsDownload() async throws {
        let store = RecordingMediaStore()
        let service = V2MediaService(
            store: store,
            downloadLimits: try .init(grantLifetime: 30),
            now: { Date(timeIntervalSince1970: 100) }
        )
        let grant = try await service.requestDownload(
            actorUserID: .init("user"),
            deviceID: .init("device"),
            mediaID: .init("media")
        )
        #expect(grant == .init(mediaID: try .init("media"), downloadSessionID: try .init("download-session"), expiresAt: Date(timeIntervalSince1970: 130)))
        #expect(await store.events() == ["downloaded"])
    }
}

private actor RecordingMediaStore: V2MediaStore {
    private var eventLog: [String] = []
    private let onGrant: @Sendable () -> Void
    init(onGrant: @escaping @Sendable () -> Void = {}) { self.onGrant = onGrant }
    func requestDownload(requesterUserID _: UserID, deviceID _: DeviceID, mediaID: MediaID, expiresAt: Date, now _: Date) -> V2MediaDownloadGrant {
        eventLog.append("downloaded")
        onGrant()
        return try! .init(mediaID: mediaID, downloadSessionID: .init("download-session"), expiresAt: expiresAt)
    }
    func events() -> [String] { eventLog }
}

private final class MediaGrantClock: Sendable {
    private let value: Mutex<Date>
    init(_ now: Date) { value = Mutex(now) }
    func now() -> Date { value.withLock { $0 } }
    func set(_ now: Date) { value.withLock { $0 = now } }
}
