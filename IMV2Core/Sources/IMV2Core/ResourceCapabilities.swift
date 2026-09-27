import Foundation

public enum V2ResourceCapabilityUsage:String,Codable,Sendable {
    case messageAttachment,userAvatar,groupAvatar
}
/// Capabilities describe the deployed adapter/policy intersection, not every protocol enum case.
public struct V2ResourceCapabilities:Codable,Equatable,Sendable {
    public let version:Int
    public let uploadModes:[V2ResourceTransferMode]
    public let maximumBytes:Int64
    public let allowedUsages:[V2ResourceCapabilityUsage]
    public let maximumParts:Int
    public let backgroundTransfer:Bool
    public init(version:Int=1,uploadModes:[V2ResourceTransferMode],maximumBytes:Int64,
                allowedUsages:[V2ResourceCapabilityUsage],maximumParts:Int,backgroundTransfer:Bool) throws {
        guard version==1,!uploadModes.isEmpty,uploadModes.allSatisfy(\.isUpload),Set(uploadModes).count==uploadModes.count,
              maximumBytes>0,!allowedUsages.isEmpty,Set(allowedUsages).count==allowedUsages.count,
              (0...10_000).contains(maximumParts),maximumParts==0 || uploadModes.contains(.httpPartPut)
        else {throw V2ResourceValidationError.invalidUploadRequest}
        self.version=version;self.uploadModes=uploadModes;self.maximumBytes=maximumBytes
        self.allowedUsages=allowedUsages;self.maximumParts=maximumParts;self.backgroundTransfer=backgroundTransfer
    }
    private enum CodingKeys:String,CodingKey {case version,uploadModes,maximumBytes,allowedUsages,maximumParts,backgroundTransfer}
    public init(from decoder:any Decoder) throws {
        let values=try decoder.container(keyedBy:CodingKeys.self)
        try self.init(version:values.decode(Int.self,forKey:.version),uploadModes:values.decode([V2ResourceTransferMode].self,forKey:.uploadModes),
            maximumBytes:values.decode(Int64.self,forKey:.maximumBytes),allowedUsages:values.decode([V2ResourceCapabilityUsage].self,forKey:.allowedUsages),
            maximumParts:values.decode(Int.self,forKey:.maximumParts),backgroundTransfer:values.decode(Bool.self,forKey:.backgroundTransfer))
    }
}
