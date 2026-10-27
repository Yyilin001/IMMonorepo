import Foundation

/// A newly delegated, narrow PUT authority. It is not a room activation or a presentation lease.
/// The native provider signs this grant into its exact object capability and fences cancelled objects.
public struct V2ResourceBackgroundAuthorization: Equatable, Codable, Sendable {
    public enum Scope: Equatable, Codable, Sendable {
        case part(number: Int)
        case whole(byteCount: Int64, checksum: V2ResourceChecksum)
    }
    public let id: UUID
    public let sessionID: MediaUploadSessionID
    public let generation: Int64
    public let mediaID: MediaID
    public let scope: Scope
    public var partNumber: Int? { if case .part(let number) = scope { number } else { nil } }
    public let issuedAtMilliseconds: Int64
    public let expiresAtMilliseconds: Int64
    public var expiresAt: Date { Date(timeIntervalSince1970: Double(expiresAtMilliseconds)/1000) }
    public init(id: UUID, sessionID: MediaUploadSessionID, generation: Int64, mediaID: MediaID,
                partNumber: Int, issuedAt: Date, expiresAt: Date) throws {
        try self.init(id:id,sessionID:sessionID,generation:generation,mediaID:mediaID,scope:.part(number: partNumber),
            issuedAtMilliseconds:V2ResourceTime.milliseconds(issuedAt),expiresAtMilliseconds:V2ResourceTime.milliseconds(expiresAt))
    }
    public init(id: UUID, sessionID: MediaUploadSessionID, generation: Int64, mediaID: MediaID,
                scope: Scope, issuedAt: Date, expiresAt: Date) throws {
        try self.init(id: id, sessionID: sessionID, generation: generation, mediaID: mediaID, scope: scope,
            issuedAtMilliseconds: V2ResourceTime.milliseconds(issuedAt), expiresAtMilliseconds: V2ResourceTime.milliseconds(expiresAt))
    }
    private init(id:UUID,sessionID:MediaUploadSessionID,generation:Int64,mediaID:MediaID,scope:Scope,
                 issuedAtMilliseconds:Int64,expiresAtMilliseconds:Int64) throws {
        switch scope {
        case .part(let number): guard (1...32).contains(number) else { throw V2ResourceValidationError.invalidTransferPlan }
        case .whole(let bytes, _): guard bytes > 0, bytes <= 256 * 1_024 * 1_024 else { throw V2ResourceValidationError.invalidTransferPlan }
        }
        guard generation>0,issuedAtMilliseconds>0,
              expiresAtMilliseconds>issuedAtMilliseconds,expiresAtMilliseconds-issuedAtMilliseconds<=900_000
        else { throw V2ResourceValidationError.invalidTransferPlan }
        self.id=id;self.sessionID=sessionID;self.generation=generation;self.mediaID=mediaID;self.scope=scope
        self.issuedAtMilliseconds=issuedAtMilliseconds;self.expiresAtMilliseconds=expiresAtMilliseconds
    }
    private enum CodingKeys:String,CodingKey { case id,sessionID,generation,mediaID,scope,issuedAtMilliseconds,expiresAtMilliseconds }
    public init(from decoder:any Decoder) throws {
        let c=try decoder.container(keyedBy:CodingKeys.self)
        try self.init(id:c.decode(UUID.self,forKey:.id),sessionID:c.decode(MediaUploadSessionID.self,forKey:.sessionID),
            generation:c.decode(Int64.self,forKey:.generation),mediaID:c.decode(MediaID.self,forKey:.mediaID),
            scope:c.decode(Scope.self,forKey:.scope),issuedAtMilliseconds:c.decode(Int64.self,forKey:.issuedAtMilliseconds),
            expiresAtMilliseconds:c.decode(Int64.self,forKey:.expiresAtMilliseconds))
    }
}
