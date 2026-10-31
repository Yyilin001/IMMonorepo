import Foundation
import GRDB
import IMV2Core
@testable import IMV2ClientKit

/// Resource tests inspect the production typed send payload and finish with a
/// matching owner receipt, rather than synthesizing legacy outbox acceptance.
extension GRDBV2LocalSyncStore {
    func resourceSendPayloads() throws -> [V2SendMessageCommand] {
        try databasePool.read { db in
            try Data.fetchAll(db,sql:"SELECT command FROM v2_message_send_operations ORDER BY rowid").map {
                try JSONDecoder().decode(V2MessageSendOperationCommand.self,from:$0).command
            }
        }
    }
    private func resourceSendFixtureEnvelope(_ id:ClientMessageID) throws -> (UUID,V2MessageSendOperationCommand) {
        try databasePool.read { db in
            guard let row=try Row.fetchOne(db,sql:"SELECT work_id,command FROM v2_message_send_operations WHERE client_message_id=?",arguments:[id.rawValue]),
                  let work=UUID(uuidString:row["work_id"]) else { throw V2OperationWorkError.invalidRecord }
            return (work,try JSONDecoder().decode(V2MessageSendOperationCommand.self,from:row["command"]))
        }
    }
    /// Applies the matching accepted body through the room-log importer;
    /// never writes the projection-observed GC gate directly.
    func observeResourceSendFixtureProjection(_ id: ClientMessageID,
        accepted: V2MessageOperationAcceptance, mediaPresentations: [V2MediaPresentation] = []) throws {
        let (_, envelope) = try resourceSendFixtureEnvelope(id)
        let command = envelope.command
        guard mediaPresentations.map(\.mediaID) == command.media.map(\.mediaID) else {
            throw V2OperationWorkError.invalidRecord
        }
        let presentationWire = try mediaPresentations.map { presentation -> [String: Any] in
            let descriptor: V2ResourceDescriptor? = try databasePool.read { db in
                guard let row = try Row.fetchOne(db, sql: "SELECT job_id FROM v2_resource_transfer_jobs WHERE media_id=?", arguments: [presentation.mediaID.rawValue]),
                      let id = UUID(uuidString: row["job_id"]), let job = try Self.readResourceTransfer(id, db: db),
                      let session = job.session else { return nil }
                return try .init(key: .init(home: session.locator.home, mediaID: presentation.mediaID), revision: session.generation,
                    displayName: job.request.displayName, contentType: job.request.contentType, byteCount: job.request.byteCount,
                    checksum: job.request.checksum, state: .ready)
            }
            return try resourcePresentationWireFixture(room: command.roomID.rawValue, media: presentation.mediaID.rawValue,
                contentType: presentation.contentType, bytes: presentation.byteCount, descriptor: descriptor)
        }
        let event = try V2ClientGroupEvent(sourceEventID: .init(uuid: UUID()), roomSequence: accepted.roomSequence, projectionKind: "message",
            payload: JSONSerialization.data(withJSONObject: ["event_type": "message.accepted",
                "message_id": accepted.messageID.rawValue, "room_id": command.roomID.rawValue,
                "room_sequence": accepted.roomSequence, "message_revision": 1,
                "sender_user_id": command.senderUserID.rawValue, "text": command.text,
                "media_ids": command.media.map { $0.mediaID.rawValue },
                "media_presentations": presentationWire,
                "server_created_at_ms": 1750000000000]))
        _ = try applyGroupEventPage(.init(roomID: command.roomID, events: [event],
            nextRoomSequence: accepted.roomSequence, hasMore: false))
    }

    func claimResourceSendForRecovery(_ id:ClientMessageID,now:Date) throws {
        let (work,_)=try resourceSendFixtureEnvelope(id)
        guard case let .claimed(claim)=try claimOperationWork(id:work,ownerID:UUID(),action:.submit,now:now) else { throw V2OperationWorkError.invalidTransition }
        try deferOperationWork(claim,until:now,code:"outcomeUnknown",nextAction:.reconcile)
    }
    func completeResourceSendFixture(_ id:ClientMessageID,result:V2MessageSendOperationTerminalOutcome,now:Date=Date()) throws {
        let (work,command)=try resourceSendFixtureEnvelope(id)
        // Submission is marked durably before a trusted receipt may be applied.
        if let current=try operationWork(id:work), !current.submissionStarted {
            guard case .claimed = try claimOperationWork(id:work,ownerID:UUID(),action:.submit,now:min(Date(),Date(timeIntervalSince1970:Double(command.firstSubmissionDeadlineMilliseconds)/1000-1))) else { throw V2OperationWorkError.invalidTransition }
        }
        let receipt=try V2MessageSendOperationReceipt(identity:command.identity,fingerprint:command.fingerprint,outcome:result,resolvedAtMilliseconds:UInt64(now.timeIntervalSince1970*1000))
        try completeMessageSend(command,receipt:receipt,now:now)
    }
}
