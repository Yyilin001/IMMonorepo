import Foundation
import IMV2Core
@testable import IMV2Server
import Testing

@Suite("V2 content review worker")
struct V2ContentReviewWorkerTests {
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
        #expect(await reviewStore.resolvedVerdicts() == [V2ContentReviewVerdict.violation(category: "configured_policy", severity: 4, confidence: 1)])
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
        #expect(await reviewStore.releasedLeaseCount() == 0)
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
        #expect(await reviewStore.releasedLeaseCount() == 1)
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
        #expect(await reviewStore.releasedLeaseCount() == 1)
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

        #expect(try await V2ConfiguredContentReviewer(violatingTerms: ["CAFÉ"]).review(input) == .violation(category: "configured_policy", severity: 4, confidence: 1))
    }
}

private actor RecordingContentReviewStore: V2ContentReviewStore {
    private let leases: [V2ContentReviewLease]
    private var currentResults: [Bool]
    private var resolved: [V2ContentReviewVerdict] = []
    private var releasedLeaseCountValue = 0
    init(leases: [V2ContentReviewLease], current: Bool = true) {
        self.leases = leases
        self.currentResults = [current]
    }
    init(leases: [V2ContentReviewLease], currentResults: [Bool]) {
        self.leases = leases
        self.currentResults = currentResults
    }
    func claimPending(now _: Date, leaseDuration _: TimeInterval, limit: Int) -> [V2ContentReviewLease] { Array(leases.prefix(limit)) }
    func isCurrent(_: V2ContentReviewLease, now _: Date) -> Bool {
        guard let result = currentResults.first else { return false }
        if currentResults.count > 1 { currentResults.removeFirst() }
        return result
    }
    func resolve(_: V2ContentReviewLease, verdict: V2ContentReviewVerdict, now _: Date) { resolved.append(verdict) }
    func release(_: V2ContentReviewLease) { releasedLeaseCountValue += 1 }
    func resolvedVerdicts() -> [V2ContentReviewVerdict] { resolved }
    func releasedLeaseCount() -> Int { releasedLeaseCountValue }
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
