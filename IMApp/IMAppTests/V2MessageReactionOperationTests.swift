import Foundation
import IMV2Core
@testable import IMV2ClientKit
@testable import IMApp
import Testing

actor V2AppReactionClient:V2MessageReactionOperationClient {
    let account:UserID,rejectOld:Bool
    var calls=0,submissions=0
    init(account:UserID,rejectOld:Bool=false) { self.account=account;self.rejectOld=rejectOld }
    func snapshot(roomID:RoomID,messageID:MessageID,reaction:String) async throws -> V2MessageReactionSnapshot {
        calls += 1
        return try .init(roomID:roomID,actorUserID:account,messageID:messageID,reaction:reaction,targetState:.absent,revision:0)
    }
    func submit(_ command:V2MessageReactionOperationCommand) async throws -> V2MessageReactionRecoveryResult {
        calls += 1;submissions += 1
        return .receipt(try .init(identity:command.identity,fingerprint:command.fingerprint,outcome:rejectOld ? .rejected(.permissionDenied) : .committed(.init(targetState:command.targetState,revision:command.expectedReactionRevision+1,event:nil)),resolvedAtMilliseconds:UInt64(Date().timeIntervalSince1970*1_000)))
    }
    func recover(_ request:V2MessageReactionRecoveryRequest) async throws -> V2MessageReactionRecoveryResult { .unresolved }
}
