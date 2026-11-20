import Foundation
import IMV2Core
import IMV2ClientRuntime

/// Account-wide profile authority/cache; each window retains its own repository activation.
/// Names and own-profile updates share the account lifetime and existing durable command identities.
public actor V2ProfileService {
    public nonisolated let accountID: UserID
    public nonisolated let presentations: V2ProfilePresentationRepository
    public nonisolated let projections: V2ProfileRepository
    public nonisolated let names: V2ProfileNameService
    private let lifetime = V2DirectoryLifetime()
    private var own: V2OwnProfileService?
    private var closed = false
    public init(accountID: UserID, store: GRDBV2LocalSyncStore, presentations: V2ProfilePresentationRepository, names: V2NameOperationService) {
        self.accountID = accountID; self.presentations = presentations
        projections = .init(store: store, reader: V2ProfileProjectionReader(presentations: presentations))
        self.names = .init(service: names, lifetime: lifetime)
    }
    /// Composition entry: installs the account's own-profile command dependency once.
    public func ownProfile(using service: V2ProfileIntentService) throws -> V2OwnProfileService {
        guard !closed else { throw V2DirectoryServiceError.closed }
        if let own { return own }
        let result = V2OwnProfileService(service: service, lifetime: lifetime); own = result
        return result
    }
    /// Retrieves the own-profile service installed by the platform composition.
    public func ownProfile() throws -> V2OwnProfileService {
        guard !closed else { throw V2DirectoryServiceError.closed }
        guard let own else { throw V2DirectoryServiceError.invalidInput }
        return own
    }
    public func close() async {
        closed = true
        await lifetime.close()
        await projections.close()
        await presentations.close()
    }
}
