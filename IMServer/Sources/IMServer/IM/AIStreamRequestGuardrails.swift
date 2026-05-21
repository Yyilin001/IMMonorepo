import Vapor

struct AIStreamGuardrailConfiguration: Sendable {
    var maxPromptCharacters: Int
    var maxEstimatedCostUnits: Int
    var blockedPromptTerms: [String]

    static let productionDefault = AIStreamGuardrailConfiguration(
        maxPromptCharacters: 4_000,
        maxEstimatedCostUnits: 24_000,
        blockedPromptTerms: []
    )
}

struct AIStreamRequestGuardrails {
    let app: Application

    func validateStart(
        prompt: String,
        conversationID: UUID,
        userID: UUID
    ) throws {
        let configuration = app.aiStreamGuardrailConfiguration
        guard prompt.count <= configuration.maxPromptCharacters else {
            throw Abort(.payloadTooLarge, reason: "AI prompt is too large.")
        }

        let normalizedPrompt = prompt.lowercased()
        if configuration.blockedPromptTerms.contains(where: { term in
            !term.isEmpty && normalizedPrompt.contains(term.lowercased())
        }) {
            app.logger.warning(
                "AI stream prompt rejected by content guardrail",
                metadata: [
                    "conversationID": .string(conversationID.uuidString),
                    "userID": .string(userID.uuidString)
                ]
            )
            throw Abort(.badRequest, reason: "AI prompt failed content safety checks.")
        }

        let estimatedCostUnits = prompt.count + AIStreamProviderRunner.maxFinalTextLength
        guard estimatedCostUnits <= configuration.maxEstimatedCostUnits else {
            app.logger.warning(
                "AI stream prompt rejected by cost guardrail",
                metadata: [
                    "conversationID": .string(conversationID.uuidString),
                    "userID": .string(userID.uuidString),
                    "estimatedCostUnits": .stringConvertible(estimatedCostUnits),
                    "maxEstimatedCostUnits": .stringConvertible(configuration.maxEstimatedCostUnits)
                ]
            )
            throw Abort(.paymentRequired, reason: "AI stream cost limit exceeded.")
        }
    }
}

private struct AIStreamGuardrailConfigurationStorageKey: StorageKey {
    typealias Value = AIStreamGuardrailConfiguration
}

extension Application {
    var aiStreamGuardrailConfiguration: AIStreamGuardrailConfiguration {
        get {
            storage[AIStreamGuardrailConfigurationStorageKey.self] ?? .productionDefault
        }
        set {
            storage[AIStreamGuardrailConfigurationStorageKey.self] = newValue
        }
    }
}
