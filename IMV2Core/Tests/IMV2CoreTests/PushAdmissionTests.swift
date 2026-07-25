import Testing
@testable import IMV2Core

struct PushAdmissionTests {
    @Test("campaign gate suppresses before any device budget is consumed")
    func campaignGateSuppresses() throws {
        let budget = try V2PushDeviceBudget(maxWorkUnits: 2, maxNewKeyOperations: 1)
        let admission = try V2PushAdmissionEvaluator.evaluate(
            campaignEnabled: false,
            request: .init(campaignID: try .init(rawValue: "wake"), requiresNewKeyOperation: true),
            budget: budget
        )
        #expect(admission == .suppressed(.campaignDisabled))
    }

    @Test("new-key budget is independent from generic wake work budget")
    func newKeyBudgetIsSeparate() throws {
        let budget = try V2PushDeviceBudget(maxWorkUnits: 3, usedWorkUnits: 1, maxNewKeyOperations: 1, usedNewKeyOperations: 1)
        let generic = try V2PushAdmissionEvaluator.evaluate(campaignEnabled: true, request: .init(campaignID: try .init(rawValue: "wake"), requiresNewKeyOperation: false), budget: budget)
        let newKey = try V2PushAdmissionEvaluator.evaluate(campaignEnabled: true, request: .init(campaignID: try .init(rawValue: "wake"), requiresNewKeyOperation: true), budget: budget)
        #expect(generic == .allowed(nextBudget: try .init(maxWorkUnits: 3, usedWorkUnits: 2, maxNewKeyOperations: 1, usedNewKeyOperations: 1)))
        #expect(newKey == .suppressed(.deviceNewKeyBudgetExhausted))
    }
}
