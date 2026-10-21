import Foundation
import Testing
@testable import IMV2ActorContracts

@Suite("Service qualification follows committed membership revisions")
struct V2ActorServiceMembershipTests {
    @Test("a standby cannot self-qualify before admission or after removal")
    func standbyHasNoServingAuthority() throws {
        let initial = try V2ActorServiceQualification.Membership(revision: 1, current: ["a"])
        #expect(throws: V2ActorServiceQualification.ConfigurationError.invalidRoster) {
            try V2ActorServiceQualification(localNodeID: "b", membership: initial)
        }
        let standby = try V2ActorServiceQualification(localNodeID: "b", membership: initial, allowNonMember: true)
        #expect(standby.snapshot() == nil)
        #expect(standby.update(witnesses: ["a": .now + .seconds(10)], membershipRevision: 1) == nil)
        try standby.installMembership(.init(revision: 2, current: ["a"], next: ["a", "b"]))
        #expect(standby.snapshot() == nil)
        #expect(standby.update(witnesses: [:], membershipRevision: 2) == nil)
        #expect(standby.update(witnesses: ["a": .now + .seconds(10)], membershipRevision: 2) != nil)
        try standby.installCommittedMembership(.init(revision: 3, current: ["a"]))
        #expect(standby.snapshot() == nil)
        #expect(standby.update(witnesses: ["a": .now + .seconds(10)], membershipRevision: 3) == nil)
    }

    @Test func certifiedCatchupAndReadFailureGate() throws {
        let qualification = try V2ActorServiceQualification(localNodeID: "a", roster: ["a"])
        qualification.suspendMembershipConfirmation()
        #expect(qualification.snapshot() == nil)
        #expect(qualification.update(witnesses: [:], membershipRevision: 1) == nil)
        let latest = try V2ActorServiceQualification.Membership(revision: 9, current: ["a", "b"])
        try qualification.installCommittedMembership(latest)
        #expect(qualification.update(witnesses: ["b": .now + .seconds(10)], membershipRevision: 9) == nil)
        qualification.confirmMembership()
        #expect(qualification.update(witnesses: ["b": .now + .seconds(10)], membershipRevision: 1) == nil)
        #expect(qualification.update(witnesses: ["b": .now + .seconds(10)], membershipRevision: 9) != nil)
        #expect(throws: V2ActorServiceQualification.ConfigurationError.self) {
            try qualification.installCommittedMembership(.init(revision: 8, current: ["a"]))
        }
        #expect(throws: V2ActorServiceQualification.ConfigurationError.self) {
            try qualification.installCommittedMembership(.init(revision: 9, current: ["a"]))
        }
    }

    @Test func expansionRequiresBothMajoritiesAndFreshEvidence() throws {
        let qualification = try V2ActorServiceQualification(localNodeID: "a", roster: ["a"])
        let original = try #require(qualification.snapshot())
        let joint = try V2ActorServiceQualification.Membership(revision: 2, current: ["a"], next: ["a", "b"])
        try qualification.installMembership(joint)
        #expect(qualification.snapshot() == nil)
        let until = ContinuousClock.now + .seconds(10)
        #expect(qualification.update(witnesses: ["b": until], membershipRevision: 1) == nil)
        #expect(qualification.update(witnesses: [:], membershipRevision: 2) == nil)
        let transitional = try #require(qualification.update(witnesses: ["b": until], membershipRevision: 2))
        #expect(transitional.generation != original.generation && transitional.validUntil == until)
        try qualification.installMembership(joint) // Exact replay cannot revoke a valid generation.
        #expect(qualification.snapshot()?.generation == transitional.generation)
        try qualification.installMembership(.init(revision: 3, current: ["a", "b"]))
        #expect(qualification.snapshot() == nil)
        #expect(qualification.update(witnesses: ["b": until], membershipRevision: 2) == nil)
        let stable = try #require(qualification.update(witnesses: ["b": until], membershipRevision: 3))
        #expect(stable.generation != transitional.generation)
        #expect(qualification.update(witnesses: [:], membershipRevision: 2) == nil)
        #expect(qualification.snapshot()?.generation == stable.generation)
    }

    @Test func disjointRostersCannotCountLocalVoteTwice() throws {
        let joint = try V2ActorServiceQualification.Membership(revision: 2,
            current: ["a", "b", "c"], next: ["d", "e", "f"])
        let qualification = try V2ActorServiceQualification(localNodeID: "a", membership: joint)
        let until = ContinuousClock.now + .seconds(10), shorter = ContinuousClock.now + .seconds(5)
        #expect(qualification.update(witnesses: ["b": until, "d": until], membershipRevision: 2) == nil)
        #expect(qualification.update(witnesses: ["d": until, "e": until], membershipRevision: 2) == nil)
        let proof = try #require(qualification.update(witnesses: ["b": until, "d": until, "e": shorter], membershipRevision: 2))
        #expect(proof.validUntil == shorter)
        try qualification.installMembership(.init(revision: 3, current: ["d", "e", "f"]))
        #expect(qualification.update(witnesses: ["d": until, "e": until, "f": until], membershipRevision: 3) == nil)
        #expect(qualification.snapshot() == nil)
    }

    @Test func joiningNodeNeedsOldRosterMajority() throws {
        let joint = try V2ActorServiceQualification.Membership(revision: 2,
            current: ["a", "b", "c"], next: ["a", "b", "c", "d"])
        let qualification = try V2ActorServiceQualification(localNodeID: "d", membership: joint)
        let until = ContinuousClock.now + .seconds(10)
        #expect(qualification.update(witnesses: ["a": until], membershipRevision: 2) == nil)
        #expect(qualification.update(witnesses: ["a": until, "b": until], membershipRevision: 2) != nil)
    }

    @Test func transitionsRejectSkippingRollbackAndChangingPendingTarget() throws {
        let qualification = try V2ActorServiceQualification(localNodeID: "a", roster: ["a"])
        #expect(throws: V2ActorServiceQualification.ConfigurationError.self) {
            try qualification.installMembership(.init(revision: 2, current: ["a", "b"]))
        }
        #expect(throws: V2ActorServiceQualification.ConfigurationError.self) {
            try qualification.installMembership(.init(revision: 3, current: ["a"], next: ["a", "b"]))
        }
        try qualification.installMembership(.init(revision: 2, current: ["a"], next: ["a", "b"]))
        #expect(throws: V2ActorServiceQualification.ConfigurationError.self) {
            try qualification.installMembership(.init(revision: 1, current: ["a"]))
        }
        #expect(throws: V2ActorServiceQualification.ConfigurationError.self) {
            try qualification.installMembership(.init(revision: 3, current: ["a", "c"]))
        }
        #expect(qualification.membership.revision == 2 && qualification.snapshot() == nil)
    }
}
