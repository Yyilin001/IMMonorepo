import IMV2ServerApplication
import IMV2ServerContracts
import Crypto
import Foundation
import IMV2ActorCluster
import IMV2ActorContracts
import IMV2Server
import IMV2ServerInfrastructure
import NIOSSL

public enum V2RoomActorApplicationConfigurationError: Error, Equatable, Sendable {
    case missingConfiguration
    case invalidConfiguration
}

/// 进程本地身份和明确的部署信任映射。
/// 发现结果不得扩展已配置的服务、Host 或数据库分片集合。
public struct V2RoomActorApplicationConfiguration: Sendable {
    public let name: String
    public let address: String
    public let port: Int
    public let threadPoolSize: Int
    public let hostIdentity: V2ActorHostIdentity?
    public let signer: V2ActorSigningIdentity
    public let trust: V2ActorTrustStore
    public let tls: TLSConfiguration
    public let discovery: V2RoomDiscoveryConfiguration
    public let allowedShards: Set<String>
    public let serviceShardAccess: [V2ActorServiceID: Set<String>]
    public let runtime: V2RoomRuntimeConfiguration
    public let authentication: V2ActorAuthenticationLimits

    /// 必需的 JSON 文件引用 PEM 文件及包含 32 字节原始数据的签名密钥文件。
    /// 密钥材料和部署文档均不得写入日志。
    /// Host 的收集窗口覆盖配置的发送和回执延迟；
    /// 各批处理器仍使用自身较短或自适应的延迟。
    /// 角色为 nil 时，Gateway 根据已验证的部署文档选择 Host 或调用方模式；
    /// 仅作为调用方的应用传入 false。
    public init(environment: any V2RuntimeEnvironment, hostsRooms: Bool?,
                configuredShardIDs: Set<String>, batchWaitMilliseconds: Int64 = 2) throws {
        guard let path = environment.value(for: "IMV2_ROOM_ACTOR_CONFIGURATION_FILE"),
              !path.isEmpty else { throw V2RoomActorApplicationConfigurationError.missingConfiguration }
        let bytes = try Self.readFile(path, maximumBytes: 1_048_576)
        try self.init(document: JSONDecoder().decode(Document.self, from: bytes),
                      hostsRooms: hostsRooms, configuredShardIDs: configuredShardIDs,
                      batchWaitMilliseconds: batchWaitMilliseconds)
    }

    init(document: Document, hostsRooms: Bool?, configuredShardIDs: Set<String>,
         batchWaitMilliseconds: Int64 = 2) throws {
        guard !document.name.isEmpty, document.name.utf8.count <= 128,
              Self.isDNSName(document.address),
              (1...65_535).contains(document.port), (1...64).contains(document.threadPoolSize),
              !configuredShardIDs.isEmpty, configuredShardIDs.count <= 256,
              (1...256).contains(document.services.count), (1...256).contains(document.peers.count),
              (hostsRooms == nil || hostsRooms == (document.hostID != nil)), (1...25).contains(batchWaitMilliseconds) else {
            throw V2RoomActorApplicationConfigurationError.invalidConfiguration
        }
        let signingID = try V2ActorServiceID(document.serviceID)
        let key = try Self.readFile(document.signingKeyPath, maximumBytes: 32)
        let privateKey = try Curve25519.Signing.PrivateKey(rawRepresentation: key)
        var trusted: [V2ActorTrustedService] = []
        var access: [V2ActorServiceID: Set<String>] = [:]
        var keys: [V2ActorServiceID: Data] = [:]
        var pinnedHosts: [V2ActorHostID: V2ActorServiceID] = [:]
        for service in document.services {
            let id = try V2ActorServiceID(service.id)
            guard keys[id] == nil, let publicKey = Data(base64Encoded: service.publicKeyBase64),
                  publicKey.count == 32, service.hostIDs.count <= 256,
                  service.shardIDs.count <= 256 else {
                throw V2RoomActorApplicationConfigurationError.invalidConfiguration
            }
            let shards = Set(service.shardIDs)
            guard !shards.isEmpty, shards.count == service.shardIDs.count,
                  shards.isSubset(of: configuredShardIDs) else {
                throw V2RoomActorApplicationConfigurationError.invalidConfiguration
            }
            let hosts = Set(service.hostIDs.map { V2ActorHostID(uuid: $0) })
            guard hosts.count == service.hostIDs.count else {
                throw V2RoomActorApplicationConfigurationError.invalidConfiguration
            }
            for host in hosts {
                guard pinnedHosts.updateValue(id, forKey: host) == nil else {
                    throw V2RoomActorApplicationConfigurationError.invalidConfiguration
                }
            }
            trusted.append(try .init(serviceID: id, publicKey: publicKey,
                permissions: Set(service.permissions), hostedIDs: hosts))
            access[id] = shards
            keys[id] = publicKey
        }
        guard keys[signingID] == privateKey.publicKey.rawRepresentation else {
            throw V2RoomActorApplicationConfigurationError.invalidConfiguration
        }
        let identity = document.hostID.map { V2ActorHostIdentity(hostID: .init(uuid: $0), incarnationID: UUID()) }
        if let identity, pinnedHosts[identity.hostID] != signingID {
            throw V2RoomActorApplicationConfigurationError.invalidConfiguration
        }
        let runtime = try V2RoomRuntimeConfiguration(batchWaitMilliseconds: batchWaitMilliseconds)
        var peers: [V2RoomDiscoveryPeer] = []
        var seenHosts = Set<V2ActorHostID>()
        for peer in document.peers {
            let host = V2ActorHostID(uuid: peer.hostID)
            let service = try V2ActorServiceID(peer.serviceID)
            let shards = Set(peer.shardIDs)
            guard Self.isDNSName(peer.address), seenHosts.insert(host).inserted, pinnedHosts[host] == service,
                  !shards.isEmpty, shards.count == peer.shardIDs.count,
                  shards.isSubset(of: configuredShardIDs) else {
                throw V2RoomActorApplicationConfigurationError.invalidConfiguration
            }
            peers.append(try .init(hostID: host, serviceID: service, address: peer.address,
                port: peer.port, accessibleShardIDs: shards, maximumRooms: peer.maximumRooms))
        }
        let allowed: Set<String>
        if let identity {
            guard let own = document.peers.first(where: { $0.hostID == identity.hostID.uuidValue }),
                  own.address == document.address, own.port == document.port,
                  own.maximumRooms >= runtime.maximumActiveRooms else {
                throw V2RoomActorApplicationConfigurationError.invalidConfiguration
            }
            allowed = Set(own.shardIDs)
        } else { allowed = [] }
        guard Set(document.peers.flatMap(\.shardIDs)) == configuredShardIDs else {
            throw V2RoomActorApplicationConfigurationError.invalidConfiguration
        }
        let chain = try NIOSSLCertificate.fromPEMFile(document.certificatePath)
        guard !chain.isEmpty else { throw V2RoomActorApplicationConfigurationError.invalidConfiguration }
        var tls = TLSConfiguration.makeServerConfiguration(certificateChain: chain.map { .certificate($0) },
            privateKey: .privateKey(try NIOSSLPrivateKey(file: document.privateKeyPath, format: .pem)))
        tls.minimumTLSVersion = .tlsv13
        tls.maximumTLSVersion = .tlsv13
        tls.certificateVerification = .fullVerification
        tls.trustRoots = .certificates(try NIOSSLCertificate.fromPEMFile(document.trustRootPath))
        self.name = document.name; self.address = document.address; self.port = document.port
        self.threadPoolSize = document.threadPoolSize; self.hostIdentity = identity
        self.signer = try .init(serviceID: signingID, privateKey: key)
        self.trust = try .init(services: trusted); self.tls = tls
        self.discovery = try .init(peers: peers)
        self.allowedShards = allowed
        self.serviceShardAccess = identity != nil ? access.compactMapValues {
            let shared = $0.intersection(allowed)
            return shared.isEmpty ? nil : shared
        } : [:]
        self.runtime = runtime
        self.authentication = try .init(maximumRequestBytes: runtime.maximumRequestBytes)
    }

    /// DistributedCluster 将对端地址作为 SNI 发送。NIOSSL 不接受该字段中的
    /// IP 字面量，因此在创建活动传输前予以拒绝。
    private static func isDNSName(_ address: String) -> Bool {
        guard (1...253).contains(address.utf8.count),
              address.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) ||
                  (48...57).contains($0) || $0 == 45 || $0 == 46 }) else { return false }
        let labels = address.split(separator: ".", omittingEmptySubsequences: false)
        return !labels.allSatisfy { Int($0) != nil } && labels.allSatisfy {
            (1...63).contains($0.utf8.count) && $0.first != "-" && $0.last != "-"
        }
    }

    private static func readFile(_ path: String, maximumBytes: Int) throws -> Data {
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        guard let size = attributes[.size] as? NSNumber, size.intValue > 0,
              size.intValue <= maximumBytes else {
            throw V2RoomActorApplicationConfigurationError.invalidConfiguration
        }
        let bytes = try Data(contentsOf: URL(fileURLWithPath: path))
        guard !bytes.isEmpty, bytes.count <= maximumBytes else {
            throw V2RoomActorApplicationConfigurationError.invalidConfiguration
        }
        return bytes
    }

    struct Document: Decodable, Sendable {
        let name: String
        let address: String
        let port: Int
        let threadPoolSize: Int
        let serviceID: String
        let hostID: UUID?
        let signingKeyPath: String
        let certificatePath: String
        let privateKeyPath: String
        let trustRootPath: String
        let services: [Service]
        let peers: [Peer]
        struct Service: Decodable, Sendable {
            let id: String
            let publicKeyBase64: String
            let permissions: [V2ActorServicePermission]
            let hostIDs: [UUID]
            let shardIDs: [String]
        }
        struct Peer: Decodable, Sendable {
            let hostID: UUID
            let serviceID: String
            let address: String
            let port: Int
            let shardIDs: [String]
            let maximumRooms: Int
        }
    }
}
