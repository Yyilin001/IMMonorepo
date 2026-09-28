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
    func claimResourceSendForRecovery(_ id:ClientMessageID,now:Date) throws {
        let (work,_)=try resourceSendFixtureEnvelope(id)
        guard case let .claimed(claim)=try claimOperationWork(id:work,ownerID:UUID(),action:.submit,now:now) else { throw V2OperationWorkError.invalidTransition }
        try deferOperationWork(claim,until:now,code:"outcomeUnknown",nextAction:.reconcile)
    }
    func completeResourceSendFixture(_ id:ClientMessageID,result:V2MessageSendOperationTerminalOutcome) throws {
        let (work,command)=try resourceSendFixtureEnvelope(id)
        // Submission is marked durably before a trusted receipt may be applied.
        if let current=try operationWork(id:work), !current.submissionStarted {
            guard case .claimed = try claimOperationWork(id:work,ownerID:UUID(),action:.submit,now:min(Date(),Date(timeIntervalSince1970:Double(command.firstSubmissionDeadlineMilliseconds)/1000-1))) else { throw V2OperationWorkError.invalidTransition }
        }
        let receipt=try V2MessageSendOperationReceipt(identity:command.identity,fingerprint:command.fingerprint,outcome:result,resolvedAtMilliseconds:UInt64(Date().timeIntervalSince1970*1000))
        try completeMessageSend(command,receipt:receipt)
    }
}
