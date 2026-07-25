import IMV2Core
import Testing

@Suite("V2 mention authorization")
struct MentionTests {
    @Test("only room administrators can mention everyone")
    func everyoneRequiresAdministrativeRole() async throws {
        let limits = try V2MentionLimits(maximumTargets: 2)
        let member = V2MentionVisibility(senderRole: .member, visibleActiveUsers: [], mentionableUsers: [])
        #expect(throws: V2MentionValidationError.notAuthorized) {
            try V2MentionAuthorization.authorize([.everyone], visibility: member, limits: limits)
        }
        try V2MentionAuthorization.authorize([.everyone], visibility: .init(senderRole: .admin, visibleActiveUsers: [], mentionableUsers: []), limits: limits)
    }

    @Test("user mention authorization never distinguishes invisible causes")
    func userMentionRequiresFrozenVisibility() async throws {
        let target = try UserID("00000000-0000-0000-0000-000000000701")
        let visibility = V2MentionVisibility(senderRole: .member, visibleActiveUsers: [target], mentionableUsers: [])
        #expect(throws: V2MentionValidationError.notAuthorized) {
            try V2MentionAuthorization.authorize([.user(target)], visibility: visibility, limits: try .init())
        }
        try V2MentionAuthorization.authorize([.user(target)], visibility: .init(senderRole: .member, visibleActiveUsers: [target], mentionableUsers: [target]), limits: try .init())
    }
}
