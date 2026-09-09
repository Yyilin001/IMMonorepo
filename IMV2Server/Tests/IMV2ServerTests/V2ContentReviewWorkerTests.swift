import Foundation
import IMV2Core
@testable import IMV2Server
import Testing
import Synchronization

@Suite("V2 content review worker")
struct V2ContentReviewWorkerTests {
    @Test("retry persistence failures are surfaced after later leases finish", arguments: ["clock", "small-delay", "large-delay", "storage"])
    func retryFailureDoesNotStarveLaterLeases(mode: String) async throws {
        let base = Date(timeIntervalSince1970: 1_750_000_000)
        let invalidTimes: [Double] = mode == "clock" ? [.nan, .infinity, -.infinity, .greatestFiniteMagnitude, -.greatestFiniteMagnitude, 1e14, -1e14, -1e12] : [base.timeIntervalSince1970]
        for seconds in invalidTimes {
            let failing = V2ContentReviewInput(messageID: .init(uuid: UUID()), roomID: .init(uuid: UUID()), contentRevision: 1, text: "retry", mediaCount: 0)
            let succeeding = V2ContentReviewInput(messageID: .init(uuid: UUID()), roomID: failing.roomID, contentRevision: 1, text: "clear", mediaCount: 0)
            let store = RecordingContentReviewStore(leases: [.init(input: failing, claimToken: UUID()), .init(input: succeeding, claimToken: UUID())], retryFailure: mode == "storage" ? .unavailable : nil)
            let delay: Double = mode == "small-delay" ? .leastNonzeroMagnitude : (mode == "large-delay" ? .greatestFiniteMagnitude : 1)
            let clock = ContentReviewBoundaryClock([base, Date(timeIntervalSince1970: seconds), base, base])
            let moderationStore = RecordingTrustedModerationStore()
            let moderation = V2TrustedSafetyModerationService(store: moderationStore, safetyActorUserID: .init(uuid: UUID()), capacityProfile: try reviewTestProfile())
            let worker = try V2ContentReviewWorker(store: store, reviewer: SelectiveContentReviewer(failingMessageID: failing.messageID), moderation: moderation, retryPolicy: .init(initialDelay: delay, maximumDelay: delay, maximumAttempts: 10, jitterFraction: 0), now: { clock.now() })
            if mode == "storage" {
                await #expect(throws: ReviewRetryFailure.unavailable) { try await worker.runOnce(limit: 2) }
            } else {
                await #expect(throws: V2RoomWriteStoreError.corruptPersistenceState) { try await worker.runOnce(limit: 2) }
            }
            #expect(await store.resolvedVerdicts() == [.clear])
            #expect(await store.retryDispositions().isEmpty)
            #expect(await store.stagedFindings().isEmpty)
            #expect(await moderationStore.command() == nil)
        }
    }

    @Test("content review requires a finite positive lease")
    func invalidLeaseDuration() async throws {
        let moderation = V2TrustedSafetyModerationService(store: RecordingTrustedModerationStore(), safetyActorUserID: .init(uuid: UUID()), capacityProfile: try reviewTestProfile())
        for duration in [Double.nan, .infinity, -.infinity, 0, -1] {
            #expect(throws: V2ContentReviewWorkerError.invalidLeaseDuration) {
                try V2ContentReviewWorker(store: RecordingContentReviewStore(leases: []), reviewer: V2ConfiguredContentReviewer(), moderation: moderation, leaseDuration: duration)
            }
        }
    }

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

    @Test("owner fence failure retains review work for retry or explicit recovery", arguments: [1, 2])
    func ownerFenceFailureDoesNotResolveReview(_ attempt: Int) async throws {
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        let input = V2ContentReviewInput(messageID: .init(uuid: UUID()), roomID: .init(uuid: UUID()), contentRevision: 1, text: "blocked", mediaCount: 0)
        let reviewStore = RecordingContentReviewStore(leases: [.init(input: input, claimToken: UUID(), attempt: attempt)])
        let moderationStore = RecordingTrustedModerationStore(failure: .ownerChanged)
        let service = V2TrustedSafetyModerationService(store: moderationStore, safetyActorUserID: .init(uuid: UUID()), capacityProfile: try reviewTestProfile(), now: { now })
        let worker = try V2ContentReviewWorker(store: reviewStore,
            reviewer: V2ConfiguredContentReviewer(violatingTerms: ["blocked"]), moderation: service,
            retryPolicy: .init(initialDelay: 1, maximumDelay: 1, maximumAttempts: 2, jitterFraction: 0), now: { now })
        #expect(try await worker.runOnce(limit: 1) == .init(claimedCount: 1, resolvedCount: 0, redactedCount: 0, releasedCount: 1))
        #expect(await moderationStore.command()?.operationID.rawValue == input.messageID.rawValue)
        #expect(await reviewStore.resolvedVerdicts().isEmpty)
        #expect(await reviewStore.stagedFindings().count == 1)
        #expect(await reviewStore.retryDispositions() == [attempt == 1 ? .retry(at: now.addingTimeInterval(1)) : .pause])
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
    private let retryFailure: ReviewRetryFailure?
    init(leases: [V2ContentReviewLease], current: Bool = true, retryFailure: ReviewRetryFailure? = nil) {
        self.retryFailure = retryFailure
        self.leases = leases
        self.validationResults = [current ? .current : .superseded]
    }
    init(leases: [V2ContentReviewLease], currentResults: [Bool]) {
        self.retryFailure = nil
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
    func scheduleRetry(_: V2ContentReviewLease, disposition: V2DurableRetryDisposition, now _: Date) throws {
        if let retryFailure { throw retryFailure }
        scheduledRetries.append(disposition)
    }
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
    private let failure: V2RoomOwnerFenceError?

    init(outcome: V2ModerationOutcome? = nil, failure: V2RoomOwnerFenceError? = nil) {
        self.failure = failure
        self.outcome = outcome
    }

    func applyTrustedSafety(command: V2ModerationCommand, capacityProfile _: V2CapacityProfile, eventID: EventID, planID: FanoutPlanID, now: Date) throws -> V2ModerationOutcome {
        received = command
        if let failure { throw failure }
        if let outcome { return outcome }
        return .applied(try .init(roomID: command.roomID, operationID: command.operationID, action: command.action, targetUserID: nil, messageID: command.messageID, messageRevision: 2, muteUntil: nil, roomSequence: 2, eventID: eventID, fanoutPlanID: planID, createdAt: now))
    }
    func command() -> V2ModerationCommand? { received }
}

private func reviewTestProfile() throws -> V2CapacityProfile {
    try .init(id: "standard", limits: .init(maxEligibleMembers: 16, maxCommandsPerWindow: 32, maxFanoutUnitsPerWindow: 32, maxOutstandingFanoutUnits: 64, maxOutstandingPlans: 16, maxEnumerationPageSize: 16, maxPlannerConcurrency: 1, maxDeliveryConcurrency: 1, retryAfterSeconds: 3))
}

private enum ReviewRetryFailure: Error { case unavailable }

private final class ContentReviewBoundaryClock: Sendable {
    private let state: Mutex<([Date], Int)>
    init(_ dates: [Date]) { state = Mutex((dates, 0)) }
    func now() -> Date {
        state.withLock { state in
            let date = state.0[min(state.1, state.0.count - 1)]
            state.1 += 1
            return date
        }
    }
}
