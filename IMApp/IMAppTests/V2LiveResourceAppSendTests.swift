import Foundation
import IMV2Core
import Network
import Security
import Synchronization
import Testing
import UIKit
@testable import IMV2ClientKit
@testable import IMApp

/// Opt-in, owned-stack test. No real account, default database or Keychain is used.
@MainActor
@Suite("Live iOS resource send closure", .serialized, .timeLimit(.minutes(3)),
       .enabled(if: ProcessInfo.processInfo.environment["IMV2_LIVE_APP_RESOURCES"] == "1"))
struct V2LiveResourceAppSendTests {
    @Test(arguments: [false, true])
    func appAccountRecoversFrozenImageAndFileAndRecipientReadsBoth(nativeBackground: Bool) async throws {
        let fixture = try AppResourceFixture(); defer { fixture.http.invalidateAndCancel() }
        let author = try await fixture.register(), recipient = try await fixture.register()
        let room = try await fixture.room(author: author.userID, recipient: recipient.userID)
        let connection = try fixture.connection()
        let authenticated = try await connection.connectAndAuthenticate(accessToken: author.accessToken, deviceID: author.deviceID, supportedCapabilityProfiles: ["base"])
        let transport = V2ProtobufSyncTransport(wire: connection, protocolVersion: authenticated.protocolVersion)
        let root = FileManager.default.temporaryDirectory.appending(path: "live-app-resource-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let incarnation = UUID()
        let scope = V2AccountStorageScope(incarnation: incarnation, accountID: author.userID,
            directory: root.appending(path: incarnation.uuidString), cacheDirectory: root.appending(path: "cache"))
        let binding = V2LocalInstallationBinding(value: UUID()), database = root.appending(path: "account.sqlite")
        let credentials = AppResourceCredentials(value: author)
        let http = V2URLSessionMediaEdgeHTTPTransport(session: fixture.http)
        let upload = try V2HTTPResourceUploadClient(endpoint: fixture.url("v2/resource-uploads"), credentials: credentials, transport: http)
        let groupClient = try V2HTTPGroupAvatarCommandClient(roomsEndpoint: fixture.url("v2/groups"), actorUserID: author.userID, credentials: credentials, transport: http)
        let diagnostics = V2NetworkDiagnostics()
        let imports = try V2HTTPResourceImportClient(endpoint: fixture.url("v2/resource-imports"), credentials: credentials, transport: http)
        func open() async throws -> (GRDBV2LocalSyncStore, V2ResourceCenter, V2ResourceTransferEngine, V2DurableConversationSendService, V2OperationWorkDispatcher, V2BackgroundTransferCoordinator?) {
            let store = try GRDBV2LocalSyncStore(databaseURL: database, installationBinding: binding, userID: author.userID)
            let center = try await V2ResourceCenter.make(scope: scope, store: store)
            let engine = V2ResourceTransferEngine(store: store, control: upload, executor: V2URLSessionResourcePlanExecutor(session: fixture.http),
                resources: center, capabilities: .init(reader: upload))
            var background: V2BackgroundTransferCoordinator?
            if nativeBackground {
                let id = try await store.backgroundSessionID(), files = await center.files
                let locator = try V2BackgroundSessionDirectory(directory: root.appending(path: "routes"), allowedRoot: root)
                let driver = try V2NativeBackgroundSession.shared(sessionID: id, root: files.backgroundDirectory, locator: locator)
                let coordinator = try V2BackgroundTransferCoordinator(sessionID: id, activationID: UUID(), store: store,
                    scheduler: .init(), driver: driver, files: files, root: files.backgroundDirectory, diagnostics: diagnostics)
                try await engine.attachBackground(coordinator)
                background = coordinator
            }
            try await center.attachUploads(engine)
            let messages = V2MessageSendOperationService(accountID: author.userID, store: store, client: V2ProtobufMessageSendOperationClient(transport: transport, connection: connection))
            let groups = V2GroupAvatarIntentEngine(actorUserID: author.userID, store: store, transfers: engine, submissions: groupClient)
            let sender = V2DurableConversationSendService(store: store, engine: engine, resources: center, messageOperations: messages, imports: imports, groupAvatars: groups)
            let dispatcher = V2OperationWorkDispatcher(store: store, handlers: [.init(kind: .sendMessage) { try await messages.execute($0) }])
            return (store, center, engine, sender, dispatcher, background)
        }
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 16, height: 16), format: format).pngData { context in
            UIColor.blue.setFill(); context.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
        }
        let file = nativeBackground ? Data(repeating: 65, count: 9 * 1_024 * 1_024) : Data("A real file frozen by the iOS App send service".utf8)
        let initial = try await open()
        let stager = V2FileConversationAttachmentStager(resources: initial.1)
        let source = root.appending(path: "notes.txt"); try file.write(to: source)
        let frozen: V2SendIntent
        do {
            let photo = try await stager.stageNormalizedPhoto(.init(data: image, format: .png), purpose: .messageDraft(room))
            let document = try await stager.stageImportedFile(at: source, purpose: .messageDraft(room))
            try await initial.3.freezeSend(text: "iOS persisted multi-attachment", mentions: [], replyTo: nil, roomID: room,
                attachments: [photo, document])
            frozen = try #require(try await initial.0.preparingSendIntents(in: room).first)
            #expect(try await initial.3.pending(in: room).count == 1)
            #expect(try await initial.0.dueOperationWork(now: Date(), kinds: [.sendMessage]).isEmpty)
            await stager.close(); await initial.3.close(); await initial.1.close(); try await initial.0.close()
        } catch {
            await stager.close(); await initial.3.close(); await initial.1.close(); try? await initial.0.close(); await connection.disconnect(); throw error
        }
        let restored = try await open(), runtime = V2AccountRuntime()
        do {
            #expect(try await restored.0.preparingSendIntents(in: room) == [frozen])
            if let background = restored.5 {
                let id = try #require(frozen.attachmentJobIDs.last)
                _ = try await restored.2.resume(id: id) // Allocate the original upload session.
                _ = try await restored.2.resume(id: id) // Delegate the actual file to the OS.
                #expect(try await restored.0.resourceTransfer(id: id)?.nextAction == .awaitingBackground)
                let sessionID = try await restored.0.backgroundSessionID()
                let mappings = try await restored.0.activeBackgroundMappings(session: sessionID)
                let mapping = try #require(mappings.first { $0.jobID == id })
                #expect(mapping.partNumber == nil && mapping.expectedBytes == Int64(file.count))
                await runtime.startActivity(id: "systemBackgroundUploads") { try await background.run() }
            }
            await runtime.startActivity(id: "resourceTransfers") { try await restored.2.runRecovery() }
            await runtime.startActivity(id: "resourcePreparation") { try await restored.3.runRecovery() }
            await runtime.startActivity(id: "operationDispatcher") { try await restored.4.run() }
            let deadline = ContinuousClock.now + .seconds(90)
            var accepted: V2SubmittedSendIntent?
            var diagnosedReceipts: UInt64 = 0
            while accepted == nil {
                try #require(ContinuousClock.now < deadline)
                accepted = try await restored.0.submittedSendIntents(in: room).first
                if accepted?.status != .acceptedAwaitingProjection { accepted = nil }
                if accepted == nil {
                    if diagnostics.snapshot().backgroundRecorded != diagnosedReceipts {
                        diagnosedReceipts = diagnostics.snapshot().backgroundRecorded
                        let metrics = diagnostics.snapshot().backgrounds
                        print("Native background diagnostics: " + metrics.map {
                            "status=\(String(describing: $0.statusCode)),error=\(String(describing: $0.errorCode)),sent=\(String(describing: $0.bodyBytesSent)),observed=\($0.completionObserved)"
                        }.joined(separator: ";"))
                    }
                    try await Task.sleep(for: .milliseconds(100))
                }
            }
            let page = try await transport.pullGroupEvents(roomID: room, afterRoomSequence: 0, pageSize: 100)
            _ = try await restored.0.applyGroupEventPage(page)
            let messages = try await restored.0.messages(in: room)
            let message = try #require(messages.first { $0.text == frozen.text })
            #expect(messages.filter { $0.text == frozen.text }.count == 1)
            #expect(message.media.count == 2)
            #expect(try await restored.3.pending(in: room).isEmpty)
            #expect(try await restored.0.resourceDirectory(roomID: room).entries.count == 2)
            let recipientRoot = root.appending(path: "recipient")
            let receiverStore = try GRDBV2LocalSyncStore(databaseURL: recipientRoot.appending(path: "account.sqlite"), installationBinding: .init(value: UUID()), userID: recipient.userID)
            let receiver = try await V2ResourceCenter.make(scope: .init(incarnation: UUID(), accountID: recipient.userID,
                directory: recipientRoot.appending(path: "support"), cacheDirectory: recipientRoot.appending(path: "cache")), store: receiverStore)
            do {
                let reader = AppResourceCredentials(value: recipient)
                let directory = try V2HTTPRoomResourceDirectoryClient(baseURL: fixture.url(""), credentials: reader, transport: http)
                let remotePage = try #require(try await receiver.synchronize(roomID: room, query: .init(), using: directory))
                #expect(remotePage.items.count == 2)
                let resolver = try V2HTTPMediaDownloadTargetResolver(endpoint: fixture.url("v2/media"), credentials: reader, transport: http)
                let downloads = try await receiver.downloadCache(using: .init(targetResolver: resolver, byteTransfer: V2URLSessionMediaByteTransfer(session: fixture.http)))
                for item in remotePage.items {
                    let source = V2MediaMessageLocation(roomID: room, messageID: message.messageID)
                    let resource = try await downloads.download(.init(mediaID: item.descriptor.key.mediaID), message: source)
                    let lease = try await resource.borrowFile()
                    let bytes = try Data(contentsOf: lease.fileURL); await lease.release()
                    #expect(bytes == (item.descriptor.contentType == "image/png" ? image : file))
                    if item.descriptor.contentType == "image/png" { #expect(item.descriptor.pixelWidth == 16 && item.descriptor.pixelHeight == 16) }
                }
                await receiver.close(); try await receiverStore.close()
            } catch { await receiver.close(); try? await receiverStore.close(); throw error }
            await runtime.close(); await restored.4.stopAndDrain(); await restored.3.close(); await restored.1.close(); try await restored.0.close()
            await connection.disconnect()
            print("Live iOS resource send: frozen image+file, local pending, account reopen, real runtime activities, single TLS projection and independent recipient bytes passed. Native background: \(nativeBackground).")
        } catch {
            await runtime.close(); await restored.4.stopAndDrain(); await restored.3.close(); await restored.1.close(); try? await restored.0.close(); await connection.disconnect(); throw error
        }
    }
}

private struct AppResourceCredentials: V2ClientMediaEdgeCredentialProvider {
    let value: V2AuthCredentials
    func mediaEdgeCredentials() -> V2ClientMediaEdgeCredentials { .init(accessToken: value.accessToken, deviceID: value.deviceID) }
}
private final class AppResourceFixturePersistence: V2IssuedCredentialRecoveryPersisting, V2DeviceRevocationPersisting {
    private let data = Mutex<Data?>(nil)
    func load() -> Data? { data.withLock { $0 } }
    func save(_ value: Data) { data.withLock { $0 = value } }
    func delete() { data.withLock { $0 = nil } }
}
private struct AppResourceFixture {
    let base: URL, anchor: Data
    let http: URLSession
    init() throws {
        let env = ProcessInfo.processInfo.environment
        let rawBase = try #require(env["IMV2_LIVE_ACCOUNT_HTTPS_URL"])
        base = try #require(URL(string: rawBase))
        try #require(base.scheme == "https" && base.host == "localhost")
        let encodedAnchor = try #require(env["IMV2_LIVE_RESOURCE_CA_BASE64"])
        anchor = try #require(Data(base64Encoded: encodedAnchor))
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil; config.urlCache = nil; config.urlCredentialStorage = nil
        config.timeoutIntervalForRequest = 10; config.timeoutIntervalForResource = 20
        http = URLSession(configuration: config, delegate: AppResourceFixtureTrust(anchor: anchor), delegateQueue: nil)
    }
    func url(_ path: String) -> URL { base.appendingPathComponent(path) }
    func register() async throws -> V2AuthCredentials {
        let suffix = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(20))
        let device = DeviceID(uuid: UUID())
        let auth = try V2HTTPPasswordAccountAuthenticator(registrationEndpoint: url("v2/account-auth/password/register"),
            assertionEndpoint: url("v2/account-auth/password/assertion"), transport: V2URLSessionAuthHTTPTransport(session: http))
        let assertion = try await auth.register(accountHandle: "app_" + suffix, password: "local-app-resource-password",
            publicHandle: "app" + suffix, displayName: "iOS resource test", deviceID: device)
        let identity = AppResourceFixtureIdentity(assertion: assertion.value, device: device)
        let recovery = V2IssuedCredentialRecoveryStore(persistence: AppResourceFixturePersistence(),
            revocations: V2DeviceRevocationStore(persistence: AppResourceFixturePersistence()))
        let issuer = try V2HTTPAccountAssertionDeviceCredentialProvider(issueEndpoint: url("v2/device-credentials"), assertionProvider: identity,
            deviceIdentityProvider: identity, operationStore: AppResourceFixtureRegistrationStore(), recovery: recovery,
            transport: V2URLSessionAuthHTTPTransport(session: http))
        let credentials = try await issuer.issueDeviceCredentials()
        try await issuer.finalizeIssuedDeviceCredentials(credentials)
        return credentials
    }
    func room(author: UserID, recipient: UserID) async throws -> RoomID {
        var request = URLRequest(url: url("__fixture__/room")); request.httpMethod = "POST"
        request.setValue(try #require(ProcessInfo.processInfo.environment["IMV2_LIVE_RESOURCE_FIXTURE_TOKEN"]), forHTTPHeaderField: "X-Resource-Fixture")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["viewer": recipient.rawValue, "author": author.rawValue])
        let (data, response) = try await http.data(for: request)
        try #require((response as? HTTPURLResponse)?.statusCode == 200)
        return try RoomID(#require(JSONDecoder().decode([String: String].self, from: data)["roomID"]))
    }
    func connection() throws -> V2TLSFrameConnection {
        let environment = ProcessInfo.processInfo.environment
        let port = try #require(environment["IMV2_LIVE_RESOURCE_GATEWAY_PORT"].flatMap(UInt16.init).flatMap(NWEndpoint.Port.init(rawValue:)))
        let ca = anchor
        return V2TLSFrameConnection(connectionFactory: {
            let tls = NWProtocolTLS.Options()
            sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv13)
            sec_protocol_options_set_max_tls_protocol_version(tls.securityProtocolOptions, .TLSv13)
            sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, protocolTrust, complete in
                let trust = sec_trust_copy_ref(protocolTrust).takeRetainedValue()
                guard let anchor = SecCertificateCreateWithData(nil, ca as CFData),
                      SecTrustSetAnchorCertificates(trust, [anchor] as CFArray) == errSecSuccess,
                      SecTrustSetAnchorCertificatesOnly(trust, true) == errSecSuccess,
                      SecTrustSetPolicies(trust, SecPolicyCreateSSL(true, "localhost" as CFString)) == errSecSuccess,
                      SecTrustEvaluateWithError(trust, nil) else { complete(false); return }
                complete(true)
            }, .global(qos: .utility))
            let network = NWConnection(host: "localhost", port: port, using: NWParameters(tls: tls, tcp: .init()))
            return V2NetworkTLSByteConnection(connection: network, queue: .global(qos: .utility))
        }, frameLimits: try .init(maximumPayloadBytes: 65_536, acceptedVersions: [0, UInt8(IMV2ProtocolVersion.current)]),
           requestTimeout: .seconds(10), supportsAuthorPresentationDelta: false)
    }

}

private final class AppResourceFixtureTrust: NSObject, URLSessionDelegate {
    let anchor: Data
    init(anchor: Data) { self.anchor = anchor }
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        // The fixture CA is scoped to localhost. Cloud upload targets use the
        // platform's normal certificate and hostname verification.
        if challenge.protectionSpace.host != "localhost" {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              challenge.protectionSpace.host == "localhost", let trust = challenge.protectionSpace.serverTrust,
              let certificate = SecCertificateCreateWithData(nil, anchor as CFData),
              SecTrustSetAnchorCertificates(trust, [certificate] as CFArray) == errSecSuccess,
              SecTrustSetAnchorCertificatesOnly(trust, true) == errSecSuccess,
              SecTrustSetPolicies(trust, SecPolicyCreateSSL(true, "localhost" as CFString)) == errSecSuccess,
              SecTrustEvaluateWithError(trust, nil)
        else { completionHandler(.cancelAuthenticationChallenge, nil); return }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
}

private struct AppResourceFixtureIdentity: V2DeviceBoundAccountAssertionProvider, V2DeviceIdentityProvider {
    let assertion: String
    let device: DeviceID
    func accountAssertion(for deviceID: DeviceID) throws -> String {
        guard deviceID == device else { throw V2AuthSessionError.deviceMismatch }
        return assertion
    }
    func deviceID() -> DeviceID { device }
}
private actor AppResourceFixtureRegistrationStore: V2DeviceCredentialRegistrationOperationStore {
    var pending: V2PendingDeviceCredentialRegistration?
    func load() -> V2PendingDeviceCredentialRegistration? { pending }
    func save(_ value: V2PendingDeviceCredentialRegistration) { pending = value }
    func delete() { pending = nil }
}
