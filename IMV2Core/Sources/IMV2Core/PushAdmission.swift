import Foundation

public struct V2PushCampaignID: Hashable, Codable, Sendable {
    public let rawValue: String
    public init(rawValue: String) throws {
        guard !rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw V2CoreError.invalidIdentifier }
        self.rawValue = rawValue
    }
}

public struct V2PushDeviceBudget: Equatable, Sendable {
    public let maxWorkUnits: Int
    public let usedWorkUnits: Int
    public let maxNewKeyOperations: Int
    public let usedNewKeyOperations: Int

    public init(maxWorkUnits: Int, usedWorkUnits: Int = 0, maxNewKeyOperations: Int, usedNewKeyOperations: Int = 0) throws {
        guard maxWorkUnits >= 0, usedWorkUnits >= 0, maxNewKeyOperations >= 0, usedNewKeyOperations >= 0 else { throw V2CoreError.invalidNonNegativeValue }
        self.maxWorkUnits = maxWorkUnits
        self.usedWorkUnits = usedWorkUnits
        self.maxNewKeyOperations = maxNewKeyOperations
        self.usedNewKeyOperations = usedNewKeyOperations
    }
}

public struct V2PushAdmissionRequest: Equatable, Sendable {
    public let campaignID: V2PushCampaignID
    public let requiresNewKeyOperation: Bool

    public init(campaignID: V2PushCampaignID, requiresNewKeyOperation: Bool) {
        self.campaignID = campaignID
        self.requiresNewKeyOperation = requiresNewKeyOperation
    }
}

public enum V2PushSuppressionReason: Equatable, Sendable {
    case campaignDisabled
    case deviceBudgetUnavailable
    case deviceWorkBudgetExhausted
    case deviceNewKeyBudgetExhausted
    /// The device has no current provider endpoint. This is terminal for the
    /// current generic wake, not a reason to retry durable room delivery.
    case endpointUnavailable
    /// The provider proved that the registered endpoint can no longer receive
    /// wakes. The endpoint is disabled before this suppression is recorded.
    case endpointRejected
}

public enum V2PushAdmission: Equatable, Sendable {
    case allowed(nextBudget: V2PushDeviceBudget)
    case suppressed(V2PushSuppressionReason)
}

/// Evaluated before any encryption-key lookup or provider request. This
/// deliberately carries no message text, sender identity, room metadata, or
/// synchronization payload: Push is a generic wake-up hint only.
public enum V2PushAdmissionEvaluator {
    public static func evaluate(
        campaignEnabled: Bool,
        request: V2PushAdmissionRequest,
        budget: V2PushDeviceBudget
    ) throws -> V2PushAdmission {
        guard campaignEnabled else { return .suppressed(.campaignDisabled) }
        guard budget.usedWorkUnits < budget.maxWorkUnits else { return .suppressed(.deviceWorkBudgetExhausted) }
        guard !request.requiresNewKeyOperation || budget.usedNewKeyOperations < budget.maxNewKeyOperations else {
            return .suppressed(.deviceNewKeyBudgetExhausted)
        }
        return .allowed(nextBudget: try V2PushDeviceBudget(
            maxWorkUnits: budget.maxWorkUnits,
            usedWorkUnits: budget.usedWorkUnits + 1,
            maxNewKeyOperations: budget.maxNewKeyOperations,
            usedNewKeyOperations: budget.usedNewKeyOperations + (request.requiresNewKeyOperation ? 1 : 0)
        ))
    }
}
