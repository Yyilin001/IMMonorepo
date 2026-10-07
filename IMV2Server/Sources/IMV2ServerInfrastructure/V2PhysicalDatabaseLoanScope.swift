import Foundation

/// Scheduling authority installed only by the package's real Sync entry.
/// It is distinct from diagnostic loan-source attribution.
package enum V2PhysicalDatabaseLoanPurpose: Equatable, Sendable { case general, sync }
package enum V2PhysicalDatabaseLoanScope {
    @TaskLocal package static var purpose: V2PhysicalDatabaseLoanPurpose = .general
}
