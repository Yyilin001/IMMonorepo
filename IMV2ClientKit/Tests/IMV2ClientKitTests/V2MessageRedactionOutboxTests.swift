import Foundation
@testable import IMV2ClientKit
import IMV2Core
import Testing

@Suite("V2 message redaction outbox")
struct V2MessageRedactionOutboxTests {
    @Test("retry after restart retains the moderator operation and reason code")
    func retrySurvivesRestart() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "im-v2-redaction-\(UUID().uuidString).sqlite")
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        let transport = ScriptedRedactionTransport(results: [.offline, .accepted])
        let store = try GRDBV2LocalSyncStore(databaseURL: url, installationBinding: redactionBinding)
        let engine = V2MessageRedactionOutboxEngine(store: store, transport: transport, makeUUID: { UUID(uuidString: "00000000-0000-0000-0000-000000000961")! }, now: { now })
        let command = try await engine.enqueueRedaction(roomID: .init("00000000-0000-0000-0000-000000000962"), messageID: .init("00000000-0000-0000-0000-000000000963"), reasonCode: .init("policy_violation"))
        #expect(try await engine.flushOnce() == .retryScheduled(command.operationID))

        let restarted = try GRDBV2LocalSyncStore(databaseURL: url, installationBinding: redactionBinding)
        let retryEngine = V2MessageRedactionOutboxEngine(store: restarted, transport: transport, now: { now.addingTimeInterval(1) })
        #expect(try await retryEngine.flushOnce() == .acknowledged(command.operationID))
        let saved = try #require(await restarted.pendingMessageRedactions().first)
        #expect(saved.operationID == command.operationID)
        #expect(saved.reasonCode.rawValue == "policy_violation")
        #expect(saved.state == .acknowledged)
        #expect(saved.resultingMessageRevision == 2)
        #expect(await transport.operationIDs() == [command.operationID, command.operationID])
    }

    @Test("forbidden redaction is terminal and is not retried")
    func forbiddenIsTerminal() async throws {
        let store = try GRDBV2LocalSyncStore(databaseURL: FileManager.default.temporaryDirectory.appending(path: "im-v2-redaction-\(UUID().uuidString).sqlite"), installationBinding: redactionBinding)
        let engine = V2MessageRedactionOutboxEngine(store: store, transport: ScriptedRedactionTransport(results: [.forbidden]), makeUUID: { UUID(uuidString: "00000000-0000-0000-0000-000000000964")! }, now: { Date(timeIntervalSince1970: 1_750_000_000) })
        let command = try await engine.enqueueRedaction(roomID: .init("00000000-0000-0000-0000-000000000965"), messageID: .init("00000000-0000-0000-0000-000000000966"), reasonCode: .init("policy_violation"))
        #expect(try await engine.flushOnce() == .rejected(command.operationID, code: "FORBIDDEN"))
        let saved = try #require(await store.pendingMessageRedactions().first)
        #expect(saved.state == .rejected)
        #expect(saved.terminalCode == "FORBIDDEN")
        #expect(try await engine.flushOnce() == .idle)
    }
}

private actor ScriptedRedactionTransport: V2ClientMessageRedactionTransport {
    enum Result: Sendable { case offline, forbidden, accepted }
    private var results: [Result]
    private var received: [ModerationOperationID] = []

    init(results: [Result]) { self.results = results }

    func redactMessage(roomID: RoomID, operationID: ModerationOperationID, messageID: MessageID, reasonCode _: V2ModerationReasonCode) throws -> V2ClientMessageRedaction {
        received.append(operationID)
        switch results.removeFirst() {
        case .offline: throw V2RealtimeTransportError.unexpectedResponse
        case .forbidden: throw V2RealtimeTransportError.server(code: "FORBIDDEN", retryable: false, retryAfterSeconds: 0, currentRevision: nil)
        case .accepted: return .init(roomID: roomID, messageID: messageID, messageRevision: 2, roomSequence: 9, createdAt: .distantPast)
        }
    }

    func operationIDs() -> [ModerationOperationID] { received }
}

private let redactionBinding = V2LocalInstallationBinding(value: UUID(uuidString: "00000000-0000-0000-0000-000000000967")!)
