// Generates group-avatar-swift.txt using the repository's IMV2Core module.
import Foundation
import IMV2Core
let actor = try UserID("AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")
let device = try DeviceID("BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")
let room = try RoomID("CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")
let media = try MediaID("DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD")
let operation = try GroupAvatarOperationID("EEEEEEEE-EEEE-EEEE-EEEE-EEEEEEEEEEEE")
let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys,.withoutEscapingSlashes]
func show<T: Encodable>(_ key: String,_ value: T) throws { print(key + "\t" + String(data: try encoder.encode(value),encoding: .utf8)!) }
let now = Date(timeIntervalSince1970: 1800000000)
for (label, mutation): (String,V2GroupAvatarMutation) in [("set",.set(media)),("remove",.remove)] {
    let command = try V2GroupAvatarCommand(operationID: operation,roomID: room,expectedRevision: 4,mutation: mutation)
    let state = try V2GroupAvatarState(roomID: room,mediaID: mutation.mediaID,revision: 5)
    let change = try V2GroupAvatarChange(state: state,roomSequence: 9,updatedAt: now)
    try show(label,command);try show(label+"State",state)
    for (kind,outcome): (String,V2GroupAvatarCommandResponse.Outcome) in [("committed",.committed(change)),("revisionConflict",.revisionConflict),("idempotencyConflict",.idempotencyConflict),("resourceUnavailable",.resourceUnavailable),("forbidden",.forbidden)] {
        try show(label+"-"+kind,V2GroupAvatarCommandResponse(actorUserID: actor,deviceID: device,command: command,outcome: outcome))
    }
    for action in [V2GroupAvatarRecoveryRequest.Action.query,.closeIfAbsent] {
        let request = V2GroupAvatarRecoveryRequest(command: command,action: action)
        try show(label+"-"+action.rawValue,request)
        for (kind,result): (String,V2GroupAvatarRecoveryResult) in [("committed",.committed(change)),("closed",.closed),("idempotencyConflict",.idempotencyConflict)] {
            try show(label+"-"+action.rawValue+"-"+kind,V2GroupAvatarRecoveryResponse(actorUserID: actor,deviceID: device,request: request,result: result))
        }
        if action == .query { try show(label+"-query-unresolved",V2GroupAvatarRecoveryResponse(actorUserID: actor,deviceID: device,request: request,result: .unresolved)) }
    }
}
let checksum = try V2ResourceChecksum(value: String(repeating: "a",count: 64))
let plan = try V2ResourceTransferPlan(mode: .httpGet,url: URL(string:"https://delivery.invalid/avatar?signature=fixture")!,expiresAt: now.addingTimeInterval(120),expectedByteCount: 8,checksum: checksum)
let access = try V2ResourceAvatarAccess(mediaID: media,variantID: .init("FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF"),version: 3,checksum: checksum,byteCount: 8,plan: plan)
for (label,avatar) in [("presentation",Optional(access)),("withoutPlan",Optional(access.withoutDownloadPlan())),("empty",nil)] {
    let state = try V2GroupAvatarState(roomID: room,mediaID: avatar?.mediaID,revision: avatar == nil ? 0 : 5)
    try show(label,V2GroupAvatarPresentation(actorUserID: actor,deviceID: device,state: state,membershipRevision: 7,resourceGeneration: avatar == nil ? nil : 2,canManage: true,avatar: avatar,observedAt: now,validUntil: now.addingTimeInterval(300),serverNow: now))
}
