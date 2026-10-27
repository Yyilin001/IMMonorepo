import Foundation
import GRDB
import IMV2Core
@testable import IMV2ClientKit
import XCTest

private struct RecoveryE2ECredentials: V2ClientMediaEdgeCredentialProvider {
    let account: LocalE2EAccountCredentials
    func mediaEdgeCredentials() async throws -> V2ClientMediaEdgeCredentials {
        .init(accessToken: account.accessToken, deviceID: account.deviceID)
    }
}
extension LocalE2EAccountCredentials {
    private func recoveryTransport(_ scheduler: V2AccountWorkScheduler) -> V2URLSessionMediaEdgeHTTPTransport {
        .init(executor: .init(scheduler: scheduler))
    }
    /// Reuses the caller's authenticated TCP connection when supplied. A
    /// standalone test call owns its socket through actual submit/recovery drain.
    func withMessageSendClient<Value: Sendable>(auth: V2AuthSession? = nil, connection existing: V2TLSFrameConnection? = nil, transport existingTransport: V2ProtobufSyncTransport? = nil,
        operation: (V2ProtobufMessageSendOperationClient) async throws -> Value) async throws -> Value {
        guard existing == nil || existingTransport != nil else { throw V2MessageSendTransportError.invalidResponse }
        let connection = try existing ?? V2TLSFrameConnection(endpoint: V2RealtimeEndpoint(host: "localhost", port: 7_443),
            frameLimits: V2FrameLimits(maximumPayloadBytes: 65_536, acceptedVersions: [0, UInt8(IMV2ProtocolVersion.current)]))
        do {
            if await connection.messageSendSession() == nil {
                if let auth {
                    let credentials = try await auth.realtimeCredentials()
                    guard credentials.userID == userID, credentials.deviceID == deviceID else { throw V2MessageSendTransportError.authenticationRequired }
                    _ = try await connection.connectAndAuthenticate(accessToken: credentials.accessToken, deviceID: credentials.deviceID,
                        supportedCapabilityProfiles: ["base"])
                    try await auth.requireAuthenticatedEpoch(XCTUnwrap(credentials.sessionEpoch))
                } else {
                    _ = try await connection.connectAndAuthenticate(accessToken: accessToken, deviceID: deviceID,
                        supportedCapabilityProfiles: ["base"])
                }
            }
            let readiness = await connection.messageSendSession()
            let session = try XCTUnwrap(readiness)
            guard session.accountID == userID, session.deviceID == deviceID else { throw V2MessageSendTransportError.authenticationRequired }
            let transport = existingTransport ?? V2ProtobufSyncTransport(wire: connection, protocolVersion: session.protocolVersion)
            let value = try await operation(.init(transport: transport, connection: connection))
            if existing == nil { await connection.disconnect() }
            return value
        } catch {
            if existing == nil { await connection.disconnect() }
            throw error
        }
    }
    func sendMessage(roomID: RoomID, clientMessageID: ClientMessageID, text: String,
                     media: [V2MediaReference] = [], mentions: [V2MentionTarget] = [], auth: V2AuthSession? = nil, connection: V2TLSFrameConnection? = nil, transport: V2ProtobufSyncTransport? = nil) async throws -> V2MessageOperationAcceptance {
        guard media.isEmpty else { throw V2OperationWorkError.dependencyUnavailable }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try GRDBV2LocalSyncStore(databaseURL: root.appendingPathComponent("send.sqlite"),
            installationBinding: .init(value: UUID()), userID: userID)
        let scheduler = V2AccountWorkScheduler()
        do {
            return try await withMessageSendClient(auth: auth, connection: connection, transport: transport) { client in
            let service = V2MessageSendOperationService(accountID: userID, store: store, client: client)
            let intent = try V2SendIntent(id: UUID(), roomID: roomID, clientMessageID: clientMessageID,
                text: text, mentions: mentions, attachmentJobIDs: [])
            try await store.freezeSendIntent(intent)
            _ = try await store.handOffSendIntent(intent.id)
            let workID = try await store.databasePool.read { db in
                try XCTUnwrap(String.fetchOne(db, sql: "SELECT work_id FROM v2_send_intents WHERE intent_id=?",
                    arguments: [intent.id.uuidString]).flatMap(UUID.init(uuidString:)))
            }
            let command = try await store.messageSendCommand(workID: workID)
            let limit = ContinuousClock.now + .seconds(60)
            while true {
                try Task.checkCancellation()
                let storedWork = try await store.operationWork(id: workID)
                let work = try XCTUnwrap(storedWork)
                if work.scheduling == .finished {
                    guard work.execution == .committed else {
                        print("IMV2_MESSAGE_SEND_TERMINAL execution=\(work.execution.rawValue) code=\(work.lastErrorCode ?? "none")")
                        throw V2OperationWorkError.invalidTransition
                    }
                    let original = try await client.recover(.init(identity: command.identity, fingerprint: command.fingerprint,
                        domainFingerprint: command.command.fingerprint))
                    let persisted = try await store.databasePool.read { db in
                        try XCTUnwrap(Data.fetchOne(db, sql: "SELECT terminal_receipt FROM v2_operation_work WHERE work_id=?",
                            arguments: [workID.uuidString]))
                    }
                    let persistedProof = try JSONDecoder().decode(V2MessageSendOperationReceipt.self, from: persisted)
                    guard case .receipt(let proof) = original, proof == persistedProof,
                        proof.validates(identity: try command.identity, fingerprint: try command.fingerprint),
                        case .accepted(let accepted) = proof.outcome else { throw V2OperationWorkError.identityConflict }
                    await scheduler.closeAndDrain(); try await store.close()
                    return accepted
                }
                guard work.scheduling != .needsAttention, ContinuousClock.now < limit else { throw V2OperationWorkError.invalidTransition }
                if work.nextActionAt <= Date() {
                    if case .claimed(let claim) = try await store.claimOperationWork(id: workID, ownerID: UUID(), action: work.nextAction, now: Date()) {
                        try await service.execute(claim)
                    } else { try await Task.sleep(for: .milliseconds(50)) }
                } else { try await Task.sleep(for: .milliseconds(50)) }
            }
            }
        } catch {
            await scheduler.closeAndDrain(); try? await store.close(); throw error
        }
    }
    func createGroup(operationID: GroupRoomOperationID, title: String, members: [UserID]) async throws -> RoomID {
        let scheduler = V2AccountWorkScheduler()
        let client = try V2HTTPGroupCreationOperationClient(baseURL: XCTUnwrap(URL(string: "https://localhost:8443")),
            credentials: RecoveryE2ECredentials(account: self), transport: recoveryTransport(scheduler))
        do {
            let audience = try V2GroupCreationAudience.canonical(members, actorUserID: userID)
            let intent = try V2GroupCreationIntent(identity: .init(accountID: userID, scope: .account(userID), operation: .groupRoom(operationID)),
                title: title, capacityClass: .standard, initialMemberCount: audience.count,
                audienceDigest: V2GroupCreationAudience.digest(audience),
                firstSubmissionDeadlineMilliseconds: UInt64(Date().timeIntervalSince1970 * 1000) + 600_000)
            guard case .progress = try await client.begin(intent) else { throw V2OperationWorkError.invalidTransition }
            if !audience.isEmpty {
                guard case .progress = try await client.append(.init(intent: intent, offset: 0, memberUserIDs: audience)) else { throw V2OperationWorkError.invalidTransition }
            }
            let limit = ContinuousClock.now + .seconds(60)
            var result = try await client.finalize(intent)
            while true {
                try Task.checkCancellation()
                if case .receipt(let proof) = result {
                    guard proof.validates(intent: intent), case .created(let room, _, _, _) = proof.outcome,
                        try await client.recover(intent, action: .query) == .receipt(proof) else { throw V2OperationWorkError.identityConflict }
                    await scheduler.closeAndDrain(); return room
                }
                guard ContinuousClock.now < limit else { throw V2OperationWorkError.invalidTransition }
                try await Task.sleep(for: .milliseconds(100))
                result = try await client.recover(intent, action: .query)
            }
        } catch { await scheduler.closeAndDrain(); throw error }
    }
    func changeMembership(roomID: RoomID, operationID: MembershipOperationID, targetUserID: UserID,
                          action: V2RoomMembershipAction, expectedMembershipRevision: UInt64) async throws -> V2MembershipApplied {
        let scheduler = V2AccountWorkScheduler()
        let client = try V2HTTPMembershipOperationClient(baseURL: XCTUnwrap(URL(string: "https://localhost:8443")),
            credentials: RecoveryE2ECredentials(account: self), transport: recoveryTransport(scheduler))
        do {
            let intent = try V2MembershipIntent(roomID: roomID, actorUserID: userID, operationID: operationID,
                targetUserID: targetUserID, action: action, expectedMembershipRevision: expectedMembershipRevision,
                confirmedUntilMilliseconds: UInt64(Date().timeIntervalSince1970 * 1000) + 120_000)
            guard case .admitted(let admission) = try await client.admit(intent) else { throw V2OperationWorkError.invalidTransition }
            let command = try V2MembershipOperationCommand(intent: intent, admission: admission)
            let result = try await client.submit(command)
            guard case .receipt(let proof) = result, proof.validates(command: command), case .changed(let applied) = proof.outcome,
                try await client.recover(command, action: .query) == result else { throw V2OperationWorkError.identityConflict }
            await scheduler.closeAndDrain(); return applied
        } catch { await scheduler.closeAndDrain(); throw error }
    }
}
