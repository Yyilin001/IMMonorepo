import Foundation
import IMV2Core
@testable import IMV2ClientKit

struct DurableForwardFixture:Sendable {
    let user=UserID(uuid:UUID()),binding=V2LocalInstallationBinding(value:UUID())
    let url=FileManager.default.temporaryDirectory.appending(path:"forward-fixture-"+UUID().uuidString).appending(path:"state.sqlite")
    let now=Date(timeIntervalSince1970:1_800_000_000)
    let command:V2ForwardPlanOperationCommand
    init(sourceCount:Int=25,targetCount:Int=2) throws {
        let rooms=[RoomID(uuid:UUID()),RoomID(uuid:UUID())]
        command=try .init(actorUserID:user,command:.init(operationID:.init(uuid:UUID()),sources:(0..<sourceCount).map { index in try .init(roomID:rooms[index%2],messageID:.init(uuid:UUID()),revision:.init(UInt64(index+1))) },targetRoomIDs:(0..<targetCount).map { _ in .init(uuid:UUID()) }),firstSubmissionDeadlineMilliseconds:UInt64(now.addingTimeInterval(86_400).timeIntervalSince1970*1_000))
    }
    func open() throws -> GRDBV2LocalSyncStore { try .init(databaseURL:url,installationBinding:binding,userID:user) }
    func remove() { try? FileManager.default.removeItem(at:url.deletingLastPathComponent()) }
    func progress(resolvedCount:Int,cancelRemaining:Bool=false) throws -> V2ForwardPlanProgress {
        let children=try (0..<command.childCount).map { index -> V2ForwardPlanChildProgress in
            let child=try command.childCommand(index:index)
            let state:V2ForwardPlanChildState
            if Int(index)<resolvedCount {
                let items=try child.sources.enumerated().map { offset,source in
                    try V2ForwardPlanItemResult(sourceMessageID:source.messageID,targetRoomID:child.targetRoomIDs[0],outcome:.accepted(.init(messageID:.init(uuid:UUID()),roomSequence:index*20+UInt64(offset)+1)))
                }
                state = .resolved(try .init(parentIdentity:command.identity,parentFingerprint:command.fingerprint,index:index,operationID:child.operationID,outcome:.completed(items),resolvedAtMilliseconds:1_800_000_000_000))
            } else if cancelRemaining {
                state = .resolved(try .init(parentIdentity:command.identity,parentFingerprint:command.fingerprint,index:index,operationID:child.operationID,outcome:.cancelledBeforeStart,resolvedAtMilliseconds:1_800_000_000_000))
            } else { state = .pending }
            return try .init(index:index,operationID:child.operationID,state:state)
        }
        return try .init(identity:command.identity,fingerprint:command.fingerprint,executionState:resolvedCount==Int(command.childCount) || cancelRemaining ? .completed : .processing,children:children)
    }
    func resolved(_ progress:V2ForwardPlanProgress) throws -> V2ForwardPlanResolvedResult {
        try .init(receipt:.init(identity:command.identity,fingerprint:command.fingerprint,outcome:.completed(.derive(command:command,progress:progress)),resolvedAtMilliseconds:1_800_000_000_000),progress:progress)
    }
}
