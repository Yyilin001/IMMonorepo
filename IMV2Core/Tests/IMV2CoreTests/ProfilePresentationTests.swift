import Foundation
import Testing
@testable import IMV2Core

struct ProfilePresentationTests {
    @Test("direct conversations prefer an owner-private alias")
    func directConversationPrefersAlias() {
        let fixture = Fixture()
        let resolved = V2ProfileResolver.resolve(
            userID: fixture.target,
            profile: fixture.activeProfile,
            alias: fixture.alias,
            groupMember: fixture.groupMember,
            surface: .directConversation
        )

        #expect(resolved.displayName == "工作联系人")
        #expect(resolved.avatar == fixture.avatar)
        #expect(resolved.dependency.profileRevision == fixture.profileRevision)
        #expect(resolved.dependency.aliasRevision == fixture.aliasRevision)
        #expect(resolved.dependency.groupMemberRevision == fixture.groupMemberRevision)
    }

    @Test("group messages use group nickname unless private aliases are allowed")
    func groupMessagePriorityIsExplicit() {
        let fixture = Fixture()
        let standard = V2ProfileResolver.resolve(
            userID: fixture.target,
            profile: fixture.activeProfile,
            alias: fixture.alias,
            groupMember: fixture.groupMember,
            surface: .groupMessage(allowsPrivateAlias: false)
        )
        let privateRemark = V2ProfileResolver.resolve(
            userID: fixture.target,
            profile: fixture.activeProfile,
            alias: fixture.alias,
            groupMember: fixture.groupMember,
            surface: .groupMessage(allowsPrivateAlias: true)
        )

        #expect(standard.displayName == "群内昵称")
        #expect(privateRemark.displayName == "工作联系人")
    }

    @Test("tombstone profiles cannot expose a stale name or avatar")
    func tombstoneIsSafe() throws {
        let fixture = Fixture()
        let tombstone = try V2ProfileView(
            userID: fixture.target,
            publicIdentity: nil,
            avatar: nil,
            state: .deleted,
            revision: fixture.profileRevision,
            visibilityRevision: fixture.visibilityRevision
        )
        let resolved = V2ProfileResolver.resolve(
            userID: fixture.target,
            profile: tombstone,
            alias: fixture.alias,
            groupMember: nil,
            surface: .directConversation
        )

        #expect(resolved.displayName == "已注销用户")
        #expect(resolved.avatar == nil)
        #expect(resolved.state == .deleted)
    }

    @Test("invalid inactive views cannot retain public identity data")
    func inactiveProfileRejectsDisplayData() throws {
        let fixture = Fixture()
        #expect(throws: V2ProfilePresentationValidationError.invalidProfileView) {
            _ = try V2ProfileView(
                userID: fixture.target,
                publicIdentity: fixture.identity,
                avatar: nil,
                state: .hidden,
                revision: fixture.profileRevision,
                visibilityRevision: fixture.visibilityRevision
            )
        }
    }
}

private struct Fixture {
    let owner = try! UserID("00000000-0000-0000-0000-000000000001")
    let target = try! UserID("00000000-0000-0000-0000-000000000002")
    let room = try! RoomID("00000000-0000-0000-0000-000000000003")
    let profileRevision = V2ProfileRevision(rawValue: 7)!
    let aliasRevision = V2ProfileRevision(rawValue: 3)!
    let groupMemberRevision = V2ProfileRevision(rawValue: 5)!
    let visibilityRevision = V2ProfileRevision(rawValue: 2)!
    let avatar = V2AvatarReference(mediaID: try! MediaID("00000000-0000-0000-0000-000000000004"))

    var identity: V2PublicIdentity {
        try! .init(userID: target, handle: .init("target_user"), displayName: "全局名称", accountKind: .regular)
    }

    var activeProfile: V2ProfileView {
        try! .init(
            userID: target,
            publicIdentity: identity,
            avatar: avatar,
            state: .active,
            revision: profileRevision,
            visibilityRevision: visibilityRevision
        )
    }

    var alias: V2ContactAlias {
        try! .init(ownerUserID: owner, targetUserID: target, remarkName: "工作联系人", revision: aliasRevision)
    }

    var groupMember: V2GroupMemberPresentation {
        try! .init(roomID: room, userID: target, groupNickname: "群内昵称", revision: groupMemberRevision)
    }
}
