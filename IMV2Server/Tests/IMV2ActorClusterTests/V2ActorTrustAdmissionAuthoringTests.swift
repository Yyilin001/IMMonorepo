import Crypto
import Foundation
import IMV2ActorContracts
import Testing
@testable import IMV2ActorCluster

@Suite("Deployment trust grant authoring")
struct V2ActorTrustAdmissionAuthoringTests {
    @Test(arguments: ["valid", "changed-key", "removed", "wrong-cluster", "wrong-signer", "duplicate", "empty"])
    func signsOnlyAdditionsAndProductionVerifierAccepts(kind: String) throws {
        let key = Curve25519.Signing.PrivateKey(), newcomerKey = Curve25519.Signing.PrivateKey()
        let deployment = UUID(), host = UUID()
        let authority: [String: Any] = ["id": "authority", "publicKeyBase64": key.publicKey.rawRepresentation.base64EncodedString(),
            "permissions": [], "hostIDs": [], "gatewayNodeIDs": [], "shardIDs": []]
        let newcomer: [String: Any] = ["id": "new-host", "publicKeyBase64": newcomerKey.publicKey.rawRepresentation.base64EncodedString(),
            "permissions": ["realtimePublish", "realtimeReceive", "placementRead", "placementWrite"],
            "hostIDs": [host.uuidString], "gatewayNodeIDs": ["new-host"], "shardIDs": ["rooms-primary"],
            "userBucketIDs": ["users-primary"]]
        let old: [String: Any] = ["placementControl": ["clusterID": deployment.uuidString],
            "trustAdmissionAuthorityServiceID": "authority", "services": [authority]]
        var expanded = old, services = [authority, newcomer]
        var signingKey = key.rawRepresentation
        switch kind {
        case "changed-key": services[0]["publicKeyBase64"] = newcomerKey.publicKey.rawRepresentation.base64EncodedString()
        case "removed": services.removeFirst()
        case "wrong-cluster": expanded["placementControl"] = ["clusterID": UUID().uuidString]
        case "wrong-signer": signingKey = newcomerKey.rawRepresentation
        case "duplicate": services.append(newcomer)
        case "empty": services = [authority]
        default: break
        }
        expanded["services"] = services
        let oldBytes = try JSONSerialization.data(withJSONObject: old)
        let newBytes = try JSONSerialization.data(withJSONObject: expanded)
        if kind != "valid" {
            #expect(throws: (any Error).self) {
                try V2ActorTrustAdmissionAuthoring.create(previous: oldBytes, expanded: newBytes, privateKey: signingKey)
            }
            return
        }
        let bytes = try V2ActorTrustAdmissionAuthoring.create(previous: oldBytes, expanded: newBytes, privateKey: signingKey)
        let authorityID = try V2ActorServiceID("authority")
        let trust = try V2ActorTrustStore(services: [.init(serviceID: authorityID,
            publicKey: key.publicKey.rawRepresentation, permissions: [])],
            admissionAuthority: .init(deploymentID: deployment, serviceID: authorityID))
        let packet = try V2ActorProtobuf.decode(V2ActorSignedPacket.self, from: bytes)
        try trust.admitAuthorizedServices(packet)
        try trust.admitAuthorizedServices(packet)
        let admitted = try trust.configuredService(V2ActorServiceID("new-host"))
        #expect(admitted.sourceIDs == ["rooms-primary", "user:users-primary", "control"])
        #expect(admitted.hostedIDs == [V2ActorHostID(uuid: host)])
        #expect(admitted.gatewayNodeIDs == ["new-host"])
    }
}
