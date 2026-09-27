import Foundation
import GRDB
import IMV2Core
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public protocol V2MessageOperationRecovering: Sendable {
    func recover(_ request: V2MessageOperationRecoveryRequest) async throws -> V2MessageOperationRecoveryResult
}

public struct V2HTTPMessageOperationRecoveryClient: V2MessageOperationRecovering {
    private let endpoint: URL
    private let credentials: any V2ClientMediaEdgeCredentialProvider
    private let transport: any V2ClientMediaEdgeHTTPTransport
    public init(endpoint: URL, credentials: any V2ClientMediaEdgeCredentialProvider, transport: any V2ClientMediaEdgeHTTPTransport) throws {
        guard endpoint.scheme == "https", endpoint.host != nil, endpoint.user == nil, endpoint.password == nil,
              endpoint.fragment == nil else { throw V2ClientMediaTransferError.invalidMediaEdgeEndpoint }
        self.endpoint = endpoint; self.credentials = credentials; self.transport = transport
    }
    public func recover(_ input: V2MessageOperationRecoveryRequest) async throws -> V2MessageOperationRecoveryResult {
        let identity = try await credentials.mediaEdgeCredentials()
        guard !identity.accessToken.isEmpty,
              !identity.accessToken.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 })
        else { throw V2ClientMediaTransferError.authorizationUnavailable }
        var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 15)
        request.httpMethod = "POST"; request.httpBody = try JSONEncoder().encode(input)
        request.setValue("Bearer \(identity.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(identity.deviceID.rawValue, forHTTPHeaderField: "X-IM-Device-ID")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        try Task.checkCancellation()
        let (data, response) = try await transport.data(for: request)
        try Task.checkCancellation()
        guard response.statusCode == 200, V2HTTPContract.isJSON(response), data.count <= 65_536 else {
            throw V2ClientMediaTransferError.invalidMediaEdgeResponse
        }
        return try JSONDecoder().decode(V2MessageOperationRecoveryResult.self, from: data)
    }
}

/// 与发送 outbox 共用刷新单飞和账号生命周期。恢复记录在原命令状态变更的同一事务写入。
public struct V2MessageOperationRecoveryController: Sendable {
    private let store: GRDBV2LocalSyncStore
    private let remote: any V2MessageOperationRecovering
    private let actorUserID: @Sendable () async throws -> UserID
    public init(store: GRDBV2LocalSyncStore, remote: any V2MessageOperationRecovering,
                actorUserID: @escaping @Sendable () async throws -> UserID) {
        self.store = store; self.remote = remote; self.actorUserID = actorUserID
    }
    func requireRecovery(_ command: V2PendingMessageCommand, now: Date) async throws {
        try await store.requireMessageOperationRecovery(command.clientMessageID, now: now)
    }
    func flushOnce(now: Date) async throws -> V2CommandFlushResult? {
        guard let command = try await store.nextMessageOperationRecovery(now: now) else { return nil }
        do {
            let actor = try await actorUserID()
            let original = try V2SendMessageCommand(roomID: command.roomID, senderUserID: actor,
                clientMessageID: command.clientMessageID, text: command.text, media: command.media,
                mentions: command.mentions, entities: command.entities, replyTo: command.replyTo,
                limits: .init(maxUTF8Bytes: max(1, command.text.utf8.count)))
            let result = try await remote.recover(.init(roomID: command.roomID, clientMessageID: command.clientMessageID,
                fingerprint: original.fingerprint, action: .closeIfAbsent))
            try Task.checkCancellation()
            guard try await actorUserID() == actor else { throw CancellationError() }
            switch result {
            case .accepted(let accepted):
                try await store.completeMessageOperationRecovery(command.clientMessageID, result: result)
                _ = accepted
                return .accepted(command.clientMessageID)
            case .closed:
                try await store.completeMessageOperationRecovery(command.clientMessageID, result: result)
                return .rejected(command.clientMessageID, code: "MESSAGE_OPERATION_CLOSED")
            case .fingerprintConflict:
                try await store.completeMessageOperationRecovery(command.clientMessageID, result: result)
                return .rejected(command.clientMessageID, code: "IDEMPOTENCY_CONFLICT")
            case .unresolved:
                break
            }
        } catch is CancellationError { throw CancellationError()
        } catch { /* Original identity remains frozen; retry only recovery, never a replacement send. */ }
        try await store.scheduleMessageOperationRecovery(command.clientMessageID, now: now)
        return .retryScheduled(command.clientMessageID)
    }
}

extension GRDBV2LocalSyncStore {
    static let messageOperationRecoverySchemaSQL = """
        CREATE TABLE v2_message_operation_recoveries (
            client_message_id TEXT PRIMARY KEY REFERENCES v2_pending_message_commands(client_message_id) ON DELETE RESTRICT,
            state TEXT NOT NULL DEFAULT 'pending' CHECK (state = 'pending'),
            attempt_count INTEGER NOT NULL DEFAULT 0 CHECK (attempt_count >= 0),
            next_attempt_at REAL NOT NULL
        );
        CREATE INDEX v2_message_operation_recovery_due ON v2_message_operation_recoveries(next_attempt_at,client_message_id);
        """

    func requireMessageOperationRecovery(_ id: ClientMessageID, now: Date) throws {
        try databasePool.write { db in
            try Self.requirePendingCommand(id, db: db)
            try db.execute(sql: """
                UPDATE v2_pending_message_commands SET state='rejected',terminal_code='MESSAGE_OUTCOME_UNKNOWN'
                WHERE client_message_id=?;
                """, arguments: [id.rawValue])
            try db.execute(sql: "INSERT OR IGNORE INTO v2_message_operation_recoveries(client_message_id,next_attempt_at) VALUES (?,?)",
                           arguments: [id.rawValue, try Self.commandRetryTimestamp(now)])
        }
    }
    func nextMessageOperationRecovery(now: Date) throws -> V2PendingMessageCommand? {
        try databasePool.read { db in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT command.* FROM v2_message_operation_recoveries recovery JOIN v2_pending_message_commands command USING(client_message_id)
                WHERE recovery.next_attempt_at <= ? ORDER BY recovery.next_attempt_at,recovery.client_message_id LIMIT 1
                """, arguments: [try Self.commandRetryTimestamp(now)]) else { return nil }
            return try Self.decodePendingCommand(row)
        }
    }
    func scheduleMessageOperationRecovery(_ id: ClientMessageID, now: Date) throws {
        try databasePool.write { db in
            guard let count = try Int.fetchOne(db, sql: "SELECT attempt_count FROM v2_message_operation_recoveries WHERE client_message_id=?", arguments: [id.rawValue])
            else { return }
            let delay = Double.random(in: 1...min(300, pow(2, Double(min(count + 1, 9)))))
            try db.execute(sql: "UPDATE v2_message_operation_recoveries SET attempt_count=MIN(attempt_count+1,1000000),next_attempt_at=? WHERE client_message_id=?",
                           arguments: [try Self.commandRetryTimestamp(now.addingTimeInterval(delay)), id.rawValue])
        }
    }
    func completeMessageOperationRecovery(_ id: ClientMessageID, result: V2MessageOperationRecoveryResult) throws {
        try databasePool.write { db in
            guard try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM v2_message_operation_recoveries WHERE client_message_id=?)", arguments: [id.rawValue]) == true
            else { throw V2ClientCommandError.commandNotPending }
            switch result {
            case .accepted(let value):
                try db.execute(sql: """
                    UPDATE v2_pending_message_commands SET state='accepted',accepted_message_id=?,accepted_room_sequence=?,terminal_code=NULL
                    WHERE client_message_id=?
                    """, arguments: [value.messageID.rawValue, try Self.commandStorageInteger(value.roomSequence), id.rawValue])
            case .closed, .fingerprintConflict:
                try db.execute(sql: "UPDATE v2_pending_message_commands SET state='rejected',terminal_code=? WHERE client_message_id=?",
                               arguments: [result == .closed ? "MESSAGE_OPERATION_CLOSED" : "IDEMPOTENCY_CONFLICT", id.rawValue])
            case .unresolved: throw V2ClientCommandError.commandConflict
            }
            try db.execute(sql: "DELETE FROM v2_message_operation_recoveries WHERE client_message_id=?", arguments: [id.rawValue])
        }
    }
}
