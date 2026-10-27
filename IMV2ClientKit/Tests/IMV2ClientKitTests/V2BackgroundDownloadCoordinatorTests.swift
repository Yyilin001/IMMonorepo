import CryptoKit
import Foundation
import GRDB
import IMV2Core
@testable import IMV2ClientKit
import Testing
import Synchronization

@Suite("Account-owned background download lifecycle", .timeLimit(.minutes(1)))
struct V2BackgroundDownloadCoordinatorTests {
    @Test func coldOwnerAdoptsOnlyExactInstalledDownloadAndReadsItsExistingCounters() async throws {
        let f = try await Fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        try await f.index()
        let id = UUID(), mapping = UUID()
        _ = try await f.store.beginBackgroundDownload(id: id, mediaID: f.media, message: f.message, accountID: f.account)
        try await f.store.bindBackgroundDownloadBytes(id: id, target: f.target, accountID: f.account)
        let reservation = try await f.files.reserveBackgroundDownload(mapping: mapping, session: f.session, target: f.target)
        let identifier = try await f.driver.create(target: f.target, mappingID: mapping)
        let grant = try #require(f.target.backgroundDownloadAuthorization)
        let origin = try #require(V2BackgroundResultInbox.originDigest(f.target.url))
        let task = try V2BackgroundDownloadTask(id: mapping, sessionID: f.session, identifier: identifier, grantID: grant.id,
            expectedByteCount: f.target.expectedByteCount, checksum: f.target.checksum, originDigest: origin,
            expiresAtMilliseconds: grant.expiresAtMilliseconds)
        try await f.store.installBackgroundDownloadTask(id: id, task: task, accountID: f.account)
        try await f.files.installBackgroundDownload(reservation, task: task)
        try await f.driver.resume(identifier)
        await f.driver.setReceivedBytes(6)
        let owner = try f.owner()
        #expect(await owner.transferProgress().isEmpty)
        try await owner.initialize()
        let adopted = await owner.transferProgress()[.download(id)]
        #expect(adopted?.attemptID == mapping && adopted?.transferredBytes == 6)
        #expect(await f.driver.createCount == 1)
        #expect(await f.scheduler.snapshot().activeDownloads == 1)
        try await f.center.attachBackgroundDownloads(owner)
        await f.driver.holdEnumeration()
        let slowCounters = Task { await owner.transferProgress() }
        await f.driver.waitForHeldEnumeration()
        let returned = Mutex(false)
        let localPage = Task {
            let stream = try await f.center.transferSnapshots(for: .init())
            returned.withLock { $0 = true }; return stream
        }
        let deadline = ContinuousClock.now + .seconds(5)
        while !returned.withLock({ $0 }), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        let returnedBeforeOS = returned.withLock { $0 }
        let newMedia = MediaID(uuid: UUID())
        let descriptor = try V2ResourceDescriptor(key: .init(home: .room(f.message.roomID), mediaID: newMedia), revision: 1,
            displayName: .init("waiting.bin"), contentType: "application/octet-stream", byteCount: 4,
            checksum: .init(value: String(repeating: "b", count: 64)), state: .ready)
        try await f.store.indexResource(descriptor, reference: .message(f.message, ordinal: 1), businessRevision: 1)
        guard case .queued(let waitingID) = try await f.center.prepareMessageDownload(mediaID: newMedia, message: f.message) else { Issue.record("Missing queued demand"); return }
        let stream = try await localPage.value
        // Ensure the new periodic OS query itself is now blocked, rather than
        // merely an unrelated driver's query held by this test.
        await f.driver.waitForHeldEnumeration()
        let seen = Mutex(false), gate = AsyncStream<Void>.makeStream()
        let observation = Task {
            for await snapshot in stream {
                if case .available(let page) = snapshot, page.entries.contains(where: { $0.id == waitingID && $0.waitingReason == .requestSlot }) { seen.withLock { $0 = true }; return }
            }
        }
        let localWait = Task {
            try await f.center.observingTransfer(waitingID) {
                let token = V2ResourceTransferWaitScope.context?.begin(.requestSlot)
                defer { token?.end() }
                for await _ in gate.stream { }
            }
        }
        let waitDeadline = ContinuousClock.now + .seconds(5)
        while !seen.withLock({ $0 }), ContinuousClock.now < waitDeadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(seen.withLock { $0 }, "Local waiting reason depended on blocked OS enumeration")
        gate.continuation.finish(); _ = try await localWait.value
        observation.cancel(); await observation.value
        await f.driver.releaseEnumeration()
        _ = await slowCounters.value; _ = try await localPage.value
        #expect(returnedBeforeOS, "Local task page waited for stalled OS enumeration")
        await owner.close()
        #expect(await owner.transferProgress().isEmpty)
        await f.center.close(); try await f.store.close()
    }

    @Test func systemCountersReachAccountSnapshotsWithoutCompletionWakeOrInventedReceipts() async throws {
        let f = try await Fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        try await f.index()
        let owner = try f.owner(), activity = Task { try await owner.run() }
        try await f.center.attachBackgroundDownloads(owner)
        let cache = try await f.center.downloadCache(using: .init(targetResolver: f.resolver, byteTransfer: NoForegroundDownload()))
        let request = Task { try await cache.download(.init(mediaID: f.media), message: f.message) }
        try await f.driver.waitForResume()
        let job = try #require(try await f.store.backgroundDownloads(accountID: f.account).first)
        var snapshots = try await f.center.transferSnapshots(for: .init()).makeAsyncIterator()
        await f.driver.setReceivedBytes(3)
        while let snapshot = await snapshots.next() {
            if case .available(let page) = snapshot, let row = page.entries.first, row.attemptProgress?.transferredBytes == 3 {
                #expect(row.id == .download(job.id) && row.confirmedBytes == nil && row.phase == .transferring); break
            }
        }
        // No wake is delivered: the visible-page polling observes OS counters.
        await f.driver.setReceivedBytes(7)
        while let snapshot = await snapshots.next() {
            if case .available(let page) = snapshot, let row = page.entries.first, row.attemptProgress?.transferredBytes == 7 {
                #expect(row.id == .download(job.id) && row.confirmedBytes == nil); break
            }
        }
        #expect(await f.driver.createCount == 1)
        try await f.driver.finish()
        _ = try await request.value
        while let snapshot = await snapshots.next() {
            if case .available(let page) = snapshot, let row = page.entries.first, row.phase == .completed {
                #expect(row.attemptProgress == nil && row.confirmedBytes == Int64(Fixture.bytes.count)); break
            }
        }
        #expect(await owner.transferProgress().isEmpty)
        await owner.close(); _ = await activity.result; await f.center.close(); try await f.store.close()
    }

    @Test(arguments: [false, true]) func userJoiningNativeFlightPromotesSameJobAndNeverCreatesAnotherOSTask(queued: Bool) async throws {
        let f = try await Fixture(schedulerConfiguration: .init(byteTransferLimit: 2))
        defer { try? FileManager.default.removeItem(at: f.root) }
        try await f.index()
        try await f.center.setDownloadNetworkPreferences(.init(automaticDownloads: .init(categories: [.file], maximumByteCount: 1024)))
        let owner = try f.owner(), activity = Task { try await owner.run() }
        try await f.center.attachBackgroundDownloads(owner)
        let cache = try await f.center.downloadCache(using: .init(targetResolver: f.resolver, byteTransfer: NoForegroundDownload()))
        let occupied = queued ? try await f.scheduler.acquire(.init(service: "mediaProvider", priority: .background, kind: .byteTransfer(.download))) : nil
        let automatic = Task {
            try await V2NetworkWorkScope.$context.withValue(.init(service: "resources", priority: .background)) {
                try await cache.download(.init(mediaID: f.media), message: f.message)
            }
        }
        let deadline = ContinuousClock.now + .seconds(10)
        if queued {
            while await f.scheduler.snapshot().waitingByteTransfers != 1 {
                try #require(ContinuousClock.now < deadline); try await Task.sleep(for: .milliseconds(10))
            }
        } else { try await f.driver.waitForResume() }
        let original = try #require(try await f.store.backgroundDownloads(accountID: f.account).first)
        #expect(original.priority == .background)
        #expect(await f.driver.createCount == (queued ? 0 : 1))
        let user = Task { try await cache.download(.init(mediaID: f.media), message: f.message) }
        try await f.driver.waitForResume()
        while true {
            let priority = try await f.store.backgroundDownloads(accountID: f.account).first?.priority
            let backgroundCount = await f.scheduler.snapshot().activeBackgroundTransfers
            if priority == .interactive && backgroundCount == (queued ? 1 : 0) { break }
            try #require(ContinuousClock.now < deadline); try await Task.sleep(for: .milliseconds(10))
        }
        let promoted = try #require(try await f.store.backgroundDownloads(accountID: f.account).first)
        #expect(promoted.id == original.id && promoted.priority == .interactive)
        #expect(promoted.attemptCount == original.attemptCount && promoted.retryAtMilliseconds == original.retryAtMilliseconds)
        #expect(await f.scheduler.snapshot().activeDownloads == (queued ? 2 : 1))
        automatic.cancel()
        await #expect(throws: CancellationError.self) { try await automatic.value }
        try await f.driver.finish()
        let resource = try await user.value, lease = try await resource.borrowFile()
        #expect(try Data(contentsOf: lease.fileURL) == Fixture.bytes)
        await lease.release()
        #expect(await f.driver.createCount == 1)
        #expect(try await f.store.managedResourceTransfers(.init(group: .finished)).entries.map(\.id) == [.download(original.id)])
        #expect(await f.scheduler.snapshot().activeDownloads == (queued ? 1 : 0))
        if let occupied { _ = await f.scheduler.release(occupied) }
        await owner.close(); _ = await activity.result; await f.center.close(); try await f.store.close()
    }

    @Test func pauseBeforeTransportAttachmentSurvivesColdReconciliationAndRejectsLateCompletion() async throws {
        let f = try await Fixture(autoDrain: false)
        defer { try? FileManager.default.removeItem(at: f.root) }
        try await f.index()
        let id = UUID(), mappingID = UUID()
        _ = try await f.store.beginBackgroundDownload(id: id, mediaID: f.media, message: f.message, accountID: f.account)
        try await f.store.bindBackgroundDownloadBytes(id: id, target: f.target, accountID: f.account)
        let reservation = try await f.files.reserveBackgroundDownload(mapping: mappingID, session: f.session, target: f.target)
        let identifier = try await f.driver.create(target: f.target, mappingID: mappingID)
        let grant = try #require(f.target.backgroundDownloadAuthorization)
        let task = try V2BackgroundDownloadTask(id: mappingID, sessionID: f.session, identifier: identifier,
            grantID: grant.id, expectedByteCount: f.target.expectedByteCount, checksum: f.target.checksum,
            originDigest: #require(V2BackgroundResultInbox.originDigest(f.target.url)), expiresAtMilliseconds: grant.expiresAtMilliseconds)
        try await f.store.installBackgroundDownloadTask(id: id, task: task, accountID: f.account)
        try await f.files.installBackgroundDownload(reservation, task: task)
        try await f.driver.resume(identifier)
        // There is no attached cache or coordinator when the command is saved.
        try await f.center.pauseTransfer(.download(id))
        #expect(try await f.store.backgroundDownloads(accountID: f.account).first?.state == .pausing(task))
        #expect(try await !f.store.finishBackgroundDownloadTask(id: id, mappingID: mappingID, sessionID: f.session,
            identifier: identifier, success: true, accountID: f.account))
        let owner = try f.owner(), activity = Task { try await owner.run() }
        try await f.driver.waitForCancellation()
        #expect(try await f.store.managedResourceTransfers(.init()).entries.first?.phase == .pausing)
        await f.driver.finishDrain()
        try await f.waitForPhase(.download(id), .paused)
        #expect(try await f.store.backgroundDownloads(accountID: f.account).first?.state == .paused)
        #expect(try await f.files.snapshot().backgroundReservedBytes == 0)
        #expect(await f.scheduler.snapshot().active == 0)
        #expect(await f.driver.createCount == 1)
        await #expect(throws: V2ResourceDownloadControlError.paused) {
            _ = try await owner.download(mediaID: f.media, message: f.message, initialTarget: f.target)
        }
        #expect(try await !f.store.finishBackgroundDownloadTask(id: id, mappingID: mappingID, sessionID: f.session,
            identifier: identifier, success: true, accountID: f.account))
        await owner.close(); _ = await activity.result
        await f.center.close(); try await f.store.close()
    }

    @Test(arguments: [false, true], [0, 1, 2])
    func manualPauseWaitsForNativeDrainAndContinuesSameJobWithFreshAuthority(holdCreate: Bool, nextAction: Int) async throws {
        let f = try await Fixture(autoDrain: false, holdCreate: holdCreate)
        defer { try? FileManager.default.removeItem(at: f.root) }
        try await f.index()
        let owner = try f.owner(), activity = Task { try await owner.run() }
        try await f.center.attachBackgroundDownloads(owner)
        let cache = try await f.center.downloadCache(using: .init(targetResolver: f.resolver, byteTransfer: NoForegroundDownload()))
        let request = Task { try await cache.download(.init(mediaID: f.media), message: f.message) }
        if holdCreate { await f.driver.waitForHeldCreate() } else { try await f.driver.waitForResume() }
        let job = try #require(try await f.store.managedResourceTransfers(.init()).entries.first)
        #expect(job.actions.contains(.pause))
        try await f.center.pauseTransfer(job.id)
        #expect(try await f.store.managedResourceTransfers(.init()).entries.first?.phase == .pausing)
        await #expect(throws: V2ResourceTransferManagementError.actionUnavailable) { try await f.center.resumeTransfer(job.id) }
        if holdCreate { await f.driver.releaseHeldCreate() }
        try await f.driver.waitForCancellation()
        #expect(await f.scheduler.snapshot().active == 1)
        #expect(try await f.files.snapshot().backgroundReservedBytes == 2 * Int64(Fixture.bytes.count))
        if nextAction == 1 { try await f.center.cancelTransfer(job.id) }
        await f.driver.finishDrain()
        _ = await request.result
        try await f.waitForPhase(job.id, nextAction == 1 ? .cancelled : .paused)
        #expect(await f.scheduler.snapshot().active == 0)
        #expect(try await f.files.snapshot().backgroundReservedBytes == 0)
        if nextAction != 1 {
            let paused = try #require(try await f.store.managedResourceTransfers(.init()).entries.first)
            #expect(paused.actions == [.resume, .cancel])
            await #expect(throws: V2ResourceDownloadControlError.paused) {
                try await cache.download(.init(mediaID: f.media), message: f.message)
            }
            #expect(await f.driver.createCount == 1)
            if nextAction == 2 { await f.resolver.deny() }
            let recovery = Task { try await cache.runRecovery() }
            try await f.center.resumeTransfer(job.id)
            if nextAction == 2 {
                try await f.waitForPhase(job.id, .requiresAttention(.sourceUnavailable))
                #expect(await f.driver.createCount == 1)
            } else {
                try await f.driver.waitForResume(2)
                let resumed = try await f.store.managedResourceTransfers(.init())
                #expect(resumed.entries.map(\.id) == [job.id])
                try await f.driver.finish()
                try await f.waitForPhase(job.id, .completed)
                #expect(await f.driver.createCount == 2)
            }
            recovery.cancel(); _ = await recovery.result
        }
        await f.center.close(); _ = await activity.result; try await f.store.close()
    }

    @Test func suspendedTaskResumesOnlyAfterCapacityAndMappingThenPublishesThroughFileStore() async throws {
        let f = try await Fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let owner = try f.owner()
        let activity = Task { try await owner.run() }
        let request = Task { try await owner.download(mediaID: f.media, message: f.message, initialTarget: f.target) }
        try await f.driver.waitForResume()
        #expect(await f.driver.durableBeforeResume)
        #expect(await f.scheduler.snapshot().active == 1)
        try await f.driver.finish()
        let file = try await request.value
        #expect(try Data(contentsOf: file.fileURL) == Fixture.bytes)
        #expect(await f.resolver.calls == 0)
        #expect(await f.scheduler.snapshot().active == 0)
        let publication = try await f.files.publishDownload(of: file.fileURL, reservation: file.reservation,
            byteCount: f.target.expectedByteCount, checksum: f.target.checksum)
        try await owner.didPublish(file)
        #expect(!FileManager.default.fileExists(atPath: file.fileURL.path))
        let published = try await f.files.verifiedFile(id: publication.id, checksum: f.target.checksum, bytes: f.target.expectedByteCount)
        #expect(try Data(contentsOf: published) == Fixture.bytes)
        await publication.lease.release()
        #expect(try await f.store.backgroundDownloads(accountID: f.account).isEmpty)
        let history = try await f.store.managedResourceTransfers(.init(group: .finished))
        #expect(history.entries.first?.phase == .completed)
        #expect(history.entries.first?.confirmedBytes == f.target.expectedByteCount)
        #expect(history.entries.first?.mediaID == f.media)
        await owner.close(); _ = await activity.result; await f.center.close(); try await f.store.close()
    }

    @Test func completedBytesCannotBePublishedAfterPermissionRevocation() async throws {
        let f = try await Fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let owner = try f.owner(), activity = Task { try await owner.run() }
        let cache = try V2ResourceDownloadCache(files: f.files, journal: await f.store.resourceFileJournal(),
            network: .init(targetResolver: f.resolver, byteTransfer: NoForegroundDownload()), progress: .init())
        await cache.attachBackgroundDownloads(owner)
        let request = Task { try await cache.download(.init(mediaID: f.media), message: f.message) }
        try await f.driver.waitForResume()
        await f.resolver.deny()
        try await f.driver.finish()
        await #expect(throws: V2ClientMediaTransferError.authorizationDenied) { _ = try await request.value }
        #expect(try await f.store.backgroundDownloads(accountID: f.account).isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(at: f.inbox.directory.appendingPathComponent("files"), includingPropertiesForKeys: nil).isEmpty)
        await cache.close(); _ = await activity.result; await f.center.close(); try await f.store.close()
    }

    @Test func sharedBackgroundBytesFreshlyAuthorizeEachCallerIndependently() async throws {
        let f = try await Fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let owner = try f.owner(), activity = Task { try await owner.run() }
        let cache = try V2ResourceDownloadCache(files: f.files, journal: await f.store.resourceFileJournal(),
            network: .init(targetResolver: f.resolver, byteTransfer: NoForegroundDownload()), progress: .init())
        await cache.attachBackgroundDownloads(owner)
        let first = Task { try await cache.download(.init(mediaID: f.media), message: f.message) }
        try await f.driver.waitForResume()
        let other = MediaID(uuid: UUID())
        let second = Task { try await cache.download(.init(mediaID: other), message: f.message) }
        await f.resolver.waitForCalls(2)
        await f.resolver.deny(f.media)
        try await f.driver.finish()
        await #expect(throws: V2ClientMediaTransferError.authorizationDenied) { _ = try await first.value }
        let authorized = try await second.value, lease = try await authorized.borrowFile()
        #expect(try Data(contentsOf: lease.fileURL) == Fixture.bytes)
        #expect(await f.driver.createCount == 1)
        #expect(await f.resolver.calls == 4)
        await lease.release(); await cache.close(); _ = await activity.result
        await f.center.close(); try await f.store.close()
    }

    @Test(arguments: [false, true], [V2NetworkWorkPriority.interactive, .background]) func coldOwnerAdoptsTheOriginalTaskAndWaiterDoesNotCreateAnotherAttempt(initiallyLocked: Bool, priority: V2NetworkWorkPriority) async throws {
        let f = try await Fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let jobID = UUID(), mappingID = UUID()
        _ = try await f.store.beginBackgroundDownload(id: jobID, mediaID: f.media, message: f.message, accountID: f.account, priority: priority)
        let reservation = try await f.files.reserveBackgroundDownload(mapping: mappingID, session: f.session, target: f.target)
        let identifier = try await f.driver.create(target: f.target, mappingID: mappingID)
        let grant = try #require(f.target.backgroundDownloadAuthorization)
        let mapping = try V2BackgroundDownloadTask(id: mappingID, sessionID: f.session, identifier: identifier,
            grantID: grant.id, expectedByteCount: f.target.expectedByteCount, checksum: f.target.checksum,
            originDigest: #require(V2BackgroundResultInbox.originDigest(f.target.url)), expiresAtMilliseconds: grant.expiresAtMilliseconds)
        try await f.store.installBackgroundDownloadTask(id: jobID, task: mapping, accountID: f.account)
        try await f.files.installBackgroundDownload(reservation, task: mapping)
        try await f.driver.resume(identifier)
        if initiallyLocked { await f.driver.setProtectedDataAvailable(false) }
        let owner = try f.owner()
        async let first: Void = owner.initialize()
        async let second: Void = owner.initialize()
        _ = try await (first, second)
        #expect(await f.scheduler.snapshot().active == 1)
        #expect(await f.scheduler.snapshot().activeBackgroundTransfers == (initiallyLocked || priority == .background ? 1 : 0))
        let activity = Task { try await owner.run() }
        let request = Task {
            try await V2NetworkWorkScope.$context.withValue(.init(service: "resources", priority: priority)) {
                try await owner.download(mediaID: f.media, message: f.message, initialTarget: f.target)
            }
        }
        if initiallyLocked { await f.driver.setProtectedDataAvailable(true) }
        let deadline = ContinuousClock.now + .seconds(10)
        while await f.scheduler.snapshot().activeBackgroundTransfers != (priority == .background ? 1 : 0) {
            try #require(ContinuousClock.now < deadline); try await Task.sleep(for: .milliseconds(10))
        }
        try await f.driver.finish()
        let file = try await request.value
        #expect(await f.driver.createCount == 1)
        let persisted = try #require(try await f.store.backgroundDownloads(accountID: f.account).first)
        #expect(persisted.id == jobID && persisted.state == .downloaded(mapping) && persisted.priority == priority)
        #expect(file.fileURL.lastPathComponent == mappingID.uuidString)
        await owner.close(); _ = await activity.result; await f.center.close(); try await f.store.close()
    }

    @Test func lockedOwnerKeepsTaskUntilPermitExpiresThenDrainsWithoutReleasingDurableBytesEarly() async throws {
        let f = try await Fixture(autoDrain: false), clock = DownloadClock()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let owner = try f.owner(now: { clock.read() }), activity = Task { try await owner.run() }
        let request = Task { try await owner.download(mediaID: f.media, message: f.message, initialTarget: f.target) }
        try await f.driver.waitForResume()
        await f.driver.setProtectedDataAvailable(false)
        clock.advance(120)
        await f.driver.setProtectedDataAvailable(false)
        try await f.driver.waitForCancellation()
        #expect(await f.scheduler.snapshot().active == 1)
        #expect(try await f.files.snapshot().backgroundReservedBytes == 2 * Int64(Fixture.bytes.count))
        await f.driver.finishDrain()
        await f.driver.setProtectedDataAvailable(true)
        try await owner.cancel(mediaID: f.media)
        await #expect(throws: (any Error).self) { _ = try await request.value }
        #expect(await f.scheduler.snapshot().active == 0)
        #expect(try await f.files.snapshot().backgroundReservedBytes == 0)
        await owner.close(); _ = await activity.result; await f.center.close(); try await f.store.close()
    }

    @Test(arguments: 0..<12) func cancellationKeepsThePhysicalSlotUntilTheRealDriverDrain(attempt: Int) async throws {
        let repeated = attempt.isMultiple(of: 2)
        let f = try await Fixture(autoDrain: false)
        defer { try? FileManager.default.removeItem(at: f.root) }
        let owner = try f.owner(), activity = Task { try await owner.run() }
        let request = Task { try await owner.download(mediaID: f.media, message: f.message, initialTarget: f.target) }
        try await f.driver.waitForResume()
        let cancellation = Task { try await owner.cancel(mediaID: f.media) }
        let repeatedCancellation = repeated ? Task { try await owner.cancel(mediaID: f.media) } : nil
        try await f.driver.waitForCancellation()
        #expect(await f.scheduler.snapshot().active == 1)
        #expect(try await f.files.snapshot().backgroundReservedBytes == 2 * Int64(Fixture.bytes.count))
        await f.driver.finishDrain()
        try await cancellation.value
        try await repeatedCancellation?.value
        await #expect(throws: CancellationError.self) { _ = try await request.value }
        #expect(await f.scheduler.snapshot().active == 0)
        #expect(try await f.files.snapshot().backgroundReservedBytes == 0)
        #expect(try await f.store.backgroundDownloads(accountID: f.account).isEmpty)
        await owner.close(); _ = await activity.result; await f.center.close(); try await f.store.close()
    }

    @Test func managementCancellationReturnsBeforeNativeDrainAndRetiresOnlyAfterActualStop() async throws {
        let f = try await Fixture(autoDrain: false)
        defer { try? FileManager.default.removeItem(at: f.root) }
        try await f.index()
        let owner = try f.owner(), activity = Task { try await owner.run() }
        try await f.center.attachBackgroundDownloads(owner)
        let cache = try await f.center.downloadCache(using: .init(targetResolver: f.resolver, byteTransfer: NoForegroundDownload()))
        let request = Task { try await cache.download(.init(mediaID: f.media), message: f.message) }
        try await f.driver.waitForResume()
        let job = try #require(try await f.store.managedResourceTransfers(.init()).entries.first)
        #expect(job.actions == [.pause, .cancel])
        try await f.center.cancelTransfer(job.id)
        try await f.driver.waitForCancellation()
        #expect(try await f.store.managedResourceTransfers(.init()).entries.first?.phase == .cancelling)
        #expect(await f.scheduler.snapshot().active == 1)
        #expect(try await f.files.snapshot().backgroundReservedBytes == 2 * Int64(Fixture.bytes.count))
        await f.driver.finishDrain()
        await #expect(throws: CancellationError.self) { _ = try await request.value }
        try await f.waitForPhase(job.id, .cancelled)
        #expect(await f.scheduler.snapshot().active == 0)
        #expect(try await f.files.snapshot().backgroundReservedBytes == 0)
        await #expect(throws: V2ResourceTransferManagementError.actionUnavailable) { try await f.center.cancelTransfer(job.id) }
        await f.center.close(); _ = await activity.result; try await f.store.close()
    }

    @Test func managementRetryUsesFreshAuthorityAndSameUUIDThroughRealNativeFailuresAndPublication() async throws {
        let f = try await Fixture(lifetime: 120)
        defer { try? FileManager.default.removeItem(at: f.root) }
        try await f.index()
        let owner = try f.owner(), activity = Task { try await owner.run() }
        try await f.center.attachBackgroundDownloads(owner)
        let cache = try await f.center.downloadCache(using: .init(targetResolver: f.resolver, byteTransfer: NoForegroundDownload()))
        let request = Task { try await cache.download(.init(mediaID: f.media), message: f.message) }
        for attempt in 1...5 { try await f.driver.waitForResume(attempt); try await f.driver.fail() }
        await #expect(throws: V2ResourceDownloadControlError.paused) { _ = try await request.value }
        let job = try #require(try await f.store.managedResourceTransfers(.init()).entries.first)
        #expect(job.phase == .requiresAttention(.needsAttention) && job.actions == [.retry, .cancel])
        let calls = await f.resolver.calls
        let recovery = Task { try await cache.runRecovery() }
        defer { recovery.cancel() }
        try await f.center.retryTransfer(job.id)
        try await f.driver.waitForResume(6)
        #expect(await f.resolver.calls > calls)
        #expect(try await f.store.managedResourceTransfers(.init()).entries.map(\.id) == [job.id])
        try await f.driver.finish()
        try await f.waitForPhase(job.id, .completed)
        try await f.waitForBackgroundCleanup()
        #expect(try await f.files.snapshot().backgroundReservedBytes == 0)
        let handle = try await cache.download(.init(mediaID: f.media), message: f.message), lease = try await handle.borrowFile()
        #expect(try Data(contentsOf: lease.fileURL) == Fixture.bytes)
        #expect(await f.driver.createCount == 6)
        await lease.release()
        recovery.cancel(); _ = await recovery.result
        await f.center.close(); _ = await activity.result; try await f.store.close()
    }

    @Test(arguments: [false, true]) func coldRetryClaimRecoversSameNativeJobAndRejectsRevokedAuthority(deny: Bool) async throws {
        let f = try await Fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        try await f.index()
        let id = try await f.seedPaused()
        try await f.center.retryTransfer(.download(id))
        let journal = await f.store.resourceFileJournal()
        #expect(try journal.claimDownloadResume(id, owner: UUID())?.transport == .background)
        await f.center.close()
        let restored = try await V2ResourceCenter.make(scope: f.scope, store: f.store)
        let owner = try f.owner(resourceFiles: await restored.files), activity = Task { try await owner.run() }
        try await restored.attachBackgroundDownloads(owner)
        let cache = try await restored.downloadCache(using: .init(targetResolver: f.resolver, byteTransfer: NoForegroundDownload()))
        if deny { await f.resolver.deny() }
        let recovery = Task { try await cache.runRecovery() }
        defer { recovery.cancel() }
        if deny {
            try await f.waitForPhase(.download(id), .requiresAttention(.sourceUnavailable))
            #expect(await f.driver.createCount == 0)
        } else {
            try await f.driver.waitForResume()
            try await f.driver.finish()
            try await f.waitForPhase(.download(id), .completed)
            #expect(await f.driver.createCount == 1)
        }
        #expect(try await f.store.managedResourceTransfers(.init()).entries.map(\.id) == [.download(id)])
        recovery.cancel(); _ = await recovery.result
        await restored.close(); _ = await activity.result; try await f.store.close()
    }

    @Test(arguments: [false, true]) func unpublishedNativeReceiptFinishesWithoutOriginalPageOrSecondDownload(cacheHit: Bool) async throws {
        let f = try await Fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        try await f.index()
        let owner = try f.owner(), activity = Task { try await owner.run() }
        let request = Task { try await owner.download(mediaID: f.media, message: f.message, initialTarget: f.target) }
        try await f.driver.waitForResume(); try await f.driver.finish()
        let raw = try await request.value
        let job = try #require(try await f.store.managedResourceTransfers(.init()).entries.first)
        if cacheHit {
            let source = f.root.appending(path: "other-authorized-source")
            try Fixture.bytes.write(to: source)
            _ = try await f.files.publishCopy(of: source, byteCount: f.target.expectedByteCount, checksum: f.target.checksum, retention: .cache)
        }
        try await f.center.attachBackgroundDownloads(owner)
        let cache = try await f.center.downloadCache(using: .init(targetResolver: f.resolver, byteTransfer: NoForegroundDownload()))
        let recovery = Task { try await cache.runRecovery() }
        defer { recovery.cancel() }
        try await f.waitForPhase(job.id, .completed)
        try await f.waitForBackgroundCleanup()
        #expect(await f.driver.createCount == 1)
        #expect(!FileManager.default.fileExists(atPath: raw.fileURL.path))
        #expect(try await f.files.snapshot().backgroundReservedBytes == 0)
        let handle = try await cache.download(.init(mediaID: f.media), message: f.message), lease = try await handle.borrowFile()
        #expect(try Data(contentsOf: lease.fileURL) == Fixture.bytes)
        await lease.release()
        recovery.cancel(); _ = await recovery.result
        await f.center.close(); _ = await activity.result; try await f.store.close()
    }

    enum RejectedResumePlan: CaseIterable, Sendable { case denied, changedBytes, foregroundOnly }
    @Test(arguments: RejectedResumePlan.allCases) func backgroundRetryRejectsChangedOrUnsupportedFreshPlanBeforeCreatingAnyNativeTask(mode: RejectedResumePlan) async throws {
        let f = try await Fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        try await f.index()
        let id = try await f.seedPaused(), owner = try f.owner(), activity = Task { try await owner.run() }
        try await f.center.attachBackgroundDownloads(owner)
        let cache = try await f.center.downloadCache(using: .init(targetResolver: f.resolver, byteTransfer: NoForegroundDownload()))
        switch mode {
        case .denied: await f.resolver.deny()
        case .changedBytes:
            let checksum = try V2ResourceChecksum(value: String(repeating: "f", count: 64)), now = Date()
            let target = try V2ClientMediaTransferTarget(downloadPlan: .init(mode: .httpGet, url: f.target.url,
                expiresAt: f.target.expiresAt, expectedByteCount: f.target.expectedByteCount, checksum: checksum,
                backgroundDownloadAuthorization: .init(id: UUID(), expectedByteCount: f.target.expectedByteCount, checksum: checksum, issuedAt: now, expiresAt: f.target.expiresAt)))
            await f.resolver.replace(target)
        case .foregroundOnly:
            let target = try V2ClientMediaTransferTarget(downloadPlan: .init(mode: .httpGet, url: f.target.url,
                expiresAt: f.target.expiresAt, expectedByteCount: f.target.expectedByteCount, checksum: f.target.checksum))
            await f.resolver.replace(target)
        }
        let recovery = Task { try await cache.runRecovery() }
        defer { recovery.cancel() }
        try await f.center.retryTransfer(.download(id))
        try await f.waitForPhase(.download(id), .requiresAttention(mode == .changedBytes ? .integrity : .sourceUnavailable))
        #expect(await f.driver.createCount == 0)
        #expect(try await f.store.managedResourceTransfers(.init()).entries.map(\.id) == [.download(id)])
        recovery.cancel(); _ = await recovery.result
        await f.center.close(); _ = await activity.result; try await f.store.close()
    }

    @Test func cancellationBeforeTransportAttachmentSurvivesStartupAndPrunedHistoryCannotResurrectOldID() async throws {
        let f = try await Fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        try await f.index()
        let id = try await f.seedPaused()
        try await f.center.cancelTransfer(.download(id))
        #expect(try await f.store.managedResourceTransfers(.init()).entries.first?.phase == .cancelling)
        let owner = try f.owner(), activity = Task { try await owner.run() }
        try await f.center.attachBackgroundDownloads(owner)
        try await f.waitForPhase(.download(id), .cancelled)
        try await f.store.pruneResourceTransferHistory(now: Date().addingTimeInterval(31 * 24 * 60 * 60))
        await #expect(throws: CancellationError.self) {
            try await owner.download(mediaID: f.media, message: f.message, initialTarget: f.target, restoringJobID: id)
        }
        #expect(await f.driver.createCount == 0)
        #expect(try await f.store.managedResourceTransfers(.init()).entries.isEmpty)
        await f.center.close(); _ = await activity.result; try await f.store.close()
    }

    @Test func cancellationWhileFreshAuthorityIsPendingCannotResurrectPrunedTaskAndCloseDrainsActualReply() async throws {
        let f = try await Fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        try await f.index()
        let id = try await f.seedPaused(), owner = try f.owner(), activity = Task { try await owner.run() }
        try await f.center.attachBackgroundDownloads(owner)
        let cache = try await f.center.downloadCache(using: .init(targetResolver: f.resolver, byteTransfer: NoForegroundDownload()))
        await f.resolver.holdNextResolution()
        let recovery = Task { try await cache.runRecovery() }
        try await f.center.retryTransfer(.download(id))
        await f.resolver.waitUntilHeld()
        try await f.center.cancelTransfer(.download(id))
        try await f.waitForPhase(.download(id), .cancelled)
        try await f.store.pruneResourceTransferHistory(now: Date().addingTimeInterval(31 * 24 * 60 * 60))
        let witness = NativeDownloadCloseWitness()
        let closing = Task { await f.center.close(); await witness.finish() }
        let deadline = ContinuousClock.now + .seconds(10)
        while true {
            do { _ = try await f.center.transferSnapshots(for: .init()) }
            catch V2ResourceStorageError.closed { break }
            catch is CancellationError { }
            try #require(ContinuousClock.now < deadline); await Task.yield()
        }
        #expect(await witness.finished == false)
        await f.resolver.releaseHeldResolution()
        await closing.value
        _ = await recovery.result; _ = await activity.result
        #expect(await f.driver.createCount == 0)
        #expect(try await f.store.managedResourceTransfers(.init()).entries.isEmpty)
        try await f.store.close()
    }

    @Test func cancellationDuringNativeCreationDoesNotFinishBeforeUnmappedSystemTaskDrains() async throws {
        let f = try await Fixture(autoDrain: false, holdCreate: true)
        defer { try? FileManager.default.removeItem(at: f.root) }
        try await f.index()
        let owner = try f.owner(), activity = Task { try await owner.run() }
        try await f.center.attachBackgroundDownloads(owner)
        let cache = try await f.center.downloadCache(using: .init(targetResolver: f.resolver, byteTransfer: NoForegroundDownload()))
        let request = Task { try await cache.download(.init(mediaID: f.media), message: f.message) }
        await f.driver.waitForHeldCreate()
        let job = try #require(try await f.store.managedResourceTransfers(.init()).entries.first)
        #expect(job.phase == .queued)
        try await f.center.cancelTransfer(job.id)
        #expect(try await f.store.managedResourceTransfers(.init()).entries.first?.phase == .cancelling)
        #expect(await f.scheduler.snapshot().active == 1)
        await f.driver.releaseHeldCreate()
        try await f.driver.waitForCancellation()
        #expect(try await f.store.managedResourceTransfers(.init()).entries.first?.phase == .cancelling)
        #expect(await f.scheduler.snapshot().active == 1)
        #expect(try await f.files.snapshot().backgroundReservedBytes == 2 * Int64(Fixture.bytes.count))
        await f.driver.finishDrain()
        try await f.waitForPhase(job.id, .cancelled)
        await #expect(throws: CancellationError.self) { _ = try await request.value }
        #expect(await f.scheduler.snapshot().active == 0)
        #expect(try await f.files.snapshot().backgroundReservedBytes == 0)
        await f.center.close(); _ = await activity.result; try await f.store.close()
    }

    @Test func resourceCenterRejectsAnotherIncarnationsNativeOwnerWithoutClosingThatOwner() async throws {
        let f = try await Fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let otherScope = V2AccountStorageScope(incarnation: UUID(), accountID: f.account,
            directory: f.root.appending(path: "another-incarnation"), cacheDirectory: f.root.appending(path: "another-cache"))
        let other = try await V2ResourceCenter.make(scope: otherScope, store: f.store)
        let owner = try f.owner()
        await #expect(throws: V2AccountStorageError.scopeMismatch) { try await other.attachBackgroundDownloads(owner) }
        try await f.center.attachBackgroundDownloads(owner)
        try await owner.initialize()
        await other.close(); await f.center.close(); try await f.store.close()
    }

    @Test(arguments: [V2NetworkWorkPriority.interactive, .background]) func nativeTransportUsesPersistedIntentPriorityInsteadOfAlwaysBackground(priority: V2NetworkWorkPriority) async throws {
        let f = try await Fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        try await f.index()
        try await f.center.setDownloadNetworkPreferences(.init(allowsCellular: true, allowsConstrained: true, automaticDownloads: .init(categories: [.file], maximumByteCount: 1024)))
        let owner = try f.owner(), activity = Task { try await owner.run() }
        let request = Task {
            try await V2NetworkWorkScope.$context.withValue(.init(service: "resources", priority: priority)) {
                try await owner.download(mediaID: f.media, message: f.message, initialTarget: f.target)
            }
        }
        try await f.driver.waitForResume()
        #expect(try await f.store.backgroundDownloads(accountID: f.account).first?.priority == priority)
        let state = await f.scheduler.snapshot()
        #expect(await f.driver.networkConstraints == [V2ResourceDownloadNetworkPreferences(allowsCellular: true, allowsConstrained: true).constraints(automatic: priority == .background)])
        #expect(state.activeDownloads == 1 && state.activeUploads == 0)
        #expect(state.activeBackgroundTransfers == (priority == .background ? 1 : 0))
        try await f.driver.finish()
        let raw = try await request.value
        let published = try await f.files.publishDownload(of: raw.fileURL, reservation: raw.reservation,
            byteCount: f.target.expectedByteCount, checksum: f.target.checksum)
        try await owner.didPublish(raw); await published.lease.release()
        await owner.close(); _ = await activity.result; await f.center.close(); try await f.store.close()
    }

    private struct Fixture {
        static let bytes = Data("background-file".utf8)
        let root: URL, session: UUID, account: UserID, media: MediaID, message: V2MediaMessageLocation
        let store: GRDBV2LocalSyncStore, scheduler: V2AccountWorkScheduler
        let target: V2ClientMediaTransferTarget, resolver: DownloadResolver, driver: DownloadDriver
        let inbox: V2BackgroundResultInbox
        let files: V2ResourceFileStore
        let center: V2ResourceCenter, scope: V2AccountStorageScope
        init(autoDrain: Bool = true, lifetime: TimeInterval = 60, holdCreate: Bool = false,
             schedulerConfiguration: V2AccountWorkScheduler.Configuration = .init(byteTransferLimit: 1)) async throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            session = UUID(); account = .init(uuid: UUID()); media = .init(uuid: UUID())
            message = .init(roomID: .init(uuid: UUID()), messageID: .init(uuid: UUID()))
            store = try .init(databaseURL: root.appendingPathComponent("db.sqlite"), installationBinding: .init(value: UUID()), userID: account)
            scheduler = .init(configuration: schedulerConfiguration)
            let now = Date(), expiry = now.addingTimeInterval(lifetime)
            let digest = try V2ResourceChecksum(value: SHA256.hash(data: Self.bytes).map { String(format: "%02x", $0) }.joined())
            target = try .init(downloadPlan: .init(mode: .httpGet, url: URL(string: "https://objects.invalid/download?cap=private")!,
                expiresAt: expiry, expectedByteCount: Int64(Self.bytes.count), checksum: digest,
                backgroundDownloadAuthorization: .init(id: UUID(), expectedByteCount: Int64(Self.bytes.count), checksum: digest, issuedAt: now, expiresAt: expiry)))
            scope = V2AccountStorageScope(incarnation: UUID(), accountID: account,
                directory: root.appending(path: "account"), cacheDirectory: root.appending(path: "cache"))
            center = try await .make(scope: scope, store: store)
            files = await center.files
            inbox = try .init(root: scope.backgroundDirectory.appendingPathComponent("downloads"), sessionID: session)
            resolver = .init(target: target)
            let boundStore = store, boundAccount = account, boundMedia = media
            driver = .init(inbox: inbox, byteInbox: .init(root: scope.backgroundDirectory, sessionID: session), autoDrain: autoDrain, bytes: Self.bytes, holdCreate: holdCreate) { id, task in
                guard let job = try? await boundStore.backgroundDownloads(accountID: boundAccount).first(where: {
                    if case .transferring(let value) = $0.state { return value.id == id && value.identifier == task }; return false
                }) else { return false }
                return job.mediaID == boundMedia
            }
        }
        func owner(resourceFiles: V2ResourceFileStore? = nil, now: @escaping @Sendable () -> Date = { Date() }) throws -> V2BackgroundDownloadCoordinator {
            let selected = resourceFiles ?? files
            return try .init(sessionID: session, accountID: account, store: store, scheduler: scheduler, resolver: resolver, driver: driver, files: selected, root: selected.backgroundDirectory, now: now)
        }
        func index() async throws {
            let descriptor = try V2ResourceDescriptor(key: .init(home: .room(message.roomID), mediaID: media), revision: 1,
                displayName: .init("native.bin"), contentType: "application/octet-stream", byteCount: target.expectedByteCount, checksum: target.checksum, state: .ready)
            try await store.indexResource(descriptor, reference: .message(message, ordinal: 0), businessRevision: 1)
        }
        func seedPaused() async throws -> UUID {
            let id = UUID()
            _ = try await store.beginBackgroundDownload(id: id, mediaID: media, message: message, accountID: account)
            try await store.bindBackgroundDownloadBytes(id: id, target: target, accountID: account)
            // Arrange the existing bounded-failure boundary. Tests above drive
            // five real driver failures; this helper isolates cold claim/auth.
            for _ in 0..<5 { try await store.failBackgroundDownloadPreparation(id: id, accountID: account) }
            return id
        }
        func waitForPhase(_ id: V2ManagedResourceTransferID, _ phase: V2ManagedResourceTransferPhase) async throws {
            let deadline = ContinuousClock.now + .seconds(20)
            while try await store.managedResourceTransfers(.init()).entries.first(where: { $0.id == id })?.phase != phase {
                if ContinuousClock.now >= deadline {
                    let observed = try await store.managedResourceTransfers(.init()).entries.map(\.phase)
                    let tasks = await driver.tasks(), created = await driver.createCount
                    let receipts = try inbox.results().map { ($0.statusCode,$0.errorCode,$0.receivedBytes) }
                    Issue.record("Expected \(phase); observed \(observed), nativeCreated=\(created), tasks=\(tasks), receipts=\(receipts)")
                    throw CancellationError()
                }
                try await Task.sleep(for: .milliseconds(10))
            }
        }
        func waitForBackgroundCleanup() async throws {
            let deadline = ContinuousClock.now + .seconds(10)
            while try await files.snapshot().backgroundReservedBytes != 0 {
                try #require(ContinuousClock.now < deadline)
                try await Task.sleep(for: .milliseconds(10))
            }
        }
    }
}


private actor DownloadResolver: V2ClientMediaDownloadTargetResolver {
    let target: V2ClientMediaTransferTarget
    var calls = 0, allowed = true
    var denied: Set<MediaID> = []
    var replacement: V2ClientMediaTransferTarget?
    private var holdNext = false, holding = false
    private var held: CheckedContinuation<Void, Never>?
    func replace(_ target: V2ClientMediaTransferTarget) { replacement = target }
    func holdNextResolution() { holdNext = true }
    func waitUntilHeld() async {
        var iterator = pulses.stream.makeAsyncIterator()
        while !holding { guard await iterator.next() != nil else { return } }
    }
    func releaseHeldResolution() { held?.resume(); held = nil; holding = false }
    let pulses = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    init(target: V2ClientMediaTransferTarget) { self.target = target }
    func deny() { allowed = false }
    func deny(_ media: MediaID) { denied.insert(media) }
    func waitForCalls(_ count: Int) async {
        var iterator = pulses.stream.makeAsyncIterator()
        while calls < count { guard await iterator.next() != nil else { return } }
    }
    func resolveDownloadTarget(mediaID: MediaID, message: V2MediaMessageLocation?) async throws -> V2ClientMediaTransferTarget {
        calls += 1; pulses.continuation.yield(())
        if holdNext {
            holdNext = false; holding = true; pulses.continuation.yield(())
            // Deliberately ignore cancellation to verify the real owner drain.
            await withCheckedContinuation { held = $0 }
        }
        guard allowed && !denied.contains(mediaID) else { throw V2ClientMediaTransferError.authorizationDenied }
        return replacement ?? target
    }
}

private actor NativeDownloadCloseWitness {
    private(set) var finished = false
    func finish() { finished = true }
}

private actor DownloadDriver: V2BackgroundDownloadSessionDriving, V2BackgroundProtectedDataChecking {
    private var holdsEnumeration = false
    private var heldEnumerations: [CheckedContinuation<Void, Never>] = []
    private let enumerationEvents = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    func holdEnumeration() { holdsEnumeration = true }
    func waitForHeldEnumeration() async { for await _ in enumerationEvents.stream { return } }
    func releaseEnumeration() {
        holdsEnumeration = false
        let pending = heldEnumerations; heldEnumerations.removeAll()
        for waiter in pending { waiter.resume() }
    }
    func setReceivedBytes(_ bytes: Int64) {
        actual = actual.map { .init(identifier: $0.identifier, mappingID: $0.mappingID, suspended: $0.suspended, receivedBytes: bytes) }
    }
    let inbox: V2BackgroundResultInbox
    let byteInbox: V2ResourceBackgroundDownloadInbox
    let autoDrain: Bool, bytes: Data
    let durable: @Sendable (UUID, Int) async -> Bool
    var actual: [V2BackgroundSystemTask] = []
    var wake: @Sendable () async -> Void = {}
    var networkConstraints: [V2ResourceDownloadNetworkConstraints] = []
    var createCount = 0, durableBeforeResume = false, resumed = false, cancelling = false
    let resumedEvents = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    let cancelEvents = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    private var drainFinished = false
    private var drainWaiters: [CheckedContinuation<Void, Never>] = []
    var origin: String?
    private var available = true
    private var holdCreate: Bool
    private var heldCreate: CheckedContinuation<Void, Never>?
    private let createEvents = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    func protectedDataAvailable() -> Bool { available }
    func setProtectedDataAvailable(_ value: Bool) async { available = value; await wake() }
    init(inbox: V2BackgroundResultInbox, byteInbox: V2ResourceBackgroundDownloadInbox, autoDrain: Bool, bytes: Data, holdCreate: Bool = false, durable: @escaping @Sendable (UUID, Int) async -> Bool) {
        self.inbox = inbox; self.byteInbox = byteInbox; self.autoDrain = autoDrain; self.bytes = bytes; self.durable = durable
        self.holdCreate = holdCreate
    }
    func tasks() async -> [V2BackgroundSystemTask] {
        if holdsEnumeration { await withCheckedContinuation { heldEnumerations.append($0); enumerationEvents.continuation.yield(()) } }
        return actual
    }
    func installWake(_ wake: @escaping @Sendable () async -> Void) { self.wake = wake }
    func create(target: V2ClientMediaTransferTarget, mappingID: UUID) async throws -> Int {
        let request = try V2BackgroundDownloadRequest.make(target: target)
        networkConstraints.append(.init(allowsCellular: request.allowsCellularAccess, allowsExpensive: request.allowsExpensiveNetworkAccess, allowsConstrained: request.allowsConstrainedNetworkAccess))
        guard try byteInbox.permit(mappingID).state == .prepared else { throw V2BackgroundTransferError.mappingConflict }
        createCount += 1; origin = V2BackgroundResultInbox.originDigest(target.url)
        let identifier = createCount
        actual.append(.init(identifier: identifier, mappingID: mappingID, suspended: true))
        if holdCreate {
            await withCheckedContinuation { heldCreate = $0; createEvents.continuation.yield(()) }
        }
        return identifier
    }
    func waitForHeldCreate() async { for await _ in createEvents.stream { return } }
    func releaseHeldCreate() { holdCreate = false; heldCreate?.resume(); heldCreate = nil }
    func resume(_ identifier: Int) async throws {
        guard let task = actual.first(where: { $0.identifier == identifier }), let id = task.mappingID else { throw V2BackgroundTransferError.mappingConflict }
        durableBeforeResume = await durable(id, identifier)
        let installed = try byteInbox.permit(id).state.identifier == identifier
        durableBeforeResume = durableBeforeResume && installed
        guard durableBeforeResume else { throw V2BackgroundTransferError.mappingConflict }
        actual = actual.map { $0.identifier == identifier ? .init(identifier: identifier, mappingID: id, suspended: false) : $0 }
        resumed = true; resumedEvents.continuation.yield(())
    }
    func waitForResume(_ count: Int = 1) async throws {
        var iterator = resumedEvents.stream.makeAsyncIterator()
        while !actual.contains(where: { $0.identifier >= count && !$0.suspended }) { guard await iterator.next() != nil else { throw CancellationError() } }
    }
    func waitForCancellation() async throws {
        var iterator = cancelEvents.stream.makeAsyncIterator()
        while !cancelling { guard await iterator.next() != nil else { throw CancellationError() } }
    }
    func finish() async throws {
        let tasks = actual; actual.removeAll()
        for task in tasks {
            let id = try #require(task.mappingID)
            let file = inbox.directory.appendingPathComponent("provider-\(UUID())")
            try bytes.write(to: file)
            try byteInbox.receive(file, mapping: id, identifier: task.identifier, origin: origin)
            try inbox.write(.init(mappingID: id, taskIdentifier: task.identifier, statusCode: 200, errorCode: nil, sentBytes: 0,
                originDigest: origin, receivedBytes: Int64(bytes.count)))
        }
        await wake()
    }
    func fail() async throws {
        let tasks = actual; actual.removeAll()
        for task in tasks {
            let id = try #require(task.mappingID)
            try inbox.write(.init(mappingID: id, taskIdentifier: task.identifier, statusCode: 503, errorCode: URLError.networkConnectionLost.rawValue,
                sentBytes: 0, originDigest: origin, receivedBytes: 0))
        }
        await wake()
    }
    func finishDrain() {
        drainFinished = true
        let pending = drainWaiters; drainWaiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
    func cancelAndDrain(_ identifiers: [Int]) async {
        guard actual.contains(where: { identifiers.contains($0.identifier) }) else { return }
        cancelling = true; cancelEvents.continuation.yield(())
        // Native URLSession wakes every waiter on the same completed task.
        // A single-consumer stream would strand a concurrent cleanup caller.
        if !autoDrain && !drainFinished { await withCheckedContinuation { drainWaiters.append($0) } }
        actual.removeAll { identifiers.contains($0.identifier) }
        await wake()
    }
}

private struct NoForegroundDownload: V2ClientMediaByteTransfer {
    func download(target: V2ClientMediaTransferTarget, destinationURL: URL) throws {
        throw V2BackgroundTransferError.unsupported
    }
}

private final class DownloadClock: Sendable {
    private let value = Mutex(Date())
    func read() -> Date { value.withLock { $0 } }
    func advance(_ seconds: TimeInterval) { value.withLock { $0 = $0.addingTimeInterval(seconds) } }
}
