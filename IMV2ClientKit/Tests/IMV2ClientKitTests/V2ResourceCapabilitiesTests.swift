import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import IMV2Core
@testable import IMV2ClientKit
import Testing

struct V2ResourceCapabilitiesTests {
    @Test("freezing a real attachment and its original dependency never waits for a capability or transport request")
    func freezesOfflineOriginalWithoutNetwork() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "offline-original-freeze-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let account = UserID(uuid: UUID()), room = RoomID(uuid: UUID())
        let store = try GRDBV2LocalSyncStore(databaseURL: root.appending(path: "V2.sqlite"),
            installationBinding: .init(value: UUID()), userID: account)
        let resources = try await makeResourceTestCenter(store: store, root: root)
        let source = root.appending(path: "offline.txt"); try Data("offline original".utf8).write(to: source)
        let asset = try await resources.importLocal(at: source, displayName: .init("offline.txt"), contentType: .init("text/plain"), purpose: .messageDraft(room))
        let reader = OfflineCapabilityReader()
        let engine = V2ResourceTransferEngine(store: store, control: NoFreezeTransport(), executor: NoFreezeTransport(),
            resources: resources, capabilities: .init(reader: reader))
        let jobID = UUID()
        let request = try V2ResourceUploadRequest(operationID: .init(uuid: UUID()), mediaID: .init(uuid: UUID()),
            usage: .messageAttachment(room), contentType: asset.contentType.value, byteCount: asset.byteCount,
            checksum: asset.checksum, displayName: asset.displayName)
        let intent = try V2SendIntent(id: UUID(), roomID: room, clientMessageID: .init(uuid: UUID()), text: "offline draft", attachmentJobIDs: [jobID])
        try await engine.prepareSend(intent, resources: [.init(id: jobID, request: request, localAssetID: asset.id)])
        #expect(await reader.reads == 0)
        #expect(try await store.preparingSendIntent(id: intent.id)?.clientMessageID == intent.clientMessageID)
        #expect(try await store.resourceTransfer(id: jobID)?.stage == .prepared)
        #expect(try await resources.selectedLocalAssets(purpose: .messageDraft(room)).isEmpty)
        let lease = try await resources.borrowLocalOriginal(for: .upload(jobID))
        #expect(try Data(contentsOf: lease.fileURL) == Data("offline original".utf8))
        await lease.release()
        await engine.close(); await resources.close(); try await store.close()
    }

    @Test func readsAuthenticatedBoundedCapabilityEndpoint() async throws {
        let endpoint=try #require(URL(string:"https://account.invalid/v2/resource-uploads"))
        let expected=try V2ResourceCapabilities(uploadModes:[.httpPut],maximumBytes:4096,allowedUsages:[.messageAttachment],maximumParts:0,backgroundTransfer:false)
        let transport=CapabilityHTTPTransport(body:try JSONEncoder().encode(expected))
        let client=try V2HTTPResourceUploadClient(endpoint:endpoint,credentials:CapabilityCredentials(),transport:transport)
        #expect(try await client.capabilities()==expected)
        let request=try #require(await transport.request)
        #expect(request.url?.path=="/v2/resource-capabilities")
        #expect(request.httpMethod=="GET" && request.httpBody==nil)
        #expect(request.value(forHTTPHeaderField:"Authorization")=="Bearer account-only")
        #expect(request.value(forHTTPHeaderField:"Cache-Control")=="no-store")
        #expect(request.timeoutInterval==5)
    }

    @Test func offlineCapabilityReadKeepsDraftAdmissionOpenAndBacksOff() async throws {
        let reader=OfflineCapabilityReader()
        let cache=V2ResourceCapabilitiesCache(reader:reader)
        try await cache.refreshIfNeeded()
        try await cache.refreshIfNeeded()
        #expect(await reader.reads==1)
        let request=try V2ResourceUploadRequest(operationID:.init(UUID().uuidString),mediaID:.init(UUID().uuidString),usage:.userAvatar,contentType:"image/png",byteCount:100,checksum:.init(value:String(repeating:"a",count:64)))
        try await cache.validateNewUpload(request)
        await cache.close()
        await #expect(throws:CancellationError.self) { try await cache.validateNewUpload(request) }
    }

    @Test func imageInputLimitPreservesTheLargerNonImageBudget() async throws {
        let capability = try V2ResourceCapabilities(uploadModes: [.httpPut], maximumBytes: 4096,
            allowedUsages: [.messageAttachment], maximumParts: 0, backgroundTransfer: false,
            maximumImageBytes: 2048)
        #expect(try JSONDecoder().decode(V2ResourceCapabilities.self, from: JSONEncoder().encode(capability)) == capability)
        let cache = V2ResourceCapabilitiesCache(reader: FixedCapabilityReader(value: capability))
        try await cache.refreshIfNeeded()
        func request(_ contentType: String) throws -> V2ResourceUploadRequest {
            try .init(operationID: .init(uuid: UUID()), mediaID: .init(uuid: UUID()),
                usage: .messageAttachment(.init(uuid: UUID())), contentType: contentType,
                byteCount: 2049, checksum: .init(value: String(repeating: "a", count: 64)))
        }
        await #expect(throws: V2ResourceCapabilityError.fileTooLarge(maximumBytes: 2048)) {
            try await cache.validateNewUpload(request("image/png"))
        }
        try await cache.validateNewUpload(request("application/octet-stream"))
    }
}

private struct NoFreezeTransport: V2ResourceUploadControlling, V2ResourcePlanExecuting {
    func create(_ request: V2ResourceUploadRequest) throws -> V2ResourceUploadSession { Issue.record("freeze issued create"); throw CancellationError() }
    func status(_ locator: V2ResourceUploadLocator) throws -> V2ResourceUploadSession { Issue.record("freeze issued status"); throw CancellationError() }
    func target(_ session: V2ResourceUploadSession) throws -> V2ResourceTransferPlan? { Issue.record("freeze issued target"); throw CancellationError() }
    func finalize(_ session: V2ResourceUploadSession) throws -> V2ResourceUploadSession { Issue.record("freeze issued finalize"); throw CancellationError() }
    func cancel(_ session: V2ResourceUploadSession) throws -> V2ResourceUploadSession { Issue.record("freeze issued cancel"); throw CancellationError() }
    func upload(fileURL: URL, plan: V2ResourceTransferPlan) throws { Issue.record("freeze issued byte upload"); throw CancellationError() }
}

private struct FixedCapabilityReader: V2ResourceCapabilityReading {
    let value: V2ResourceCapabilities
    func capabilities() async throws -> V2ResourceCapabilities { value }
}

private actor OfflineCapabilityReader:V2ResourceCapabilityReading {
    var reads=0
    func capabilities() throws -> V2ResourceCapabilities { reads += 1;throw URLError(.notConnectedToInternet) }
}
private struct CapabilityCredentials:V2ClientMediaEdgeCredentialProvider {
    func mediaEdgeCredentials() throws -> V2ClientMediaEdgeCredentials {
        .init(accessToken:"account-only",deviceID:try .init("00000000-0000-0000-0000-000000000001"))
    }
}
private actor CapabilityHTTPTransport:V2ClientMediaEdgeHTTPTransport {
    let body:Data
    var request:URLRequest?
    init(body:Data) {self.body=body}
    func data(for request:URLRequest) throws -> (Data,HTTPURLResponse) {
        self.request=request
        let url=try #require(request.url)
        return (body,try #require(HTTPURLResponse(url:url,statusCode:200,httpVersion:nil,headerFields:["Content-Type":"application/json"])))
    }
}
