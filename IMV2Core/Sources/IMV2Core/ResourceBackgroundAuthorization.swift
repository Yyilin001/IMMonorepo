import Foundation

/// A newly delegated, narrow PUT authority. It is not a room activation or a presentation lease.
/// The native provider signs this grant into its exact object capability and fences cancelled objects.
public struct V2ResourceBackgroundAuthorization: Equatable, Codable, Sendable {
    public let id: UUID
    public let sessionID: MediaUploadSessionID
    public let generation: Int64
    public let mediaID: MediaID
    public let partNumber: Int
    public let issuedAtMilliseconds: Int64
    public let expiresAtMilliseconds: Int64
    public var expiresAt: Date { Date(timeIntervalSince1970: Double(expiresAtMilliseconds)/1000) }
    public init(id: UUID, sessionID: MediaUploadSessionID, generation: Int64, mediaID: MediaID,
                partNumber: Int, issuedAt: Date, expiresAt: Date) throws {
        try self.init(id:id,sessionID:sessionID,generation:generation,mediaID:mediaID,partNumber:partNumber,
            issuedAtMilliseconds:V2ResourceTime.milliseconds(issuedAt),expiresAtMilliseconds:V2ResourceTime.milliseconds(expiresAt))
    }
    private init(id:UUID,sessionID:MediaUploadSessionID,generation:Int64,mediaID:MediaID,partNumber:Int,
                 issuedAtMilliseconds:Int64,expiresAtMilliseconds:Int64) throws {
        guard generation>0,(1...32).contains(partNumber),issuedAtMilliseconds>0,
              expiresAtMilliseconds>issuedAtMilliseconds,expiresAtMilliseconds-issuedAtMilliseconds<=900_000
        else { throw V2ResourceValidationError.invalidTransferPlan }
        self.id=id;self.sessionID=sessionID;self.generation=generation;self.mediaID=mediaID;self.partNumber=partNumber
        self.issuedAtMilliseconds=issuedAtMilliseconds;self.expiresAtMilliseconds=expiresAtMilliseconds
    }
    private enum CodingKeys:String,CodingKey { case id,sessionID,generation,mediaID,partNumber,issuedAtMilliseconds,expiresAtMilliseconds }
    public init(from decoder:any Decoder) throws {
        let c=try decoder.container(keyedBy:CodingKeys.self)
        try self.init(id:c.decode(UUID.self,forKey:.id),sessionID:c.decode(MediaUploadSessionID.self,forKey:.sessionID),
            generation:c.decode(Int64.self,forKey:.generation),mediaID:c.decode(MediaID.self,forKey:.mediaID),
            partNumber:c.decode(Int.self,forKey:.partNumber),issuedAtMilliseconds:c.decode(Int64.self,forKey:.issuedAtMilliseconds),
            expiresAtMilliseconds:c.decode(Int64.self,forKey:.expiresAtMilliseconds))
    }
}
