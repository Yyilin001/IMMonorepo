import Foundation
@testable import IMClientKit
import Testing
@testable import IMApp

struct IMConversationSheetSnapshotTests {
    @Test func conversationStatusSnapshotTrimsEmptyMessages() {
        #expect(IMConversationStatusSnapshot(message: nil).message == nil)
        #expect(IMConversationStatusSnapshot(message: "   \n").message == nil)
        #expect(IMConversationStatusSnapshot(message: " 同步失败 ").message == "同步失败")
    }

    @Test func manageMembersSnapshotProjectsOwnerActionsFromVisiblePageState() throws {
        let ownerID = UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!
        let adminID = UUID(uuidString: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")!
        let memberID = UUID(uuidString: "cccccccc-cccc-cccc-cccc-cccccccccccc")!
        let builder = IMManageMembersSnapshotBuilder()
        let conversation = makeConversation(
            id: "conversation",
            title: "Group",
            memberCount: 3,
            members: [
                makeMember(id: ownerID, email: "owner@example.com", role: .owner, displayTitle: "Owner"),
                makeMember(id: adminID, email: "admin@example.com", role: .admin, displayTitle: "Admin"),
                makeMember(id: memberID, email: "member@example.com", role: .member, displayTitle: "Member")
            ],
            lastMessagePreviewText: "",
            updatedAt: Date(timeIntervalSince1970: 10)
        )

        let snapshot = builder.build(
            conversation: conversation,
            pageState: IMConversationMemberPageState(
                items: [
                    makeMember(id: ownerID, email: "owner@example.com", role: .owner, displayTitle: "Owner"),
                    makeMember(id: adminID, email: "admin@example.com", role: .admin, displayTitle: "Admin"),
                    makeMember(id: memberID, email: "member@example.com", role: .member, displayTitle: "Member")
                ],
                query: "mem",
                nextCursor: "next",
                total: 10,
                isLoading: false,
                isLoadingMore: true
            ),
            currentUserID: ownerID,
            visibleQuery: " mem "
        )

        #expect(snapshot.hasConversation)
        #expect(snapshot.loadedMemberCount == 3)
        #expect(snapshot.memberTotal == 10)
        #expect(snapshot.canLoadMore)
        #expect(snapshot.isLoadingMore)

        let ownerRow = try #require(snapshot.rows.first { $0.id == ownerID })
        let adminRow = try #require(snapshot.rows.first { $0.id == adminID })
        let memberRow = try #require(snapshot.rows.first { $0.id == memberID })

        #expect(ownerRow.isCurrentUser)
        #expect(ownerRow.roleEmailText == "群主 · owner@example.com")
        #expect(ownerRow.actions.isEmpty)
        #expect(adminRow.actions.map(\.kind) == [
            .demoteAdmin(memberID: adminID),
            .transferOwner(memberID: adminID),
            .removeMember(memberID: adminID)
        ])
        #expect(memberRow.actions.map(\.kind) == [
            .promoteAdmin(memberID: memberID),
            .transferOwner(memberID: memberID),
            .removeMember(memberID: memberID)
        ])
        #expect(memberRow.actions.last?.isDestructive == true)
    }

    @Test func manageMembersSnapshotLimitsAdminActionsAndFallsBackWhenQueryDiffers() throws {
        let ownerID = UUID(uuidString: "dddddddd-dddd-dddd-dddd-dddddddddddd")!
        let adminID = UUID(uuidString: "eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee")!
        let memberID = UUID(uuidString: "ffffffff-ffff-ffff-ffff-ffffffffffff")!
        let pageOnlyID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let builder = IMManageMembersSnapshotBuilder()
        let conversation = makeConversation(
            id: "conversation",
            title: "Group",
            memberCount: 3,
            members: [
                makeMember(id: ownerID, email: "owner@example.com", role: .owner, displayTitle: "Owner"),
                makeMember(id: adminID, email: "admin@example.com", role: .admin, displayTitle: "Admin"),
                makeMember(id: memberID, email: "member@example.com", role: .member, displayTitle: "Member")
            ],
            lastMessagePreviewText: "",
            updatedAt: Date(timeIntervalSince1970: 10)
        )

        let snapshot = builder.build(
            conversation: conversation,
            pageState: IMConversationMemberPageState(
                items: [
                    makeMember(id: pageOnlyID, email: "page@example.com", role: .member, displayTitle: "Page Only")
                ],
                query: "server-query",
                total: 0,
                isLoading: true
            ),
            currentUserID: adminID,
            visibleQuery: "local-query"
        )

        #expect(snapshot.rows.map(\.id) == [ownerID, adminID, memberID])
        #expect(snapshot.memberTotal == 3)
        #expect(snapshot.isLoading)

        let ownerRow = try #require(snapshot.rows.first { $0.id == ownerID })
        let adminRow = try #require(snapshot.rows.first { $0.id == adminID })
        let memberRow = try #require(snapshot.rows.first { $0.id == memberID })

        #expect(ownerRow.actions.isEmpty)
        #expect(adminRow.isCurrentUser)
        #expect(adminRow.actions.isEmpty)
        #expect(memberRow.actions.map(\.kind) == [.removeMember(memberID: memberID)])
        #expect(memberRow.actions.first?.failureMessage == "移除成员失败。")
    }

    @Test func manageMembersSnapshotRepresentsMissingConversation() {
        let snapshot = IMManageMembersSnapshotBuilder().build(
            conversation: nil,
            pageState: IMConversationMemberPageState(isLoading: true),
            currentUserID: nil,
            visibleQuery: ""
        )

        #expect(!snapshot.hasConversation)
        #expect(snapshot.rows.isEmpty)
        #expect(snapshot.loadedMemberCount == 0)
        #expect(snapshot.memberTotal == 0)
        #expect(snapshot.isLoading)
    }

    @Test func groupInviteRowSnapshotProjectsInviteForRendering() {
        let activeInvite = IMGroupInviteResponseBody(
            token: "active-token",
            conversationID: UUID(uuidString: "44444444-4444-4444-4444-444444444444")!,
            inviteURL: "https://example.com/invites/active-token",
            expiresAt: Date(timeIntervalSince1970: 1_000),
            revokedAt: nil,
            useCount: 3
        )
        let revokedInvite = IMGroupInviteResponseBody(
            token: "revoked-token",
            conversationID: UUID(uuidString: "55555555-5555-5555-5555-555555555555")!,
            inviteURL: "https://example.com/invites/revoked-token",
            expiresAt: Date(timeIntervalSince1970: 2_000),
            revokedAt: Date(timeIntervalSince1970: 1_500),
            useCount: 7
        )

        let activeSnapshot = IMGroupInviteRowSnapshot(invite: activeInvite)
        let revokedSnapshot = IMGroupInviteRowSnapshot(invite: revokedInvite)

        #expect(activeSnapshot.id == "active-token")
        #expect(activeSnapshot.token == "active-token")
        #expect(activeSnapshot.inviteURL == "https://example.com/invites/active-token")
        #expect(activeSnapshot.statusText == "可用邀请")
        #expect(activeSnapshot.expirationSummaryText.hasPrefix("使用 3 次 · "))
        #expect(activeSnapshot.expirationSummaryText.hasSuffix(" 过期"))
        #expect(activeSnapshot.canRevoke)

        #expect(revokedSnapshot.statusText == "已撤销")
        #expect(!revokedSnapshot.canRevoke)
        #expect(revokedSnapshot.expirationSummaryText.hasPrefix("使用 7 次 · "))
    }

    @Test func favoriteMessageSnapshotProjectsMessageForRendering() {
        let messageID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let conversationID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let message = IMConversationMessageResponseBody(
            id: messageID,
            conversationID: conversationID,
            senderUserID: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!,
            serverSequence: 9,
            timelineSequence: 11,
            content: .richText(.plain("favorite text")),
            createdAt: nil
        )

        let snapshot = IMFavoriteMessageSnapshot(message: message, title: " Projected Chat ")

        #expect(snapshot.id == messageID.uuidString)
        #expect(snapshot.conversationID == conversationID.uuidString)
        #expect(snapshot.messageID == messageID.uuidString)
        #expect(snapshot.title == "Projected Chat")
        #expect(snapshot.iconName == "text.bubble")
        #expect(snapshot.previewText == "favorite text")
        #expect(snapshot.createdAtText == "时间未知")
    }

    @Test func conversationTitleSnapshotBuilderProjectsStableTitleMap() {
        let firstID = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
        let secondID = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"

        let titles = IMConversationTitleSnapshotBuilder().build(
            conversations: [
                makeConversation(
                    id: firstID,
                    title: " Projected Title ",
                    memberCount: 2,
                    lastMessagePreviewText: "",
                    updatedAt: Date(timeIntervalSince1970: 10)
                ),
                makeConversation(
                    id: secondID,
                    title: "   ",
                    memberCount: 3,
                    lastMessagePreviewText: "",
                    updatedAt: Date(timeIntervalSince1970: 20)
                )
            ]
        )

        #expect(titles[firstID] == "Projected Title")
        #expect(titles[secondID] == "会话")
    }

    @Test func forwardCandidateBuilderProjectsAndSortsConversations() {
        let sourceID = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
        let olderID = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
        let newestID = "cccccccc-cccc-cccc-cccc-cccccccccccc"
        let sameTimeID = "dddddddd-dddd-dddd-dddd-dddddddddddd"
        let sameTimeBeforeID = "11111111-1111-1111-1111-111111111111"
        let builder = IMForwardConversationCandidateSnapshotBuilder()

        let snapshots = builder.build(
            conversations: [
                makeConversation(
                    id: olderID,
                    title: " Older ",
                    memberCount: 3,
                    lastMessagePreviewText: "old preview",
                    updatedAt: Date(timeIntervalSince1970: 100)
                ),
                makeConversation(
                    id: sourceID,
                    title: "Source",
                    memberCount: 2,
                    lastMessagePreviewText: "source preview",
                    updatedAt: Date(timeIntervalSince1970: 400)
                ),
                makeConversation(
                    id: sameTimeID,
                    title: "Later ID",
                    memberCount: 5,
                    lastMessagePreviewText: "",
                    updatedAt: Date(timeIntervalSince1970: 300)
                ),
                makeConversation(
                    id: newestID,
                    title: "",
                    memberCount: 4,
                    lastMessagePreviewText: " newest preview ",
                    updatedAt: Date(timeIntervalSince1970: 500)
                ),
                makeConversation(
                    id: sameTimeBeforeID,
                    title: "Before ID",
                    memberCount: 6,
                    lastMessagePreviewText: "",
                    updatedAt: Date(timeIntervalSince1970: 300)
                )
            ],
            excluding: sourceID
        )

        #expect(snapshots.map(\.id) == [newestID, sameTimeBeforeID, sameTimeID, olderID])
        #expect(snapshots[0].title == "会话")
        #expect(snapshots[0].previewText == "newest preview")
        #expect(snapshots[1].title == "Before ID")
        #expect(snapshots[1].previewText == "6 位成员")
        #expect(snapshots[2].previewText == "5 位成员")
        #expect(snapshots[3].title == "Older")
        #expect(snapshots[3].previewText == "old preview")
    }

    private func makeConversation(
        id: String,
        title: String,
        memberCount: Int,
        members: [IMConversationMember] = [],
        lastMessagePreviewText: String,
        updatedAt: Date
    ) -> IMConversation {
        IMConversation(
            id: id,
            title: title,
            kind: .group,
            memberCount: memberCount,
            memberUserIDs: [],
            members: members,
            messages: [],
            lastMessagePreviewText: lastMessagePreviewText,
            hasMoreHistory: false,
            serverLastReadSequence: 0,
            serverUnreadCount: 0,
            localUnreadDelta: 0,
            updatedAt: updatedAt
        )
    }

    private func makeMember(
        id: UUID,
        email: String,
        role: IMConversationMemberRole,
        displayTitle: String
    ) -> IMConversationMember {
        IMConversationMember(
            id: id,
            email: email,
            role: role,
            displayTitle: displayTitle
        )
    }
}
