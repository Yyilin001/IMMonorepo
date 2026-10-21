import Foundation
import IMV2ActorContracts

/// A dedicated bootstrap-pinned signer; it has no ordinary service permissions.
public struct V2ActorTrustAdmissionAuthority: Sendable {
    public let deploymentID: UUID
    public let serviceID: V2ActorServiceID
    public init(deploymentID: UUID, serviceID: V2ActorServiceID) {
        self.deploymentID = deploymentID; self.serviceID = serviceID
    }
}

package struct V2ActorTrustAdmission: Codable, Sendable {
    package struct Service: Codable, Sendable {
        package let serviceID: V2ActorServiceID
        package let publicKey: Data
        package let permissions: Set<V2ActorServicePermission>
        package let hostedIDs: Set<V2ActorHostID>
        package let gatewayNodeIDs: Set<String>
        package let sourceIDs: Set<String>

        package init(_ service: V2ActorTrustedService) {
            serviceID = service.serviceID; publicKey = service.publicKey.rawRepresentation
            permissions = service.permissions; hostedIDs = service.hostedIDs; gatewayNodeIDs = service.gatewayNodeIDs; sourceIDs = service.sourceIDs
        }
        package func trustedService() throws -> V2ActorTrustedService {
            try .init(serviceID: serviceID, publicKey: publicKey, permissions: permissions,
                hostedIDs: hostedIDs, gatewayNodeIDs: gatewayNodeIDs, sourceIDs: sourceIDs)
        }
    }
    package let deploymentID: UUID
    package let services: [Service]
    package init(deploymentID: UUID, services: [V2ActorTrustedService]) {
        self.deploymentID = deploymentID; self.services = services.map(Service.init)
    }
}
