import Foundation
import CryptoKit
import IMV2Core
import Testing
import Synchronization
@testable import IMApp
@testable import IMV2ClientKit

@MainActor
@Suite("Background opaque completion bridge", .timeLimit(.minutes(1)))
struct V2BackgroundTransferBridgeTests {
    @Test func retiredRouteDrainsOnlyAQuarantineSessionWithoutRecreatingAccountFiles() async throws {
        let container=FileManager.default.temporaryDirectory.appending(path:"retired-system-route-\(UUID())")
        defer { try? FileManager.default.removeItem(at:container) }
        let support=container.appending(path:"support"),root=support.appending(path:UUID().uuidString+".background")
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let id=UUID(),identifier="imv2.background.download."+id.uuidString.lowercased()
        let directory=try V2BackgroundSessionDirectory(directory:support.appending(path:"routes"),allowedRoot:support)
        try directory.register(session:id,kind:.download,root:root)
        try FileManager.default.removeItem(at:root)
        var completed=0
        V2BackgroundTransferEvents.handle(identifier:identifier,directory:directory,orphanRoot:container.appending(path:"orphans")) { completed += 1 }
        let deadline=ContinuousClock.now.advanced(by:.seconds(10))
        while completed==0 || V2NativeBackgroundSession.existing(identifier:identifier) != nil {
            try #require(ContinuousClock.now<deadline)
            await Task.yield()
        }
        #expect(completed==1)
        #expect(!FileManager.default.fileExists(atPath:root.path))
    }

    @Test func lateOwnerCannotFinishTheCurrentSystemCallback() throws {
        let container=FileManager.default.temporaryDirectory.appending(path:"system-route-owner-\(UUID())")
        defer { try? FileManager.default.removeItem(at:container) }
        let support=container.appending(path:"support"),root=support.appending(path:UUID().uuidString+".background")
        let id=UUID(),identifier="imv2.background."+id.uuidString.lowercased()
        _ = try V2BackgroundResultInbox(root:root,sessionID:id)
        let directory=try V2BackgroundSessionDirectory(directory:support.appending(path:"routes"),allowedRoot:support)
        let driver=try V2NativeBackgroundSession.shared(sessionID:id,root:root,locator:directory)
        var first=0,second=0
        V2BackgroundTransferEvents.handle(identifier:identifier,directory:directory,orphanRoot:container.appending(path:"orphans")) { first += 1 }
        V2BackgroundTransferEvents.handle(identifier:identifier,directory:directory,orphanRoot:container.appending(path:"orphans")) { second += 1 }
        #expect(first==1 && second==0)
        V2BackgroundTransferEvents.finished(identifier:identifier,owner:UUID())
        #expect(second==0)
        V2BackgroundTransferEvents.finished(identifier:identifier,owner:driver.eventOwnerID)
        V2BackgroundTransferEvents.finished(identifier:identifier,owner:driver.eventOwnerID)
        #expect(second==1)
        driver.invalidateAfterDrain()
    }

    @Test func systemCompletionDoesNotRequireBusinessDatabaseAndRunsOnce() throws {
        let container=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:container) }
        let support=container.appending(path:"support"),root=support.appending(path:UUID().uuidString+".background")
        let id=UUID(),identifier="imv2.background."+id.uuidString.lowercased()
        let inbox=try V2BackgroundResultInbox(root:root,sessionID:id)
        let directory=try V2BackgroundSessionDirectory(directory:support.appending(path:"routes"),allowedRoot:support)
        try directory.register(session:id,kind:.upload,root:root)
        try inbox.write(.init(mappingID:UUID(),taskIdentifier:1,statusCode:200,errorCode:nil,sentBytes:4))
        var completed=0
        V2BackgroundTransferEvents.handle(identifier:identifier,directory:directory,orphanRoot:container.appending(path:"orphans")) { completed += 1 }
        let driver=try V2NativeBackgroundSession.shared(sessionID:id,root:root,locator:directory)
        // Serial delegate delivery calls this only after its opaque inbox write.
        // No account, credentials, unlocked SQLite or foreground runtime is opened.
        V2BackgroundTransferEvents.finished(identifier:identifier,owner:driver.eventOwnerID)
        V2BackgroundTransferEvents.finished(identifier:identifier,owner:driver.eventOwnerID)
        #expect(completed==1)
        #expect(try inbox.results().count==1)
        driver.invalidateAfterDrain()
    }
    @Test func productionWritersRequestSeparateExactProtectionPolicies() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let source=root.appendingPathComponent("import.png");try Data([1]).write(to:source)
        let writer=RecordingResourceProtectionWriter()
        let fixture = try await V2OriginalResourceTestFixture(root: root, protection: writer)
        let stager = fixture.stager
        let original=try await stager.stageImportedFile(at:source, purpose: .personalAvatar)
        let lease = try await stager.borrow(.selection(original.localAssetID))
        let originalURL = lease.fileURL
        let inbox=try V2BackgroundResultInbox(root:root.appendingPathComponent("handoff"),sessionID:UUID(),protectionWriter:writer),mapping=UUID()
        try inbox.write(.init(mappingID:mapping,taskIdentifier:1,statusCode:200,errorCode:nil,sentBytes:1))
        let file=inbox.directory.appendingPathComponent(mapping.uuidString+".result")
        #expect(writer.policy(at:originalURL) == .complete)
        #expect(writer.policy(at:inbox.directory) == .untilFirstAuthentication)
        #expect(writer.policy(at:file) == .untilFirstAuthentication)
        #expect(writer.policy(at:originalURL) == .complete)
        await lease.release(); try await fixture.close()
    }
    @Test func downloadPermitAndReceivedBytesUseAFUWithoutRelaxingOriginalProtection() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "download-protection-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let writer = RecordingResourceProtectionWriter(), body = Data([1,2,3,4])
        let checksum = try V2ResourceChecksum(value: SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined())
        let now = Date(), grant = try V2ResourceBackgroundDownloadAuthorization(id: UUID(), expectedByteCount: 4,
            checksum: checksum, issuedAt: now, expiresAt: now.addingTimeInterval(60))
        let session = UUID(), mapping = UUID(), origin = String(repeating: "a", count: 64)
        let background = root.appending(path: "account.background")
        let inbox = V2ResourceBackgroundDownloadInbox(root: background, sessionID: session, protection: writer)
        try inbox.prepare(reservation: UUID(), mapping: mapping, grant: grant, origin: origin)
        let permit = inbox.directory.appending(path: mapping.uuidString + ".permit")
        try inbox.install(mapping: mapping, identifier: 1)
        let original = root.appending(path: "original"), provider = root.appending(path: "provider")
        try body.write(to: original); try body.write(to: provider)
        writer.apply(.complete, to: original)
        try inbox.receive(provider, mapping: mapping, identifier: 1, origin: origin)
        let received = inbox.fileURL(mapping)
        #expect(writer.policy(at: original) == .complete)
        #expect(writer.policy(at: background) == .untilFirstAuthentication)
        #expect(writer.policy(at: permit) == .untilFirstAuthentication)
        #expect(writer.policy(at: received) == .untilFirstAuthentication)
        #expect(try received.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
        #expect(try Data(contentsOf: received) == body)
        try inbox.discard(mapping)
    }

    #if !targetEnvironment(simulator)
    @Test func physicalDeviceProtectionAttributesKeepOriginalAndInboxSeparate() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let source=root.appendingPathComponent("original");try Data([1]).write(to:source)
        try V2SystemResourceFileProtectionWriter().apply(.complete,to:source)
        let inbox=try V2BackgroundResultInbox(root:root,sessionID:UUID()),mapping=UUID()
        try inbox.write(.init(mappingID:mapping,taskIdentifier:1,statusCode:200,errorCode:nil,sentBytes:1))
        let file=inbox.directory.appendingPathComponent(mapping.uuidString+".result")
        let original=try FileManager.default.attributesOfItem(atPath:source.path)[.protectionKey]
        let handoff=try FileManager.default.attributesOfItem(atPath:file.path)[.protectionKey]
        let originalRaw=(original as? FileProtectionType)?.rawValue ?? (original as? String)
        let handoffRaw=(handoff as? FileProtectionType)?.rawValue ?? (handoff as? String)
        #expect(originalRaw == FileProtectionType.complete.rawValue)
        #expect(handoffRaw == FileProtectionType.completeUntilFirstUserAuthentication.rawValue)
    }
    #endif
}
private final class RecordingResourceProtectionWriter:V2ResourceFileProtectionWriting {
    private let values=Mutex<[String:V2ResourceFileProtection]>([:])
    func apply(_ protection:V2ResourceFileProtection,to file:URL) { values.withLock { $0[file.path]=protection } }
    func policy(at file:URL) -> V2ResourceFileProtection? { values.withLock { $0[file.path] } }
}
