import Foundation

public enum V2ResourceFileProtection:String,Sendable {
    case complete="NSFileProtectionComplete"
    case untilFirstAuthentication="NSFileProtectionCompleteUntilFirstUserAuthentication"
}
public protocol V2ResourceFileProtectionWriting:Sendable {
    func apply(_ protection:V2ResourceFileProtection,to file:URL) throws
}
public struct V2SystemResourceFileProtectionWriter:V2ResourceFileProtectionWriting {
    public init() {}
    public func apply(_ protection:V2ResourceFileProtection,to file:URL) throws {
        #if os(iOS) || os(tvOS) || os(watchOS)
        // NSFileProtectionKey accepts an NSString value (Foundation contract).
        try FileManager.default.setAttributes([.protectionKey:protection.rawValue],ofItemAtPath:file.path)
        #endif
    }
}
