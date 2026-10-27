import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Crypto
import IMV2Core
import Testing
@testable import IMV2ClientKit

@Suite("Upload response context and durable session binding", .timeLimit(.minutes(1)))
struct V2ResourceUploadContractTests {
    enum Usage: CaseIterable, Sendable { case attachment, personalAvatar, groupAvatar }
    enum Action: String, CaseIterable, Sendable { case create, status, finalize, cancel }
    enum Mutation: CaseIterable, Sendable { case session, media, generation }
    enum HomeMismatch: CaseIterable, Sendable { case otherScope, wrongKind }
    enum LocatorMismatch: CaseIterable, Sendable { case home, session }

    @Test(arguments: Action.allCases)
    func matchingResponsePreservesAdvancedGenerationAndCompletion(action: Action) async throws {
        let f = try Fixture(), result = try f.session(generation: 3, ready: true)
        let http = UploadContractHTTP(data: try JSONEncoder().encode(result)), client = try f.client(http)
        #expect(try await f.perform(action, client: client) == result)
        let request = try #require(await http.last), body = try #require(request.httpBody)
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture")
        #expect(request.value(forHTTPHeaderField: "Cache-Control") == "no-store")
        #expect(request.url?.path == "/v2/resource-uploads" + (action == .create ? "" : "/" + action.rawValue))
        switch action {
        case .create: #expect(try JSONDecoder().decode(V2ResourceUploadRequest.self, from: body) == f.request)
        case .status: #expect(try JSONDecoder().decode(V2ResourceUploadLocator.self, from: body) == f.locator)
        case .finalize:
            let input = try JSONDecoder().decode(V2ResourceUploadFinalizeRequest.self, from: body)
            #expect(input.locator == f.locator && input.generation == 2)
        case .cancel:
            let input = try JSONDecoder().decode(V2ResourceUploadCancelRequest.self, from: body)
            #expect(input.locator == f.locator && input.generation == 2)
        }
    }

    @Test(arguments: Usage.allCases)
    func creationRequiresMatchingMediaAndTargetScope(usage: Usage) async throws {
        let f = try Fixture(usage: usage), valid = try f.session()
        #expect(try await f.client(UploadContractHTTP(data: JSONEncoder().encode(valid))).create(f.request) == valid)
        var mismatches = [try f.session(media: .init(uuid: UUID())), try f.session(home: f.wrongHome(.wrongKind))]
        if usage != .personalAvatar { mismatches.append(try f.session(home: f.wrongHome(.otherScope))) }
        for wrong in mismatches {
            let client = try f.client(UploadContractHTTP(data: JSONEncoder().encode(wrong)))
            await #expect(throws: V2ClientMediaTransferError.invalidMediaEdgeResponse) { try await client.create(f.request) }
        }
    }

    @Test(arguments: LocatorMismatch.allCases)
    func statusRequiresTheRequestedLocator(mismatch: LocatorMismatch) async throws {
        let f = try Fixture()
        let wrong = try f.session(home: mismatch == .home ? f.wrongHome(.otherScope) : nil,
            sessionID: mismatch == .session ? .init(uuid: UUID()) : nil)
        let client = try f.client(UploadContractHTTP(data: JSONEncoder().encode(wrong)))
        await #expect(throws: V2ClientMediaTransferError.invalidMediaEdgeResponse) { try await client.status(f.locator) }
    }

    @Test(arguments: [Action.finalize, .cancel], Mutation.allCases)
    func mutationResponsesCannotSwitchIdentityOrRegressGeneration(action: Action, mutation: Mutation) async throws {
        let f = try Fixture()
        let wrong = try f.session(sessionID: mutation == .session ? .init(uuid: UUID()) : nil,
            media: mutation == .media ? .init(uuid: UUID()) : nil, generation: mutation == .generation ? 1 : 3)
        let client = try f.client(UploadContractHTTP(data: JSONEncoder().encode(wrong)))
        await #expect(throws: V2ClientMediaTransferError.invalidMediaEdgeResponse) { try await f.perform(action, client: client) }
    }

    @Test(arguments: Usage.allCases, HomeMismatch.allCases)
    func firstSessionRequiresTheBoundDestinationAccountOrRoom(usage: Usage, mismatch: HomeMismatch) async throws {
        let f = try await StoreFixture(usage: usage)
        await #expect(throws: V2ResourceJournalError.conflict) {
            try await f.store.saveResourceSession(f.context.session(home: f.context.wrongHome(mismatch)), for: f.job)
        }
        let stored = try #require(try await f.store.resourceTransfer(id: f.job))
        #expect(stored.session == nil && stored.stage == .prepared)
        guard stored.session == nil else { try await f.close(); return }
        let valid = try f.context.session()
        try await f.store.saveResourceSession(valid, for: f.job)
        #expect(try await f.store.resourceTransfer(id: f.job)?.session == valid)
        try await f.close()
    }

    @Test(arguments: Mutation.allCases)
    func cancellationConfirmationCannotReplaceKnownSessionIdentity(mutation: Mutation) async throws {
        let f = try await StoreFixture(usage: .attachment), valid = try f.context.session()
        try await f.store.saveResourceSession(valid, for: f.job)
        _ = try #require(try await f.store.requestResourceCancellation(id: f.job))
        let before = try #require(try await f.store.resourceTransfer(id: f.job))
        let wrong = try f.context.session(sessionID: mutation == .session ? .init(uuid: UUID()) : nil,
            media: mutation == .media ? .init(uuid: UUID()) : nil, generation: mutation == .generation ? 1 : 3,
            cancelled: true)
        await #expect(throws: V2ResourceJournalError.conflict) {
            try await f.store.confirmResourceCancellation(id: f.job, session: wrong)
        }
        let after = try #require(try await f.store.resourceTransfer(id: f.job))
        #expect(after.session == before.session && after.stage == before.stage && after.cancellationRequested)
        guard after.session == before.session else { try await f.close(); return }
        let cancelled = try f.context.session(generation: 3, cancelled: true)
        try await f.store.confirmResourceCancellation(id: f.job, session: cancelled)
        #expect(try await f.store.resourceTransfer(id: f.job)?.stage == .cancelled)
        try await f.close()
    }

    private struct Fixture {
        static let bytes = Data(repeating: UInt8(7), count: 42)
        let user = UserID(uuid: UUID()), room = RoomID(uuid: UUID())
        let request: V2ResourceUploadRequest
        let locator: V2ResourceUploadLocator
        init(usage: Usage = .attachment) throws {
            let target: V2ResourceUsage = switch usage {
            case .attachment: .messageAttachment(room)
            case .personalAvatar: .userAvatar
            case .groupAvatar: .groupAvatar(room)
            }
            request = try .init(operationID: .init(uuid: UUID()), mediaID: .init(uuid: UUID()), usage: target,
                contentType: "image/png", byteCount: Int64(Self.bytes.count),
                checksum: .init(value: SHA256.hash(data: Self.bytes).map { String(format: "%02x", $0) }.joined()), displayName: .init("upload.png"))
            locator = .init(home: target.home(actorUserID: user), sessionID: .init(uuid: UUID()))
        }
        func wrongHome(_ mismatch: HomeMismatch) -> V2ResourceHome {
            switch (locator.home, mismatch) {
            case (.account, .otherScope): .account(.init(uuid: UUID()))
            case (.account, .wrongKind): .room(room)
            case (.room, .otherScope): .room(.init(uuid: UUID()))
            case (.room, .wrongKind): .account(user)
            }
        }
        func session(home: V2ResourceHome? = nil, sessionID: MediaUploadSessionID? = nil, media: MediaID? = nil,
                     generation: Int64 = 2, ready: Bool = false, cancelled: Bool = false) throws -> V2ResourceUploadSession {
            try .init(locator: .init(home: home ?? locator.home, sessionID: sessionID ?? locator.sessionID),
                mediaID: media ?? request.mediaID, generation: generation,
                state: cancelled ? .cancelled : ready ? .completed : .created, resourceState: ready ? .ready : .pending,
                expiresAt: .distantFuture, bindableUntil: ready ? .distantFuture : nil)
        }
        func client(_ http: UploadContractHTTP) throws -> V2HTTPResourceUploadClient {
            try .init(endpoint: #require(URL(string: "https://account.invalid/v2/resource-uploads")),
                credentials: UploadContractCredentials(), transport: http)
        }
        func perform(_ action: Action, client: V2HTTPResourceUploadClient) async throws -> V2ResourceUploadSession {
            switch action {
            case .create: try await client.create(request)
            case .status: try await client.status(locator)
            case .finalize: try await client.finalize(session())
            case .cancel: try await client.cancel(session())
            }
        }
    }
    private struct StoreFixture {
        let root = FileManager.default.temporaryDirectory.appending(path: "upload-contract-\(UUID())")
        let job = UUID()
        let context: Fixture
        let store: GRDBV2LocalSyncStore
        let center: V2ResourceCenter
        init(usage: Usage) async throws {
            context = try Fixture(usage: usage)
            store = try .init(databaseURL: root.appending(path: "V2.sqlite"), installationBinding: .init(value: UUID()), userID: context.user)
            center = try await makeResourceTestCenter(store: store, root: root)
            let purpose: V2LocalResourceAssetPurpose = switch context.request.usage {
            case .messageAttachment(let room): .messageDraft(room)
            case .groupAvatar(let room): .groupAvatar(room)
            case .userAvatar: .personalAvatar
            }
            let asset = try await center.importLocal(data: Fixture.bytes, displayName: context.request.displayName,
                contentType: .init(context.request.contentType), purpose: purpose)
            _ = try await store.prepareResourceTransfer(id: job, request: context.request, localAssetID: asset.id)
        }
        func close() async throws { await center.close(); try await store.close(); try FileManager.default.removeItem(at: root) }
    }
}
private struct UploadContractCredentials: V2ClientMediaEdgeCredentialProvider {
    func mediaEdgeCredentials() -> V2ClientMediaEdgeCredentials { .init(accessToken: "fixture", deviceID: .init(uuid: UUID())) }
}
private actor UploadContractHTTP: V2ClientMediaEdgeHTTPTransport {
    let data: Data
    var last: URLRequest?
    init(data: Data) { self.data = data }
    func data(for request: URLRequest) throws -> (Data, HTTPURLResponse) {
        last = request
        let url = try #require(request.url)
        let response = try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"]))
        return (data, response)
    }
}
