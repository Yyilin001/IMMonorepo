import Foundation
import IMV2Core
@testable import IMV2Server
import Testing

@Suite("V2 content review worker")
struct V2ContentReviewWorkerTests {
    @Test("trusted room control forwards once to the privileged moderation store")
    func trustedRoomControlForwardsWithoutRecursion() async throws {
        let moderationStore = RecordingTrustedModerationStore()
        let service = V2TrustedSafetyModerationService(
            store: moderationStore,
            safetyActorUserID: try .init("00000000-0000-0000-0000-000000000793"),
            capacityProfile: try reviewTestProfile(),
            identifiers: .init(makeUUID: { UUID(uuidString: "00000000-0000-0000-0000-000000000794")! })
        )
        let request = try V2TrustedSafetyRoomControl(
            roomID: .init("00000000-0000-0000-0000-000000000791"),
            operationID: .init("00000000-0000-0000-0000-000000000792"),
            action: .freezeRoom,
            reasonCode: .init("safety_review")
        )

        let outcome = try await service.apply(request)
        let command = try #require(await moderationStore.command())

        #expect(command.action == .freezeRoom)
        #expect(command.messageID == nil)
        guard case .applied(let result) = outcome else {
            Issue.record("expected the room-control command to be applied")
            return
        }
        #expect(result.operationID == request.operationID)
    }

    @Test("a violation uses the stable message ID as its trusted redaction operation")
    func violationRedactsAndResolves() async throws {
        let input = try V2ContentReviewInput(
            messageID: .init("00000000-0000-0000-0000-000000000801"),
            roomID: .init("00000000-0000-0000-0000-000000000802"),
            contentRevision: 1,
            text: "blocked",
            mediaCount: 0
        )
        let lease = V2ContentReviewLease(input: input, claimToken: UUID())
        let reviewStore = RecordingContentReviewStore(leases: [lease])
        let moderationStore = RecordingTrustedModerationStore()
        let service = V2TrustedSafetyModerationService(
            store: moderationStore,
            safetyActorUserID: try .init("00000000-0000-0000-0000-000000000803"),
            capacityProfile: try reviewTestProfile(),
            identifiers: .init(makeUUID: { UUID(uuidString: "00000000-0000-0000-0000-000000000804")! })
        )
        let worker = try V2ContentReviewWorker(
            store: reviewStore,
            reviewer: V2ConfiguredContentReviewer(violatingTerms: ["blocked"]),
            moderation: service
        )

        #expect(try await worker.runOnce(limit: 1) == .init(claimedCount: 1, resolvedCount: 1, redactedCount: 1, releasedCount: 0))
        let command = try #require(await moderationStore.command())
        #expect(command.action == .redactMessage)
        #expect(command.messageID == input.messageID)
        #expect(command.operationID.rawValue == input.messageID.rawValue)
        #expect(await reviewStore.stagedFindings() == [try .init(category: "configured_policy", severity: 4, confidence: 1)])
        #expect(await reviewStore.resolvedVerdicts() == [try V2ContentReviewVerdict.violation(.init(category: "configured_policy", severity: 4, confidence: 1))])
    }

    @Test("a stale content revision is superseded without calling moderation")
    func staleLeaseDoesNotRedact() async throws {
        let input = try V2ContentReviewInput(
            messageID: .init("00000000-0000-0000-0000-000000000811"),
            roomID: .init("00000000-0000-0000-0000-000000000812"),
            contentRevision: 1,
            text: "blocked",
            mediaCount: 0
        )
        let reviewStore = RecordingContentReviewStore(leases: [.init(input: input, claimToken: UUID())], current: false)
        let moderationStore = RecordingTrustedModerationStore()
        let service = V2TrustedSafetyModerationService(store: moderationStore, safetyActorUserID: try .init("00000000-0000-0000-0000-000000000813"), capacityProfile: try reviewTestProfile())
        let worker = try V2ContentReviewWorker(store: reviewStore, reviewer: V2ConfiguredContentReviewer(violatingTerms: ["blocked"]), moderation: service)

        #expect(try await worker.runOnce(limit: 1) == .init(claimedCount: 1, resolvedCount: 1, redactedCount: 0, releasedCount: 0))
        #expect(await moderationStore.command() == nil)
        #expect(await reviewStore.resolvedVerdicts().isEmpty)
    }

    @Test("a concurrent redaction cannot resolve a newer review lease")
    func alreadyRedactedOutcomeRechecksTheLease() async throws {
        let input = try V2ContentReviewInput(
            messageID: .init("00000000-0000-0000-0000-000000000816"),
            roomID: .init("00000000-0000-0000-0000-000000000817"),
            contentRevision: 1,
            text: "blocked",
            mediaCount: 0
        )
        let reviewStore = RecordingContentReviewStore(
            leases: [.init(input: input, claimToken: UUID())],
            currentResults: [true, false]
        )
        let moderation = V2TrustedSafetyModerationService(
            store: RecordingTrustedModerationStore(outcome: .messageAlreadyRedacted),
            safetyActorUserID: try .init("00000000-0000-0000-0000-000000000818"),
            capacityProfile: try reviewTestProfile()
        )
        let worker = try V2ContentReviewWorker(
            store: reviewStore,
            reviewer: V2ConfiguredContentReviewer(violatingTerms: ["blocked"]),
            moderation: moderation
        )

        #expect(try await worker.runOnce(limit: 1) == .init(claimedCount: 1, resolvedCount: 1, redactedCount: 0, releasedCount: 0))
        #expect(await reviewStore.resolvedVerdicts().isEmpty)
        #expect(await reviewStore.retryDispositions().isEmpty)
    }

    @Test("an applied violation resolves against the claim without treating its own tombstone as superseded")
    func appliedViolationDoesNotInvalidateItsOwnReview() async throws {
        let input = try V2ContentReviewInput(
            messageID: .init("00000000-0000-0000-0000-000000000819"),
            roomID: .init("00000000-0000-0000-0000-00000000081a"),
            contentRevision: 1,
            text: "blocked",
            mediaCount: 0
        )
        let reviewStore = RecordingContentReviewStore(
            leases: [.init(input: input, claimToken: UUID())],
            currentResults: [true, false]
        )
        let moderation = V2TrustedSafetyModerationService(
            store: RecordingTrustedModerationStore(),
            safetyActorUserID: try .init("00000000-0000-0000-0000-00000000081b"),
            capacityProfile: try reviewTestProfile()
        )
        let worker = try V2ContentReviewWorker(
            store: reviewStore,
            reviewer: V2ConfiguredContentReviewer(violatingTerms: ["blocked"]),
            moderation: moderation
        )

        #expect(try await worker.runOnce(limit: 1) == .init(claimedCount: 1, resolvedCount: 1, redactedCount: 1, releasedCount: 0))
        #expect(await reviewStore.resolvedVerdicts().count == 1)
    }

    @Test("a reviewer failure releases the lease so durable work can be retried")
    func reviewerFailureReleasesLease() async throws {
        let input = try V2ContentReviewInput(
            messageID: .init("00000000-0000-0000-0000-000000000821"),
            roomID: .init("00000000-0000-0000-0000-000000000822"),
            contentRevision: 1,
            text: "provider unavailable",
            mediaCount: 0
        )
        let reviewStore = RecordingContentReviewStore(leases: [.init(input: input, claimToken: UUID())])
        let moderation = V2TrustedSafetyModerationService(
            store: RecordingTrustedModerationStore(),
            safetyActorUserID: try .init("00000000-0000-0000-0000-000000000823"),
            capacityProfile: try reviewTestProfile()
        )
        let worker = try V2ContentReviewWorker(
            store: reviewStore,
            reviewer: FailingContentReviewer(),
            moderation: moderation
        )

        #expect(try await worker.runOnce(limit: 1) == .init(claimedCount: 1, resolvedCount: 0, redactedCount: 0, releasedCount: 1))
        guard case .retry = try #require(await reviewStore.retryDispositions().first) else {
            Issue.record("expected a delayed retry")
            return
        }
        #expect(await reviewStore.resolvedVerdicts().isEmpty)
    }

    @Test("a failed review does not stop later leases in the same bounded batch")
    func reviewerFailureDoesNotStarveLaterLeases() async throws {
        let failed = try V2ContentReviewInput(
            messageID: .init("00000000-0000-0000-0000-000000000824"),
            roomID: .init("00000000-0000-0000-0000-000000000825"),
            contentRevision: 1,
            text: "provider unavailable",
            mediaCount: 0
        )
        let succeeding = try V2ContentReviewInput(
            messageID: .init("00000000-0000-0000-0000-000000000826"),
            roomID: failed.roomID,
            contentRevision: 1,
            text: "ordinary message",
            mediaCount: 0
        )
        let reviewStore = RecordingContentReviewStore(leases: [
            .init(input: failed, claimToken: UUID()),
            .init(input: succeeding, claimToken: UUID())
        ])
        let moderation = V2TrustedSafetyModerationService(
            store: RecordingTrustedModerationStore(),
            safetyActorUserID: try .init("00000000-0000-0000-0000-000000000827"),
            capacityProfile: try reviewTestProfile()
        )
        let worker = try V2ContentReviewWorker(
            store: reviewStore,
            reviewer: SelectiveContentReviewer(failingMessageID: failed.messageID),
            moderation: moderation
        )

        #expect(try await worker.runOnce(limit: 2) == .init(claimedCount: 2, resolvedCount: 1, redactedCount: 0, releasedCount: 1))
        #expect(await reviewStore.retryDispositions().count == 1)
        #expect(await reviewStore.resolvedVerdicts() == [.clear])
    }

    @Test("configured review terms normalize case and canonical Unicode before deciding")
    func configuredReviewerNormalizesTerms() async throws {
        let input = try V2ContentReviewInput(
            messageID: .init("00000000-0000-0000-0000-000000000831"),
            roomID: .init("00000000-0000-0000-0000-000000000832"),
            contentRevision: 1,
            text: "contains Cafe\u{301}",
            mediaCount: 0
        )

        #expect(try await V2ConfiguredContentReviewer(violatingTerms: ["CAFÉ"]).review(input) == .violation(.init(category: "configured_policy", severity: 4, confidence: 1)))
    }

    @Test("an exhausted review attempt is durably paused instead of hot-looped")
    func exhaustedReviewPauses() async throws {
        let input = try V2ContentReviewInput(
            messageID: .init("00000000-0000-0000-0000-000000000841"),
            roomID: .init("00000000-0000-0000-0000-000000000842"),
            contentRevision: 1,
            text: "provider unavailable",
            mediaCount: 0
        )
        let reviewStore = RecordingContentReviewStore(leases: [
            .init(input: input, claimToken: UUID(), attempt: 2)
        ])
        let moderation = V2TrustedSafetyModerationService(
            store: RecordingTrustedModerationStore(),
            safetyActorUserID: try .init("00000000-0000-0000-0000-000000000843"),
            capacityProfile: try reviewTestProfile()
        )
        let worker = try V2ContentReviewWorker(
            store: reviewStore,
            reviewer: FailingContentReviewer(),
            moderation: moderation,
            retryPolicy: .init(initialDelay: 1, maximumDelay: 1, maximumAttempts: 2, jitterFraction: 0)
        )

        #expect(try await worker.runOnce(limit: 1) == .init(claimedCount: 1, resolvedCount: 0, redactedCount: 0, releasedCount: 1))
        #expect(await reviewStore.retryDispositions() == [.pause])
    }

    @Test("review findings reject values that cannot satisfy persistence constraints")
    func reviewFindingIsBoundedAtTheProviderBoundary() {
        #expect(throws: V2ContentReviewWorkerError.invalidFindingCategory) {
            try V2ContentReviewFinding(category: "not valid", severity: 1, confidence: 0.5)
        }
        #expect(throws: V2ContentReviewWorkerError.invalidFindingSeverity) {
            try V2ContentReviewFinding(category: "policy", severity: 5, confidence: 0.5)
        }
        #expect(throws: V2ContentReviewWorkerError.invalidFindingConfidence) {
            try V2ContentReviewFinding(category: "policy", severity: 1, confidence: .nan)
        }
    }
}

private actor RecordingContentReviewStore: V2ContentReviewStore {
    private let leases: [V2ContentReviewLease]
    private var validationResults: [V2ContentReviewLeaseValidation]
    private var resolved: [V2ContentReviewVerdict] = []
    private var staged: [V2ContentReviewFinding] = []
    private var scheduledRetries: [V2DurableRetryDisposition] = []
    init(leases: [V2ContentReviewLease], current: Bool = true) {
        self.leases = leases
        self.validationResults = [current ? .current : .superseded]
    }
    init(leases: [V2ContentReviewLease], currentResults: [Bool]) {
        self.leases = leases
        self.validationResults = currentResults.map { $0 ? .current : .superseded }
    }
    func claimPending(now _: Date, leaseDuration _: TimeInterval, limit: Int) -> [V2ContentReviewLease] { Array(leases.prefix(limit)) }
    func validateAndRenew(_: V2ContentReviewLease, now _: Date, leaseDuration _: TimeInterval) -> V2ContentReviewLeaseValidation {
        guard let result = validationResults.first else { return .lostLease }
        if validationResults.count > 1 { validationResults.removeFirst() }
        return result
    }
    func resolve(_: V2ContentReviewLease, verdict: V2ContentReviewVerdict, now _: Date) -> Bool {
        resolved.append(verdict)
        return true
    }
    func stageViolation(_: V2ContentReviewLease, finding: V2ContentReviewFinding) -> Bool {
        staged.append(finding)
        return true
    }
    func scheduleRetry(_: V2ContentReviewLease, disposition: V2DurableRetryDisposition, now _: Date) { scheduledRetries.append(disposition) }
    func resolvedVerdicts() -> [V2ContentReviewVerdict] { resolved }
    func stagedFindings() -> [V2ContentReviewFinding] { staged }
    func retryDispositions() -> [V2DurableRetryDisposition] { scheduledRetries }
}

private struct FailingContentReviewer: V2ContentReviewing {
    func review(_: V2ContentReviewInput) async throws -> V2ContentReviewVerdict {
        throw V2ContentReviewWorkerError.dispositionNotApplied
    }
}

private struct SelectiveContentReviewer: V2ContentReviewing {
    let failingMessageID: MessageID

    func review(_ input: V2ContentReviewInput) async throws -> V2ContentReviewVerdict {
        guard input.messageID != failingMessageID else {
            throw V2ContentReviewWorkerError.dispositionNotApplied
        }
        return .clear
    }
}

private actor RecordingTrustedModerationStore: V2TrustedSafetyModerationStore {
    private var received: V2ModerationCommand?
    private let outcome: V2ModerationOutcome?

    init(outcome: V2ModerationOutcome? = nil) {
        self.outcome = outcome
    }

    func applyTrustedSafety(command: V2ModerationCommand, capacityProfile _: V2CapacityProfile, eventID: EventID, planID: FanoutPlanID, now: Date) -> V2ModerationOutcome {
        received = command
        if let outcome { return outcome }
        return .applied(.init(roomID: command.roomID, operationID: command.operationID, action: command.action, targetUserID: nil, messageID: command.messageID, messageRevision: 2, muteUntil: nil, roomSequence: 2, eventID: eventID, fanoutPlanID: planID, createdAt: now))
    }
    func command() -> V2ModerationCommand? { received }
}

private func reviewTestProfile() throws -> V2CapacityProfile {
    try .init(id: "standard", limits: .init(maxEligibleMembers: 16, maxCommandsPerWindow: 32, maxFanoutUnitsPerWindow: 32, maxOutstandingFanoutUnits: 64, maxOutstandingPlans: 16, maxEnumerationPageSize: 16, maxPlannerConcurrency: 1, maxDeliveryConcurrency: 1, retryAfterSeconds: 3))
}
