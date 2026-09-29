import IMV2ServerApplication
import IMV2ServerContracts
import FluentKit
import Foundation
import IMV2ActorContracts
import IMV2Core
import SQLKit

/// Durable control handoff to the fixed owner. A processing operation can be
/// closed only by the owner's submit/close lock, never by a missing local row.
public struct PostgresV2DirectRoomOperationStore: Sendable {
    private let database: any Database
    private let routes: any V2DirectRoomShardRouting
    private let selector: V2DirectRoomShardRouter
    private let bootstrap: V2ActorCreationBootstrapPort
    public init(database: any Database, routes: any V2DirectRoomShardRouting,
        selector: V2DirectRoomShardRouter, bootstrap: V2ActorCreationBootstrapPort) {
        self.database=database; self.routes=routes; self.selector=selector; self.bootstrap=bootstrap
    }
    public func submit(_ command: V2DirectRoomOperationCommand, now: Date = Date(),
        deadline: ContinuousClock.Instant) async throws -> V2DirectRoomOperationResult {
        let request = try V2DirectRoomOperationRecoveryRequest(identity: command.identity,
            fingerprint: command.fingerprint, action: .query)
        // Pair routing is the existing control authority; the frozen placement
        // is written before owner I/O and cannot change after an uncertain call.
        return try await routes.withDirectPairRoute(actorUserID: command.actorUserID,
            targetUserID: command.targetUserID,
            proposedShardID: selector.shardID(for: command.actorUserID, and: command.targetUserID), deadline: deadline) { route in
            let preparation: Preparation = try await database.transaction { tx in
                let sql=try sqlDatabase(tx); try await lock(request.identity,sql:sql)
                if let row=try await read(request.identity,sql:sql) {
                    guard try row.fingerprint==request.fingerprint else { return .result(.fingerprintConflict) }
                    if let receipt=try row.receipt { return .result(.receipt(receipt)) }
                    guard try row.command==command,let room=row.roomID,let shard=row.shardID else { throw V2DirectMessagingStoreError.corruptPersistenceState }
                    return .owner(room,shard,command)
                }
                let ms=UInt64(try v2GatewayMilliseconds(now))
                if command.firstSubmissionDeadlineMilliseconds<=ms {
                    return .result(try await terminal(request,outcome:.rejected(.firstSubmissionExpired),now:now,sql:sql))
                }
                guard command.firstSubmissionDeadlineMilliseconds-ms<=600_000 else {
                    return .result(try await terminal(request,outcome:.rejected(.invalidDeadline),now:now,sql:sql))
                }
                let room=RoomID(uuid:UUID())
                try await sql.raw("INSERT INTO im_v2.direct_room_operation_handoffs(actor_user_id,operation_id,fingerprint,command,room_id,room_shard_id,phase) VALUES (\(bind: command.actorUserID.uuidValue!),\(bind: command.operationID.uuidValue!),\(bind: try json(request.fingerprint))::jsonb,\(bind: try json(command))::jsonb,\(bind: room.uuidValue!),\(bind: route.shardID),'processing')").run()
                return .owner(room,route.shardID,command)
            }
            let result: V2DirectRoomOperationResult
            switch preparation {
            case .result(let existing):result=existing
            case .owner(let room,let shard,_):
                guard shard==route.shardID else { throw V2RoomShardRouteError.routeConflict }
                guard case .provenDirect(let proof)=try await bootstrap.execute(.provenDirect(.init(command:command,roomID:room,roomShardID:shard)),deadline) else { throw V2DirectMessagingStoreError.corruptPersistenceState }
                result=proof
            }
            return (result,try openedRoom(result,request:request))
        }.mirrored(by:self,request:request)
    }
    public func recover(_ request: V2DirectRoomOperationRecoveryRequest, now: Date = Date(),
        deadline: ContinuousClock.Instant) async throws -> V2DirectRoomOperationResult {
        let preparation: Preparation = try await database.transaction { tx in
            let sql=try sqlDatabase(tx);try await lock(request.identity,sql:sql)
            guard let row=try await read(request.identity,sql:sql) else {
                guard request.action == .closeIfAbsent else { return .result(.unresolved) }
                return .result(try await terminal(request,outcome:.closed,now:now,sql:sql))
            }
            guard try row.fingerprint==request.fingerprint else { return .result(.fingerprintConflict) }
            if let receipt=try row.receipt { return .result(.receipt(receipt)) }
            guard let room=row.roomID,let shard=row.shardID else { throw V2DirectMessagingStoreError.corruptPersistenceState }
            guard let command=try row.command else { throw V2DirectMessagingStoreError.corruptPersistenceState }
            return .owner(room,shard,command)
        }
        switch preparation {
        case .result(let result): return result
        case .owner(let room,let shard,let command):
            guard case .userPair(let actor,let target)=request.identity.scope else { throw V2DirectMessagingStoreError.corruptPersistenceState }
            let result=try await routes.withDirectPairRoute(actorUserID:actor,targetUserID:target,proposedShardID:shard,deadline:deadline) { route in
                guard route.shardID==shard else { throw V2RoomShardRouteError.routeConflict }
                guard case .provenDirect(let result)=try await bootstrap.execute(.provenDirectRecovery(.init(request:request,roomID:room,roomShardID:shard)),deadline) else { throw V2DirectMessagingStoreError.corruptPersistenceState }
                if case .unresolved=result,request.action == .query {
                    guard case .provenDirect(let progressed)=try await bootstrap.execute(.provenDirect(.init(command:command,roomID:room,roomShardID:shard)),deadline) else { throw V2DirectMessagingStoreError.corruptPersistenceState }
                    return (progressed,try openedRoom(progressed,request:request))
                }
                return (result,try openedRoom(result,request:request))
            }
            if case .unresolved=result { return .processing(try .init(identity:request.identity,fingerprint:request.fingerprint)) }
            return try await mirror(result,request:request)
        }
    }
    fileprivate func mirror(_ result: V2DirectRoomOperationResult, request: V2DirectRoomOperationRecoveryRequest) async throws -> V2DirectRoomOperationResult {
        guard case .receipt(let receipt)=result else {
            if case .unresolved=result { return .processing(try .init(identity:request.identity,fingerprint:request.fingerprint)) }
            return result
        }
        guard receipt.identity==request.identity,receipt.fingerprint==request.fingerprint else { throw V2DirectMessagingStoreError.corruptPersistenceState }
        return try await database.transaction { tx in
            let sql=try sqlDatabase(tx);try await lock(request.identity,sql:sql)
            guard let row=try await read(request.identity,sql:sql),try row.fingerprint==request.fingerprint else { throw V2DirectMessagingStoreError.corruptPersistenceState }
            if let old=try row.receipt { guard old==receipt else { throw V2DirectMessagingStoreError.corruptPersistenceState };return .receipt(old) }
            try await sql.raw("UPDATE im_v2.direct_room_operation_handoffs SET phase='resolved',receipt=\(bind: try json(receipt))::jsonb WHERE actor_user_id=\(bind: request.identity.accountID.uuidValue!) AND operation_id=\(bind: op(request.identity))").run()
            return .receipt(receipt)
        }
    }
    private enum Preparation:Sendable { case result(V2DirectRoomOperationResult),owner(RoomID,String,V2DirectRoomOperationCommand) }
}
private extension V2DirectRoomOperationResult {
    func mirrored(by store: PostgresV2DirectRoomOperationStore, request:V2DirectRoomOperationRecoveryRequest) async throws -> Self {
        try await store.mirror(self,request:request)
    }
}
private struct HandoffRow:Decodable {
    let fingerprintJSON:String;let commandJSON:String?;let receiptJSON:String?;let roomUUID:UUID?;let shardID:String?
    enum CodingKeys:String,CodingKey {case fingerprintJSON="fingerprint_json",commandJSON="command_json",receiptJSON="receipt_json",roomUUID="room_id",shardID="room_shard_id"}
    var fingerprint:V2OperationFingerprint { get throws {try decode(fingerprintJSON)} }
    var command:V2DirectRoomOperationCommand? {get throws {try commandJSON.map{try decode($0)}}}
    var receipt:V2DirectRoomOperationReceipt? {get throws {try receiptJSON.map{try decode($0)}}}
    var roomID:RoomID? {roomUUID.map{.init(uuid:$0)}}
}
private func sqlDatabase(_ tx:any Database) throws -> any SQLDatabase {guard let sql=tx as? any SQLDatabase else {throw V2DirectMessagingStoreError.corruptPersistenceState};return sql}
private func json<T:Encodable>(_ value:T) throws -> String {String(decoding:try JSONEncoder().encode(value),as:UTF8.self)}
private func decode<T:Decodable>(_ value:String) throws -> T {try JSONDecoder().decode(T.self,from:Data(value.utf8))}
private func op(_ identity:V2OperationIdentity)->UUID {UUID(uuidString:identity.operation.rawOperationID)!}
private func lock(_ identity:V2OperationIdentity,sql:any SQLDatabase) async throws {
    let key="v2-direct-room-handoff:"+identity.accountID.rawValue+":"+identity.operation.rawOperationID
    try await sql.raw("SELECT pg_advisory_xact_lock(hashtextextended(\(bind:key),0))").run()
}
private func read(_ identity:V2OperationIdentity,sql:any SQLDatabase) async throws -> HandoffRow? {
    guard let row=try await sql.raw("SELECT fingerprint::text AS fingerprint_json,command::text AS command_json,receipt::text AS receipt_json,room_id,room_shard_id FROM im_v2.direct_room_operation_handoffs WHERE actor_user_id=\(bind:identity.accountID.uuidValue!) AND operation_id=\(bind:op(identity))").first(decoding:HandoffRow.self) else { return nil }
    let storedFingerprint=try row.fingerprint
    if let command=try row.command { guard command.actorUserID==identity.accountID,command.operationID.rawValue==identity.operation.rawOperationID,try command.fingerprint==storedFingerprint else { throw V2DirectMessagingStoreError.corruptPersistenceState } }
    if let receipt=try row.receipt { guard receipt.identity.accountID==identity.accountID,receipt.identity.operation.rawOperationID==identity.operation.rawOperationID,receipt.fingerprint==storedFingerprint else { throw V2DirectMessagingStoreError.corruptPersistenceState } }
    return row
}
private func terminal(_ request:V2DirectRoomOperationRecoveryRequest,outcome:V2DirectRoomOperationTerminalOutcome,now:Date,sql:any SQLDatabase) async throws -> V2DirectRoomOperationResult {
    let receipt=try V2DirectRoomOperationReceipt(identity:request.identity,fingerprint:request.fingerprint,outcome:outcome,resolvedAtMilliseconds:UInt64(try v2GatewayMilliseconds(now)))
    try await sql.raw("INSERT INTO im_v2.direct_room_operation_handoffs(actor_user_id,operation_id,fingerprint,phase,receipt) VALUES (\(bind:request.identity.accountID.uuidValue!),\(bind:op(request.identity)),\(bind:try json(request.fingerprint))::jsonb,'resolved',\(bind:try json(receipt))::jsonb)").run()
    return .receipt(receipt)
}
private func openedRoom(_ result:V2DirectRoomOperationResult,request:V2DirectRoomOperationRecoveryRequest) throws -> RoomID? {
    guard case .receipt(let receipt)=result else {return nil}
    guard receipt.identity==request.identity,receipt.fingerprint==request.fingerprint else {throw V2DirectMessagingStoreError.corruptPersistenceState}
    if case .opened(let room,_)=receipt.outcome {return room};return nil
}
