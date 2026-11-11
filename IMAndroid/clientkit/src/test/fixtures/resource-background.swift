import Foundation
import IMV2Core
let room=try RoomID("22222222-2222-2222-2222-222222222222")
let session=try MediaUploadSessionID("CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")
let media=try MediaID("BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")
let checksum=try V2ResourceChecksum(value:String(repeating:"a",count:64))
let issued=Date(timeIntervalSince1970:1_750_000_000)
let expiry=issued.addingTimeInterval(900)
let whole=try V2ResourceBackgroundAuthorization(id:UUID(uuidString:"DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD")!,sessionID:session,generation:3,mediaID:media,scope:.whole(byteCount:16,checksum:checksum),issuedAt:issued,expiresAt:expiry)
let part=try V2ResourceBackgroundAuthorization(id:UUID(uuidString:"EEEEEEEE-EEEE-EEEE-EEEE-EEEEEEEEEEEE")!,sessionID:session,generation:3,mediaID:media,partNumber:2,issuedAt:issued,expiresAt:expiry)
let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys,.withoutEscapingSlashes]
func show<T:Encodable>(_ key:String,_ value:T)throws {print(key+"\t"+String(data:try encoder.encode(value),encoding:.utf8)!)}
try show("whole",whole);try show("part",part)
try show("wholePlan",V2ResourceTransferPlan(mode:.httpPut,url:URL(string:"https://objects.invalid/whole?cap=private-whole")!,expiresAt:expiry,expectedByteCount:16,checksum:checksum,backgroundAuthorization:whole))
try show("partPlan",V2ResourceTransferPlan(mode:.httpPartPut,url:URL(string:"https://objects.invalid/part?cap=private-part")!,expiresAt:expiry,expectedByteCount:8,byteRange:.init(lowerBound:8,upperBound:15),partNumber:2,backgroundAuthorization:part))
let locator=V2ResourceUploadLocator(home:.room(room),sessionID:session)
try show("targets",V2ResourceUploadTargetsRequest(locator:locator,generation:3,partNumbers:[2,1],background:true))
try show("nextTarget",V2ResourceUploadTargetsRequest(locator:locator,generation:3,background:true))
