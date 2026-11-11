import Foundation
import IMV2Core
let actor=try UserID("AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")
let room=try RoomID("BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")
let message=try MessageID("CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")
let media=try MediaID("DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD")
let variant=try ResourceVariantID("EEEEEEEE-EEEE-EEEE-EEEE-EEEEEEEEEEEE")
let operation=try ResourceImportOperationID("FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF")
let target=try MediaID("11111111-1111-1111-1111-111111111111")
let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys,.withoutEscapingSlashes]
func show<T:Encodable>(_ key:String,_ value:T)throws { print(key+"\t"+String(data:try encoder.encode(value),encoding:.utf8)!) }
var sources:[(String,V2ResourceImportSource)]=[("message-original",.message(location:.init(roomID:room,messageID:message),mediaID:media,variantID:nil)),("message-variant",.message(location:.init(roomID:room,messageID:message),mediaID:media,variantID:variant))]
for (name,context):(String,V2ProfileViewContext) in [("relationship",.relationship),("direct",.directConversation),("room",.room(room)),("review",.groupJoinReview(room))] {
    sources.append((name,.avatar(key:.init(userID:actor,context:context),mediaID:media,variantID:variant)))
}
for (name,source) in sources {
    try show("source-"+name,source)
    for (label,usage):(String,V2ResourceUsage) in [("user",.userAvatar),("group",.groupAvatar(room)),("attachment",.messageAttachment(room))] {
        try show(name+"-"+label,V2ResourceImportRequest(operationID:operation,source:source,targetUsage:usage,targetMediaID:target))
    }
}
for (name,home):(String,V2ResourceHome) in [("account",.account(actor)),("room",.room(room))] {
    let locator=V2ResourceImportLocator(home:home,operationID:operation);try show(name+"-locator",locator)
    for state in [V2ResourceImportState.pending,.copying,.processing,.ready,.cancelled,.failed] {
        try show(name+"-"+state.rawValue,V2ResourceImportStatus(locator:locator,mediaID:target,state:state,bindableUntil:state == .ready ? Date(timeIntervalSince1970:1800000000):nil))
    }
}
