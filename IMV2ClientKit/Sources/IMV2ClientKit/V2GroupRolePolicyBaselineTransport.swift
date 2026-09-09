import IMV2Core

/// Retrieves a complete current policy observation through an authenticated
/// connection. Applying it requires the local account, membership and version
/// fences; fetching alone does not modify any projection or recovery intent.
public protocol V2ClientGroupRolePolicyBaselineTransport: Sendable {
    func fetchRolePolicyBaseline(roomID: RoomID) async throws -> V2GroupRolePolicyBaseline
}
