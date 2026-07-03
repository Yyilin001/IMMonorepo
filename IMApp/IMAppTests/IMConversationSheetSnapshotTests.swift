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

    @Test func conversationMemberEmailDraftNormalizesDelimitedInput() {
        let draft = IMConversationMemberEmailDraft(
            " Alice@Example.COM, \n bob@example.com\n\n,carol@example.com "
        )

        #expect(draft.rawValue.hasPrefix(" Alice"))
        #expect(draft.emails == [
            "alice@example.com",
            "bob@example.com",
            "carol@example.com"
        ])
        #expect(!draft.isEmpty)
        #expect(!draft.hasSingleEmail)
        #expect(IMConversationMemberEmailDraft("   \n,").isEmpty)
        #expect(IMConversationMemberEmailDraft(" single@example.com ").hasSingleEmail)
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

    @Test func manageMembersObservedStateTracksOnlyMemberSnapshotInputs() {
        let memberID = UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!
        let currentUserID = UUID(uuidString: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")!
        let conversation = makeConversation(
            id: "conversation",
            title: "Original Title",
            memberCount: 1,
            members: [
                makeMember(id: memberID, email: "member@example.com", role: .member, displayTitle: "Member")
            ],
            lastMessagePreviewText: "preview",
            updatedAt: Date(timeIntervalSince1970: 10)
        )
        let renamedConversation = makeConversation(
            id: "conversation",
            title: "Renamed Title",
            memberCount: 1,
            members: [
                makeMember(id: memberID, email: "member@example.com", role: .member, displayTitle: "Member")
            ],
            lastMessagePreviewText: "changed preview",
            updatedAt: Date(timeIntervalSince1970: 20)
        )
        let pageState = IMConversationMemberPageState(
            items: [
                makeMember(id: memberID, email: "member@example.com", role: .member, displayTitle: "Member")
            ],
            query: "mem",
            total: 1,
            isLoading: false
        )
        let baseline = IMManageMembersObservedState(
            conversationID: "conversation",
            conversation: IMManageMembersConversationSignature(conversation: conversation),
            pageState: pageState,
            currentUserID: currentUserID,
            visibleQuery: " mem "
        )

        #expect(
            baseline == IMManageMembersObservedState(
                conversationID: "conversation",
                conversation: IMManageMembersConversationSignature(conversation: renamedConversation),
                pageState: pageState,
                currentUserID: currentUserID,
                visibleQuery: "mem"
            )
        )

        let changedPageState = IMConversationMemberPageState(
            items: [
                makeMember(id: memberID, email: "member@example.com", role: .admin, displayTitle: "Member")
            ],
            query: "mem",
            total: 1,
            isLoading: false
        )
        #expect(
            baseline != IMManageMembersObservedState(
                conversationID: "conversation",
                conversation: IMManageMembersConversationSignature(conversation: conversation),
                pageState: changedPageState,
                currentUserID: currentUserID,
                visibleQuery: "mem"
            )
        )
        #expect(
            baseline != IMManageMembersObservedState(
                conversationID: "conversation",
                conversation: IMManageMembersConversationSignature(conversation: conversation),
                pageState: pageState,
                currentUserID: memberID,
                visibleQuery: "mem"
            )
        )
        #expect(
            baseline != IMManageMembersObservedState(
                conversationID: "conversation",
                conversation: IMManageMembersConversationSignature(conversation: conversation),
                pageState: pageState,
                currentUserID: currentUserID,
                visibleQuery: "admin"
            )
        )
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

    @Test func favoriteMessageSnapshotCanReplaceTitleWithoutChangingMessageProjection() {
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

        let snapshot = IMFavoriteMessageSnapshot(message: message, title: "Old Chat")
        let retitled = snapshot.replacingTitle(" New Chat ")

        #expect(retitled.id == snapshot.id)
        #expect(retitled.conversationID == snapshot.conversationID)
        #expect(retitled.messageID == snapshot.messageID)
        #expect(retitled.title == "New Chat")
        #expect(retitled.iconName == snapshot.iconName)
        #expect(retitled.previewText == snapshot.previewText)
        #expect(retitled.createdAtText == snapshot.createdAtText)
        #expect(snapshot.replacingTitle(" ").title == "会话")
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

    @Test func conversationTitleSnapshotBuilderCanProjectOnlyRequestedTitles() {
        let includedID = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
        let excludedID = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"

        let titles = IMConversationTitleSnapshotBuilder().build(
            conversations: [
                makeConversation(
                    id: includedID,
                    title: " Included ",
                    memberCount: 2,
                    lastMessagePreviewText: "",
                    updatedAt: Date(timeIntervalSince1970: 10)
                ),
                makeConversation(
                    id: excludedID,
                    title: "Excluded",
                    memberCount: 3,
                    lastMessagePreviewText: "",
                    updatedAt: Date(timeIntervalSince1970: 20)
                )
            ],
            including: [includedID]
        )

        #expect(titles == [includedID: "Included"])
    }

    @Test func conversationTitleSnapshotBuilderSkipsEmptyRequestedTitleSet() {
        let titles = IMConversationTitleSnapshotBuilder().build(
            conversations: [
                makeConversation(
                    id: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
                    title: "Excluded",
                    memberCount: 2,
                    lastMessagePreviewText: "",
                    updatedAt: Date(timeIntervalSince1970: 10)
                )
            ],
            including: []
        )

        #expect(titles.isEmpty)
    }

    @Test func conversationTitleObservedStateTracksOnlyRequestedProjectedTitles() {
        let requestedID = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
        let unrelatedID = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
        let memberID = UUID(uuidString: "cccccccc-cccc-cccc-cccc-cccccccccccc")!
        let requested = makeConversation(
            id: requestedID,
            title: " Requested ",
            memberCount: 2,
            lastMessagePreviewText: "requested preview",
            updatedAt: Date(timeIntervalSince1970: 10)
        )
        let unrelated = makeConversation(
            id: unrelatedID,
            title: "Unrelated",
            memberCount: 3,
            lastMessagePreviewText: "unrelated preview",
            updatedAt: Date(timeIntervalSince1970: 20)
        )

        let baseline = IMConversationTitleObservedState(
            conversations: [requested, unrelated],
            including: [requestedID]
        )

        var changedUnrelated = unrelated
        changedUnrelated.title = "Changed Unrelated"
        changedUnrelated.updatedAt = Date(timeIntervalSince1970: 900)

        var changedRequestedUnrenderedFields = requested
        changedRequestedUnrenderedFields.members = [
            makeMember(
                id: memberID,
                email: "member@example.com",
                role: .member,
                displayTitle: "Member"
            )
        ]
        changedRequestedUnrenderedFields.lastMessagePreviewText = "changed preview"
        changedRequestedUnrenderedFields.updatedAt = Date(timeIntervalSince1970: 800)

        #expect(
            baseline == IMConversationTitleObservedState(
                conversations: [changedRequestedUnrenderedFields, changedUnrelated],
                including: [requestedID]
            )
        )

        var changedRequestedTitle = requested
        changedRequestedTitle.title = "Changed Requested"
        #expect(
            baseline != IMConversationTitleObservedState(
                conversations: [changedRequestedTitle, unrelated],
                including: [requestedID]
            )
        )

        #expect(
            baseline != IMConversationTitleObservedState(
                conversations: [requested, unrelated],
                including: [requestedID, unrelatedID]
            )
        )
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

    @Test func forwardCandidateObservedStateIgnoresNonCandidateDisplayChanges() {
        let sourceID = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
        let candidateID = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
        let memberID = UUID(uuidString: "cccccccc-cccc-cccc-cccc-cccccccccccc")!
        let source = makeConversation(
            id: sourceID,
            title: "Source",
            memberCount: 2,
            lastMessagePreviewText: "source preview",
            updatedAt: Date(timeIntervalSince1970: 100)
        )
        let candidate = makeConversation(
            id: candidateID,
            title: " Candidate ",
            memberCount: 3,
            lastMessagePreviewText: " preview ",
            updatedAt: Date(timeIntervalSince1970: 200)
        )

        let baseline = IMForwardConversationCandidateObservedState(
            conversations: [source, candidate],
            excluding: sourceID
        )

        var changedSource = source
        changedSource.title = "Changed Source"
        changedSource.lastMessagePreviewText = "changed source preview"
        changedSource.updatedAt = Date(timeIntervalSince1970: 900)

        var changedUnrenderedCandidateFields = candidate
        changedUnrenderedCandidateFields.members = [
            makeMember(
                id: memberID,
                email: "member@example.com",
                role: .member,
                displayTitle: "Member"
            )
        ]
        changedUnrenderedCandidateFields.serverUnreadCount = 12
        changedUnrenderedCandidateFields.draftText = "draft"

        #expect(
            baseline == IMForwardConversationCandidateObservedState(
                conversations: [changedSource, changedUnrenderedCandidateFields],
                excluding: sourceID
            )
        )

        var changedPreview = candidate
        changedPreview.lastMessagePreviewText = "changed preview"
        #expect(
            baseline != IMForwardConversationCandidateObservedState(
                conversations: [source, changedPreview],
                excluding: sourceID
            )
        )

        var changedSortDate = candidate
        changedSortDate.updatedAt = Date(timeIntervalSince1970: 300)
        #expect(
            baseline != IMForwardConversationCandidateObservedState(
                conversations: [source, changedSortDate],
                excluding: sourceID
            )
        )
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
