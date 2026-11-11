import Foundation
import IMV2Core
let user=try UserID("AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")
let room=try RoomID("BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")
let message=try MessageID("CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")
let media=try MediaID("DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD")
let variant=try ResourceVariantID("EEEEEEEE-EEEE-FFFF-EEEE-EEEEEEEEEEEE")
let checksum=try V2ResourceChecksum(algorithm:.sha256,value:String(repeating:"a",count:64))
let key=V2ResourceKey(home:.room(room),mediaID:media)
let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys,.withoutEscapingSlashes]
func show<T:Encodable>(_ key:String,_ value:T)throws { print(key+"\t"+String(data:try encoder.encode(value),encoding:.utf8)!) }
try show("room-key",key);try show("account-key",V2ResourceKey(home:.account(user),mediaID:media))
for state in [V2ResourceState.pending,.verifying,.scanning,.processing,.ready,.rejected,.deletionPending,.deleted] {
    try show("descriptor-"+state.rawValue,V2ResourceDescriptor(key:key,revision:7,displayName:.init("图片.png"),contentType:"image/png",byteCount:1234,checksum:state == .ready ? checksum:nil,state:state))
}
let descriptor=try V2ResourceDescriptor(key:key,revision:7,displayName:.init("目录/图e\u{301}.png"),contentType:"image/png",byteCount:1234,checksum:checksum,state:.ready,pixelWidth:640,pixelHeight:480,durationMilliseconds:0)
try show("descriptor-complete",descriptor)
try show("descriptor-large-dimensions",V2ResourceDescriptor(key:key,revision:8,displayName:.init("极大尺寸.png"),contentType:"image/png",byteCount:1234,checksum:checksum,state:.ready,pixelWidth:Int.max,pixelHeight:1,durationMilliseconds:Int64.max))
for (name,rendition):(String,V2ResourceVariantKey.Rendition) in [("original",.original),("derived",.derived(id:variant,version:try .init(3)))] {
    let variantKey=V2ResourceVariantKey(resource:key,rendition:rendition)
    try show("variant-key-"+name,variantKey);try show("variant-"+name,V2ResourceVariantDescriptor(key:variantKey,checksum:checksum,byteCount:1234))
}
for category in V2ResourceCategory.allCases { try show("query-"+category.rawValue,V2RoomResourceQuery(category:category)) }
try show("query-bounded",V2RoomResourceQuery(category:.image,limit:100,cursor:"opaque+/中文=",before:253402300799000,after:0))
let position=try V2RoomResourcePosition(roomSequence:12,ordinal:9,mediaID:media)
let item=try V2RoomResourceItem(messageID:message,messageRevision:3,position:position,createdAt:1800000000000,descriptor:descriptor)
try show("position",position);try show("item",item)
try show("page",V2RoomResourcePage(items:[item],snapshotUpperRoomSequence:20,nextCursor:"opaque+/中文="))
try show("page-final",V2RoomResourcePage(items:[item],snapshotUpperRoomSequence:20,nextCursor:nil))
try show("page-empty",V2RoomResourcePage(items:[],snapshotUpperRoomSequence:0,nextCursor:nil))
