import Foundation
import Testing
import Synchronization
@testable import IMApp
@testable import IMV2ClientKit

@MainActor
@Suite("Background opaque completion bridge")
struct V2BackgroundTransferBridgeTests {
    @Test func systemCompletionDoesNotRequireBusinessDatabaseAndRunsOnce() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let id=UUID(),identifier="imv2.background."+id.uuidString.lowercased()
        let inbox=try V2BackgroundResultInbox(root:root,sessionID:id)
        try inbox.write(.init(mappingID:UUID(),taskIdentifier:1,statusCode:200,errorCode:nil,sentBytes:4))
        var completed=0
        V2BackgroundTransferEvents.handle(identifier:identifier,root:root) { completed += 1 }
        // Serial delegate delivery calls this only after its opaque inbox write.
        // No account, credentials, unlocked SQLite or foreground runtime is opened.
        V2BackgroundTransferEvents.finished(identifier:identifier)
        V2BackgroundTransferEvents.finished(identifier:identifier)
        #expect(completed==1)
        #expect(try inbox.results().count==1)
        let driver=try V2NativeBackgroundSession.shared(sessionID:id,root:root)
        driver.invalidateAfterDrain()
    }
    @Test func productionWritersRequestSeparateExactProtectionPolicies() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let source=root.appendingPathComponent("import.png");try Data([1]).write(to:source)
        let writer=RecordingResourceProtectionWriter()
        let stager=try V2FileConversationAttachmentStager(directory:root.appendingPathComponent("staging"),protectionWriter:writer)
        let original=try await stager.stageImportedFile(at:source)
        let inbox=try V2BackgroundResultInbox(root:root.appendingPathComponent("handoff"),sessionID:UUID(),protectionWriter:writer),mapping=UUID()
        try inbox.write(.init(mappingID:mapping,taskIdentifier:1,statusCode:200,errorCode:nil,sentBytes:1))
        let file=inbox.directory.appendingPathComponent(mapping.uuidString+".result")
        #expect(writer.policy(at:original.fileURL) == .complete)
        #expect(writer.policy(at:inbox.directory) == .untilFirstAuthentication)
        #expect(writer.policy(at:file) == .untilFirstAuthentication)
        #expect(writer.policy(at:original.fileURL) == .complete)
        try await stager.close(preservingDurableFiles:true)
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
