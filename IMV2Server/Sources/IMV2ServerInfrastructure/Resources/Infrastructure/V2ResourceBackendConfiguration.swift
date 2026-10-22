import IMV2ServerApplication
import IMV2ServerContracts
import Foundation

/// Provider selection belongs to composition. Persisted sessions pin id + revision.
public struct V2ResourceBackendConfiguration:Sendable {
    public enum Kind: String, Codable, Sendable { case local, oss }
    public struct OSS: Codable, Sendable {
        public let bucket: String
        public let region: String
        public let endpoint: URL
        public let prefix: String
        public let credentialEnvironmentPrefix: String?
    }
    public struct Entry:Codable,Sendable {
        public let id:String
        public let revision:Int
        public let directory:String?
        public var kind: Kind? = nil
        public var oss: OSS? = nil
        public var providerKind: Kind { kind ?? .local }
        public var binding:V2StorageBinding { get throws {try .init(id:id,configurationRevision:revision)} }
    }
    public let entries:[Entry]
    public let defaultBinding:V2StorageBinding
    public init(environment:any V2RuntimeEnvironment,defaultDirectory:URL) throws {
        if let encoded=environment.value(for:"IM_V2_RESOURCE_STORAGE_BINDINGS_JSON") {
            guard encoded.utf8.count<=16_384,let data=encoded.data(using:.utf8) else {throw V2ResourceProviderError.configurationInvalid}
            entries=try JSONDecoder().decode([Entry].self,from:data)
        } else {entries=[.init(id:"local-filesystem",revision:1,directory:defaultDirectory.path)]}
        guard !entries.isEmpty,entries.count<=8,entries.allSatisfy({entry in
            !entry.id.isEmpty && entry.id.utf8.count<=64 && entry.id.utf8.allSatisfy({(48...57).contains($0)||(65...90).contains($0)||(97...122).contains($0)||$0==45||$0==95}) && entry.revision>0
        }),Set(entries.map {"\($0.id):\($0.revision)"}).count==entries.count else {throw V2ResourceProviderError.configurationInvalid}
        for entry in entries {
            switch entry.providerKind {
            case .local:
                guard entry.directory?.hasPrefix("/") == true, entry.oss == nil else { throw V2ResourceProviderError.configurationInvalid }
            case .oss:
                guard entry.directory == nil, let oss = entry.oss else { throw V2ResourceProviderError.configurationInvalid }
                _ = try V2OSSConfiguration(bucket: oss.bucket, region: oss.region, endpoint: oss.endpoint,
                    prefix: oss.prefix, binding: entry.binding)
                if let prefix = oss.credentialEnvironmentPrefix {
                    guard !prefix.isEmpty, prefix.utf8.allSatisfy({ (65...90).contains($0) || (48...57).contains($0) || $0 == 95 }) else {
                        throw V2ResourceProviderError.configurationInvalid
                    }
                }
            }
        }
        let defaultID=environment.value(for:"IM_V2_RESOURCE_DEFAULT_BINDING") ?? entries[0].id
        let defaultRevision:Int
        if let configured=environment.value(for:"IM_V2_RESOURCE_DEFAULT_REVISION") {
            guard let revision=Int(configured),revision>0 else {throw V2ResourceProviderError.configurationInvalid}
            defaultRevision=revision
        } else if environment.value(for:"IM_V2_RESOURCE_DEFAULT_BINDING") != nil {
            let matches=entries.filter {$0.id==defaultID}
            guard matches.count==1 else {throw V2ResourceProviderError.configurationInvalid}
            defaultRevision=matches[0].revision
        } else {defaultRevision=entries[0].revision}
        defaultBinding=try .init(id:defaultID,configurationRevision:defaultRevision)
        guard try entries.contains(where:{try $0.binding==defaultBinding}) else {throw V2ResourceProviderError.configurationInvalid}
    }
}
