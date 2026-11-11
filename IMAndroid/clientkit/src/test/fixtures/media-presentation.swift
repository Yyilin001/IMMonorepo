import Foundation
import IMV2Core
let room=try RoomID("BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")
let media=try MediaID("DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD")
let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys,.withoutEscapingSlashes]
for type in ["image/png","image/gif","video/mp4","audio/ogg","application/pdf"] {
    let descriptor=try V2ResourceDescriptor(key:.init(home:.room(room),mediaID:media),revision:3,displayName:.init("目录/附件é"),contentType:type,byteCount:1234,checksum:.init(algorithm:.sha256,value:String(repeating:"a",count:64)),state:.ready)
    let presentation=try V2MediaPresentation(mediaID:media,kind:V2MediaPresentation.kind(forContentType:type),contentType:type,byteCount:1234,resourceDescriptor:descriptor)
    print(type+"\t"+String(data:try encoder.encode(presentation),encoding:.utf8)!)
}
