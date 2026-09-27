import Foundation

/// Local adapters can coexist during a backend change. Every persisted session pins id + revision.
public struct V2ResourceBackendConfiguration:Sendable {
    public struct Entry:Codable,Sendable {
        public let id:String
        public let revision:Int
        public let directory:String
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
            !entry.id.isEmpty && entry.id.utf8.count<=64 && entry.id.utf8.allSatisfy({(48...57).contains($0)||(65...90).contains($0)||(97...122).contains($0)||$0==45||$0==95}) && entry.revision>0 && entry.directory.hasPrefix("/")
        }),Set(entries.map {"\($0.id):\($0.revision)"}).count==entries.count else {throw V2ResourceProviderError.configurationInvalid}
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
