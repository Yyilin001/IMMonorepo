import Foundation

/// Only bounded Sync BUSY retries install this scope. A local deadline never
/// proves a dispatched server transaction has settled.
enum V2SyncRequestScope {
    @TaskLocal static var deadline: ContinuousClock.Instant?
}
