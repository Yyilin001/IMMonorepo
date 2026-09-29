@testable import IMV2ServerApplication
@testable import IMV2ServerContracts
import Foundation
import IMV2ActorContracts
import IMV2Core
@testable import IMV2Server
@testable import IMV2ServerInfrastructure
import Testing

@Suite("V2 Actor administration typed wire")
struct V2ActorAdministrationWireTests {
    private let room = try! RoomID("room-a")
    private let actor = try! UserID("actor-a")
    private let target = try! UserID("target-b")
    private let message = try! MessageID("message-c")
    private let event = try! EventID("event-d")
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func roundTrip<T: Codable & Equatable>(_ value: T) throws -> T {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        return try decoder.decode(T.self, from: encoder.encode(value))
    }

    @Test("every command and query preserves its business identity and fields")
    func commandsAndQueries() throws {
        let reason = try V2ModerationReasonCode("review_1")
        let trusted = V2ActorTrustedSafetyWire(try V2TrustedSafetyModeration(
            roomID: room, operationID: ModerationOperationID("trusted-op"), action: .redactMessage,
            messageID: message, expectedMessageRevision: 7, reasonCode: reason))
        #expect(try trusted.trustedModeration().expectedMessageRevision == 7)
        let control = V2ActorTrustedSafetyWire(try V2TrustedSafetyRoomControl(
            roomID: room, operationID: ModerationOperationID("freeze-op"),
            action: .freezeRoom, reasonCode: reason))
        #expect(try control.trustedRoomControl().action == .freezeRoom)
        let nickname = V2ActorGroupNicknameUpdateWire(command: try .init(actorUserID: actor, roomID: room,
            operationID: .init("nickname-op"), expectedRevision: .init(rawValue: 8), nickname: "Name", firstSubmissionDeadlineMilliseconds: 1_700_000_120_000))
        let commands: [V2RoomAdministrationCommand] = [.trustedSafety(trusted), .trustedSafety(control), .groupNickname(nickname)]
        for command in commands {
            #expect(try roundTrip(command) == command)
            #expect(command.roomID == room)
            #expect(command.retryPolicy == .durableIdempotent)
            if case .trustedSafety = command { #expect(command.actorUserID == nil) }
            else { #expect(command.actorUserID == actor) }
        }
        #expect(commands[2].stableOperationIdentity == .groupNickname(nickname.operationID))

        let query = V2RoomAdministrationQuery.groupNicknames(
            .init(roomID: room, actorUserID: actor, afterUserID: target, limit: 100))
        #expect(try roundTrip(query) == query)
        #expect(query.roomID == room && query.actorUserID == actor && query.retryPolicy == .readOnly)
        if case .groupNicknames(let value) = query { try value.validateForDomain() }
    }

    @Test("all result families retain revisions, sequences, events, times and outcome cases")
    func results() throws {
        let change = try V2RoomMembershipChange(roomID: room, targetUserID: target,
            action: .remove, membershipRevision: 9, roomSequence: 10, eventID: event, createdAt: now)
        let membership = V2ActorMembershipOutcomeWire(V2RoomMembershipChangeOutcome.changed(change))
        #expect(try membership.domain() == .changed(change))
        #expect(try roundTrip(membership) == membership)
        #expect(try V2ActorMembershipOutcomeWire(V2RoomMembershipChangeOutcome.revisionConflict(current: 12)).domain()
            == .revisionConflict(current: 12))

        let pinnedValue = try V2PinnedMessage(roomID: room, messageID: message,
            isPinned: true, roomSequence: 11, updatedAt: now)
        let pinned = V2ActorGroupCapabilityOutcomeWire<V2ActorPinnedMessageResultWire>(
            V2GroupCapabilitiesOutcome<V2PinnedMessage>.idempotent(pinnedValue))
        #expect(try pinned.domain() == .idempotent(pinnedValue))
        let announcementValue = try V2GroupAnnouncement(roomID: room, body: "announcement",
            revision: 12, roomSequence: 13, updatedAt: now)
        let announcement = V2ActorGroupCapabilityOutcomeWire<V2ActorGroupAnnouncementResultWire>(
            V2GroupCapabilitiesOutcome<V2GroupAnnouncement>.applied(announcementValue))
        #expect(try announcement.domain() == .applied(announcementValue))
        let permissionValue = try V2GroupRolePermissionsChange(roomID: room, role: .member,
            permissions: [.sendMessages, .pinMessages], revision: 14, roomSequence: 15)
        let permission = V2ActorGroupCapabilityOutcomeWire<V2ActorRolePermissionsResultWire>(
            V2GroupCapabilitiesOutcome<V2GroupRolePermissionsChange>.applied(permissionValue))
        #expect(try permission.domain() == .applied(permissionValue))
        let memberValue = try V2GroupMemberRoleChange(roomID: room, targetUserID: target,
            role: .admin, membershipRevision: 16, roomSequence: 17)
        let memberRole = V2ActorGroupCapabilityOutcomeWire<V2ActorMemberRoleResultWire>(
            V2GroupCapabilitiesOutcome<V2GroupMemberRoleChange>.idempotent(memberValue))
        #expect(try memberRole.domain() == .idempotent(memberValue))

        let moderationValue = try V2ModerationResult(roomID: room,
            operationID: ModerationOperationID("moderation-result"), action: .removeMember,
            targetUserID: target, messageID: nil, messageRevision: nil,
            membershipRevision: 18, muteUntil: nil, roomSequence: 19, eventID: event, createdAt: now)
        let moderation = V2ActorModerationOutcomeWire(V2ModerationOutcome.applied(moderationValue))
        #expect(try moderation.domain() == .applied(moderationValue))
        let presentation = try V2GroupMemberPresentation(roomID: room, userID: target,
            groupNickname: "Member", revision: V2ProfileRevision(rawValue: 20)!)
        let page = V2ActorGroupNicknamePageWire(V2GroupNicknamePage(values: [presentation], nextCursor: target))
        #expect(try page.domain() == V2GroupNicknamePage(values: [presentation], nextCursor: target))

        let results: [V2RoomAdministrationResult] = [
            .membership(membership), .pinned(pinned), .announcement(announcement),
            .rolePermissions(permission), .memberRole(memberRole),
            .trustedSafety(moderation), .groupNickname(try .init(
                identity: V2GroupNicknameUpdateCommand(actorUserID: target, roomID: room,
                    operationID: GroupNicknameOperationID("result-nickname"), expectedRevision: nil,
                    nickname: "Member", firstSubmissionDeadlineMilliseconds: 1000).identity,
                fingerprint: V2GroupNicknameUpdateCommand(actorUserID: target, roomID: room,
                    operationID: GroupNicknameOperationID("result-nickname"), expectedRevision: nil,
                    nickname: "Member", firstSubmissionDeadlineMilliseconds: 1000).fingerprint,
                outcome: .committed(presentation), resolvedAtMilliseconds: 1)), .groupNicknames(page)
        ]
        for result in results { #expect(try roundTrip(result) == result) }
        let failureCases: [V2RoomAdministrationResult] = [
            .membership(.rateLimited(retryAfterSeconds: 5)),
            .membership(.unavailable(.expiredShardLease)),
            .pinned(.alreadyInDesiredState), .announcement(.revisionConflict),
            .rolePermissions(.idempotencyConflict), .memberRole(.unavailable(.missingShardLease)),
            .trustedSafety(.messageAlreadyRedacted)
        ]
        for result in failureCases { #expect(try roundTrip(result) == result) }

        let membershipFailures: [V2ActorMembershipOutcomeWire] = [
            .idempotent(.init(change)), .idempotencyConflict, .revisionConflict(current: 0),
            .targetAlreadyMember, .targetNotMember, .memberLimitReached,
            .rateLimited(retryAfterSeconds: 5), .unavailable(.missingShardLease)
        ]
        for value in membershipFailures {
            #expect(try roundTrip(value) == value)
            #expect(V2ActorMembershipOutcomeWire(try value.domain()) == value)
        }
        let capabilityFailures: [V2ActorGroupCapabilityOutcomeWire<V2ActorPinnedMessageResultWire>] = [
            .applied(.init(pinnedValue)), .idempotent(.init(pinnedValue)), .idempotencyConflict,
            .alreadyInDesiredState, .revisionConflict, .rateLimited(retryAfterSeconds: 3),
            .unavailable(.expiredShardLease)
        ]
        for value in capabilityFailures {
            #expect(try roundTrip(value) == value)
            #expect(V2ActorGroupCapabilityOutcomeWire<V2ActorPinnedMessageResultWire>(try value.domain()) == value)
        }
        let moderationFailures: [V2ActorModerationOutcomeWire] = [
            .applied(.init(moderationValue)), .idempotent(.init(moderationValue)),
            .idempotencyConflict, .targetNotMember, .messageAlreadyRedacted,
            .actionAlreadyInDesiredState, .rateLimited(retryAfterSeconds: 7),
            .unavailable(.missingShardLease)
        ]
        for value in moderationFailures {
            #expect(try roundTrip(value) == value)
            #expect(V2ActorModerationOutcomeWire(try value.domain()) == value)
        }
    }

    @Test("malformed wire fails decoding or throwing domain mapping")
    func invalidWire() throws {
        let trusted = V2ActorTrustedSafetyWire(roomID: room,
            operationID: try ModerationOperationID("bad-trusted"), action: .redactMessage,
            messageID: message, expectedMessageRevision: UInt64.max, reasonCode: "safety")
        #expect(throws: (any Error).self) { try trusted.trustedModeration() }
        #expect(throws: (any Error).self) {
            try V2GroupNicknameUpdateCommand(actorUserID: actor, roomID: room,
                operationID: GroupNicknameOperationID("bad-nickname"), expectedRevision: nil,
                nickname: String(repeating: "x", count: 81), firstSubmissionDeadlineMilliseconds: 1000)
        }
        let invalidPresentation = V2ActorGroupMemberPresentationWire(roomID: room, userID: target,
            groupNickname: "\u{0001}", revision: V2ProfileRevision(rawValue: 1)!)
        #expect(throws: (any Error).self) { try invalidPresentation.domain() }
        let noncanonicalPresentation = V2ActorGroupMemberPresentationWire(roomID: room, userID: target,
            groupNickname: " Name ", revision: V2ProfileRevision(rawValue: 1)!)
        #expect(throws: V2ProfilePresentationValidationError.invalidDisplayName) {
            try noncanonicalPresentation.domain()
        }
        let invalidResult = V2ActorMembershipChangeResultWire(roomID: room, targetUserID: target,
            action: .add, membershipRevision: 0, roomSequence: 1, eventID: event, createdAt: now)
        #expect(throws: (any Error).self) { try invalidResult.domain() }
        let invalidDate = V2ActorPinnedMessageResultWire(roomID: room, messageID: message,
            isPinned: true, roomSequence: 1, updatedAt: .distantFuture.addingTimeInterval(.infinity))
        #expect(throws: V2ActorAdministrationWireError.invalidDate) { try invalidDate.domain() }
        let query = V2ActorGroupNicknamesQueryWire(roomID: room, actorUserID: actor,
            afterUserID: nil, limit: 501)
        #expect(throws: V2ActorAdministrationWireError.invalidPageLimit) {
            try query.validateForDomain()
        }
        #expect(throws: V2ActorAdministrationWireError.invalidRetryAfter) {
            try V2ActorMembershipOutcomeWire.rateLimited(retryAfterSeconds: -1).domain()
        }
    }
}
