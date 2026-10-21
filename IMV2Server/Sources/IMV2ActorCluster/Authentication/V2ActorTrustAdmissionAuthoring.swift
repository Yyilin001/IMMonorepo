import Foundation
import IMV2ActorContracts

/// Deployment-side authoring. The resulting packet still passes the production
/// verifier before it can be exported; it grants no membership or ownership.
package enum V2ActorTrustAdmissionAuthoring {
    private struct Configuration: Decodable {
        struct Control: Decodable { let clusterID: UUID }
        struct Service: Decodable, Equatable {
            let id: String
            let publicKeyBase64: String
            let permissions: [V2ActorServicePermission]
            let hostIDs: [UUID]
            let shardIDs: [String]
            let userBucketIDs: [String]?
            let gatewayNodeIDs: [String]?

            func trusted() throws -> V2ActorTrustedService {
                let buckets = userBucketIDs ?? [], gateways = gatewayNodeIDs ?? []
                guard let key = Data(base64Encoded: publicKeyBase64), key.count == 32,
                      Set(permissions).count == permissions.count,
                      Set(hostIDs).count == hostIDs.count,
                      Set(shardIDs).count == shardIDs.count, shardIDs.count <= 256,
                      Set(buckets).count == buckets.count, buckets.count <= 256,
                      buckets.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 128 && !$0.contains(":") }),
                      Set(gateways).count == gateways.count else {
                    throw V2ActorAuthenticationError.invalidConfiguration
                }
                var sources = Set(shardIDs).union(buckets.map { "user:" + $0 })
                if !buckets.isEmpty, !gateways.isEmpty, permissions.contains(.realtimePublish) {
                    sources.insert("control")
                }
                return try .init(serviceID: V2ActorServiceID(id), publicKey: key,
                    permissions: Set(permissions), hostedIDs: Set(hostIDs.map { V2ActorHostID(uuid: $0) }),
                    gatewayNodeIDs: Set(gateways), sourceIDs: sources)
            }
        }
        let placementControl: Control
        let trustAdmissionAuthorityServiceID: String
        let services: [Service]
    }

    package static func create(previous: Data, expanded: Data, privateKey: Data) throws -> Data {
        guard previous.count <= 4_194_304, expanded.count <= 4_194_304 else {
            throw V2ActorAuthenticationError.oversized
        }
        let decoder = JSONDecoder()
        let old = try decoder.decode(Configuration.self, from: previous)
        let new = try decoder.decode(Configuration.self, from: expanded)
        guard old.placementControl.clusterID == new.placementControl.clusterID,
              old.trustAdmissionAuthorityServiceID == new.trustAdmissionAuthorityServiceID,
              Set(old.services.map(\.id)).count == old.services.count,
              Set(new.services.map(\.id)).count == new.services.count else {
            throw V2ActorAuthenticationError.invalidConfiguration
        }
        let newByID = Dictionary(uniqueKeysWithValues: new.services.map { ($0.id, $0) })
        // Refuse removal or any rewrite, rather than silently signing only the
        // additions from a deployment that also changes established identities.
        guard old.services.allSatisfy({ newByID[$0.id] == $0 }) else {
            throw V2ActorAuthenticationError.forbidden
        }
        let oldIDs = Set(old.services.map(\.id))
        let additions = try new.services.filter { !oldIDs.contains($0.id) }.map { try $0.trusted() }
        let authority = try V2ActorServiceID(old.trustAdmissionAuthorityServiceID)
        let trust = try V2ActorTrustStore(services: old.services.map { try $0.trusted() },
            admissionAuthority: .init(deploymentID: old.placementControl.clusterID, serviceID: authority))
        let signer = try V2ActorSigningIdentity(serviceID: authority, privateKey: privateKey)
        let packet = try signer.sign(V2ActorTrustAdmission(deploymentID: old.placementControl.clusterID,
            services: additions), maximumBytes: 262_144)
        try trust.admitAuthorizedServices(packet)
        return try V2ActorProtobuf.encode(packet)
    }
}
