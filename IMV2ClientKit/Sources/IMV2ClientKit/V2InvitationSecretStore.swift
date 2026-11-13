import Foundation
import IMV2Core

public enum V2InvitationSecretStoreError:Error,Equatable,Sendable { case unavailable,locked,missing,invalidReference,invalidSecret }
public protocol V2InvitationSecretStoring:Sendable {
    func save(_ authorization:V2GroupInvitationSecretAuthorization,reference:UUID,accountID:UserID) throws
    func load(reference:UUID,accountID:UserID) throws -> V2GroupInvitationSecretAuthorization
    func remove(reference:UUID,accountID:UserID) throws
}
