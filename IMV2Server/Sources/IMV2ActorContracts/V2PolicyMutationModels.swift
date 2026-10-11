import Foundation
import IMV2Core

public struct V2PolicyAccountDisableCommandWire: Codable, Equatable, Sendable {
    public let userID: UUID
    public let operationID: UUID
    public let reason: String
    public let operatorPrincipal: String
    public init(userID: UUID, operationID: UUID, reason: String, operatorPrincipal: String) {
        self.userID = userID; self.operationID = operationID; self.reason = reason; self.operatorPrincipal = operatorPrincipal
    }
}
public enum V2PolicyMutationCommand: Codable, Equatable, Sendable {
    case social(V2SocialOperationCommand)
    case strangerPreference(V2AccountPreferenceCommand)
    case disable(V2PolicyAccountDisableCommandWire)
}
public enum V2PolicyMutationResult: Codable, Equatable, Sendable {
    case social(V2SocialOperationRecoveryResult)
    case preference(V2AccountPreferenceRecoveryResult)
    case disable(V2PolicyAccountDisableReceipt)
}
public struct V2PolicyAccountDisableReceipt: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case disabled, idempotent, alreadyDisabled }
    public let kind: Kind
    public let disabledAt: Date
    public init(kind: Kind, disabledAt: Date) { self.kind = kind; self.disabledAt = disabledAt }
}
