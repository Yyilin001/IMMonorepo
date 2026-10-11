import Foundation
import IMV2ActorContracts
import IMV2ServerApplication

/// Committed policy data. Versions advance with facts in the same transaction;
/// ownership leases are deliberately absent from this read model.
package struct V2PolicyFactsSnapshot: Equatable, Sendable {
    package let scope: V2PolicyAuthorizationScope
    package let version: Int64
    package let facts: V2PolicyOwnerFacts

    package init(scope: V2PolicyAuthorizationScope, version: Int64, facts: V2PolicyOwnerFacts) throws {
        guard scope.isValid, version > 0 else { throw V2PolicyAuthorizationLifecycleError.invalidTarget }
        switch (scope, facts) {
        case (.account(let user), .account(let account)) where user == account.userID: break
        case (.stranger(let user), .stranger(let setting)) where user == setting.userID: break
        case (.pair, .pair): break
        default: throw V2PolicyAuthorizationLifecycleError.invalidTarget
        }
        self.scope = try scope.policyWire.policyScope; self.version = version; self.facts = facts
    }
    package init(wire: V2PolicySnapshotWire) throws {
        try self.init(scope: wire.scope.policyScope, version: wire.version,
            facts: wire.facts)
    }
    package var wire: V2PolicySnapshotWire {
        get throws { try .init(scope: scope.policyWire, version: version, facts: facts) }
    }
}
