import Foundation
import IMV2Core
let actor=try UserID("AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")
let room=try RoomID("BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")
let operation=try ClientMessageID("CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")
let media=try ["DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD","EEEEEEEE-EEEE-EEEE-EEEE-EEEEEEEEEEEE"].map { V2MediaReference(mediaID:try MediaID($0)) }
let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys,.withoutEscapingSlashes]
for (name,text,items):(String,String,[V2MediaReference]) in [("empty","",media),("unicode","e\u{301} 图片\n",media),("reversed","e\u{301} 图片\n",media.reversed()),("single","单附件",Array(media.prefix(1)))] {
    let command=try V2SendMessageCommand(roomID:room,senderUserID:actor,clientMessageID:operation,text:text,media:items,limits:.init(maxUTF8Bytes:32768))
    let send=try V2MessageSendOperationCommand(command:command,firstSubmissionDeadlineMilliseconds:1800000000000)
    let value:[String:String] = ["text":text,"media":items.map { $0.mediaID.rawValue }.joined(separator:","),"domain":command.fingerprint.digest.map { String(format:"%02x",$0) }.joined(),"fingerprint":try send.fingerprint.digest.map { String(format:"%02x",$0) }.joined()]
    print(name+"\t"+String(data:try encoder.encode(value),encoding:.utf8)!)
}
