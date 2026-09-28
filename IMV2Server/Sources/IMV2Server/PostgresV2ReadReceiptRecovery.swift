import FluentKit
import Foundation
import IMV2ActorContracts
import IMV2Core
import SQLKit

extension PostgresV2ReadReceiptStore {
    /// The owner fences every recovery. Historical own receipts survive membership loss; current watermark proofs require current membership.
    public func recoverActivationValidated(_ request:V2ReadReceiptRecoveryRequest,token:V2RoomActivationToken,
        timeouts:V2RoomActivationSQLTimeouts = .default) async throws -> V2ReadReceiptRecoveryResult {
        try await V2ActorRoomQueryExecutor(database:database,timeouts:timeouts).withFencedRead(
            roomIDs:[request.command.roomID],tokens:[token]) { transaction in
                try await ReadReceiptRecoveryReader(database:transaction).read(request)
            }
    }
}
private struct ReadReceiptRecoveryReader {
    let database:any Database
    func read(_ request:V2ReadReceiptRecoveryRequest) async throws -> V2ReadReceiptRecoveryResult {
        let command = request.command
        guard let sql = database as? any SQLDatabase,let room = command.roomID.uuidValue,
              let actor = command.actorUserID.uuidValue,let operation = command.operationID.uuidValue else { throw V2ReadReceiptStoreError.invalidRequest }
        // An original result is stronger evidence than a current maximum. Match the original request first.
        if let original = try await sql.raw("""
            SELECT room_id,requested_room_sequence,resulting_room_sequence,recorded_at
            FROM im_v2.read_receipt_operations WHERE user_id=\(bind:actor) AND operation_id=\(bind:operation)
            """).first(decoding:RecoveryOperation.self) {
            guard original.room == room,original.requested == Int64(command.readThroughRoomSequence) else { return .fingerprintConflict }
            guard original.resulting>=original.requested else { throw V2ReadReceiptStoreError.corruptPersistenceState }
            let receipt = try V2ReadReceipt(roomID:command.roomID,userID:command.actorUserID,
                readThroughRoomSequence:UInt64(exactly:original.resulting) ?? 0,recordedAt:original.recordedAt)
            return .originalReceipt(try .init(command:command,receipt:receipt))
        }
        guard let context = try await sql.raw("""
            SELECT room.room_sequence AS head,EXISTS(SELECT 1 FROM im_v2.room_memberships member
              WHERE member.room_id=room.room_id AND member.user_id=\(bind:actor)
                AND member.joined_revision<=room.membership_revision
                AND (member.left_revision IS NULL OR member.left_revision>room.membership_revision)) AS member
            FROM im_v2.rooms room WHERE room.room_id=\(bind:room) FOR SHARE
            """).first(decoding:RecoveryContext.self) else { return .currentUnavailable(.roomNotFound) }
        guard context.member else { return .currentUnavailable(.permissionDenied) }
        guard context.head>=Int64(command.readThroughRoomSequence) else { return .currentUnavailable(.invalidWatermark) }
        if let current = try await sql.raw("SELECT read_through_room_sequence AS sequence,updated_at FROM im_v2.room_read_receipts WHERE room_id=\(bind:room) AND user_id=\(bind:actor)").first(decoding:RecoveryWatermark.self),current.sequence>=Int64(command.readThroughRoomSequence) {
            guard current.sequence<=context.head else { throw V2ReadReceiptStoreError.corruptPersistenceState }
            let watermark = try V2ReadReceipt(roomID:command.roomID,userID:command.actorUserID,
                readThroughRoomSequence:UInt64(exactly:current.sequence) ?? 0,recordedAt:current.updatedAt)
            return .watermarkProof(try .init(command:command,watermark:watermark))
        }
        return .unresolved
    }
}
private struct RecoveryContext:Decodable { let head:Int64;let member:Bool }
private struct RecoveryOperation:Decodable {
    let room:UUID;let requested:Int64;let resulting:Int64;let recordedAt:Date
    enum CodingKeys:String,CodingKey { case room="room_id",requested="requested_room_sequence",resulting="resulting_room_sequence",recordedAt="recorded_at" }
}
private struct RecoveryWatermark:Decodable {
    let sequence:Int64;let updatedAt:Date
    enum CodingKeys:String,CodingKey { case sequence,updatedAt="updated_at" }
}
