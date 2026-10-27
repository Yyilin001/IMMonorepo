import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Crypto
import IMV2Core
import Testing
@testable import IMV2ClientKit

@Suite("Upload plans stay bound to frozen modes and actual bytes", .timeLimit(.minutes(1)))
struct V2UploadPlanAdmissionTests {
    enum Invalid: CaseIterable, Sendable {
        case wholeSize, wholeChecksum, unnegotiatedPart, unnegotiatedWhole, outsideRange, downloadMode, expired, partChecksum
        var error: V2ClientMediaTransferError {
            switch self { case .expired: .targetExpired; case .partChecksum: .checksumMismatch; default: .invalidTarget }
        }
    }
    enum Valid: CaseIterable, Sendable { case whole, part, partWithoutDigest }
    enum Background: CaseIterable, Sendable { case valid, wrongDigest, unnegotiated }

    @Test(arguments: Invalid.allCases)
    func invalidPlansDoNotReachTheByteExecutorOrLoseTheOriginal(scenario: Invalid) async throws {
        let f = try await Fixture(invalid: scenario)
        _ = try await f.engine.resume(id: f.job)
        await #expect(throws: scenario.error) { try await f.engine.resume(id: f.job) }
        #expect(await f.executor.payloads.isEmpty)
        #expect(try await f.store.resourceTransfer(id: f.job)?.request == f.request)
        #expect(try await f.store.resourceTransfer(id: f.job)?.stage != .ready)
        try await f.verifyOriginalAndNoTemporaryReservation()
        try await f.close()
    }

    @Test(arguments: Valid.allCases)
    func validPlansSendExactWholeOrSliceBytesAndReleaseTemporaryCapacity(scenario: Valid) async throws {
        let f = try await Fixture(valid: scenario)
        _ = try await f.engine.resume(id: f.job); _ = try await f.engine.resume(id: f.job)
        #expect(await f.executor.payloads == [scenario == .whole ? Fixture.bytes : Fixture.part])
        #expect(try await f.store.resourceTransfer(id: f.job)?.nextAction == (scenario == .whole ? .finalize : .status))
        try await f.verifyOriginalAndNoTemporaryReservation()
        try await f.close()
    }

    @Test(arguments: [false, true])
    func putOnlyRequestAcceptsWholeBackgroundButRejectsPartPlan(wholeBackground: Bool) async throws {
        let f = try await Fixture(valid: .whole, wholeBackground: wholeBackground), driver = PlanDriver()
        try await f.capabilities.refreshIfNeeded()
        #expect(await f.capabilities.allowsBackground())
        let background = try await f.background(driver)
        try await f.engine.attachBackground(background)
        _ = try await f.engine.resume(id: f.job)
        if wholeBackground {
            _ = try await f.engine.resume(id: f.job)
            #expect(await driver.payloads == [Fixture.bytes])
            #expect(try await f.store.resourceTransfer(id: f.job)?.nextAction == .awaitingBackground)
        } else {
            await #expect(throws: V2ClientMediaTransferError.invalidTarget) { try await f.engine.resume(id: f.job) }
            #expect(await driver.payloads.isEmpty)
        }
        #expect(await f.control.foregroundCalls == 0)
        #expect(await f.control.backgroundCalls == 1)
        #expect(await f.executor.payloads.isEmpty)
        await background.close()
        try await f.verifyOriginalAndNoTemporaryReservation()
        try await f.close()
    }

    @Test(arguments: Background.allCases)
    func backgroundChecksModeAndDigestBeforeCreatingASystemTask(scenario: Background) async throws {
        let f = try await Fixture(valid: scenario == .unnegotiated ? .whole : .part), driver = PlanDriver()
        let created = try await f.engine.resume(id: f.job), session = try #require(created.session)
        let background = try await f.background(driver)
        try await background.initialize()
        let owner = UUID(), claimed = try #require(try await f.store.claimResourceStep(id: f.job, owner: owner, now: Date()))
        let source = try await f.center.borrowLocalOriginal(for: .upload(f.job))
        let expiry = Date().addingTimeInterval(120)
        let grant = try V2ResourceBackgroundAuthorization(id: UUID(), sessionID: session.locator.sessionID, generation: session.generation,
            mediaID: f.request.mediaID, partNumber: 1, issuedAt: Date(), expiresAt: expiry)
        let plan = try V2ResourceTransferPlan(mode: .httpPartPut, url: #require(URL(string: "https://bytes.invalid/part")), expiresAt: expiry,
            expectedByteCount: 4, byteRange: .init(lowerBound: 0, upperBound: 3), partNumber: 1,
            checksum: scenario == .wrongDigest ? Fixture.wrongDigest : Fixture.digest(Fixture.part), backgroundAuthorization: grant)
        if scenario == .wrongDigest {
            await #expect(throws: V2ClientMediaTransferError.checksumMismatch) {
                try await background.enqueue(job: claimed, resourceOwner: owner, plan: plan, source: source)
            }
        } else if scenario == .unnegotiated {
            await #expect(throws: V2BackgroundTransferError.invalidAuthorization) {
                try await background.enqueue(job: claimed, resourceOwner: owner, plan: plan, source: source)
            }
        } else { try await background.enqueue(job: claimed, resourceOwner: owner, plan: plan, source: source) }
        if scenario != .valid {
            #expect(await driver.payloads.isEmpty)
            #expect(try await f.center.storageSnapshot().backgroundReservedBytes == 0)
        } else {
            #expect(await driver.payloads == [Fixture.part])
        }
        await source.release(); await background.close()
        try await f.verifyOriginalAndNoTemporaryReservation()
        try await f.close()
    }

    private struct Fixture {
        static let bytes = Data([1,2,3,4,5,6,7,8]), part = Data([1,2,3,4])
        static var wrongDigest: V2ResourceChecksum { get throws { try .init(value: String(repeating: "f", count: 64)) } }
        static func digest(_ data: Data) throws -> V2ResourceChecksum {
            try .init(value: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
        }
        let root = FileManager.default.temporaryDirectory.appending(path: "upload-plan-\(UUID())")
        let job = UUID()
        let request: V2ResourceUploadRequest
        let store: GRDBV2LocalSyncStore
        let center: V2ResourceCenter
        let engine: V2ResourceTransferEngine
        let control: PlanControl
        let executor = PlanExecutor()
        let capabilities = V2ResourceCapabilitiesCache(reader: PlanCapabilities())
        init(invalid: Invalid? = nil, valid: Valid = .whole, wholeBackground: Bool = false) async throws {
            let room = RoomID(uuid: UUID()), user = UserID(uuid: UUID())
            let partMode = [.unnegotiatedWhole, .outsideRange, .partChecksum].contains(invalid) || (invalid == nil && valid != .whole)
            request = try .init(operationID: .init(uuid: UUID()), mediaID: .init(uuid: UUID()), usage: .messageAttachment(room),
                contentType: "application/octet-stream", byteCount: 8, checksum: Self.digest(Self.bytes),
                clientModes: [partMode ? .httpPartPut : .httpPut], displayName: .init("source.bin"))
            store = try .init(databaseURL: root.appending(path: "V2.sqlite"), installationBinding: .init(value: UUID()), userID: user)
            center = try await makeResourceTestCenter(store: store, root: root)
            let asset = try await center.importLocal(data: Self.bytes, displayName: request.displayName,
                contentType: .init(request.contentType), purpose: .messageDraft(room))
            let isPart = [.unnegotiatedPart, .outsideRange, .partChecksum].contains(invalid) || (invalid == nil && valid != .whole)
            let range: V2ResourceByteRange? = isPart ? try .init(lowerBound: 0, upperBound: invalid == .outsideRange ? 8 : 3) : nil
            let plan = try V2ResourceTransferPlan(mode: invalid == .downloadMode ? .httpGet : isPart ? .httpPartPut : .httpPut,
                url: #require(URL(string: "https://bytes.invalid/upload")), expiresAt: invalid == .expired ? .distantPast : .distantFuture,
                expectedByteCount: range?.byteCount ?? (invalid == .wholeSize ? 9 : 8), byteRange: range, partNumber: isPart ? 1 : nil,
                checksum: [.wholeChecksum, .partChecksum].contains(invalid) ? Self.wrongDigest : (isPart ? (valid == .partWithoutDigest ? nil : Self.digest(Self.part)) : Self.digest(Self.bytes)))
            let background = try V2ResourceTransferPlan(mode: .httpPartPut, url: #require(URL(string: "https://bytes.invalid/background")),
                expiresAt: .distantFuture, expectedByteCount: 4, byteRange: .init(lowerBound: 0, upperBound: 3), partNumber: 1)
            control = try PlanControl(request: request, plan: plan, background: background, wholeBackground: wholeBackground)
            engine = .init(store: store, control: control, executor: executor, resources: center, capabilities: capabilities)
            _ = try await engine.prepare(id: job, request: request, localAssetID: asset.id)
            try await store.freezeSendIntent(.init(id: UUID(), roomID: room, clientMessageID: .init(uuid: UUID()), text: "frozen", attachmentJobIDs: [job]))
        }
        func background(_ driver: PlanDriver) async throws -> V2BackgroundTransferCoordinator {
            let id = try await store.backgroundSessionID(), files = await center.files
            return try .init(sessionID: id, activationID: UUID(), store: store, scheduler: .init(), driver: driver,
                files: files, root: files.backgroundDirectory)
        }
        func verifyOriginalAndNoTemporaryReservation() async throws {
            let source = try await center.borrowLocalOriginal(for: .upload(job))
            let actual = try Data(contentsOf: source.fileURL); await source.release()
            #expect(actual == Self.bytes)
            #expect(try await store.preparingSendIntents().count == 1)
            #expect(try await store.resourceSendPayloads().isEmpty)
            #expect(try await center.storageSnapshot().quota.temporaryReservedBytes == 0)
        }
        func close() async throws { await engine.close(); await center.close(); try await store.close(); try FileManager.default.removeItem(at: root) }
    }
}

private actor PlanControl: V2BackgroundResourceUploadControlling {
    let session: V2ResourceUploadSession
    let plan: V2ResourceTransferPlan, background: V2ResourceTransferPlan
    var foregroundCalls = 0, backgroundCalls = 0
    init(request: V2ResourceUploadRequest, plan: V2ResourceTransferPlan, background: V2ResourceTransferPlan, wholeBackground: Bool) throws {
        session = try .init(locator: .init(home: request.usage.home(actorUserID: .init(uuid: UUID())), sessionID: .init(uuid: UUID())),
            mediaID: request.mediaID, generation: 1, state: .created, resourceState: .pending, expiresAt: .distantFuture)
        self.plan = plan
        if wholeBackground {
            let now = Date(), expiry = now.addingTimeInterval(120)
            let grant = try V2ResourceBackgroundAuthorization(id: UUID(), sessionID: session.locator.sessionID,
                generation: session.generation, mediaID: request.mediaID,
                scope: .whole(byteCount: request.byteCount, checksum: request.checksum), issuedAt: now, expiresAt: expiry)
            self.background = try .init(mode: .httpPut, url: background.url, expiresAt: expiry,
                expectedByteCount: request.byteCount, checksum: request.checksum, backgroundAuthorization: grant)
        } else { self.background = background }
    }
    func create(_ request: V2ResourceUploadRequest) -> V2ResourceUploadSession { session }
    func status(_ locator: V2ResourceUploadLocator) -> V2ResourceUploadSession { session }
    func target(_ session: V2ResourceUploadSession) -> V2ResourceTransferPlan? { foregroundCalls += 1; return plan }
    func backgroundTarget(_ session: V2ResourceUploadSession) -> V2ResourceTransferPlan? { backgroundCalls += 1; return background }
    func finalize(_ session: V2ResourceUploadSession) throws -> V2ResourceUploadSession { throw V2ResourceJournalError.invalidRecord }
    func cancel(_ session: V2ResourceUploadSession) throws -> V2ResourceUploadSession { throw V2ResourceJournalError.invalidRecord }
}
private actor PlanExecutor: V2ResourcePlanExecuting {
    var payloads: [Data] = []
    func upload(fileURL: URL, plan: V2ResourceTransferPlan) throws { payloads.append(try Data(contentsOf: fileURL)) }
}
private struct PlanCapabilities: V2ResourceCapabilityReading {
    func capabilities() throws -> V2ResourceCapabilities {
        try .init(uploadModes: [.httpPut,.httpPartPut], maximumBytes: 1024, allowedUsages: [.messageAttachment], maximumParts: 32, backgroundTransfer: true)
    }
}
private actor PlanDriver: V2BackgroundSessionDriving {
    var payloads: [Data] = []
    var live: [V2BackgroundSystemTask] = []
    func tasks() -> [V2BackgroundSystemTask] { live }
    func create(request: URLRequest, file: URL, mappingID: UUID) throws -> Int {
        payloads.append(try Data(contentsOf: file)); let id = payloads.count
        live.append(.init(identifier: id, mappingID: mappingID, suspended: true)); return id
    }
    func resume(_ identifier: Int) { }
    func cancelAndDrain(_ identifiers: [Int]) { live.removeAll { identifiers.contains($0.identifier) } }
    func installWake(_ wake: @escaping @Sendable () async -> Void) { }
}
