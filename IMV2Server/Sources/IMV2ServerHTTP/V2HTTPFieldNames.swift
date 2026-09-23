import Vapor
import HTTPTypes

extension HTTPField.Name {
    static let v2Pragma = Self("Pragma")!
    static let v2DeviceID = Self("X-IM-Device-ID")!
    static let v2AccountEdgeAuthorization = Self("X-IM-V2-Account-Edge-Authorization")!
    static let v2AccountClientAddress = Self("X-IM-V2-Account-Client-Address")!
}
