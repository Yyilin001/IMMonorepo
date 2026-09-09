import Foundation

/// Subscription reconciliation inherits this scope through domain-transport
/// actors. The wire checks it when registering the request, so an old cleanup
/// cannot accidentally send an unsubscribe on a replacement connection.
enum V2ConnectionRequestScope {
    @TaskLocal static var connectionID: UUID?
}
