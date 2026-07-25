import Foundation
@testable import IMV2ClientKit
import IMV2Core
import Testing

@Suite("V2 member mute outbox")
struct V2MemberMuteOutboxTests {
    @Test("retry after restart retains a canonical mute command")
    func retrySurvivesRestart() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "im-v2-member-mute-\(UUID().uuidString).sqlite")
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        let transport = ScriptedMuteTransport(results: [.offline, .accepted])
        let store = try GRDBV2LocalSyncStore(databaseURL: url, installationBinding: muteBinding)
        let engine = V2MemberMuteOutboxEngine(store: store, transport: transport, makeUUID: { UUID(uuidString: "00000000-0000-0000-0000-000000000971")! }, now: { now })
        let command = try await engine.enqueueMute(roomID: .init("00000000-0000-0000-0000-000000000972"), targetUserID: .init("00000000-0000-0000-0000-000000000973"), muteUntil: now.addingTimeInterval(600.1239), reasonCode: .init("policy_violation"))

        #expect(command.muteUntil == Date(timeIntervalSince1970: 1_750_000_600.123))
        #expect(try await engine.flushOnce() == .retryScheduled(command.operationID))

        let restarted = try GRDBV2LocalSyncStore(databaseURL: url, installationBinding: muteBinding)
        let retryEngine = V2MemberMuteOutboxEngine(store: restarted, transport: transport, now: { now.addingTimeInterval(1) })
        #expect(try await retryEngine.flushOnce() == .acknowledged(command.operationID))
        let saved = try #require(await restarted.pendingMemberMutes().first)
        #expect(saved.operationID == command.operationID)
        #expect(saved.targetUserID.rawValue == "00000000-0000-0000-0000-000000000973")
        #expect(saved.muteUntil == command.muteUntil)
        #expect(saved.reasonCode.rawValue == "policy_violation")
        #expect(saved.state == .acknowledged)
        #expect(await transport.operationIDs() == [command.operationID, command.operationID])
    }

    @Test("expired and forbidden mute commands are terminal")
    func terminalMutesAreNotRetried() async throws {
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        let store = try GRDBV2LocalSyncStore(databaseURL: FileManager.default.temporaryDirectory.appending(path: "im-v2-member-mute-\(UUID().uuidString).sqlite"), installationBinding: muteBinding)
        let forbiddenEngine = V2MemberMuteOutboxEngine(store: store, transport: ScriptedMuteTransport(results: [.forbidden]), makeUUID: { UUID(uuidString: "00000000-0000-0000-0000-000000000974")! }, now: { now })
        let command = try await forbiddenEngine.enqueueMute(roomID: .init("00000000-0000-0000-0000-000000000975"), targetUserID: .init("00000000-0000-0000-0000-000000000976"), muteUntil: now.addingTimeInterval(60), reasonCode: .init("policy_violation"))
        #expect(try await forbiddenEngine.flushOnce() == .rejected(command.operationID, code: "FORBIDDEN"))

        let expiryStore = try GRDBV2LocalSyncStore(databaseURL: FileManager.default.temporaryDirectory.appending(path: "im-v2-member-mute-\(UUID().uuidString).sqlite"), installationBinding: muteBinding)
        let expiryEngine = V2MemberMuteOutboxEngine(store: expiryStore, transport: ScriptedMuteTransport(results: [.accepted]), makeUUID: { UUID(uuidString: "00000000-0000-0000-0000-000000000977")! }, now: { now })
        let expiring = try await expiryEngine.enqueueMute(roomID: .init("00000000-0000-0000-0000-000000000978"), targetUserID: .init("00000000-0000-0000-0000-000000000979"), muteUntil: now.addingTimeInterval(1), reasonCode: .init("policy_violation"))
        let expiredEngine = V2MemberMuteOutboxEngine(store: expiryStore, transport: ScriptedMuteTransport(results: [.accepted]), now: { now.addingTimeInterval(2) })
        #expect(try await expiredEngine.flushOnce() == .rejected(expiring.operationID, code: "MUTE_EXPIRED"))
        let saved = try await expiryStore.pendingMemberMutes()
        #expect(saved.first?.state == .rejected)
        #expect(saved.first?.terminalCode == "MUTE_EXPIRED")
    }
}

private actor ScriptedMuteTransport: V2ClientMemberMuteTransport {
    enum Result: Sendable { case offline, forbidden, accepted }
    private var results: [Result]
    private var received: [ModerationOperationID] = []

    init(results: [Result]) { self.results = results }

    func muteMember(roomID: RoomID, operationID: ModerationOperationID, targetUserID: UserID, muteUntil: Date, reasonCode _: V2ModerationReasonCode) throws -> V2ClientMemberMute {
        received.append(operationID)
        switch results.removeFirst() {
        case .offline:
            throw V2RealtimeTransportError.unexpectedResponse
        case .forbidden:
            throw V2RealtimeTransportError.server(code: "FORBIDDEN", retryable: false, retryAfterSeconds: 0, currentRevision: nil)
        case .accepted:
            return .init(roomID: roomID, targetUserID: targetUserID, muteUntil: muteUntil, roomSequence: 9, createdAt: .distantPast)
        }
    }

    func operationIDs() -> [ModerationOperationID] { received }
}

private let muteBinding = V2LocalInstallationBinding(value: UUID(uuidString: "00000000-0000-0000-0000-000000000980")!)
