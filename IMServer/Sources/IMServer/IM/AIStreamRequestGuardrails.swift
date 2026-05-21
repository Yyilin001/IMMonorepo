import Vapor

struct AIStreamGuardrailConfiguration: Sendable {
    var maxPromptCharacters: Int
    var maxEstimatedCostUnits: Int
    var blockedPromptTerms: [String]
    var maxRequestsPerUserPerMinute: Int
    var maxCostUnitsPerUserPerDay: Int
    var defaultModelID: String
    var largePromptModelID: String
    var largePromptCharacterThreshold: Int

    init(
        maxPromptCharacters: Int,
        maxEstimatedCostUnits: Int,
        blockedPromptTerms: [String],
        maxRequestsPerUserPerMinute: Int = 60,
        maxCostUnitsPerUserPerDay: Int = 500_000,
        defaultModelID: String = "mock-text-small",
        largePromptModelID: String = "mock-text-large",
        largePromptCharacterThreshold: Int = 2_000
    ) {
        self.maxPromptCharacters = maxPromptCharacters
        self.maxEstimatedCostUnits = maxEstimatedCostUnits
        self.blockedPromptTerms = blockedPromptTerms
        self.maxRequestsPerUserPerMinute = maxRequestsPerUserPerMinute
        self.maxCostUnitsPerUserPerDay = maxCostUnitsPerUserPerDay
        self.defaultModelID = defaultModelID
        self.largePromptModelID = largePromptModelID
        self.largePromptCharacterThreshold = largePromptCharacterThreshold
    }

    static let productionDefault = AIStreamGuardrailConfiguration(
        maxPromptCharacters: 4_000,
        maxEstimatedCostUnits: 24_000,
        blockedPromptTerms: []
    )
}

struct AIStreamStartGuardrailDecision: Sendable {
    let estimatedCostUnits: Int
    let modelID: String
}

struct AIStreamStartPolicyDecision: Sendable {
    let estimatedCostUnits: Int
    let modelID: String
    let costReservationID: UUID
}

struct AIStreamRequestGuardrails {
    let app: Application

    @discardableResult
    func validateStart(
        prompt: String,
        conversationID: UUID,
        userID: UUID
    ) throws -> AIStreamStartGuardrailDecision {
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

        return AIStreamStartGuardrailDecision(
            estimatedCostUnits: estimatedCostUnits,
            modelID: AIStreamModelRouter(configuration: configuration).modelID(forPrompt: prompt)
        )
    }
}

struct AIStreamModelRouter: Sendable {
    let configuration: AIStreamGuardrailConfiguration

    func modelID(forPrompt prompt: String) -> String {
        prompt.count >= configuration.largePromptCharacterThreshold
            ? configuration.largePromptModelID
            : configuration.defaultModelID
    }
}

actor AIStreamRateLimiter {
    private var requestTimesByUser: [UUID: [Date]] = [:]

    func reserve(userID: UUID, limit: Int, window: TimeInterval, now: Date = Date()) throws {
        guard limit > 0 else {
            throw Abort(.tooManyRequests, reason: "AI stream rate limit exceeded.")
        }

        let cutoff = now.addingTimeInterval(-window)
        let current = requestTimesByUser[userID, default: []].filter { $0 >= cutoff }
        guard current.count < limit else {
            requestTimesByUser[userID] = current
            throw Abort(.tooManyRequests, reason: "AI stream rate limit exceeded.")
        }
        requestTimesByUser[userID] = current + [now]
    }

    func reset() {
        requestTimesByUser.removeAll()
    }
}

actor AIStreamCostLedger {
    private var reservedCostByUser: [UUID: Int] = [:]
    private var reservations: [UUID: (userID: UUID, units: Int)] = [:]

    func reserve(userID: UUID, units: Int, budget: Int) throws -> UUID {
        let current = reservedCostByUser[userID, default: 0]
        guard current + units <= budget else {
            throw Abort(.paymentRequired, reason: "AI stream user cost budget exceeded.")
        }

        let reservationID = UUID()
        reservations[reservationID] = (userID, units)
        reservedCostByUser[userID] = current + units
        return reservationID
    }

    func release(_ reservationID: UUID) {
        guard let reservation = reservations.removeValue(forKey: reservationID) else {
            return
        }
        reservedCostByUser[reservation.userID, default: 0] = max(
            0,
            reservedCostByUser[reservation.userID, default: 0] - reservation.units
        )
    }

    func usedCostUnits(userID: UUID) -> Int {
        reservedCostByUser[userID, default: 0]
    }

    func reset() {
        reservedCostByUser.removeAll()
        reservations.removeAll()
    }
}

struct AIStreamProviderPolicyService {
    let app: Application

    func authorizeStart(
        prompt: String,
        conversationID: UUID,
        userID: UUID
    ) async throws -> AIStreamStartPolicyDecision {
        let guardrailDecision = try AIStreamRequestGuardrails(app: app).validateStart(
            prompt: prompt,
            conversationID: conversationID,
            userID: userID
        )
        let configuration = app.aiStreamGuardrailConfiguration
        try await app.aiStreamRateLimiter.reserve(
            userID: userID,
            limit: configuration.maxRequestsPerUserPerMinute,
            window: 60
        )
        let reservationID = try await app.aiStreamCostLedger.reserve(
            userID: userID,
            units: guardrailDecision.estimatedCostUnits,
            budget: configuration.maxCostUnitsPerUserPerDay
        )
        return AIStreamStartPolicyDecision(
            estimatedCostUnits: guardrailDecision.estimatedCostUnits,
            modelID: guardrailDecision.modelID,
            costReservationID: reservationID
        )
    }
}

private struct AIStreamGuardrailConfigurationStorageKey: StorageKey {
    typealias Value = AIStreamGuardrailConfiguration
}

private struct AIStreamRateLimiterStorageKey: StorageKey {
    typealias Value = AIStreamRateLimiter
}

private struct AIStreamCostLedgerStorageKey: StorageKey {
    typealias Value = AIStreamCostLedger
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

    var aiStreamRateLimiter: AIStreamRateLimiter {
        get {
            if let limiter = storage[AIStreamRateLimiterStorageKey.self] {
                return limiter
            }
            let limiter = AIStreamRateLimiter()
            storage[AIStreamRateLimiterStorageKey.self] = limiter
            return limiter
        }
        set {
            storage[AIStreamRateLimiterStorageKey.self] = newValue
        }
    }

    var aiStreamCostLedger: AIStreamCostLedger {
        get {
            if let ledger = storage[AIStreamCostLedgerStorageKey.self] {
                return ledger
            }
            let ledger = AIStreamCostLedger()
            storage[AIStreamCostLedgerStorageKey.self] = ledger
            return ledger
        }
        set {
            storage[AIStreamCostLedgerStorageKey.self] = newValue
        }
    }
}
