import Foundation
import IMV2Core
let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys,.withoutEscapingSlashes]
let actor=UserID(uuid:UUID(uuidString:"AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!)
let room=RoomID(uuid:UUID(uuidString:"BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!)
let operation=ClientMessageID(uuid:UUID(uuidString:"CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")!)
let reply=V2MessageReplyReference(messageID:MessageID(uuid:UUID(uuidString:"DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD")!))
let text=" A😀e\u{301} 中文 link "
let entities:[V2MessageEntity] = try [.init(offsetUTF16:2,lengthUTF16:2,kind:.bold),.init(offsetUTF16:4,lengthUTF16:2,kind:.italic),.init(offsetUTF16:5,lengthUTF16:1,kind:.underline),.init(offsetUTF16:7,lengthUTF16:2,kind:.strikethrough),.init(offsetUTF16:7,lengthUTF16:2,kind:.spoiler),.init(offsetUTF16:1,lengthUTF16:1,kind:.code),.init(offsetUTF16:0,lengthUTF16:10,kind:.preformatted),.init(offsetUTF16:10,lengthUTF16:4,kind:.link,linkURL:URL(string:"https://example.test/a?q=%E4%B8%AD#fragment")!)]
for (name,mentions,format,reference) in [("full",[V2MentionTarget.everyone,.user(actor)],entities,Optional(reply)),("ordered",[.user(actor),.everyone],Array(entities.reversed()),Optional(reply)),("plain",[],[],nil)] {
 let command=try V2SendMessageCommand(roomID:room,senderUserID:actor,clientMessageID:operation,text:text,media:[],mentions:mentions,entities:format,replyTo:reference,limits:.init(maxUTF8Bytes:32768))
 let publicCommand=try V2MessageSendOperationCommand(command:command,firstSubmissionDeadlineMilliseconds:1800000000000)
 struct Fixture:Encodable {let name:String;let text:String;let entities:[V2MessageEntity];let domain:String;let fingerprint:String}
 let f=try Fixture(name:name,text:text,entities:format,domain:command.fingerprint.digest.map{String(format:"%02x",$0)}.joined(),fingerprint:publicCommand.fingerprint.digest.map{String(format:"%02x",$0)}.joined())
 print(String(data:try encoder.encode(f),encoding:.utf8)!)
}
