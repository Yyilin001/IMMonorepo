#if os(macOS)
import Foundation
import Network
import Security
import Testing
import IMV2Core
import IMV2ClientRuntime
import IMV2SharedApple
@testable import IMV2SharedRuntime
@testable import IMV2ClientNetwork

@Suite(.serialized) struct SharedDesktopBackendTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["IM_SHARED_BACKEND_ENDPOINTS"] != nil))
    func appleLoginMessagesSearchDisconnectRestoreAndAccountExit() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["IM_SHARED_BACKEND_ENDPOINTS"])
        let fixture = try DesktopFixture(path: path)
        defer { fixture.close() }
        let suffix = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(10)
        let password = UUID().uuidString + "aA1!"
        let names = ["desktop_\(suffix)_a", "desktop_\(suffix)_b", "desktop_\(suffix)_c"]
        let accounts = try await names.asyncMap { try await fixture.register($0, password: password) }
        let room = try await fixture.direct(actor: accounts[1], target: accounts[0])
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("im-shared-desktop-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let firstPlatform = fixture.platform(installation: "a"), peerPlatform = fixture.platform(installation: "b")
        let config = try fixture.configuration(root: root.appendingPathComponent("a"))
        var first = try SharedRuntime(config, platform: firstPlatform)
        let peer = try SharedRuntime(fixture.configuration(root: root.appendingPathComponent("b")), platform: peerPlatform)
        do {
            _ = try await first.command(["operation":"login", "account":names[0], "password":password])
            _ = try await peer.command(["operation":"login", "account":names[1], "password":password])
            _ = try await first.command(["operation":"connect"]); _ = try await peer.command(["operation":"connect"])
            print("Desktop stage: connected")
            // The recipient directory can precede local read authority; seed from the creator first.
            try await open(peer, room: room)
            _ = try await peer.command(["operation":"sendText", "roomID":room, "text":"桌面初始化消息"])
            try await open(first, room: room)
            print("Desktop stage: room opened")
            let message = "四端共享搜索验证 \(suffix)"
            let commands = try #require(await first.messageBusiness)
            _ = try await commands.send(in: RoomID(room), text: message)
            try await wait { try await peer.current().chat?.messages.contains { $0.text == message } == true }
            print("Desktop stage: received text")
            let source = try #require(try await peer.current().chat?.messages.first { $0.text == message })
            _ = try await peer.command(["operation":"sendText", "roomID":room, "text":"桌面回复", "replyToMessageID":source.id])
            try await wait { try await first.current().chat?.messages.contains { $0.replyToID == source.id } == true }
            print("Desktop stage: reply received")
            _ = try await peer.command(["operation":"reactMessage", "roomID":room, "messageID":source.id, "reaction":"👍", "action":"add"])
            try await wait { try await first.current().chat?.messages.first { $0.id == source.id }?.reactions.contains { $0.value == "👍" && $0.count == 1 } == true }
            print("Desktop stage: reaction received")
            let facade = try #require(await first.conversationBusiness)
            let historyWindow = try await facade.openTimeline(in: RoomID(room), limit: 1)
            let liveWindow = try await facade.openTimeline(in: RoomID(room), limit: 20)
            guard case .timeline(let newest) = try await historyWindow.read(),
                  case .timeline(let older) = try await historyWindow.nextPage() else { throw DesktopFixture.Failure.response }
            #expect(newest.page.messages.first?.messageID != older.page.messages.first?.messageID)
            let liveText = "Swift 原生独立窗口 \(suffix)"
            _ = try await peer.command(["operation":"sendText", "roomID":room, "text":liveText])
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    for try await update in await liveWindow.updates() {
                        if case .timeline(let page) = update, page.page.messages.contains(where: { $0.text == liveText }) { return }
                    }
                    throw DesktopFixture.Failure.response
                }
                group.addTask { try await Task.sleep(for: .seconds(30)); throw DesktopFixture.Failure.timeout }
                defer { group.cancelAll() }
                try await group.next()
            }
            guard case .timeline(let stableHistory) = try await historyWindow.read() else { throw DesktopFixture.Failure.response }
            #expect(stableHistory.page.messages.map(\.messageID) == older.page.messages.map(\.messageID))
            await historyWindow.close()
            _ = try await liveWindow.read()
            print("Desktop stage: native independent window paging, observation and sibling close passed")

            _ = try await first.command(["operation":"searchMessages", "roomID":room, "text":"四端共享"])
            try await wait { try await first.current().messaging?.search?.hits.contains { $0.id == source.id } == true }
            print("Desktop stage: search matched")
            let search = try #require(await first.searchBusiness)
            try await wait { try await search.search(.init(query: "四端共享", scope: .room(RoomID(room)))).hits.contains { $0.messageID.rawValue == source.id } }
            let peerReceipts = try #require(await peer.receiptBusiness)
            try await peerReceipts.recordVisible(in: RoomID(room), messageIDs: [MessageID(source.id)])
            try await wait { try await first.current().chat?.messages.first { $0.id == source.id }?.readByPeer == true }
            #expect(try await peerReceipts.recordReadThrough(in: RoomID(room), roomSequence: source.sequence) == false)
            print("Desktop stage: native search and visible receipt confirmed by independent peer")

            _ = try await commands.edit(in: RoomID(room), messageID: MessageID(source.id), expectedRevision: source.revision, text: "原生编辑 " + message)
            try await wait { try await peer.current().chat?.messages.first { $0.id == source.id }?.text == "原生编辑 " + message }
            let edited = try #require(try await peer.current().chat?.messages.first { $0.id == source.id })
            _ = try await commands.send(in: RoomID(room), text: "原生回复", replyTo: .init(messageID: MessageID(source.id)))
            try await wait { try await peer.current().chat?.messages.contains { $0.text == "原生回复" && $0.replyToID == source.id } == true }
            _ = try await commands.react(in: RoomID(room), messageID: MessageID(source.id), reaction: "❤️", targetState: .present)
            try await wait { try await peer.current().chat?.messages.first { $0.id == source.id }?.reactions.contains { $0.value == "❤️" && $0.includesMe == false } == true }
            // Wait for our own authoritative revision before freezing a forward plan.
            try await wait { try await first.current().chat?.messages.first { $0.id == source.id }?.revision == edited.revision }
            _ = try await commands.forward(sources: [.init(roomID: RoomID(room), messageID: MessageID(source.id), revision: .init(edited.revision))], to: [RoomID(room)])
            try await wait { try await peer.current().chat?.messages.contains { $0.forwardedFromID == source.id } == true }
            _ = try await commands.react(in: RoomID(room), messageID: MessageID(source.id), reaction: "❤️", targetState: .absent)
            try await wait { try await peer.current().chat?.messages.first { $0.id == source.id }?.reactions.contains { $0.value == "❤️" } == false }
            _ = try await commands.withdraw(in: RoomID(room), messageID: MessageID(source.id), expectedRevision: edited.revision)
            try await wait { try await peer.current().chat?.messages.first { $0.id == source.id }?.withdrawn == true }
            print("Desktop stage: native facade send/edit/reply/forward/reaction/remove/withdraw confirmed by peer")

            fixture.cutConnections(installation: "a")
            try await wait { try await first.current().state == "offline" }
            print("Desktop stage: cut detected")
            let queued = "断线持久消息 \(suffix)"
            _ = try await first.command(["operation":"sendText", "roomID":room, "text":queued])
            #expect(try await first.current().chat?.pending.contains { $0.text == queued } == true)
            _ = try await first.command(["operation":"close"])
            print("Desktop stage: owner closed")
            await #expect(throws: V2ConversationServiceError.self) { try await liveWindow.read() }
            print("Desktop stage: old native window rejected after owner close")
            await #expect(throws: V2MessageServiceError.self) { try await commands.send(in: RoomID(room), text: "old account") }
            first = try SharedRuntime(config, platform: firstPlatform)
            let restored = try await first.command(["operation":"restore"]); #expect(restored.userID == accounts[0].userID)
            _ = try await first.command(["operation":"connect"]); try await open(first, room: room)
            try await wait { try await peer.current().chat?.messages.contains { $0.text == queued } == true }
            #expect(try await peer.current().chat?.messages.filter { $0.text == queued }.count == 1)
            _ = try await first.command(["operation":"signOut"])
            let other = try await first.command(["operation":"login", "account":names[2], "password":password])
            #expect(other.userID == accounts[2].userID); #expect(other.chat == nil); #expect(other.conversations.isEmpty)
            _ = try await first.command(["operation":"signOut"]); _ = try await first.command(["operation":"close"])
            _ = try await peer.command(["operation":"signOut"]); _ = try await peer.command(["operation":"close"])
            try await fixture.cleanSecureItems()
            print("Desktop shared SDK: real HTTPS/TLS login, two-peer text/reply/reaction, Unicode search, physical disconnect, Keychain/database owner reopen, no duplicate send and third-account isolation passed.")
        } catch {
            _ = try? await first.command(["operation":"close"]); _ = try? await peer.command(["operation":"close"])
            try? await fixture.cleanSecureItems()
            throw error
        }
    }
    private func open(_ client: SharedRuntime, room: String) async throws {
        var attempt = 0, reconnects = 0
        try await wait {
            let value = try await client.current(); attempt += 1
            if attempt == 1 || attempt % 100 == 0 { print("Desktop directory state=\(value.state) seq=\(value.appliedSequence) rows=\(value.conversations.count) failure=\(value.failure ?? "none")") }
            // This native host owns foreground reconnects just as the App does. Bound
            // startup reconnects; do not wait forever on a deliberately stopped runtime.
            if value.state == "offline", reconnects < 3 {
                reconnects += 1
                print("Desktop host reconnect \(reconnects), failure=\(value.failure ?? "none")")
                _ = try await client.command(["operation":"connect"])
                return false
            }
            guard value.conversations.contains(where: { $0.id == room }) else { return false }
            do { _ = try await client.command(["operation":"openConversation", "roomID":room]); return true }
            catch SharedFailure.invalidInput { return false }
        }
    }
    private func wait(_ predicate: () async throws -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(45))
        while .now < deadline { if try await predicate() { return }; try await Task.sleep(for: .milliseconds(100)) }
        throw DesktopFixture.Failure.timeout
    }
}
private extension SharedRuntime {
    func command(_ value: [String:Any]) async throws -> SharedSnapshot {
        try await execute(JSONDecoder().decode(SharedRequest.self, from: JSONSerialization.data(withJSONObject: value)))
    }
    func current() async throws -> SharedSnapshot { try await command(["operation":"snapshot"]) }
}
private extension Array {
    func asyncMap<T>(_ transform: (Element) async throws -> T) async rethrows -> [T] { var result: [T] = []; for element in self { result.append(try await transform(element)) }; return result }
}

private final class DesktopFixture: @unchecked Sendable {
    enum Failure: Error { case configuration, response, timeout }
    struct Account { let userID: String; let deviceID: String; let token: String }
    let base: URL; let port: UInt16; let ca: Data; let session: URLSession
    private let prefix = "desktop-test-" + UUID().uuidString + "-"
    private let cleanupActions = V2Lock<[@Sendable () async throws -> Void]>(initialState: [])
    private let items = V2Lock<[any SharedSecurePersistence]>(initialState: [])
    private let connections = V2Lock<[String:[V2NetworkTLSByteConnection]]>(initialState: [:])
    init(path: String) throws {
        let values = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as? [String:Any])
        base = try #require(URL(string: values["httpsBaseURL"] as? String ?? "")); port = try #require((values["gatewayPort"] as? Int).flatMap(UInt16.init(exactly:)))
        guard base.scheme == "https", base.host == "localhost" else { throw Failure.configuration }
        let pem = try String(contentsOfFile: #require(values["caPath"] as? String), encoding: .utf8)
        ca = try #require(Data(base64Encoded: pem.components(separatedBy: .newlines).filter { !$0.hasPrefix("---") }.joined()))
        session = URLSession(configuration: V2SecureURLSession.account.configuration, delegate: DesktopTrust(ca: ca), delegateQueue: nil)
    }
    func platform(installation: String) -> SharedPlatform {
        let apple = SharedPlatform.apple(), scope = prefix + installation + "-"
        return .init(credentials: { [self] name in let store = apple.credentials(scope + name); cleanupActions.withLock { $0.append { try await store.delete() } }; return store }, installationBinding: { [self] name in let store = apple.installationBinding(scope + name); cleanupActions.withLock { $0.append { try await store.delete() } }; return store },
            securePersistence: { [self] name in let item = apple.securePersistence(scope + name); items.withLock { $0.append(item) }; return item },
            http: V2URLSessionAuthHTTPTransport(session: session), imageHTTP: V2URLSessionAuthHTTPTransport(session: session),
            uploader: V2URLSessionResourcePlanExecutor(session: session), rangeTransport: V2URLSessionRangeDownloadTransport(session: session),
            tlsConnection: { [self] endpoint in
                let tls = NWProtocolTLS.Options()
                sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv13)
                sec_protocol_options_set_max_tls_protocol_version(tls.securityProtocolOptions, .TLSv13)
                let ca = ca
                sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, value, done in
                    done(DesktopTrust.validate(sec_trust_copy_ref(value).takeRetainedValue(), ca: ca))
                }, .global(qos: .utility))
                let network = NWConnection(host: .init(endpoint.host), port: .init(rawValue: endpoint.port)!, using: NWParameters(tls: tls, tcp: .init()))
                let connection = V2NetworkTLSByteConnection(connection: network, queue: .global(qos: .utility))
                connections.withLock { $0[installation, default: []].append(connection) }; return connection
            }, registrationMetadata: apple.registrationMetadata, createStagingFile: apple.createStagingFile, isAbsolutePath: apple.isAbsolutePath)
    }
    func cutConnections(installation: String) { let values = connections.withLock { $0.removeValue(forKey: installation) ?? [] }; values.forEach { $0.cancel() } }
    func configuration(root: URL) throws -> SharedConfiguration {
        try JSONDecoder().decode(SharedConfiguration.self, from: JSONSerialization.data(withJSONObject: ["accountURL":base.absoluteString, "gatewayHost":"localhost", "gatewayPort":port, "storageDirectory":root.path]))
    }
    func cleanSecureItems() async throws { for action in cleanupActions.withLock({ $0 }) { try await action() }; cleanupActions.withLock { $0.removeAll() } }
    func close() { connections.withLock { $0.values.flatMap { $0 }.forEach { $0.cancel() }; $0.removeAll() }; session.invalidateAndCancel(); items.withLock { $0.forEach { try? $0.delete() }; $0.removeAll() } }
    private func post(_ path: String, body: [String:Any], actor: Account? = nil) async throws -> [String:Any] {
        var request = URLRequest(url: base.appendingPathComponent(path)); request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let actor { request.setValue("Bearer " + actor.token, forHTTPHeaderField: "Authorization"); request.setValue(actor.deviceID, forHTTPHeaderField: "X-IM-Device-ID") }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data,response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200, data.count <= 1_048_576, let value = try JSONSerialization.jsonObject(with: data) as? [String:Any] else { throw Failure.response }
        return value
    }
    func register(_ name: String, password: String) async throws -> Account {
        let device = UUID().uuidString, operation = UUID().uuidString
        let registered = try await post("v2/account-auth/password/register", body: ["accountHandle":name,"publicHandle":name,"displayName":name,"password":password,"deviceID":device])
        let proof = try V2SecureRandom.recoveryCodeBytes().base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        let result = try await post("v2/device-credentials", body: ["accountAssertion":try #require(registered["accountAssertion"] as? String), "deviceID":device,"operationID":operation,
            "cancellation":["deviceID":["rawValue":device],"operationID":operation,"proof":"imv2-cancel-registration-v1."+proof,"issueBeforeMilliseconds":Int64(Date().timeIntervalSince1970 * 1000)+600_000]])
        return .init(userID: try #require(result["userID"] as? String), deviceID: try #require(result["deviceID"] as? String), token: try #require(result["accessToken"] as? String))
    }
    func direct(actor: Account, target: Account) async throws -> String {
        let result = try await post("v2/direct-room-operations/submit", body: ["actorUserID":["rawValue":actor.userID],"targetUserID":["rawValue":target.userID],"operationID":["rawValue":UUID().uuidString],"firstSubmissionDeadlineMilliseconds":Int64(Date().timeIntervalSince1970 * 1000)+60_000], actor: actor)
        let receipt = result["receipt"] as? [String:Any], payload = receipt?["_0"] as? [String:Any], outcome = payload?["outcome"] as? [String:Any], opened = outcome?["opened"] as? [String:Any], room = opened?["roomID"] as? [String:Any]
        return try #require(room?["rawValue"] as? String)
    }
}
private final class DesktopTrust: NSObject, URLSessionDelegate, @unchecked Sendable {
    let ca: Data
    init(ca: Data) { self.ca = ca }
    static func validate(_ trust: SecTrust, ca: Data) -> Bool {
        guard let anchor = SecCertificateCreateWithData(nil, ca as CFData),
              SecTrustSetAnchorCertificates(trust, [anchor] as CFArray) == errSecSuccess,
              SecTrustSetAnchorCertificatesOnly(trust, true) == errSecSuccess,
              SecTrustSetPolicies(trust, SecPolicyCreateSSL(true, "localhost" as CFString)) == errSecSuccess else { return false }
        return SecTrustEvaluateWithError(trust, nil)
    }
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.host == "localhost", let trust = challenge.protectionSpace.serverTrust, Self.validate(trust, ca: ca) else { completionHandler(.cancelAuthenticationChallenge, nil); return }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) { completionHandler(nil) }
}
#endif
