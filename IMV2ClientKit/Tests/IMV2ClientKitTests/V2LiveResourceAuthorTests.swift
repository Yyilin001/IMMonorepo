#if os(macOS)
import CoreGraphics
import Crypto
import Foundation
import ImageIO
import IMV2Core
import Network
import Security
import Testing
import UniformTypeIdentifiers
@testable import IMV2ClientKit

/// Run only through scripts/verify_v2_live_resource_authors.py. Both services,
/// their Actor transport, database, bytes and CA belong to that invocation.
@Suite("Live resource and author delivery", .serialized, .timeLimit(.minutes(2)),
       .enabled(if: ProcessInfo.processInfo.environment["IMV2_LIVE_RESOURCE_GATEWAY_PORT"] != nil))
struct V2LiveResourceAuthorTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["IMV2_LIVE_NICKNAME_DIRECTORY"] == "1"))
    func largeNicknameDirectoryIndependentDeviceReads() async throws {
        let fixture = try LiveAccountFixture(); defer { fixture.close() }
        let viewer = try await fixture.register(), author = try await fixture.register().credentials
        let second = try await fixture.login(viewer.handle)
        try #require(second.userID == viewer.credentials.userID && second.deviceID != viewer.credentials.deviceID)
        var request = URLRequest(url: fixture.url("__fixture__/room"))
        request.httpMethod = "POST"
        request.setValue(try #require(ProcessInfo.processInfo.environment["IMV2_LIVE_RESOURCE_FIXTURE_TOKEN"]), forHTTPHeaderField: "X-Resource-Fixture")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["viewer": viewer.credentials.userID.rawValue,
            "author": author.userID.rawValue, "directoryCount": "257"])
        let (data, response) = try await fixture.http.data(for: request)
        try #require((response as? HTTPURLResponse)?.statusCode == 200)
        struct DirectorySeed: Decodable { let roomID: String; let directoryIDs: [String] }
        let seed = try JSONDecoder().decode(DirectorySeed.self, from: data)
        let room = try RoomID(seed.roomID)
        let expected = Set(try seed.directoryIDs.map { try UserID($0) }).union([author.userID])
        try #require(expected.count == 258)
        var expectedNames = Dictionary(uniqueKeysWithValues: try seed.directoryIDs.enumerated().map {
            (try UserID($0.element), "directory\($0.offset)")
        })
        expectedNames[author.userID] = "Directory author"
        try await updateNickname(fixture, author: author, room: room, expectedRevision: nil, name: "Directory author")
        let http = V2URLSessionMediaEdgeHTTPTransport(session: fixture.http)
        func readAll(_ credentials: V2AuthCredentials, blocked: Bool) async throws -> Set<UserID> {
            let client = try V2HTTPGroupNicknamePresentationClient(groupsEndpoint: fixture.url("v2/profile-presentations/groups"),
                actorUserID: credentials.userID, credentials: ResourceLiveCredentials(value: credentials), transport: http)
            var cursor: UserID?, seen = Set<UserID>(), pageCount = 0
            repeat {
                try Task.checkCancellation()
                let page = try await client.read(roomID: room, afterUserID: cursor, limit: 32)
                pageCount += 1
                try #require(pageCount <= 10 && page.retryable.isEmpty)
                for id in page.userIDs {
                    try #require(seen.insert(id).inserted)
                    if blocked && id == author.userID {
                        #expect(page.unavailable.contains(id) && page.snapshot(for: id) == nil)
                    } else {
                        let snapshot = try #require(page.snapshot(for: id))
                        #expect(snapshot.presentation.lease.deviceID == credentials.deviceID)
                        #expect(snapshot.presentation.groupMember?.groupNickname == expectedNames[id] && snapshot.avatar == nil)
                    }
                }
                if let next = page.nextCursor {
                    try #require(next == page.userIDs.last && next != cursor)
                }
                cursor = page.nextCursor
            } while cursor != nil
            #expect(pageCount == 9 && seen == expected)
            return seen
        }
        let firstIDs = try await readAll(viewer.credentials, blocked: false)
        let secondIDs = try await readAll(second, blocked: false)
        #expect(firstIDs == secondIDs)
        try await resourceBlock(fixture, account: author, target: viewer.credentials.userID)
        #expect(try await readAll(second, blocked: true) == expected)
        print("Live nickname directory: 258 entries, 9 pages per scan, two independently issued devices; blocked author withheld without cursor loss.")
    }

    @Test("slowResourceUploadKeepsControlAndCursorProgress",
          .enabled(if: ProcessInfo.processInfo.environment["IMV2_LIVE_RESOURCE_SLOW_UPLOAD"] == "1"))
    func slowResourceUploadKeepsControlAndCursorProgress() async throws {
        let fixture = try LiveAccountFixture(); defer { fixture.close() }
        let author = try await fixture.register().credentials, viewer = try await fixture.register().credentials
        let room = try await seedRoom(fixture, viewer: viewer.userID, author: author.userID)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let bytes = Data(repeating: 65, count: 256 * 1024), file = directory.appendingPathComponent("slow.txt")
        try bytes.write(to: file)
        // One account owner, with an independently bounded byte lane. All three
        // production leaf executors below share this exact scheduler instance.
        let scheduler = V2AccountWorkScheduler(configuration: .init(ordinaryLimit: 1, serviceLimit: 1, byteTransferLimit: 1))
        let http = V2URLSessionMediaEdgeHTTPTransport(executor: .init(session: fixture.http, scheduler: scheduler))
        let credentials = ResourceLiveCredentials(value: author)
        let uploads = try V2HTTPResourceUploadClient(endpoint: fixture.url("v2/resource-uploads"), credentials: credentials, transport: http)
        let session = try await uploads.create(.init(operationID: .init(uuid: UUID()), mediaID: .init(uuid: UUID()),
            usage: .messageAttachment(room), contentType: "text/plain", byteCount: Int64(bytes.count),
            checksum: .init(value: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())))
        let plan = try #require(try await uploads.target(session))
        try #require(plan.mode == .httpPut)
        let connection = try connection(authorSupplements: false, scheduler: scheduler)
        let local = try GRDBV2LocalSyncStore(databaseURL: directory.appendingPathComponent("author.sqlite"),
            installationBinding: .init(value: UUID()), userID: author.userID)
        var uploadTask: Task<Void, Error>?
        do {
            let authenticated = try await authenticate(connection, author)
            let transport = V2ProtobufSyncTransport(wire: connection, protocolVersion: authenticated.protocolVersion)
            _ = try await transport.subscribeToGroupEvents(roomID: room, afterRoomSequence: 0)
            _ = try await slowUploadControl(fixture, action: "arm", method: "POST")
            let executor = V2URLSessionResourcePlanExecutor(session: fixture.http, scheduler: scheduler)
            let task = Task { try await executor.upload(fileURL: file, plan: plan) }
            uploadTask = task
            let deadline = ContinuousClock.now + .seconds(10)
            var state = try await slowUploadControl(fixture, action: "state", method: "GET")
            while !state.waiting && ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(50))
                state = try await slowUploadControl(fixture, action: "state", method: "GET")
            }
            try #require(state.waiting && state.active == 1 && state.hits == 1 && state.bodyBytesRead >= 16 * 1024 && state.completed == 0 && state.expired == 0)
            // The held upload owns a permit; concurrent TLS maintenance may
            // legitimately own another permit in its independent lane.
            #expect(await scheduler.snapshot().active >= 1)
            let client = V2ProtobufMessageSendOperationClient(transport: transport, connection: connection)
            let command = try V2MessageSendOperationCommand(command: .init(roomID: room, senderUserID: author.userID,
                clientMessageID: .init(uuid: UUID()), text: "control progresses while bytes remain blocked", media: [], mentions: [],
                limits: .init(maxUTF8Bytes: 4096)), firstSubmissionDeadlineMilliseconds: UInt64(Date().timeIntervalSince1970 * 1000) + 86400000)
            guard case .receipt(let receipt) = try await client.submit(command),
                  try receipt.validates(identity: command.identity, fingerprint: command.fingerprint),
                  case .accepted(let accepted) = receipt.outcome else { throw ResourceLiveFailure.presentation }
            guard case .receipt(let recovered) = try await client.recover(.init(identity: command.identity,
                fingerprint: command.fingerprint, domainFingerprint: command.command.fingerprint, action: .query)) else { throw ResourceLiveFailure.presentation }
            #expect(recovered == receipt)
            let hint = try await bounded { try await connection.nextGroupEventAvailabilityHint() }
            #expect(hint.roomID == room && hint.highWatermark == accepted.roomSequence)
            let page = try await transport.pullGroupEvents(roomID: room, afterRoomSequence: 0, pageSize: 20)
            _ = try await local.applyGroupEventPage(page)
            #expect(try await local.messages(in: room).contains { $0.messageID == accepted.messageID && $0.roomSequence == accepted.roomSequence })
            // HTTP receipt/query and this uploading account's own TCP pull all
            // completed before the held body can resume, not on a viewer lane.
            state = try await slowUploadControl(fixture, action: "state", method: "GET")
            try #require(state.waiting && state.active == 1 && state.completed == 0 && !state.released && state.expired == 0)
            _ = try await slowUploadControl(fixture, action: "release", method: "POST")
            try await task.value
            uploadTask = nil
            let completed = try await slowUploadControl(fixture, action: "state", method: "GET")
            #expect(completed.completed == 1 && completed.active == 0 && completed.expired == 0)
            _ = try await uploads.finalize(session)
            await connection.disconnect()
            await scheduler.closeAndDrain()
            #expect(await scheduler.snapshot().active == 0)
            try await local.close()
        } catch {
            _ = try? await slowUploadControl(fixture, action: "release", method: "POST")
            uploadTask?.cancel()
            if let uploadTask { _ = await uploadTask.result }
            await connection.disconnect()
            await scheduler.closeAndDrain()
            try? await local.close()
            throw error
        }
    }

    private func slowUploadControl(_ fixture: LiveAccountFixture, action: String, method: String) async throws -> SlowResourceUploadState {
        var request = URLRequest(url: fixture.url("__fixture__/slow-upload/" + action))
        request.httpMethod = method
        if method == "POST" { request.setValue("0", forHTTPHeaderField: "Content-Length") }
        request.setValue(try #require(ProcessInfo.processInfo.environment["IMV2_LIVE_RESOURCE_FIXTURE_TOKEN"]), forHTTPHeaderField: "X-Resource-Fixture")
        let (data, response) = try await fixture.http.data(for: request)
        try #require((response as? HTTPURLResponse)?.statusCode == 200)
        return try JSONDecoder().decode(SlowResourceUploadState.self, from: data)
    }

    @Test("real resource upload, author delivery, byte access and block revocation")
    func resourceLifecycle() async throws {
        let fixture = try LiveAccountFixture()
        defer { fixture.close() }
        let author = try await fixture.register().credentials
        let viewer = try await fixture.register().credentials
        let room = try await seedRoom(fixture, viewer: viewer.userID, author: author.userID)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.png")
        try makeImage(at: source)
        let bytes = try Data(contentsOf: source)
        let mediaID = MediaID(uuid: UUID())
        let mediaHTTP = V2URLSessionMediaEdgeHTTPTransport(session: fixture.http)
        let upload = try V2HTTPResourceUploadClient(endpoint: fixture.url("v2/resource-uploads"),
            credentials: ResourceLiveCredentials(value: author), transport: mediaHTTP)
        #expect(try await upload.capabilities().allowedUsages.contains(.userAvatar))
        let checksum = try V2ResourceChecksum(value: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
        var session = try await upload.create(.init(operationID: .init(uuid: UUID()), mediaID: mediaID,
            usage: .userAvatar, contentType: "image/png", byteCount: Int64(bytes.count), checksum: checksum))
        let uploadDeadline = ContinuousClock.now + .seconds(120)
        while let plan = try await upload.target(session) {
            guard ContinuousClock.now < uploadDeadline else { throw ResourceLiveFailure.processing }
            try await V2URLSessionResourcePlanExecutor(session: fixture.http).upload(fileURL: source, plan: plan)
            if plan.mode == .httpPut { break }
            session = try await upload.status(session.locator)
        }
        session = try await upload.finalize(session)
        let processingDeadline = ContinuousClock.now + .seconds(20)
        while session.resourceState != .ready && ContinuousClock.now < processingDeadline {
            guard session.state != .failed, session.resourceState != .rejected else { throw ResourceLiveFailure.processing }
            try await Task.sleep(for: .milliseconds(200))
            session = try await upload.status(session.locator)
        }
        try #require(session.resourceState == .ready)
        let ownProfile = try V2HTTPOwnProfileClient(endpoint: fixture.url("v2/profile/me"),
            credentials: ResourceLiveCredentials(value: author), transport: V2URLSessionPushEndpointHTTPTransport(session: fixture.http))
        let before = try await ownProfile.currentProfile()
        let result = try await ownProfile.patchProfile(.init(actorUserID: before.userID, operationID: .init(uuid: UUID()), expectedRevision: before.revision,
            patch: .init(displayName: .set("Resource author"), avatar: .set(.init(mediaID: mediaID))), firstSubmissionDeadlineMilliseconds: UInt64(Date().addingTimeInterval(120).timeIntervalSince1970 * 1000)))
        let updated = try #require(result.currentSnapshot)
        #expect(updated.avatar?.mediaID == mediaID)
        let authorHandle = try #require(updated.publicIdentity?.handle)
        let discovery = try V2HTTPPublicIdentityDirectory(endpoint: fixture.url("v2/public-identities/resolve"),
            actorUserID: viewer.userID, credentials: ResourceLiveCredentials(value: viewer),
            transport: V2URLSessionPushEndpointHTTPTransport(session: fixture.http))
        let found = try await discovery.resolveForPresentation(handle: authorHandle.description)
        #expect(found.identity.userID == author.userID && found.identity.displayName == "Resource author")
        #expect(found.resolution.actorUserID == viewer.userID && found.resolution.deviceID == viewer.deviceID)
        #expect(found.isValid())
        try await updateNickname(fixture, author: author, room: room, expectedRevision: nil, name: "Room author")
        print("Live resource: uploaded, processed and bound an avatar through HTTPS.")

        let authorConnection = try connection(authorSupplements: false)
        let viewerConnection = try connection(authorSupplements: true)
        let local = try GRDBV2LocalSyncStore(databaseURL: directory.appendingPathComponent("viewer.sqlite"),
            installationBinding: .init(value: UUID()), userID: viewer.userID)
        let profiles = try V2HTTPProfilePresentationClient(endpoint: fixture.url("v2/profile-presentations/batch"),
            credentials: ResourceLiveCredentials(value: viewer), transport: mediaHTTP)
        let repository = V2ProfilePresentationRepository(actorUserID: viewer.userID, deviceID: viewer.deviceID,
            reader: profiles, nicknameRevisions: { try await local.groupNicknameRevisions(keys: $0) })
        let activation = await repository.activateVisiblePage()
        do {
            let authorSession = try await authenticate(authorConnection, author)
            let viewerSession = try await authenticate(viewerConnection, viewer)
            let authorTransport = V2ProtobufSyncTransport(wire: authorConnection, protocolVersion: authorSession.protocolVersion)
            let viewerTransport = V2ProtobufSyncTransport(wire: viewerConnection, protocolVersion: viewerSession.protocolVersion)
            _ = try await resourceRelationship(fixture,account:author,target:viewer.userID,action:.request)
            _ = try await resourceRelationship(fixture,account:viewer,target:author.userID,action:.accept)
            let directRoom = try await resourceOpenDirect(fixture,account:author,target:viewer.userID)
            let directView = try await viewerConnection.beginAuthorPresentationView(roomID: directRoom.roomID)
            _ = try await viewerTransport.subscribeToGroupEvents(roomID: directRoom.roomID,
                afterRoomSequence: 0, authorPresentationView: directView)
            let directSent = try await resourceSend(fixture, client: .init(transport: authorTransport, connection: authorConnection), account:author,roomID: directRoom.roomID,
                clientMessageID: .init(uuid: UUID()), text: "A direct author with an avatar", media: [], mentions: [])
            print("Live resource stage: awaiting direct availability hint.")
            let directHint = try await bounded {
                while true {
                    let value = try await viewerConnection.nextGroupEventAvailabilityHint()
                    if value.roomID == directRoom.roomID, value.highWatermark >= directSent.roomSequence { return value }
                }
            }
            print("Live resource stage: received direct availability hint.")
            #expect(directHint.roomID == directRoom.roomID && directHint.highWatermark == directSent.roomSequence)
            // No history pull or profile HTTP read occurs between this send and
            // receive: this presentation must come from committed direct delivery.
            print("Live resource stage: awaiting direct author presentation delta.")
            let directDelta = try await bounded { try await viewerConnection.nextAuthorPresentationDelta(for: directView) }
            print("Live resource stage: received direct author presentation delta.")
            try #require(directDelta.entries.count == 1)
            guard case .presentation(let directProfile, let directAvatar, let directDeadline, let directAvatarDeadline) = directDelta.entries[0] else {
                throw ResourceLiveFailure.presentation
            }
            #expect(directDelta.view == directView)
            #expect(directProfile.lease.key == .init(userID: author.userID, context: .room(directRoom.roomID)))
            #expect(directProfile.lease.actorUserID == viewer.userID && directProfile.lease.deviceID == viewer.deviceID)
            #expect(directProfile.view.publicIdentity?.displayName == "Resource author")
            #expect(directProfile.groupMember == nil && directAvatar?.mediaID == mediaID)
            #expect(directDeadline > .now && directAvatarDeadline.map { $0 > .now } == true)
            await viewerConnection.endAuthorPresentationView(directView)
            try await viewerTransport.stopAuthorPresentation(directView)
            print("Live resource: direct-message TLS supplement authorized for its viewer, device and room without a profile pull.")
            let liveView = try await viewerConnection.beginAuthorPresentationView(roomID: room)
            _ = try await viewerTransport.subscribeToGroupEvents(roomID: room, afterRoomSequence: 1, authorPresentationView: liveView)
            let sent = try await resourceSend(fixture, client: .init(transport: authorTransport, connection: authorConnection), account:author,roomID: room, clientMessageID: .init(uuid: UUID()),
                text: "An author with a new avatar", media: [], mentions: [])
            print("Live resource stage: awaiting group availability hint.")
            let hint = try await bounded {
                while true {
                    let value = try await viewerConnection.nextGroupEventAvailabilityHint()
                    if value.roomID == room, value.highWatermark >= sent.roomSequence { return value }
                }
            }
            print("Live resource stage: received group availability hint.")
            #expect(hint.roomID == room && hint.highWatermark == 2)
            print("Live resource stage: awaiting group author presentation delta.")
            let live = try await bounded { try await viewerConnection.nextAuthorPresentationDelta(for: liveView) }
            print("Live resource stage: received group author presentation delta.")
            try #require(live.entries.count == 1)
            guard case .presentation(let livePresentation, let liveAvatar, _, _) = live.entries[0] else {
                Issue.record("Live broadcast author did not produce an authorized presentation")
                throw ResourceLiveFailure.presentation
            }
            #expect(livePresentation.view.publicIdentity?.displayName == "Resource author" && liveAvatar?.mediaID == mediaID)
            #expect(livePresentation.groupMember?.groupNickname == "Room author" && livePresentation.groupMember?.revision.rawValue == 1)
            await viewerConnection.endAuthorPresentationView(liveView)
            try await viewerTransport.stopAuthorPresentation(liveView)
            // A new nonce starts after the only message was broadcast. Its
            // supplement can therefore originate only in the subsequent pull.
            let view = try await viewerConnection.beginAuthorPresentationView(roomID: room)
            _ = try await viewerTransport.subscribeToGroupEvents(roomID: room, afterRoomSequence: 2, authorPresentationView: view)
            let page = try await viewerTransport.pullGroupEvents(roomID: room, afterRoomSequence: 0, pageSize: 20)
            #expect(page.events.count == 2)
            #expect(page.nextRoomSequence == 2)
            let nicknameEvent = try #require(page.events.first)
            #expect(nicknameEvent.projectionKind == "group_capability")
            let nicknamePayload = try #require(JSONSerialization.jsonObject(with: nicknameEvent.payload) as? [String: Any])
            #expect(nicknamePayload["event_type"] as? String == "group.nickname_changed")
            #expect(nicknamePayload["target_user_id"] as? String == author.userID.rawValue)
            #expect(nicknamePayload["nickname"] == nil)
            _ = try await local.applyGroupEventPage(page)
            let received = try await bounded { try await viewerConnection.nextAuthorPresentationDelta(for: view) }
            try #require(received.entries.count == 1)
            guard case .presentation(let value, let optionalAvatar, let presentationDeadline, let avatarDeadline) = received.entries[0],
                  let avatar = optionalAvatar else {
                let reason: String
                switch received.entries[0] {
                case .retryable: reason = "retryable"
                case .unavailable: reason = "unavailable"
                case .presentation: reason = "presentation-without-avatar"
                }
                Issue.record("History author did not produce an authorized avatar: \(reason)")
                throw ResourceLiveFailure.presentation
            }
            let key = V2ProfileViewLookupKey(userID: author.userID, context: .room(room))
            #expect(received.view == view)
            #expect(value.lease.key == key && value.lease.actorUserID == viewer.userID && value.lease.deviceID == viewer.deviceID)
            #expect(value.view.publicIdentity?.displayName == "Resource author")
            #expect(value.groupMember?.groupNickname == "Room author" && value.groupMember?.revision.rawValue == 1)
            #expect(avatar.mediaID == mediaID)
            #expect(presentationDeadline > .now && avatarDeadline.map { $0 > .now } == true)
            _ = try await repository.retainVisibleInterest(for: key, activation: activation)
            let binding = try await repository.bindAuthorView(view, activation: activation)
            try await repository.ingest(received, binding: binding)
            #expect(await repository.cachedPresentation(for: key, activation: activation)?.groupMember?.revision.rawValue == 1)
            let target = try V2ClientMediaTransferTarget(downloadPlan: avatar.plan)
            let transfer = V2URLSessionMediaByteTransfer(session: fixture.http)
            let downloaded = directory.appendingPathComponent("avatar.png")
            try await transfer.download(target: target, destinationURL: downloaded)
            try checkAvatar(at: downloaded)
            // A second byte request uses the same immutable bytes. Capability
            // checking must still run before an already populated shared cache.
            try await transfer.download(target: target, destinationURL: directory.appendingPathComponent("warm.png"))
            var invalid = try #require(URLComponents(url: avatar.plan.url, resolvingAgainstBaseURL: false))
            invalid.queryItems = [.init(name: "cap", value: "invalid-capability")]
            let (_, response) = try await fixture.http.data(from: try #require(invalid.url))
            #expect((response as? HTTPURLResponse)?.statusCode == 404)
            print("Live resource: distinct broadcast and history TLS supplements; verified 128px bytes; invalid capability rejected on warm cache.")

            // This HTTP fallback crosses from Account to the separately running
            // Gateway Actor host, then checks real control and room SQL again.
            let visible = try await readReviewPage(profiles, keys: [key])
            #expect(visible.presentations[key]?.view.publicIdentity?.displayName == "Resource author")
            #expect(visible.avatars[key]?.mediaID == mediaID)
            // Directory membership and receipt disclosure do not distribute
            // bare profile text. Resolve the same IDs separately under leases.
            let roster = try await viewerTransport.listRoomMembers(roomID: room, cursor: nil, pageSize: 100)
            #expect(Set(roster.members.map(\.userID)) == [author.userID, viewer.userID])
            var rosterRequest = IMV2Envelope(); rosterRequest.listRoomMembers = .init()
            rosterRequest.listRoomMembers.roomID = room.rawValue; rosterRequest.listRoomMembers.pageSize = 100
            let rawRoster = try await viewerTransport.requestEnvelope(rosterRequest)
            try #require(rawRoster.roomMembersPage.members.count == 2)
            for member in rawRoster.roomMembersPage.members {
                let fields = try #require(JSONSerialization.jsonObject(with: member.jsonUTF8Data()) as? [String: Any])
                #expect(Set(fields.keys) == ["userId", "role"])
                #expect(member.unknownFields.data.isEmpty)
            }
            _ = try await viewerTransport.recordReadReceipt(roomID: room, operationID: .init(uuid: UUID()), readThroughRoomSequence: sent.roomSequence)
            let readers = try await authorTransport.listReadReceiptReaders(roomID: room, messageID: sent.messageID, cursor: nil, pageSize: 50)
            #expect(readers.readers.map(\.userID) == [viewer.userID])
            var receiptRequest = IMV2Envelope(); receiptRequest.listReadReceiptReaders = .init()
            receiptRequest.listReadReceiptReaders.roomID = room.rawValue
            receiptRequest.listReadReceiptReaders.messageID = sent.messageID.rawValue
            receiptRequest.listReadReceiptReaders.pageSize = 50
            let rawReaders = try await authorTransport.requestEnvelope(receiptRequest)
            let rawReader = try #require(rawReaders.readReceiptReadersPage.readers.first)
            let readerFields = try #require(JSONSerialization.jsonObject(with: rawReader.jsonUTF8Data()) as? [String: Any])
            #expect(Set(readerFields.keys) == ["userId"] && rawReader.unknownFields.data.isEmpty)
            let preferences = try V2HTTPAccountPreferenceOperationClient(baseURL: fixture.url(""),
                credentials: ResourceLiveCredentials(value: viewer), transport: mediaHTTP)
            let preferenceBaseline = try await preferences.baseline(kind: .readReceiptPreference)
            let preferenceCommand = try V2AccountPreferenceCommand(identity: .init(accountID: viewer.userID, scope: .account(viewer.userID),
                operation: .readReceiptPreference(.init(uuid: UUID()))), value: .readReceipt(allowsDirectReadReceipts: true, allowsGroupReadReceipts: false),
                expectedRevision: preferenceBaseline.revision, firstSubmissionDeadlineMilliseconds: UInt64(Date().timeIntervalSince1970 * 1_000) + 120_000)
            guard case .receipt(let preferenceProof) = try await preferences.submit(preferenceCommand), preferenceProof.validates(command: preferenceCommand) else { Issue.record("Expected original preference proof"); return }
            #expect(try await authorTransport.listReadReceiptReaders(roomID: room, messageID: sent.messageID, cursor: nil, pageSize: 50).readers.isEmpty)
            print("Live resource: TLS roster and reader pages contain IDs only; changing disclosure preferences still hides the reader.")
            #expect(visible.presentations[key]?.groupMember?.groupNickname == "Room author")
            let nicknamePages = try V2HTTPGroupNicknamePresentationClient(
                groupsEndpoint: fixture.url("v2/profile-presentations/groups"), actorUserID: viewer.userID,
                credentials: ResourceLiveCredentials(value: viewer), transport: mediaHTTP)
            let names = try await nicknamePages.read(roomID: room, limit: 1)
            #expect(names.userIDs == [author.userID] && names.nextCursor == nil)
            #expect(names.snapshot(for: author.userID)?.presentation.groupMember?.groupNickname == "Room author")
            #expect(names.snapshot(for: author.userID)?.avatar == nil)
            let endOfNames = try await nicknamePages.read(roomID: room, afterUserID: author.userID, limit: 1)
            #expect(endOfNames.userIDs.isEmpty && endOfNames.nextCursor == nil)
            // The public profile and membership revisions remain unchanged.
            // Compression must still deliver the independent nickname version.
            try await updateNickname(fixture, author: author, room: room, expectedRevision: 1, name: "Renamed author")
            let renamedPage = try await viewerTransport.pullGroupEvents(roomID: room, afterRoomSequence: 0, pageSize: 20)
            _ = try await local.applyGroupEventPage(renamedPage)
            #expect(try await local.groupNicknameRevisions(keys: [key])[key] == 2)
            try await repository.refreshNicknameInvalidations()
            #expect(await repository.cachedSnapshot(for: key, activation: activation) == nil)
            let renamed = try await bounded { try await viewerConnection.nextAuthorPresentationDelta(for: view) }
            guard case .presentation(let renamedValue, _, _, _) = renamed.entries.first else { throw ResourceLiveFailure.presentation }
            #expect(renamedValue.groupMember?.groupNickname == "Renamed author" && renamedValue.groupMember?.revision.rawValue == 2)
            #expect(renamedValue.view.revision == value.view.revision && renamedValue.lease.contextRevision == value.lease.contextRevision)
            try await repository.ingest(renamed, binding: binding)
            #expect(await repository.cachedPresentation(for: key, activation: activation)?.groupMember == renamedValue.groupMember)
            try await updateNickname(fixture, author: author, room: room, expectedRevision: 2, name: nil)
            let clearedPage = try await viewerTransport.pullGroupEvents(roomID: room, afterRoomSequence: 0, pageSize: 20)
            _ = try await local.applyGroupEventPage(clearedPage)
            // Reads also check the durable floor if its notification has not run.
            #expect(await repository.cachedSnapshot(for: key, activation: activation) == nil)
            let cleared = try await bounded { try await viewerConnection.nextAuthorPresentationDelta(for: view) }
            guard case .presentation(let clearedValue, _, _, _) = cleared.entries.first else { throw ResourceLiveFailure.presentation }
            #expect(clearedValue.groupMember?.groupNickname == nil && clearedValue.groupMember?.revision.rawValue == 3)
            try await repository.ingest(cleared, binding: binding)
            #expect(await repository.cachedPresentation(for: key, activation: activation)?.groupMember == clearedValue.groupMember)
            try await updateNickname(fixture, author: author, room: room, expectedRevision: 3, name: "Private group name")
            try await resourceBlock(fixture, account: author, target: viewer.userID)
            let blockedPage = try await viewerTransport.pullGroupEvents(roomID: room, afterRoomSequence: 0, pageSize: 20)
            _ = try await local.applyGroupEventPage(blockedPage)
            #expect(try await local.groupNicknameRevisions(keys: [key])[key] == 4)
            #expect(await repository.cachedSnapshot(for: key, activation: activation) == nil)
            let revoked = try await bounded { try await viewerConnection.nextAuthorPresentationDelta(for: view) }
            try #require(revoked.entries.count == 1)
            guard case .unavailable(let unavailable, _) = revoked.entries[0] else { throw ResourceLiveFailure.revocation }
            #expect(unavailable == key)
            try await repository.ingest(revoked, binding: binding)
            #expect(await repository.cachedSnapshot(for: key, activation: activation) == nil)
            let hidden = try await readReviewPage(profiles, keys: [key])
            #expect(hidden.unavailable.contains(key) && hidden.presentations.isEmpty && hidden.avatars.isEmpty)
            await #expect(throws: V2PublicIdentityDirectoryClientError.notFound) {
                try await discovery.resolveForPresentation(handle: authorHandle.description)
            }
            let hiddenNames = try await nicknamePages.read(roomID: room, limit: 1)
            #expect(hiddenNames.unavailable == [author.userID] && hiddenNames.snapshot(for: author.userID) == nil)
            var nameRequest = URLRequest(url: fixture.url("v2/profile-presentations/groups/\(room.rawValue)/nicknames"))
            nameRequest.setValue("Bearer " + viewer.accessToken, forHTTPHeaderField: "Authorization")
            nameRequest.setValue(viewer.deviceID.rawValue, forHTTPHeaderField: "X-IM-Device-ID")
            var (nameBody, nameResponse) = try await fixture.http.data(for: nameRequest)
            // This raw response assertion bypasses the presentation repository's
            // cooldown. Honor the real admission limit with at most two retries.
            for _ in 0..<2 {
                guard let response = nameResponse as? HTTPURLResponse, response.statusCode == 429 else { break }
                let delay = try #require(response.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init))
                try #require(delay.isFinite && delay >= 0 && delay <= 5)
                try await Task.sleep(for: .seconds(delay + 0.05))
                (nameBody, nameResponse) = try await fixture.http.data(for: nameRequest)
            }
            #expect((nameResponse as? HTTPURLResponse)?.statusCode == 200)
            #expect((nameResponse as? HTTPURLResponse)?.value(forHTTPHeaderField: "Cache-Control") == "no-store")
            #expect(!String(decoding: nameBody, as: UTF8.self).contains("Private group name"))
            // Previously issued capabilities retain their explicitly bounded
            // TTL. The block test asserts that no NEW access is issued.
            await viewerConnection.endAuthorPresentationView(view)
            try await viewerTransport.stopAuthorPresentation(view)
            try await verifyMessageDownload(fixture, author: author, room: room, transport: authorTransport, connection: authorConnection, directory: directory)
            print("Live resource: Actor HTTP fallback and later TLS supplement both reject the newly blocked viewer.")
            print("Live resource: nickname room events persisted through revision 4; same-view authorized updates restored only current content.")
            print("Live resource: nickname directory pages carry leases, do not pre-sign avatars, and withhold blocked nickname text.")
            print("Live resource: exact discovery binds viewer/device/handle and a short deadline; a later lookup hides the blocked account.")
            try await verifyJoinReview(fixture, manager: author, ordinary: viewer, room: room)
            await repository.close()
            try await local.close()
            await viewerConnection.disconnect()
            await authorConnection.disconnect()
        } catch {
            await repository.close()
            try? await local.close()
            await viewerConnection.disconnect()
            await authorConnection.disconnect()
            throw error
        }
    }

    private func verifyMessageDownload(_ fixture: LiveAccountFixture, author: V2AuthCredentials,
                                       room: RoomID, transport: V2ProtobufSyncTransport, connection: V2TLSFrameConnection, directory: URL) async throws {
        let http = V2URLSessionMediaEdgeHTTPTransport(session: fixture.http)
        let credentials = ResourceLiveCredentials(value: author)
        let uploads = try V2HTTPResourceUploadClient(endpoint: fixture.url("v2/resource-uploads"), credentials: credentials, transport: http)
        let bytes = Data("a verified room attachment".utf8), media = MediaID(uuid: UUID())
        let file = directory.appendingPathComponent("attachment.txt")
        try bytes.write(to: file)
        let checksum = try V2ResourceChecksum(value: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
        var session = try await uploads.create(.init(operationID: .init(uuid: UUID()), mediaID: media,
            usage: .messageAttachment(room), contentType: "text/plain", byteCount: Int64(bytes.count), checksum: checksum))
        let uploadDeadline = ContinuousClock.now + .seconds(120)
        while let plan = try await uploads.target(session) {
            guard ContinuousClock.now < uploadDeadline else { throw ResourceLiveFailure.processing }
            try await V2URLSessionResourcePlanExecutor(session: fixture.http).upload(fileURL: file, plan: plan)
            if plan.mode == .httpPut { break }
            session = try await uploads.status(session.locator)
        }
        session = try await uploads.finalize(session)
        let deadline = ContinuousClock.now + .seconds(20)
        while session.resourceState != .ready && ContinuousClock.now < deadline {
            guard session.state != .failed, session.resourceState != .rejected else { throw ResourceLiveFailure.processing }
            try await Task.sleep(for: .milliseconds(200))
            session = try await uploads.status(session.locator)
        }
        try #require(session.resourceState == .ready)
        let sent = try await resourceSend(fixture, client: .init(transport: transport, connection: connection), account:credentials.value,roomID: room, clientMessageID: .init(uuid: UUID()),
            text: "Attachment download contract", media: [.init(mediaID: media)], mentions: [])
        let message = V2MediaMessageLocation(roomID: room, messageID: sent.messageID)
        let resolver = try V2HTTPMediaDownloadTargetResolver(endpoint: fixture.url("v2/media"), credentials: credentials, transport: http)
        let target = try await resolver.resolveDownloadTarget(mediaID: media, message: message)
        #expect(target.expectedByteCount == Int64(bytes.count) && target.checksum == checksum)
        let downloaded = directory.appendingPathComponent("downloaded-attachment.txt")
        try await V2URLSessionMediaByteTransfer(session: fixture.http).download(target: target, destinationURL: downloaded)
        #expect(try Data(contentsOf: downloaded) == bytes)
        // This newly accepted attachment has had no edits; its initial content revision is 1.
        _ = try await resourceWithdraw(fixture,account:credentials.value,roomID:room,messageID:sent.messageID,expectedMessageRevision:1)
        await #expect(throws: V2ClientMediaTransferError.serverStatus(404)) {
            _ = try await resolver.resolveDownloadTarget(mediaID: media, message: message)
        }
        print("Live resource: room attachment uses a checked download plan; withdrawal stops new capability issuance.")
    }

    private func verifyJoinReview(_ fixture: LiveAccountFixture, manager: V2AuthCredentials,
                                  ordinary: V2AuthCredentials, room: RoomID) async throws {
        let applicant = try await fixture.register().credentials
        let http = V2URLSessionGroupInvitationHTTPTransport(session: fixture.http)
        let ownerInvites = try V2HTTPGroupInvitationClient(baseURL: fixture.url(""),
            credentials: ResourceLiveCredentials(value: manager), transport: http)
        let applicantInvites = try V2HTTPGroupInvitationClient(baseURL: fixture.url(""),
            credentials: ResourceLiveCredentials(value: applicant), transport: http)
        let bytesHTTP=V2URLSessionMediaEdgeHTTPTransport(session:fixture.http)
        let ownerOperations=try V2HTTPInvitationOperationClient(baseURL:fixture.url(""),credentials:ResourceLiveCredentials(value:manager),transport:bytesHTTP)
        let applicantOperations=try V2HTTPInvitationOperationClient(baseURL:fixture.url(""),credentials:ResourceLiveCredentials(value:applicant),transport:bytesHTTP)
        let baseline=try await ownerOperations.baseline(roomID:room)
        let created=try await resourceInvitation(ownerOperations,account:manager,room:room,action:.create(lifetimeSeconds:600,maximumApprovedUses:10,expectedMembershipRevision:baseline.membershipRevision))
        guard case .applied(.inviteCreated(let inviteID,_,_,_))=created.outcome else {throw ResourceLiveFailure.presentation}
        let invite=try #require(try await ownerInvites.activeInvites(roomID:room).first(where:{$0.inviteID==inviteID}))
        let bearer=V2GroupInvitationSecretAuthorization(secret:invite.secret)
        let submitted=try await resourceInvitation(applicantOperations,account:applicant,room:room,action:.submit(inviteID:inviteID,tokenDigest:bearer.tokenDigest,note:"Review fixture"),authorization:bearer)
        guard case .applied(.requestSubmitted(let requestID,_))=submitted.outcome else {throw ResourceLiveFailure.presentation}
        let pending=try await ownerInvites.pendingRequests(roomID:room,cursor:nil,pageSize:100)
        let request=try #require(pending.requests.first(where:{$0.requestID==requestID}))
        #expect(pending.requests.map(\.requestID)==[requestID]);#expect(request.applicantUserID==applicant.userID)
        let ownerProfiles = try V2HTTPProfilePresentationClient(endpoint: fixture.url("v2/profile-presentations/batch"),
            credentials: ResourceLiveCredentials(value: manager), transport: bytesHTTP)
        let memberProfiles = try V2HTTPProfilePresentationClient(endpoint: fixture.url("v2/profile-presentations/batch"),
            credentials: ResourceLiveCredentials(value: ordinary), transport: bytesHTTP)
        let memberKey = V2ProfileViewLookupKey(userID: applicant.userID, context: .room(room))
        let granted = try await readReviewPage(ownerProfiles, keys: [request.presentationKey, memberKey])
        #expect(granted.presentations.count == 1 && granted.presentations[request.presentationKey]?.lease.key == request.presentationKey)
        #expect(granted.unavailable == [memberKey])
        let denied = try await readReviewPage(memberProfiles, keys: [request.presentationKey])
        #expect(denied.unavailable == [request.presentationKey] && denied.presentations.isEmpty)
        let cancelled=try await resourceInvitation(applicantOperations,account:applicant,room:room,action:.cancel(requestID:request.requestID))
        #expect(cancelled.outcome == .applied(.requestCancelled(requestID:request.requestID)))
        let after = try await readReviewPage(ownerProfiles, keys: [request.presentationKey])
        #expect(after.unavailable == [request.presentationKey] && after.presentations.isEmpty)
        let resubmitted = try await resourceInvitation(applicantOperations, account: applicant, room: room,
            action: .submit(inviteID: inviteID, tokenDigest: bearer.tokenDigest, note: "Rejection fixture"), authorization: bearer)
        guard case .applied(.requestSubmitted(let secondRequest, _)) = resubmitted.outcome else { throw ResourceLiveFailure.presentation }
        let rejectionBaseline = try await ownerOperations.baseline(roomID: room)
        let rejected = try await resourceInvitation(ownerOperations, account: manager, room: room,
            action: .decide(requestID: secondRequest, decision: .reject, expectedMembershipRevision: rejectionBaseline.membershipRevision))
        #expect(rejected.outcome == .applied(.requestDecided(requestID: secondRequest, decision: .reject, membershipRevision: nil)))
        print("Live resource: owner rejected the real join request without changing membership.")
        // Rejection is terminal for this applicant/invitation. Use a distinct
        // actual account for approval rather than reopening the rejected fact.
        let approvalApplicant = try await fixture.register().credentials
        let approvalOperations = try V2HTTPInvitationOperationClient(baseURL: fixture.url(""),
            credentials: ResourceLiveCredentials(value: approvalApplicant), transport: bytesHTTP)
        let submittedForApproval = try await resourceInvitation(approvalOperations, account: approvalApplicant, room: room,
            action: .submit(inviteID: inviteID, tokenDigest: bearer.tokenDigest, note: "Approval fixture"), authorization: bearer)
        guard case .applied(.requestSubmitted(let approvalRequest, _)) = submittedForApproval.outcome else { throw ResourceLiveFailure.presentation }
        let reviewBaseline = try await ownerOperations.baseline(roomID: room)
        let approved = try await resourceInvitation(ownerOperations, account: manager, room: room,
            action: .decide(requestID: approvalRequest, decision: .approve, expectedMembershipRevision: reviewBaseline.membershipRevision))
        guard case .applied(.requestDecided(let decided, let decision, let revision)) = approved.outcome else { throw ResourceLiveFailure.presentation }
        #expect(decided == approvalRequest && decision == .approve && revision == reviewBaseline.membershipRevision + 1)
        let memberConnection = try connection(authorSupplements: false)
        do {
            let session = try await authenticate(memberConnection, approvalApplicant)
            let transport = V2ProtobufSyncTransport(wire: memberConnection, protocolVersion: session.protocolVersion)
            let roster = try await transport.listRoomMembers(roomID: room, cursor: nil, pageSize: 100)
            #expect(roster.members.contains { $0.userID == approvalApplicant.userID })
            #expect(!roster.members.contains { $0.userID == applicant.userID })
            await memberConnection.disconnect()
        } catch { await memberConnection.disconnect(); throw error }
        let finalBaseline = try await ownerOperations.baseline(roomID: room)
        let revoked = try await resourceInvitation(ownerOperations, account: manager, room: room,
            action: .revoke(inviteID: inviteID, expectedMembershipRevision: finalBaseline.membershipRevision))
        #expect(revoked.outcome == .applied(.inviteRevoked(inviteID: inviteID)))
        #expect(try await ownerInvites.activeInvites(roomID: room).allSatisfy { $0.inviteID != inviteID })
        print("Live resource: join request cancellation, rejection, owner approval, actual member roster and invitation revocation passed.")
    }

    private func readReviewPage(_ client: V2HTTPProfilePresentationClient,
                                keys: [V2ProfileViewLookupKey]) async throws -> V2ProfilePresentationBatch {
        // This raw HTTP exercise has no UI repository to schedule Retry-After.
        // Honor only an explicit overload response; authorization failures and
        // per-item retryable results still fail the assertions unchanged.
        for attempt in 0..<3 {
            do { return try await client.readPresentations(keys) }
            catch V2ProfilePresentationError.throttled(let retryAfter) where attempt < 2 && retryAfter <= 5 {
                print("Live resource: profile HTTP honored Retry-After before its bounded retry.")
                try await Task.sleep(for: .seconds(retryAfter + 0.05))
            }
        }
        throw ResourceLiveFailure.timeout
    }

    private func updateNickname(_ fixture: LiveAccountFixture, author: V2AuthCredentials, room: RoomID,
                                expectedRevision: Int?, name: String?) async throws {
        let client = try V2HTTPNameOperationClient(
            endpoint: fixture.url("v2/profile-presentations"),
            credentials: ResourceLiveCredentials(value: author),
            transport: V2URLSessionPushEndpointHTTPTransport(session: fixture.http))
        let revision: V2ProfileRevision?
        if let expectedRevision {
            revision = try #require(V2ProfileRevision(rawValue: UInt64(expectedRevision)))
        } else { revision = nil }
        let command = try V2GroupNicknameUpdateCommand(actorUserID: author.userID,
            roomID: room, operationID: .init(uuid: UUID()), expectedRevision: revision,
            nickname: name, firstSubmissionDeadlineMilliseconds: UInt64(Date().timeIntervalSince1970 * 1000) + 600_000)
        let proof = try await client.submit(command)
        try V2FrozenNameOperation.group(command).validate(.group(proof))
        guard case .committed(let value) = proof.outcome else { throw ResourceLiveFailure.presentation }
        #expect(value.groupNickname == command.nickname)
        // Recovery must verify the same frozen identity and fingerprint, without
        // replacing its original deadline or authorizing another write.
        let recovery = try V2GroupNicknameRecoveryRequest(identity: command.identity,
            fingerprint: command.fingerprint, action: .query)
        guard case .receipt(let original) = try await client.recover(recovery) else {
            throw ResourceLiveFailure.presentation
        }
        #expect(original == proof)
    }

    private func seedRoom(_ fixture: LiveAccountFixture, viewer: UserID, author: UserID) async throws -> RoomID {
        var request = URLRequest(url: fixture.url("__fixture__/room"))
        request.httpMethod = "POST"
        let token: String = try #require(ProcessInfo.processInfo.environment["IMV2_LIVE_RESOURCE_FIXTURE_TOKEN"])
        request.setValue(token, forHTTPHeaderField: "X-Resource-Fixture")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["viewer": viewer.rawValue, "author": author.rawValue])
        let (data, response) = try await fixture.http.data(for: request)
        try #require((response as? HTTPURLResponse)?.statusCode == 200)
        return try RoomID(#require(JSONDecoder().decode([String: String].self, from: data)["roomID"]))
    }

    private func connection(authorSupplements: Bool, scheduler: V2AccountWorkScheduler? = nil) throws -> V2TLSFrameConnection {
        let environment = ProcessInfo.processInfo.environment
        let port = try #require(environment["IMV2_LIVE_RESOURCE_GATEWAY_PORT"].flatMap(UInt16.init).flatMap(NWEndpoint.Port.init(rawValue:)))
        let ca = try Data(contentsOf: URL(fileURLWithPath: #require(environment["IMV2_LIVE_ACCOUNT_CA_DER"])))
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
           requestTimeout: .seconds(10), supportsAuthorPresentationDelta: authorSupplements, workScheduler: scheduler)
    }

    private func authenticate(_ connection: V2TLSFrameConnection, _ credentials: V2AuthCredentials) async throws -> V2AuthenticatedClientSession {
        try await connection.connectAndAuthenticate(accessToken: credentials.accessToken,
            deviceID: credentials.deviceID, supportedCapabilityProfiles: ["base"])
    }

    private func bounded<Value: Sendable>(_ operation: @escaping @Sendable () async throws -> Value) async throws -> Value {
        try await withThrowingTaskGroup(of: Value.self) { group in
            group.addTask { try await operation() }
            group.addTask { try await Task.sleep(for: .seconds(8)); throw ResourceLiveFailure.timeout }
            defer { group.cancelAll() }
            return try await #require(group.next())
        }
    }

    private func makeImage(at url: URL) throws {
        let context = try #require(CGContext(data: nil, width: 300, height: 160, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 300, height: 160))
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try #require(context.makeImage()), nil)
        try #require(CGImageDestinationFinalize(destination))
    }

    private func checkAvatar(at url: URL) throws {
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(image.width == 128 && image.height == 128)
    }
}

private struct ResourceLiveCredentials: V2ClientMediaEdgeCredentialProvider, V2ClientPushEndpointCredentialProvider {
    let value: V2AuthCredentials
    func mediaEdgeCredentials() -> V2ClientMediaEdgeCredentials { .init(accessToken: value.accessToken, deviceID: value.deviceID) }
    func pushEndpointCredentials() -> V2ClientPushEndpointCredentials { .init(accessToken: value.accessToken, deviceID: value.deviceID) }
}

private struct SlowResourceUploadState: Decodable {
    let hits: Int, bodyBytesRead: Int, completed: Int, active: Int, expired: Int
    let waiting: Bool, released: Bool
}

private enum ResourceLiveFailure: Error { case processing, presentation, revocation, timeout }
private struct ResourceLiveOpenedRoom {let roomID:RoomID}
private func resourceOpenDirect(_ fixture:LiveAccountFixture,account:V2AuthCredentials,target:UserID) async throws -> ResourceLiveOpenedRoom {
    let client=try V2HTTPDirectRoomOperationClient(baseURL:fixture.url(""),credentials:ResourceLiveCredentials(value:account),transport:V2URLSessionMediaEdgeHTTPTransport(session:fixture.http))
    let command=try V2DirectRoomOperationCommand(actorUserID:account.userID,operationID:.init(uuid:UUID()),targetUserID:target,firstSubmissionDeadlineMilliseconds:UInt64(Date().timeIntervalSince1970*1000)+600000)
    guard case .receipt(let proof)=try await client.submit(command),proof.validates(command:command),case .opened(let room,_)=proof.outcome else {throw ResourceLiveFailure.presentation};return .init(roomID:room)
}
private func resourceRelationship(_ fixture:LiveAccountFixture,account:V2AuthCredentials,target:UserID,action:V2RelationshipAction) async throws {
    let client=try V2HTTPSocialOperationClient(baseURL:fixture.url(""),credentials:ResourceLiveCredentials(value:account),transport:V2URLSessionMediaEdgeHTTPTransport(session:fixture.http))
    let baseline=try await client.baseline(targetUserID:target)
    let command=try V2SocialOperationCommand(identity:.init(accountID:account.userID,scope:.userPair(account.userID,target),operation:.relationship(.init(uuid:UUID()))),action:.relationship(action),expectedRevision:baseline.relationshipRevision,firstSubmissionDeadlineMilliseconds:UInt64(Date().timeIntervalSince1970*1000)+600000)
    guard case .receipt(let proof)=try await client.submit(command),proof.validates(command:command),case .applied=proof.outcome else {throw ResourceLiveFailure.presentation}
}
private func resourceBlock(_ fixture:LiveAccountFixture,account:V2AuthCredentials,target:UserID) async throws {
    let client=try V2HTTPSocialOperationClient(baseURL:fixture.url(""),credentials:ResourceLiveCredentials(value:account),transport:V2URLSessionMediaEdgeHTTPTransport(session:fixture.http))
    let baseline=try await client.baseline(targetUserID:target)
    let command=try V2SocialOperationCommand(identity:.init(accountID:account.userID,scope:.userPair(account.userID,target),operation:.userBlock(.init(uuid:UUID()))),action:.userBlock(.block),expectedRevision:baseline.blockRevision,firstSubmissionDeadlineMilliseconds:UInt64(Date().timeIntervalSince1970*1000)+120000)
    guard case .receipt(let proof)=try await client.submit(command),proof.validates(command:command),case .applied(.userBlock(isBlocked:true,revision:_))=proof.outcome else {throw ResourceLiveFailure.presentation}
}
private func resourceSend(_ fixture:LiveAccountFixture,client: V2ProtobufMessageSendOperationClient,account:V2AuthCredentials,roomID:RoomID,clientMessageID:ClientMessageID,text:String,media:[V2MediaReference],mentions:[V2MentionTarget]) async throws -> V2MessageOperationAcceptance {
    let command=try V2MessageSendOperationCommand(command:.init(roomID:roomID,senderUserID:account.userID,clientMessageID:clientMessageID,text:text,media:media,mentions:mentions,limits:.init(maxUTF8Bytes:4096)),firstSubmissionDeadlineMilliseconds:UInt64(Date().timeIntervalSince1970*1000)+86400000)
    guard case .receipt(let proof)=try await client.submit(command),try proof.validates(identity:command.identity,fingerprint:command.fingerprint),case .accepted(let value)=proof.outcome else {throw ResourceLiveFailure.presentation};return value
}
private func resourceWithdraw(_ fixture:LiveAccountFixture,account:V2AuthCredentials,roomID:RoomID,messageID:MessageID,expectedMessageRevision:UInt64) async throws {
    let client=try V2HTTPMessageMutationOperationClient(baseURL:fixture.url(""),credentials:ResourceLiveCredentials(value:account),transport:V2URLSessionMediaEdgeHTTPTransport(session:fixture.http))
    let command=try V2MessageWithdrawalOperationCommand(command:.init(roomID:roomID,actorUserID:account.userID,operationID:.init(uuid:UUID()),messageID:messageID,expectedMessageRevision:expectedMessageRevision),firstSubmissionDeadlineMilliseconds:UInt64(Date().timeIntervalSince1970*1000)+600000)
    guard case .receipt(let proof)=try await client.submit(.withdraw(command)),try proof.validates(identity:command.identity,fingerprint:command.fingerprint),case .committed=proof.outcome else {throw ResourceLiveFailure.presentation}
}
private func resourceInvitation(_ client:V2HTTPInvitationOperationClient,account:V2AuthCredentials,room:RoomID,action:V2GroupInvitationOperationAction,authorization:V2GroupInvitationSecretAuthorization?=nil) async throws -> V2GroupInvitationOperationReceipt {
    let reference:V2OperationReference
    switch action.kind {case .groupInvite:reference = .groupInvite(.init(uuid:UUID()));case .groupJoinRequest:reference = .groupJoinRequest(.init(uuid:UUID()));case .groupJoinDecision:reference = .groupJoinDecision(.init(uuid:UUID()));default:throw ResourceLiveFailure.presentation}
    let intent=try V2GroupInvitationOperationIntent(identity:.init(accountID:account.userID,scope:.room(room),operation:reference),action:action,confirmedUntilMilliseconds:UInt64(Date().timeIntervalSince1970*1000)+120000)
    guard case .admitted(let admission)=try await client.admit(.init(intent:intent,secretAuthorization:authorization)) else {throw ResourceLiveFailure.presentation}
    let submission=try V2GroupInvitationSubmission(command:.init(intent:intent,admission:admission),secretAuthorization:authorization)
    guard case .receipt(let proof)=try await client.submit(submission),proof.validates(intent:intent) else {throw ResourceLiveFailure.presentation};return proof
}
extension V2LiveResourceAuthorTests {
    @Test("real group avatar upload, byte presentation, removal and original recovery",
          .enabled(if: ProcessInfo.processInfo.environment["IMV2_LIVE_EXTENDED_ACCEPTANCE"] == "1"))
    func groupAvatarAcceptance() async throws {
        let fixture = try LiveAccountFixture()
        defer { fixture.close() }
        let owner = try await fixture.register().credentials
        let member = try await fixture.register().credentials
        let room = try await seedRoom(fixture, viewer: member.userID, author: owner.userID)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.png")
        try makeImage(at: source)
        let bytes = try Data(contentsOf: source)
        let media = MediaID(uuid: UUID())
        let credentials = ResourceLiveCredentials(value: owner)
        let http = V2URLSessionMediaEdgeHTTPTransport(session: fixture.http)
        let upload = try V2HTTPResourceUploadClient(endpoint: fixture.url("v2/resource-uploads"), credentials: credentials, transport: http)
        let checksum = try V2ResourceChecksum(value: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
        var uploadSession = try await upload.create(.init(operationID: .init(uuid: UUID()), mediaID: media,
            usage: .groupAvatar(room), contentType: "image/png", byteCount: Int64(bytes.count), checksum: checksum))
        let limit = ContinuousClock.now + .seconds(45)
        while let plan = try await upload.target(uploadSession) {
            guard ContinuousClock.now < limit else { throw ResourceLiveFailure.processing }
            try await V2URLSessionResourcePlanExecutor(session: fixture.http).upload(fileURL: source, plan: plan)
            if plan.mode == .httpPut { break }
            uploadSession = try await upload.status(uploadSession.locator)
        }
        uploadSession = try await upload.finalize(uploadSession)
        while uploadSession.resourceState != .ready {
            guard ContinuousClock.now < limit, uploadSession.state != .failed, uploadSession.resourceState != .rejected else {
                throw ResourceLiveFailure.processing
            }
            try await Task.sleep(for: .milliseconds(200))
            uploadSession = try await upload.status(uploadSession.locator)
        }
        let commands = try V2HTTPGroupAvatarCommandClient(roomsEndpoint: fixture.url("v2/rooms"),
            actorUserID: owner.userID, credentials: credentials, transport: http)
        let ownerViews = try V2HTTPGroupAvatarPresentationClient(roomsEndpoint: fixture.url("v2/rooms"),
            actorUserID: owner.userID, credentials: credentials, transport: http)
        let memberViews = try V2HTTPGroupAvatarPresentationClient(roomsEndpoint: fixture.url("v2/rooms"),
            actorUserID: member.userID, credentials: ResourceLiveCredentials(value: member), transport: http)
        var before = try await ownerViews.readGroupAvatar(roomID: room)
        for mutation in [V2GroupAvatarMutation.set(media), .remove] {
            let command = try V2GroupAvatarCommand(operationID: .init(uuid: UUID()), roomID: room,
                expectedRevision: before.state.revision, mutation: mutation)
            let result = try await commands.submitGroupAvatar(command)
            guard case .committed(let change) = result.outcome else { throw ResourceLiveFailure.presentation }
            #expect(change.state.mediaID == mutation.mediaID)
            #expect(try await commands.submitGroupAvatar(command) == result)
            #expect(try await commands.recoverGroupAvatar(.init(command: command, action: .query)).result == .committed(change))
            let visible = try await memberViews.readGroupAvatar(roomID: room)
            #expect(visible.state == change.state && !visible.canManage)
            if let avatar = visible.avatar {
                let output = directory.appendingPathComponent("downloaded.png")
                try await V2URLSessionMediaByteTransfer(session: fixture.http).download(
                    target: .init(downloadPlan: avatar.plan), destinationURL: output)
                try checkAvatar(at: output)
            } else { #expect(mutation == .remove) }
            before = try await ownerViews.readGroupAvatar(roomID: room)
            #expect(before.state == change.state)
        }
        print("Live acceptance: group avatar real upload/processing/set/download/remove/recover passed.")
    }

    @Test("real voluntary group exit, owner protection and original recovery",
          .enabled(if: ProcessInfo.processInfo.environment["IMV2_LIVE_EXTENDED_ACCEPTANCE"] == "1"))
    func voluntaryGroupExitAcceptance() async throws {
        let fixture = try LiveAccountFixture(); defer { fixture.close() }
        let owner = try await fixture.register().credentials
        let member = try await fixture.register().credentials
        let room = try await seedRoom(fixture, viewer: member.userID, author: owner.userID)
        let socket = try connection(authorSupplements: false)
        let memberSocket = try connection(authorSupplements: false)
        do {
            let session = try await authenticate(socket, owner)
            let memberSession = try await authenticate(memberSocket, member)
            let transport = V2ProtobufSyncTransport(wire: socket, protocolVersion: session.protocolVersion)
            let memberTransport = V2ProtobufSyncTransport(wire: memberSocket, protocolVersion: memberSession.protocolVersion)
            let http = V2URLSessionMediaEdgeHTTPTransport(session: fixture.http)
            let ownerClient = try V2HTTPMembershipOperationClient(baseURL: fixture.url(""),
                credentials: ResourceLiveCredentials(value: owner), transport: http)
            let memberClient = try V2HTTPMembershipOperationClient(baseURL: fixture.url(""),
                credentials: ResourceLiveCredentials(value: member), transport: http)
            let baseline = try await transport.fetchRolePolicyBaseline(roomID: room)
            let ownerExit = try V2MembershipIntent(roomID: room, actorUserID: owner.userID,
                operationID: .init(uuid: UUID()), targetUserID: owner.userID, action: .remove,
                expectedMembershipRevision: baseline.membershipRevision, confirmedUntilMilliseconds: liveAcceptanceDeadline())
            #expect(try await ownerClient.admit(ownerExit) == .currentUnavailable(.permissionDenied))
            let intent = try V2MembershipIntent(roomID: room, actorUserID: member.userID,
                operationID: .init(uuid: UUID()), targetUserID: member.userID, action: .remove,
                expectedMembershipRevision: baseline.membershipRevision, confirmedUntilMilliseconds: liveAcceptanceDeadline())
            guard case .admitted(let admission) = try await memberClient.admit(intent) else { throw ResourceLiveFailure.presentation }
            let command = try V2MembershipOperationCommand(intent: intent, admission: admission)
            let result = try await memberClient.submit(command)
            guard case .receipt(let receipt) = result, case .changed(let change) = receipt.outcome else { throw ResourceLiveFailure.presentation }
            #expect(change.membershipRevision == baseline.membershipRevision + 1)
            #expect(try await memberClient.submit(command) == result)
            #expect(try await memberClient.recover(command, action: .query) == result)
            let roster = try await transport.listRoomMembers(roomID: room, cursor: nil, pageSize: 20)
            #expect(!roster.members.contains { $0.userID == member.userID })
            let sender = V2ProtobufMessageSendOperationClient(transport: memberTransport, connection: memberSocket)
            let forbidden = try V2MessageSendOperationCommand(command: .init(roomID: room, senderUserID: member.userID,
                clientMessageID: .init(uuid: UUID()), text: "Must fail after voluntary exit", limits: .init(maxUTF8Bytes: 4096)),
                firstSubmissionDeadlineMilliseconds: liveAcceptanceDeadline())
            guard case .receipt(let denial) = try await sender.submit(forbidden), case .rejected = denial.outcome else {
                Issue.record("Member could send after voluntary exit"); throw ResourceLiveFailure.presentation
            }
            await memberSocket.disconnect(); await socket.disconnect()
        } catch { await memberSocket.disconnect(); await socket.disconnect(); throw error }
        print("Live acceptance: voluntary exit, original replay/recovery and immediate send denial passed.")
    }

    @Test("real moderation, member mute and removal with persisted recovery",
          .enabled(if: ProcessInfo.processInfo.environment["IMV2_LIVE_EXTENDED_ACCEPTANCE"] == "1"))
    func moderationAcceptance() async throws {
        let fixture = try LiveAccountFixture()
        defer { fixture.close() }
        let owner = try await fixture.register().credentials
        let member = try await fixture.register().credentials
        let room = try await seedRoom(fixture, viewer: member.userID, author: owner.userID)
        let socket = try connection(authorSupplements: false)
        let memberSocket = try connection(authorSupplements: false)
        do {
            let session = try await authenticate(socket, owner)
            let memberSession = try await authenticate(memberSocket, member)
            let transport = V2ProtobufSyncTransport(wire: socket, protocolVersion: session.protocolVersion)
            let memberTransport = V2ProtobufSyncTransport(wire: memberSocket, protocolVersion: memberSession.protocolVersion)
            let sender = V2ProtobufMessageSendOperationClient(transport: memberTransport, connection: memberSocket)
            let sent = try await resourceSend(fixture, client: sender, account: member, roomID: room,
                clientMessageID: .init(uuid: UUID()), text: "Acceptance moderation target", media: [], mentions: [])
            let credentials = ResourceLiveCredentials(value: owner)
            let http = V2URLSessionMediaEdgeHTTPTransport(session: fixture.http)
            let moderation = try V2HTTPMessageModerationClient(baseURL: fixture.url(""), credentials: credentials, transport: http)
            let baseline = try await moderation.baseline(roomID: room, messageID: sent.messageID)
            let intent = try V2MessageModerationIntent(roomID: room, actorUserID: owner.userID, operationID: .init(uuid: UUID()),
                messageID: sent.messageID, reasonCode: .init("acceptance"), expectedMessageRevision: baseline.messageRevision,
                expectedMembershipRevision: baseline.membershipRevision, confirmedUntilMilliseconds: liveAcceptanceDeadline())
            guard case .admitted(let admission) = try await moderation.admit(intent) else { throw ResourceLiveFailure.presentation }
            let result = try await moderation.submit(.init(intent: intent, admission: admission))
            guard case .receipt(let receipt) = result, receipt.validates(intent: intent), case .redacted = receipt.outcome else {
                throw ResourceLiveFailure.presentation
            }
            #expect(try await moderation.recover(intent, action: .query) == result)
            let administration = try V2HTTPMemberAdministrationClient(baseURL: fixture.url(""), credentials: credentials, transport: http)
            for action in [V2MemberAdministrationAction.mute(untilMilliseconds: liveAcceptanceDeadline()), .remove] {
                let current = try await transport.fetchRolePolicyBaseline(roomID: room)
                let intent = try V2MemberAdministrationIntent(roomID: room, actorUserID: owner.userID,
                    operationID: .init(uuid: UUID()), targetUserID: member.userID, action: action, reasonCode: .init("acceptance"),
                    expectedMembershipRevision: current.membershipRevision, confirmedUntilMilliseconds: liveAcceptanceDeadline())
                guard case .admitted(let admission) = try await administration.admit(intent) else { throw ResourceLiveFailure.presentation }
                let command = try V2MemberAdministrationCommand(intent: intent, admission: admission)
                let result = try await administration.submit(command)
                guard case .receipt(let receipt) = result, receipt.validates(command: command), case .applied = receipt.outcome else {
                    throw ResourceLiveFailure.presentation
                }
                #expect(try await administration.recover(command, action: .query) == result)
                let forbidden = try V2MessageSendOperationCommand(command: .init(roomID: room, senderUserID: member.userID,
                    clientMessageID: .init(uuid: UUID()), text: "Must be rejected after policy change", limits: .init(maxUTF8Bytes: 4096)),
                    firstSubmissionDeadlineMilliseconds: liveAcceptanceDeadline())
                guard case .receipt(let denial) = try await sender.submit(forbidden), case .rejected = denial.outcome else {
                    Issue.record("Muted or removed member could still send"); throw ResourceLiveFailure.presentation
                }
            }
            let roster = try await transport.listRoomMembers(roomID: room, cursor: nil, pageSize: 20)
            #expect(!roster.members.contains { $0.userID == member.userID })
            await memberSocket.disconnect(); await socket.disconnect()
        } catch { await memberSocket.disconnect(); await socket.disconnect(); throw error }
        print("Live acceptance: moderation, mute/remove original recovery and post-change send denial passed.")
    }

    @Test("real message edit, reaction, personal preferences, pin and withdrawal",
          .enabled(if: ProcessInfo.processInfo.environment["IMV2_LIVE_EXTENDED_ACCEPTANCE"] == "1"))
    func messageOperationAcceptance() async throws {
        let fixture = try LiveAccountFixture()
        defer { fixture.close() }
        let author = try await fixture.register().credentials
        let viewer = try await fixture.register().credentials
        let room = try await seedRoom(fixture, viewer: viewer.userID, author: author.userID)
        let socket = try connection(authorSupplements: false)
        let reader = try connection(authorSupplements: false)
        do {
            let session = try await authenticate(socket, author)
            let readerSession = try await authenticate(reader, viewer)
            let transport = V2ProtobufSyncTransport(wire: socket, protocolVersion: session.protocolVersion)
            let viewerTransport = V2ProtobufSyncTransport(wire: reader, protocolVersion: readerSession.protocolVersion)
            let sendClient = V2ProtobufMessageSendOperationClient(transport: transport, connection: socket)
            let send = try V2MessageSendOperationCommand(command: .init(roomID: room, senderUserID: author.userID,
                clientMessageID: .init(uuid: UUID()), text: "Acceptance original", limits: .init(maxUTF8Bytes: 4096)),
                firstSubmissionDeadlineMilliseconds: liveAcceptanceDeadline())
            let submitted = try await sendClient.submit(send)
            guard case .receipt(let original) = submitted, case .accepted(let sent) = original.outcome else {
                throw ResourceLiveFailure.presentation
            }
            #expect(try await sendClient.submit(send) == submitted)
            #expect(try await sendClient.recover(.init(identity: send.identity, fingerprint: send.fingerprint,
                domainFingerprint: send.command.fingerprint, action: .query)) == submitted)
            let http = V2URLSessionMediaEdgeHTTPTransport(session: fixture.http)
            let credentials = ResourceLiveCredentials(value: author)
            let mutations = try V2HTTPMessageMutationOperationClient(baseURL: fixture.url(""), credentials: credentials, transport: http)
            let edit = try V2MessageEditOperationCommand(command: .init(roomID: room, actorUserID: author.userID,
                operationID: .init(uuid: UUID()), messageID: sent.messageID, expectedMessageRevision: 1,
                text: "Acceptance edited", maximumUTF8Bytes: 4096), firstSubmissionDeadlineMilliseconds: liveAcceptanceDeadline())
            let edited = try await mutations.submit(.edit(edit))
            guard case .receipt(let editProof) = edited, case .committed(let editCommit) = editProof.outcome else {
                throw ResourceLiveFailure.presentation
            }
            #expect(editCommit.messageRevision == 2)
            #expect(try await mutations.recover(.init(identity: edit.identity, fingerprint: edit.fingerprint, action: .query)) == edited)
            let reactions = try V2HTTPMessageReactionOperationClient(baseURL: fixture.url(""), credentials: credentials, transport: http)
            for action in [V2MessageReactionAction.add, .remove] {
                let baseline = try await reactions.snapshot(roomID: room, messageID: sent.messageID, reaction: "👍")
                let command = try V2MessageReactionOperationCommand(command: .init(roomID: room, actorUserID: author.userID,
                    operationID: .init(uuid: UUID()), messageID: sent.messageID, reaction: "👍", action: action),
                    expectedReactionRevision: baseline.revision, firstSubmissionDeadlineMilliseconds: liveAcceptanceDeadline())
                let result = try await reactions.submit(command)
                guard case .receipt(let receipt) = result, case .committed(let committed) = receipt.outcome else {
                    throw ResourceLiveFailure.presentation
                }
                #expect(committed.targetState == (action == .add ? .present : .absent))
                #expect(try await reactions.recover(.init(identity: command.identity, fingerprint: command.fingerprint, action: .query)) == result)
                let persisted = try await reactions.snapshot(roomID: room, messageID: sent.messageID, reaction: "👍")
                #expect(persisted.targetState == committed.targetState && persisted.revision == baseline.revision + 1)
            }
            let conversation = try V2ConversationStateCommand(operationID: .init(uuid: UUID()), roomID: room,
                isPinned: true, isArchived: false, muteUntil: nil, expectedRevision: .init(rawValue: 0)!,
                firstSubmissionDeadlineMilliseconds: liveAcceptanceDeadline())
            let conversationProof = try await transport.setConversationState(command: conversation)
            guard case .committed(.conversationState(let state)) = conversationProof.outcome else { throw ResourceLiveFailure.presentation }
            #expect(state.isPinned && !state.isArchived)
            #expect(try await transport.setConversationState(command: conversation) == conversationProof)
            let muteUntil = Date().addingTimeInterval(600)
            let archived = try V2ConversationStateCommand(operationID: .init(uuid: UUID()), roomID: room,
                isPinned: false, isArchived: true, muteUntil: muteUntil, expectedRevision: state.revision,
                firstSubmissionDeadlineMilliseconds: liveAcceptanceDeadline())
            let archivedProof = try await transport.setConversationState(command: archived)
            guard case .committed(.conversationState(let archivedState)) = archivedProof.outcome else { throw ResourceLiveFailure.presentation }
            #expect(!archivedState.isPinned && archivedState.isArchived && archivedState.muteUntil != nil)
            #expect(try await transport.setConversationState(command: archived) == archivedProof)
            let favorite = try V2MessageFavoriteCommand(operationID: .init(uuid: UUID()), roomID: room, messageID: sent.messageID,
                isFavorited: true, expectedRevision: .init(rawValue: 0)!, firstSubmissionDeadlineMilliseconds: liveAcceptanceDeadline())
            let favoriteProof = try await transport.setMessageFavorite(command: favorite)
            guard case .committed(.messageFavorite(let value)) = favoriteProof.outcome else { throw ResourceLiveFailure.presentation }
            #expect(value.isFavorited)
            #expect(try await transport.setMessageFavorite(command: favorite) == favoriteProof)
            let capabilities = try V2HTTPGroupCapabilityOperationClient(baseURL: fixture.url(""), credentials: credentials, transport: http)
            let baseline = try await capabilities.pinBaseline(roomID: room, messageID: sent.messageID)
            let pinned = try await acceptCapability(capabilities, owner: author.userID, room: room,
                action: .pin(messageID: sent.messageID, isPinned: true, expectedRoomSequence: baseline.roomSequence))
            guard case .pinned(_, let isPinned, _) = pinned else { throw ResourceLiveFailure.presentation }
            #expect(isPinned)
            let history = try await viewerTransport.pullGroupEvents(roomID: room, afterRoomSequence: 0, pageSize: 100)
            #expect(history.events.contains { $0.roomSequence == editCommit.roomSequence })
            let editedPayloads = history.events.compactMap { try? JSONSerialization.jsonObject(with: $0.payload) as? [String: Any] }
            #expect(editedPayloads.contains { $0["text"] as? String == "Acceptance edited" })
            let searchDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: searchDirectory, withIntermediateDirectories: false)
            defer { try? FileManager.default.removeItem(at: searchDirectory) }
            let searchStore = try GRDBV2LocalSyncStore(databaseURL: searchDirectory.appendingPathComponent("search.sqlite"),
                installationBinding: .init(value: UUID()), userID: viewer.userID)
            _ = try await searchStore.applyGroupEventPage(history)
            try await searchStore.prepareMessageSearchIndex()
            while try await searchStore.processPendingMessageSearchIndexJobs() > 0 { try Task.checkCancellation() }
            #expect(try await searchStore.searchMessages(.init(query: "Acceptance edited", scope: .room(room))).hits.map(\.messageID) == [sent.messageID])
            #expect(try await searchStore.searchMessages(.init(query: "Acceptance original", scope: .room(room))).hits.isEmpty)
            let targetRoom = try await seedRoom(fixture, viewer: viewer.userID, author: author.userID)
            let forwarding = try V2HTTPForwardPlanOperationClient(baseURL: fixture.url(""), credentials: credentials, transport: http)
            let forward = try V2ForwardPlanOperationCommand(actorUserID: author.userID,
                command: .init(operationID: .init(uuid: UUID()), sources: [.init(roomID: room, messageID: sent.messageID, revision: .init(2))],
                    targetRoomIDs: [targetRoom]), firstSubmissionDeadlineMilliseconds: liveAcceptanceDeadline())
            var forwarded = try await forwarding.submit(forward)
            let forwardLimit = ContinuousClock.now + .seconds(45)
            while true {
                if case .receipt = forwarded { break }
                guard ContinuousClock.now < forwardLimit else { throw ResourceLiveFailure.processing }
                try await Task.sleep(for: .milliseconds(100))
                forwarded = try await forwarding.recover(forward, action: .query)
            }
            guard case .receipt(let resolved) = forwarded, resolved.validates(command: forward),
                  case .completed(let summary) = resolved.receipt.outcome else { throw ResourceLiveFailure.presentation }
            #expect(summary.succeededItemCount == 1 && summary.rejectedItemCount == 0)
            #expect(try await forwarding.recover(forward, action: .query) == forwarded)
            let copied = try await viewerTransport.pullGroupEvents(roomID: targetRoom, afterRoomSequence: 0, pageSize: 100)
            let copiedPayloads = copied.events.compactMap { try? JSONSerialization.jsonObject(with: $0.payload) as? [String: Any] }
            #expect(copiedPayloads.contains { $0["text"] as? String == "Acceptance edited" })
            try await resourceWithdraw(fixture, account: author, roomID: room, messageID: sent.messageID, expectedMessageRevision: 2)
            let after = try await viewerTransport.pullGroupEvents(roomID: room, afterRoomSequence: history.nextRoomSequence, pageSize: 100)
            let withdrawalPayloads = after.events.compactMap { try? JSONSerialization.jsonObject(with: $0.payload) as? [String: Any] }
            #expect(withdrawalPayloads.contains { $0["event_type"] as? String == "message.withdrawn" })
            _ = try await searchStore.applyGroupEventPage(after)
            while try await searchStore.processPendingMessageSearchIndexJobs() > 0 { try Task.checkCancellation() }
            #expect(try await searchStore.searchMessages(.init(query: "Acceptance edited", scope: .room(room))).hits.isEmpty)
            try await searchStore.close()
            print("Live acceptance: real TLS history to SQLite search; edit removes old text and withdrawal removes search hit.")
            await reader.disconnect(); await socket.disconnect()
        } catch { await reader.disconnect(); await socket.disconnect(); throw error }
        print("Live acceptance: TCP send idempotency/recovery, edit, reaction add/remove, conversation preference, favorite, pin, forward, history and withdrawal passed.")
    }

    @Test("real TCP acceptance waits for local projection before history GC and retains canonical content",
          .enabled(if: ProcessInfo.processInfo.environment["IMV2_LIVE_EXTENDED_ACCEPTANCE"] == "1"))
    func localRetentionAcceptance() async throws {
        let fixture = try LiveAccountFixture()
        defer { fixture.close() }
        let account = try await fixture.register().credentials
        let viewer = try await fixture.register().credentials
        let room = try await seedRoom(fixture, viewer: viewer.userID, author: account.userID)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let binding = V2LocalInstallationBinding(value: UUID())
        let url = directory.appendingPathComponent("retention.sqlite")
        let store = try GRDBV2LocalSyncStore(databaseURL: url, installationBinding: binding, userID: account.userID)
        let intent = try V2SendIntent(id: UUID(), roomID: room, clientMessageID: .init(uuid: UUID()),
            text: "Retained canonical content", attachmentJobIDs: [])
        try await store.freezeSendIntent(intent)
        try await store.handOffSendIntent(intent.id)
        let work = try #require(try await store.dueOperationWork(now: Date(), kinds: [.sendMessage]).first)
        let command = try await store.messageSendCommand(workID: work.id)
        guard case .claimed = try await store.claimOperationWork(id: work.id, ownerID: UUID(), action: .submit, now: Date()) else {
            throw ResourceLiveFailure.presentation
        }
        let socket = try connection(authorSupplements: false)
        do {
            let session = try await authenticate(socket, account)
            let transport = V2ProtobufSyncTransport(wire: socket, protocolVersion: session.protocolVersion)
            let sender = V2ProtobufMessageSendOperationClient(transport: transport, connection: socket)
            guard case .receipt(let receipt) = try await sender.submit(command),
                  case .accepted(let accepted) = receipt.outcome else { throw ResourceLiveFailure.presentation }
            try await store.completeMessageSend(command, receipt: receipt)
            let later = Date().addingTimeInterval(8 * 86_400)
            #expect(try await store.pruneCompletedOperationHistory(now: later) == 0)
            #expect(try await store.submittedSendIntents(in: room).first?.status == .acceptedAwaitingProjection)
            let history = try await transport.pullGroupEvents(roomID: room, afterRoomSequence: 0, pageSize: 100)
            _ = try await store.applyGroupEventPage(history)
            #expect(try await store.messages(in: room).map(\.messageID) == [accepted.messageID])
            #expect(try await store.pruneCompletedOperationHistory(now: later) == 1)
            #expect(try await store.operationWork(id: work.id) == nil)
            #expect(try await store.messages(in: room).first?.text == intent.text)
            // Local history compaction must not erase the server's original outcome.
            #expect(try await sender.recover(.init(identity: command.identity, fingerprint: command.fingerprint,
                domainFingerprint: command.command.fingerprint, action: .query)) == .receipt(receipt))
            try await store.close()
            let reopened = try GRDBV2LocalSyncStore(databaseURL: url, installationBinding: binding, userID: account.userID)
            #expect(try await reopened.messages(in: room).map(\.messageID) == [accepted.messageID])
            #expect(try await reopened.operationWork(id: work.id) == nil)
            try await reopened.close()
            await socket.disconnect()
        } catch {
            await socket.disconnect()
            try? await store.close()
            throw error
        }
        print("Live acceptance: real TCP send retained before projection; local GC removed history only after actual TLS projection and preserved canonical content and original server receipt across SQLite reopen.")
    }

    @Test("real group creation, announcement, permission, role and membership recovery",
          .enabled(if: ProcessInfo.processInfo.environment["IMV2_LIVE_EXTENDED_ACCEPTANCE"] == "1"))
    func groupOperationAcceptance() async throws {
        let fixture = try LiveAccountFixture()
        defer { fixture.close() }
        let owner = try await fixture.register().credentials
        let member = try await fixture.register().credentials
        let newcomer = try await fixture.register().credentials
        let http = V2URLSessionMediaEdgeHTTPTransport(session: fixture.http)
        let credentials = ResourceLiveCredentials(value: owner)
        let creation = try V2HTTPGroupCreationOperationClient(baseURL: fixture.url(""), credentials: credentials, transport: http)
        let audience = try V2GroupCreationAudience.canonical([member.userID], actorUserID: owner.userID)
        let intent = try V2GroupCreationIntent(identity: .init(accountID: owner.userID, scope: .account(owner.userID),
            operation: .groupRoom(.init(uuid: UUID()))), title: "Functional acceptance", capacityClass: .standard,
            initialMemberCount: audience.count, audienceDigest: V2GroupCreationAudience.digest(audience),
            firstSubmissionDeadlineMilliseconds: liveAcceptanceDeadline())
        guard case .progress = try await creation.begin(intent),
              case .progress = try await creation.append(.init(intent: intent, offset: 0, memberUserIDs: audience)) else {
            throw ResourceLiveFailure.presentation
        }
        var result = try await creation.finalize(intent)
        let limit = ContinuousClock.now + .seconds(45)
        while case .progress = result {
            guard ContinuousClock.now < limit else { throw ResourceLiveFailure.processing }
            try await Task.sleep(for: .milliseconds(100))
            result = try await creation.recover(intent, action: .query)
        }
        guard case .receipt(let proof) = result, proof.validates(intent: intent),
              case .created(let room, _, _, _) = proof.outcome else { throw ResourceLiveFailure.presentation }
        #expect(try await creation.recover(intent, action: .query) == result)
        let socket = try connection(authorSupplements: false)
        do {
            let session = try await authenticate(socket, owner)
            let transport = V2ProtobufSyncTransport(wire: socket, protocolVersion: session.protocolVersion)
            let initial = try await transport.fetchRolePolicyBaseline(roomID: room)
            let capabilities = try V2HTTPGroupCapabilityOperationClient(baseURL: fixture.url(""), credentials: credentials, transport: http)
            let announcement = try await acceptCapability(capabilities, owner: owner.userID, room: room,
                action: .announcement(body: "Acceptance announcement", expectedRevision: 0))
            guard case .announcement(let body, let revision, _) = announcement else { throw ResourceLiveFailure.presentation }
            #expect(body == "Acceptance announcement" && revision == 1)
            let permissions = initial.memberPermissions.symmetricDifference([.pinMessages])
            _ = try await acceptCapability(capabilities, owner: owner.userID, room: room,
                action: .rolePermissions(role: .member, permissions: permissions, expectedRevision: initial.permissionRevision))
            let changed = try await transport.fetchRolePolicyBaseline(roomID: room)
            #expect(changed.memberPermissions == permissions && changed.permissionRevision == initial.permissionRevision + 1)
            _ = try await acceptCapability(capabilities, owner: owner.userID, room: room,
                action: .memberRole(targetUserID: member.userID, role: .admin, expectedMembershipRevision: changed.membershipRevision))
            let roster = try await transport.listRoomMembers(roomID: room, cursor: nil, pageSize: 20)
            #expect(roster.members.contains { $0.userID == member.userID && $0.role == .admin })
            let membership = try V2HTTPMembershipOperationClient(baseURL: fixture.url(""), credentials: credentials, transport: http)
            for action in [V2RoomMembershipAction.add, .remove] {
                let before = try await transport.fetchRolePolicyBaseline(roomID: room)
                let change = try V2MembershipIntent(roomID: room, actorUserID: owner.userID, operationID: .init(uuid: UUID()),
                    targetUserID: newcomer.userID, action: action, expectedMembershipRevision: before.membershipRevision,
                    confirmedUntilMilliseconds: liveAcceptanceDeadline())
                guard case .admitted(let admission) = try await membership.admit(change) else { throw ResourceLiveFailure.presentation }
                let command = try V2MembershipOperationCommand(intent: change, admission: admission)
                let applied = try await membership.submit(command)
                guard case .receipt(let receipt) = applied, receipt.validates(command: command), case .changed = receipt.outcome else {
                    throw ResourceLiveFailure.presentation
                }
                #expect(try await membership.recover(command, action: .query) == applied)
                let current = try await transport.listRoomMembers(roomID: room, cursor: nil, pageSize: 20)
                #expect(current.members.contains { $0.userID == newcomer.userID } == (action == .add))
            }
            await socket.disconnect()
        } catch { await socket.disconnect(); throw error }
        print("Live acceptance: group creation, announcement, permissions, role, membership add/remove and original recovery passed.")
    }

    private func acceptCapability(_ client: V2HTTPGroupCapabilityOperationClient, owner: UserID, room: RoomID,
                                  action: V2GroupCapabilityAction) async throws -> V2GroupCapabilityValue {
        let reference: V2OperationReference
        let scope: V2OperationScope
        switch action {
        case .pin(let message, _, _): reference = .pinnedMessage(.init(uuid: UUID())); scope = .message(room, message)
        case .announcement: reference = .groupAnnouncement(.init(uuid: UUID())); scope = .room(room)
        case .rolePermissions: reference = .groupPermission(.init(uuid: UUID())); scope = .room(room)
        case .memberRole: reference = .groupRole(.init(uuid: UUID())); scope = .room(room)
        }
        let intent = try V2GroupCapabilityIntent(identity: .init(accountID: owner, scope: scope, operation: reference),
            action: action, confirmedUntilMilliseconds: liveAcceptanceDeadline())
        guard case .admitted(let admission) = try await client.admit(intent) else { throw ResourceLiveFailure.presentation }
        let command = try V2GroupCapabilityCommand(intent: intent, admission: admission)
        let result = try await client.submit(command)
        guard case .receipt(let receipt) = result, receipt.validates(command: command),
              case .applied(let value) = receipt.outcome else { throw ResourceLiveFailure.presentation }
        #expect(try await client.recover(command, action: .query) == result)
        return value
    }

    @Test("real account preferences persist and recover their original outcomes",
          arguments: [V2OperationKind.strangerMessagePreference, .userAddPreference, .readReceiptPreference, .liveActivityPreference])
    func accountPreferenceAcceptance(kind: V2OperationKind) async throws {
        let fixture = try LiveAccountFixture()
        defer { fixture.close() }
        let account = try await fixture.register().credentials
        let client = try V2HTTPAccountPreferenceOperationClient(baseURL: fixture.url(""),
            credentials: ResourceLiveCredentials(value: account), transport: V2URLSessionMediaEdgeHTTPTransport(session: fixture.http))
        let initial = try await client.baseline(kind: kind)
        let reference: V2OperationReference
        let values: [V2AccountPreferenceValue]
        switch kind {
        case .strangerMessagePreference:
            reference = .strangerMessagePreference(.init(uuid: UUID()))
            values = [.strangerMessage(.deny), .strangerMessage(.allow)]
        case .userAddPreference:
            reference = .userAddPreference(.init(uuid: UUID()))
            values = [.userAdd(.deny), .userAdd(.allow)]
        case .readReceiptPreference:
            reference = .readReceiptPreference(.init(uuid: UUID()))
            values = [.readReceipt(allowsDirectReadReceipts: false, allowsGroupReadReceipts: false),
                      .readReceipt(allowsDirectReadReceipts: true, allowsGroupReadReceipts: true)]
        case .liveActivityPreference:
            reference = .liveActivityPreference(.init(uuid: UUID()))
            values = [.liveActivity(allowsOnlinePresence: false, allowsTypingIndicators: false),
                      .liveActivity(allowsOnlinePresence: true, allowsTypingIndicators: true)]
        default: throw ResourceLiveFailure.presentation
        }
        let value = try #require(values.first { $0 != initial.value })
        let command = try V2AccountPreferenceCommand(identity: .init(accountID: account.userID,
            scope: .account(account.userID), operation: reference), value: value,
            expectedRevision: initial.revision, firstSubmissionDeadlineMilliseconds: liveAcceptanceDeadline())
        let submitted = try await client.submit(command)
        guard case .receipt(let receipt) = submitted, case .applied = receipt.outcome else {
            Issue.record("Preference change was not applied: \(kind.rawValue)"); return
        }
        #expect(receipt.validates(command: command))
        #expect(try await client.recover(command, action: .query) == submitted)
        #expect(try await client.submit(command) == submitted)
        let persisted = try await client.baseline(kind: kind)
        #expect(persisted.ownerUserID == account.userID && persisted.value == value)
        #expect(persisted.revision == initial.revision + 1)
        print("Live acceptance: \(kind.rawValue) submit/replay/recover/persisted read passed.")
    }

    @Test("real relationship removal, block reversal and contact alias recovery")
    func socialAndAliasAcceptance() async throws {
        let fixture = try LiveAccountFixture()
        defer { fixture.close() }
        let owner = try await fixture.register().credentials
        let peer = try await fixture.register().credentials
        let client = try V2HTTPSocialOperationClient(baseURL: fixture.url(""), credentials: ResourceLiveCredentials(value: owner),
            transport: V2URLSessionMediaEdgeHTTPTransport(session: fixture.http))
        try await resourceRelationship(fixture, account: owner, target: peer.userID, action: .request)
        try await resourceRelationship(fixture, account: peer, target: owner.userID, action: .accept)
        let accepted = try await client.baseline(targetUserID: peer.userID)
        #expect(accepted.relationshipState == .accepted)
        let names = try V2HTTPNameOperationClient(endpoint: fixture.url("v2/profile-presentations"), credentials: ResourceLiveCredentials(value: owner),
            transport: V2URLSessionPushEndpointHTTPTransport(session: fixture.http))
        var baseline = try await names.contactSnapshot(owner: owner.userID, target: peer.userID)
        for name: String? in ["Acceptance contact", nil] {
            let command = try V2ContactAliasUpdateCommand(ownerUserID: owner.userID, targetUserID: peer.userID,
                operationID: .init(uuid: UUID()), expectedRevision: baseline.value?.revision, remarkName: name,
                firstSubmissionDeadlineMilliseconds: liveAcceptanceDeadline())
            let receipt = try await names.submit(command)
            guard case .committed(let saved) = receipt.outcome else { Issue.record("Alias change was not committed"); return }
            #expect(receipt.validates(command) && saved.remarkName == name)
            #expect(try await names.recover(.init(identity: command.identity, fingerprint: command.fingerprint, action: .query)) == .receipt(receipt))
            baseline = try await names.contactSnapshot(owner: owner.userID, target: peer.userID)
            #expect(baseline.value == saved)
        }
        try await resourceRelationship(fixture, account: owner, target: peer.userID, action: .remove)
        #expect(try await client.baseline(targetUserID: peer.userID).relationshipState == .none)
        for action in [V2UserBlockAction.block, .unblock] {
            let before = try await client.baseline(targetUserID: peer.userID)
            let command = try V2SocialOperationCommand(identity: .init(accountID: owner.userID,
                scope: .userPair(owner.userID, peer.userID), operation: .userBlock(.init(uuid: UUID()))),
                action: .userBlock(action), expectedRevision: before.blockRevision,
                firstSubmissionDeadlineMilliseconds: liveAcceptanceDeadline())
            let result = try await client.submit(command)
            guard case .receipt(let receipt) = result,
                  case .applied(.userBlock(let blocked, _)) = receipt.outcome else { Issue.record("Block change was not applied"); return }
            #expect(blocked == (action == .block) && receipt.validates(command: command))
            #expect(try await client.recover(command, action: .query) == result)
            #expect(try await client.baseline(targetUserID: peer.userID).isBlocked == blocked)
        }
        print("Live acceptance: relationship request/accept/remove, contact alias set/clear/recover, block/unblock persisted reads passed.")
    }
}

private func liveAcceptanceDeadline() -> UInt64 {
    UInt64(Date().timeIntervalSince1970 * 1_000) + 120_000
}
extension V2LiveResourceAuthorTests {
    @Test("real direct-room uniqueness, online presence and typing delivery",
          .enabled(if: ProcessInfo.processInfo.environment["IMV2_LIVE_EXTENDED_ACCEPTANCE"] == "1"))
    func liveActivityAcceptance() async throws {
        let fixture = try LiveAccountFixture()
        defer { fixture.close() }
        let author = try await fixture.register().credentials
        let viewer = try await fixture.register().credentials
        _ = try await resourceRelationship(fixture, account: author, target: viewer.userID, action: .request)
        _ = try await resourceRelationship(fixture, account: viewer, target: author.userID, action: .accept)
        // Both new operations race before either side has a room projection.
        async let authorOpening = resourceOpenDirect(fixture, account: author, target: viewer.userID)
        async let viewerOpening = resourceOpenDirect(fixture, account: viewer, target: author.userID)
        let (first, repeated) = try await (authorOpening, viewerOpening)
        #expect(first.roomID == repeated.roomID)
        #expect(try await resourceOpenDirect(fixture, account: author, target: viewer.userID).roomID == first.roomID)
        for account in [author, viewer] {
            let preferences = try V2HTTPAccountPreferenceOperationClient(baseURL: fixture.url(""),
                credentials: ResourceLiveCredentials(value: account), transport: V2URLSessionMediaEdgeHTTPTransport(session: fixture.http))
            let baseline = try await preferences.baseline(kind: .liveActivityPreference)
            let command = try V2AccountPreferenceCommand(identity: .init(accountID: account.userID,
                scope: .account(account.userID), operation: .liveActivityPreference(.init(uuid: UUID()))),
                value: .liveActivity(allowsOnlinePresence: true, allowsTypingIndicators: true),
                expectedRevision: baseline.revision, firstSubmissionDeadlineMilliseconds: liveAcceptanceDeadline())
            guard case .receipt(let proof) = try await preferences.submit(command), case .applied = proof.outcome else {
                throw ResourceLiveFailure.presentation
            }
        }
        let authorSocket = try connection(authorSupplements: false)
        let viewerSocket = try connection(authorSupplements: false)
        do {
            let authorSession = try await authenticate(authorSocket, author)
            let viewerSession = try await authenticate(viewerSocket, viewer)
            let authorTransport = V2ProtobufSyncTransport(wire: authorSocket, protocolVersion: authorSession.protocolVersion)
            let viewerTransport = V2ProtobufSyncTransport(wire: viewerSocket, protocolVersion: viewerSession.protocolVersion)
            try await authorTransport.setPresencePublicationMode(.allowWhenAuthorized)
            let presence = try await viewerTransport.subscribePresence(roomID: first.roomID)
            #expect(presence.roomID == first.roomID && presence.targetUserID == author.userID && presence.isOnline)
            #expect(presence.expiresAt > Date())
            print("Live acceptance stage: direct-room uniqueness and online presence verified.")
            try await viewerTransport.subscribeTyping(roomID: first.roomID)
            // Subscribe ACK and confirmed acceleration coverage are separate
            // protocol boundaries. Observe the actual installation witness.
            let coverage = await viewerSocket.realtimeCoverageChanges()
            _ = try await bounded {
                for await state in coverage {
                    if state.scope == .typing {
                        print("Live acceptance stage: typing coverage status=\(state.status.rawValue) reason=\(state.reason.rawValue)")
                    }
                    if state.scope == .typing, state.scopeID.lowercased() == first.roomID.rawValue.lowercased(), state.subscriptionInstalled { return state }
                }
                throw ResourceLiveFailure.timeout
            }
            print("Live acceptance stage: typing coverage installed.")
            for isTyping in [true, false] {
                try await authorTransport.setTyping(roomID: first.roomID, isTyping: isTyping)
                print("Live acceptance stage: awaiting typing state \(isTyping).")
                let event = try await bounded {
                    while true {
                        if case .typing(let state) = try await viewerSocket.nextLiveActivityEvent(),
                           state.roomID == first.roomID, state.userID == author.userID, state.isTyping == isTyping { return state }
                    }
                }
                if isTyping { #expect(event.expiresAt > Date()) }
                print("Live acceptance stage: received typing state \(isTyping).")
            }
            try await viewerTransport.unsubscribeTyping(roomID: first.roomID)
            try await viewerTransport.unsubscribePresence(roomID: first.roomID)
            await authorSocket.disconnect(); await viewerSocket.disconnect()
        } catch { await authorSocket.disconnect(); await viewerSocket.disconnect(); throw error }
        print("Live acceptance: both directions open the same direct room; authorized presence and typing start/stop delivered on real TLS.")
    }
}
extension V2LiveResourceAuthorTests {
    @Test("real stranger policy updates affect an already warm private-room sender",
          .enabled(if: ProcessInfo.processInfo.environment["IMV2_LIVE_EXTENDED_ACCEPTANCE"] == "1"))
    func strangerPolicyAcceptance() async throws {
        let fixture = try LiveAccountFixture()
        defer { fixture.close() }
        let author = try await fixture.register().credentials
        let viewer = try await fixture.register().credentials
        // No friend request/acceptance is performed for these two accounts.
        let room = try await resourceOpenDirect(fixture, account: author, target: viewer.userID).roomID
        let socket = try connection(authorSupplements: false)
        do {
            let session = try await authenticate(socket, author)
            let transport = V2ProtobufSyncTransport(wire: socket, protocolVersion: session.protocolVersion)
            let sender = V2ProtobufMessageSendOperationClient(transport: transport, connection: socket)
            _ = try await resourceSend(fixture, client: sender, account: author, roomID: room,
                clientMessageID: .init(uuid: UUID()), text: "Warm stranger scope", media: [], mentions: [])
            let policy = try V2HTTPAccountPreferenceOperationClient(baseURL: fixture.url(""),
                credentials: ResourceLiveCredentials(value: viewer), transport: V2URLSessionMediaEdgeHTTPTransport(session: fixture.http))
            for allows in [false, true] {
                let baseline = try await policy.baseline(kind: .strangerMessagePreference)
                let change = try V2AccountPreferenceCommand(identity: .init(accountID: viewer.userID,
                    scope: .account(viewer.userID), operation: .strangerMessagePreference(.init(uuid: UUID()))),
                    value: .strangerMessage(allows ? .allow : .deny), expectedRevision: baseline.revision,
                    firstSubmissionDeadlineMilliseconds: liveAcceptanceDeadline())
                guard case .receipt(let updated) = try await policy.submit(change),
                      updated.validates(command: change), case .applied = updated.outcome else {
                    throw ResourceLiveFailure.presentation
                }
                let command = try V2MessageSendOperationCommand(command: .init(roomID: room,
                    senderUserID: author.userID, clientMessageID: .init(uuid: UUID()),
                    text: "Send after stranger policy change", limits: .init(maxUTF8Bytes: 4096)),
                    firstSubmissionDeadlineMilliseconds: liveAcceptanceDeadline())
                guard case .receipt(let result) = try await sender.submit(command),
                      try result.validates(identity: command.identity, fingerprint: command.fingerprint) else {
                    throw ResourceLiveFailure.presentation
                }
                switch result.outcome {
                case .accepted: #expect(allows)
                case .rejected(let reason):
                    #expect(!allows)
                    #expect(reason == .directPolicyDenied)
                case .closed: throw ResourceLiveFailure.presentation
                }
            }
            await socket.disconnect()
        } catch { await socket.disconnect(); throw error }
        print("Live acceptance: warm stranger scope denied after policy change and accepted after reversal on the same TLS connection.")
    }

    @Test("real operator account disable ends HTTP sessions and rejects login and TLS authentication",
          .enabled(if: ProcessInfo.processInfo.environment["IMV2_LIVE_EXTENDED_ACCEPTANCE"] == "1"))
    func accountDisableAcceptance() async throws {
        let fixture = try LiveAccountFixture()
        defer { fixture.close() }
        let account = try await fixture.register()
        let store = LiveAccountCredentialStore(account.credentials)
        let session = try fixture.session(store)
        _ = try await session.restoreState()
        let devices = try await fixture.devices(session)
        #expect(try await devices.list(cursor: nil, pageSize: 10).sessions.count == 1)
        let socket = try connection(authorSupplements: false)
        _ = try await authenticate(socket, account.credentials)
        var request = URLRequest(url: fixture.url("__fixture__/disable-account"))
        request.httpMethod = "POST"
        request.setValue(try #require(ProcessInfo.processInfo.environment["IMV2_LIVE_RESOURCE_FIXTURE_TOKEN"]), forHTTPHeaderField: "X-Resource-Fixture")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["operationID": UUID().uuidString,
            "userID": account.credentials.userID.rawValue, "reason": "policy_enforcement"])
        var disabledAt: Int64?
        for expected in ["disabled", "idempotent"] {
            let (data, response) = try await fixture.http.data(for: request)
            try #require((response as? HTTPURLResponse)?.statusCode == 200)
            let result = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            #expect(result["outcome"] as? String == expected)
            let timestamp = try #require(result["disabledAtMilliseconds"] as? Int64)
            if let disabledAt { #expect(timestamp == disabledAt) } else { disabledAt = timestamp }
        }
        // No local disconnect or HTTP session teardown may manufacture this
        // observation: the already authenticated physical socket must end.
        _ = try await bounded {
            while await socket.authenticatedConnectionID() != nil {
                try await Task.sleep(for: .milliseconds(100))
            }
            return true
        }
        print("Live acceptance: pre-existing authenticated TLS connection ended after Operator disable.")
        await #expect(throws: (any Error).self) { try await devices.list(cursor: nil, pageSize: 10) }
        #expect(await session.currentState() == .unauthenticated)
        #expect(await store.load() == nil)
        await #expect(throws: (any Error).self) { try await fixture.login(account.handle) }
        await #expect(throws: (any Error).self) { try await authenticate(socket, account.credentials) }
        await socket.disconnect()
        print("Live acceptance: actual Operator disable/replay, HTTP session termination, credential removal and login/TLS rejection passed.")
    }
}
#endif
