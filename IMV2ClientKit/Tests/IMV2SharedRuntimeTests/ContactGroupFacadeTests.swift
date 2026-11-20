import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
import IMV2Core
@testable import IMV2ClientRuntime
@testable import IMV2SharedRuntime

@Suite(.timeLimit(.minutes(1))) struct ContactGroupFacadeTests {
    @Test func profileFacadeRetiresAllWindowsAndNameObservers() async throws {
        let f = try DirectoryFixture(), reader = ProfileNamesRemote()
        let presentations = V2ProfilePresentationRepository(actorUserID: f.account, deviceID: .init(uuid: UUID()), reader: EmptyProfileReader())
        let profiles = V2ProfileService(accountID: f.account, store: f.store, presentations: presentations,
            names: .init(accountID: f.account, store: f.store, client: reader))
        let a = await profiles.presentations.activate(), b = await profiles.presentations.activate()
        #expect(await presentations.diagnostics().activations == 2)
        await presentations.deactivate(a)
        #expect(await presentations.diagnostics().activations == 1)
        let target = V2NameTarget.contact(.init(uuid: UUID()))
        let first = await profiles.names.baselineUpdates(target), second = await profiles.names.baselineUpdates(target)
        let window = Task { for try await _ in first { try Task.checkCancellation() } }
        var other = second.makeAsyncIterator()
        #expect(try await other.next() != nil)
        window.cancel(); _ = await window.result
        #expect(try await profiles.names.cached(target) == nil)
        await profiles.close()
        #expect(await presentations.diagnostics().activations == 0)
        await #expect(throws: V2DirectoryServiceError.self) { try await profiles.names.cached(target) }
        await #expect(throws: V2DirectoryServiceError.self) { try await profiles.names.save(target, name: "retired", expectedRevision: nil) }
        await #expect(throws: V2DirectoryServiceError.self) { try await other.next() }
        await presentations.deactivate(b)
        try await f.close()
    }
    @Test func profileCloseDrainsNameHTTPAndSuppressesLateCompletion() async throws {
        let f = try DirectoryFixture(), reader = ProfileNamesRemote()
        let presentations = V2ProfilePresentationRepository(actorUserID: f.account, deviceID: .init(uuid: UUID()), reader: EmptyProfileReader())
        let profiles = V2ProfileService(accountID: f.account, store: f.store, presentations: presentations,
            names: .init(accountID: f.account, store: f.store, client: reader))
        let query = Task { try await profiles.names.refresh(.contact(.init(uuid: UUID()))) }
        try await reader.gate.waitUntilEntered()
        let flag = Flag(), closing = Task { await profiles.close() }
        let observed = Task { await closing.value; await flag.set() }
        for _ in 0..<30 { await Task.yield() }
        #expect(await !flag.value)
        await reader.gate.release(); await observed.value
        await #expect(throws: (any Error).self) { try await query.value }
        try await f.close()
    }
    @Test func contactPagesAndObserversAreIndependentAndClosedHandlesRejectWork() async throws {
        let f = try DirectoryFixture(); try await f.seed()
        let first = try await f.contacts.page(scope: .friends, limit: 1)
        let cursor = try #require(first.nextCursor)
        let second = try await f.contacts.page(scope: .friends, before: cursor, limit: 1)
        #expect(first.relationships.first?.targetUserID != second.relationships.first?.targetUserID)
        #expect(try await f.contacts.page(scope: .friends, limit: 1).relationships == first.relationships)
        #expect(try await f.contacts.page(scope: .outgoingRequests).relationships.isEmpty)
        let a = await f.contacts.relationships.proposalUpdates()
        let b = await f.contacts.relationships.proposalUpdates()
        let observing = Task { for try await _ in a { try Task.checkCancellation() } }
        var reader = b.makeAsyncIterator()
        #expect(try await reader.next()?.isEmpty == true)
        observing.cancel(); _ = await observing.result
        let draft = try await f.contacts.relationships.saveProposal(action: .relationship(.request), target: .init(uuid: UUID()))
        var found = false
        while let rows = try await reader.next() { if rows.contains(where: { $0.id == draft }) { found = true; break } }
        #expect(found)
        await f.contacts.close()
        await #expect(throws: V2DirectoryServiceError.self) { try await f.contacts.relationships.discardProposal(id: draft) }
        await #expect(throws: V2DirectoryServiceError.self) { try await f.contacts.page(scope: .friends) }
        await #expect(throws: V2DirectoryServiceError.self) { try await f.contacts.directConversations.existingLocalRoom(with: f.account) }
        try await f.close()
    }
    @Test func groupCloseDrainsPhysicalReadAndStaleResultCannotEscape() async throws {
        let f = try DirectoryFixture(); try await f.seed()
        await f.remote.block()
        let query = Task { try await f.groups.listRoomMembers(roomID: f.room, cursor: nil, pageSize: 50) }
        try await f.remote.waitUntilEntered()
        let closed = Flag()
        let closing = Task { await f.groups.close(); await closed.set() }
        for _ in 0..<30 { await Task.yield() }
        #expect(await !closed.value)
        await f.remote.release()
        await closing.value
        await #expect(throws: (any Error).self) { try await query.value }
        await #expect(throws: V2DirectoryServiceError.self) { try await f.groups.creation.latest() }
        await #expect(throws: V2DirectoryServiceError.self) { try await f.groups.invitations.baseline(roomID: f.room) }
        try await f.close()
    }
    @Test func membershipReadRechecksAuthorityAndRejectsRepeatedCursor() async throws {
        let f = try DirectoryFixture(); try await f.seed()
        await f.remote.block()
        let query = Task { try await f.groups.listRoomMembers(roomID: f.room, cursor: nil, pageSize: 50) }
        try await f.remote.waitUntilEntered()
        try await f.store.databasePool.write { db in try db.execute(sql: "UPDATE v2_room_event_authorizations SET is_authorized=0") }
        await f.remote.release()
        await #expect(throws: V2DirectoryServiceError.self) { try await query.value }
        try await f.store.databasePool.write { db in try db.execute(sql: "UPDATE v2_room_event_authorizations SET is_authorized=1") }
        await f.remote.repeatCursor()
        await #expect(throws: V2DirectoryServiceError.self) { try await f.groups.listRoomMembers(roomID: f.room, cursor: "same", pageSize: 50) }
        try await f.close()
    }
    @Test func cancelledWindowProducerStillDrainsBeforeAccountClose() async throws {
        let lifetime = V2DirectoryLifetime(), gate = DirectoryGate(), closed = Flag()
        let stream: AsyncThrowingStream<Int, any Error> = await lifetime.observe {
            await gate.wait()
            return AsyncThrowingStream { $0.finish() }
        }
        let consumer = Task { for try await _ in stream {} }
        try await gate.waitUntilEntered()
        consumer.cancel(); _ = await consumer.result
        let closing = Task { await lifetime.close(); await closed.set() }
        for _ in 0..<30 { await Task.yield() }
        #expect(await !closed.value)
        await gate.release(); await closing.value
        #expect(await closed.value)
    }
    @Test func queryCoordinatorCleanupIsDrainedOnce() async throws {
        let gate = DirectoryGate(), completed = Flag()
        let lifetime = V2DirectoryLifetime(onClose: { await gate.wait() })
        let first = Task { await lifetime.close(); await completed.set() }
        try await gate.waitUntilEntered()
        let second = Task { await lifetime.close() }
        #expect(await !completed.value)
        await gate.release(); await first.value; await second.value
        #expect(await gate.calls == 1)
    }
    @Test func confirmationFromAnotherActivationCannotBecomeDurableWork() async throws {
        let f = try DirectoryFixture(); try await f.seed()
        let other = try DirectoryFixture()
        let confirmation = try other.groups.membership.confirmationWindow(roomID: f.room, action: .add, expectedMembershipRevision: 1)
        await #expect(throws: (any Error).self) { try await f.groups.membership.enqueue(targetUserID: .init(uuid: UUID()), confirmation: confirmation) }
        var a = await f.groups.membership.updates(roomID: f.room).makeAsyncIterator()
        var b = await f.groups.membership.updates(roomID: f.room).makeAsyncIterator()
        #expect(try await a.next()?.isEmpty == true); #expect(try await b.next()?.isEmpty == true)
        try await f.close(); try await other.close()
    }
}
private actor Flag { var value = false; func set() { value = true } }
private struct DirectoryFixture: Sendable {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let account = UserID(uuid: UUID()), room = RoomID(uuid: UUID())
    let store: GRDBV2LocalSyncStore
    let contacts: V2ContactService
    let groups: V2GroupService
    let remote = DirectoryRemote()
    init() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = try .init(databaseURL: root.appendingPathComponent("local.sqlite"), installationBinding: .init(value: UUID()), userID: account)
        let base = URL(string: "https://example.invalid")!, http = OfflineDirectoryHTTP(), activation = UUID()
        contacts = try .init(accountID: account, store: store,
            social: .init(accountID: account, store: store, client: V2HTTPSocialOperationClient(baseURL: base, credentials: http, transport: http)),
            direct: .init(accountID: account, store: store, client: V2HTTPDirectRoomOperationClient(baseURL: base, credentials: http, transport: http)),
            directory: V2HTTPPublicIdentityDirectory(endpoint: base, actorUserID: account, credentials: http, transport: http))
        groups = try .init(accountID: account, store: store, transport: remote,
            invitationReader: V2HTTPGroupInvitationClient(baseURL: base, credentials: http, transport: http),
            creation: .init(accountID: account, store: store, client: V2HTTPGroupCreationOperationClient(baseURL: base, credentials: http, transport: http)),
            membership: .init(accountID: account, activationID: activation, store: store, client: V2HTTPMembershipOperationClient(baseURL: base, credentials: http, transport: http)),
            capabilities: .init(accountID: account, activationID: activation, store: store, client: V2HTTPGroupCapabilityOperationClient(baseURL: base, credentials: http, transport: http)),
            invitations: .init(accountID: account, activationID: activation, store: store, client: V2HTTPInvitationOperationClient(baseURL: base, credentials: http, transport: http), secrets: UnusedSecrets()),
            administration: .init(accountID: account, activationID: activation, store: store, client: V2HTTPMemberAdministrationClient(baseURL: base, credentials: http, transport: http)))
    }
    func seed() async throws {
        try await store.databasePool.write { db in
            try db.execute(sql: "INSERT INTO v2_room_event_authorizations VALUES (?, 1)", arguments: [room.rawValue])
            try db.execute(sql: "INSERT INTO v2_room_profile_projections(room_id,source_event_id,title,owner_user_id,capacity_class,created_at) VALUES (?, ?, 'Group', ?, 'standard', 1)", arguments: [room.rawValue, UUID().uuidString, account.rawValue])
            for i in 1...3 {
                try db.execute(sql: "INSERT INTO v2_relationship_projections(target_user_id,state,requested_by_user_id,updated_at) VALUES (?, 'accepted', NULL, ?)", arguments: [UUID().uuidString, Double(i)])
            }
        }
    }
    func close() async throws { await contacts.close(); await groups.close(); try await store.close(); try FileManager.default.removeItem(at: root) }
}
private actor DirectoryRemote: V2ClientMembershipDirectoryTransport {
    private var blocked = false, entered = false, repeated = false
    private var continuation: CheckedContinuation<Void, Never>?
    func block() { blocked = true }
    func repeatCursor() { repeated = true }
    func waitUntilEntered() async throws { while !entered { try Task.checkCancellation(); await Task.yield() } }
    func release() { blocked = false; continuation?.resume(); continuation = nil }
    func listRoomMembers(roomID: RoomID, cursor: String?, pageSize: Int) async throws -> V2ClientRoomMembersPage {
        if blocked { entered = true; await withCheckedContinuation { continuation = $0 } }
        return try .init(roomID: roomID, membershipRevision: 1, actorRole: .owner, members: [], nextCursor: repeated ? cursor : nil)
    }
}
private struct OfflineDirectoryHTTP: V2ClientPushEndpointCredentialProvider, V2ClientMediaEdgeCredentialProvider, V2ClientMediaEdgeHTTPTransport, V2ClientPushEndpointHTTPTransport, V2ClientGroupInvitationHTTPTransport {
    func pushEndpointCredentials() throws -> V2ClientPushEndpointCredentials { throw URLError(.notConnectedToInternet) }
    func mediaEdgeCredentials() throws -> V2ClientMediaEdgeCredentials { throw URLError(.notConnectedToInternet) }
    func data(for request: URLRequest) throws -> (Data, HTTPURLResponse) { throw URLError(.notConnectedToInternet) }
}
private struct UnusedSecrets: V2InvitationSecretStoring {
    func save(_ authorization: V2GroupInvitationSecretAuthorization, reference: UUID, accountID: UserID) throws { throw URLError(.notConnectedToInternet) }
    func load(reference: UUID, accountID: UserID) throws -> V2GroupInvitationSecretAuthorization { throw URLError(.notConnectedToInternet) }
    func remove(reference: UUID, accountID: UserID) throws {}
}

private actor DirectoryGate {
    var entered = false
    var calls = 0
    var continuation: CheckedContinuation<Void, Never>?
    func wait() async { calls += 1; entered = true; await withCheckedContinuation { continuation = $0 } }
    func waitUntilEntered() async throws { while !entered { try Task.checkCancellation(); await Task.yield() } }
    func release() { continuation?.resume(); continuation = nil }
}

private struct EmptyProfileReader: V2ProfilePresentationReading {
    func readPresentations(_ keys: [V2ProfileViewLookupKey]) throws -> V2ProfilePresentationBatch {
        throw URLError(.notConnectedToInternet)
    }
}
private struct ProfileNamesRemote: V2NameOperationClient {
    let gate = DirectoryGate()
    func contactSnapshot(owner: UserID, target: UserID) async throws -> V2ContactAliasSnapshot {
        await gate.wait(); throw URLError(.notConnectedToInternet)
    }
    func groupSnapshot(actor: UserID, room: RoomID) throws -> V2GroupNicknameSnapshot { throw URLError(.notConnectedToInternet) }
    func submit(_ command: V2ContactAliasUpdateCommand) throws -> V2ContactAliasUpdateReceipt { throw URLError(.notConnectedToInternet) }
    func submit(_ command: V2GroupNicknameUpdateCommand) throws -> V2GroupNicknameUpdateReceipt { throw URLError(.notConnectedToInternet) }
    func recover(_ request: V2ContactAliasRecoveryRequest) throws -> V2ContactAliasRecoveryResult { throw URLError(.notConnectedToInternet) }
    func recover(_ request: V2GroupNicknameRecoveryRequest) throws -> V2GroupNicknameRecoveryResult { throw URLError(.notConnectedToInternet) }
}
