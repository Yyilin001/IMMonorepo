import Foundation
import Testing
@testable import IMClientKit

struct IMConversationStoreStateReducerTests {
    @Test func reducerAppliesSummaryEventsWithoutMainActorStore() {
        let firstID = UUID(uuidString: "abababab-abab-abab-abab-abababababab")!
        let secondID = UUID(uuidString: "cdcdcdcd-cdcd-cdcd-cdcd-cdcdcdcdcdcd")!
        let reducer = IMConversationStoreStateReducer()
        var state = IMConversationStoreState(
            conversations: [],
            selectedConversationID: nil,
            statusMessage: "loading",
            conversationSummaryNextCursor: nil,
            hasMoreConversationSummaries: false,
            isLoadingMoreConversationSummaries: true
        )

        let replaceEffect = reducer.reduce(
            .replaceConversationSummaryWindow(
                [
                    Self.makeSummary(id: firstID, title: "First", updatedAt: 20),
                    Self.makeSummary(id: secondID, title: "Second", updatedAt: 10)
                ],
                nextCursor: "cursor-2",
                hasMore: true
            ),
            state: &state,
            replacingSummaryContent: Self.makeConversation(from:existing:),
            summaryContent: Self.makeConversation(from:existing:),
            upsertSummaryContents: Self.upsertSummaries(_:conversations:),
            upsertSummaryContent: Self.upsertSummary(_:conversations:),
            ensureConversationIndex: Self.ensureConversationIndex(for:conversations:)
        )

        #expect(replaceEffect.shouldSortConversations)
        #expect(replaceEffect.removedConversationIDs.isEmpty)
        #expect(state.conversations.map(\.id) == [firstID.uuidString, secondID.uuidString])
        #expect(state.selectedConversationID == firstID.uuidString)
        #expect(state.conversationSummaryNextCursor == "cursor-2")
        #expect(state.hasMoreConversationSummaries)
        #expect(!state.isLoadingMoreConversationSummaries)
        #expect(state.statusMessage == nil)

        let changesEffect = reducer.reduce(
            .applyConversationSummaryChanges(
                upserts: [Self.makeSummary(id: secondID, title: "Second Updated", updatedAt: 30)],
                removedConversationIDs: [firstID]
            ),
            state: &state,
            replacingSummaryContent: Self.makeConversation(from:existing:),
            summaryContent: Self.makeConversation(from:existing:),
            upsertSummaryContents: Self.upsertSummaries(_:conversations:),
            upsertSummaryContent: Self.upsertSummary(_:conversations:),
            ensureConversationIndex: Self.ensureConversationIndex(for:conversations:)
        )

        #expect(changesEffect.removedConversationIDs == [firstID.uuidString])
        #expect(changesEffect.shouldSyncReplyJumpState)
        #expect(changesEffect.shouldSortConversations)
        #expect(state.conversations.map(\.id) == [secondID.uuidString])
        #expect(state.conversations.first?.title == "Second Updated")
        #expect(state.selectedConversationID == secondID.uuidString)
    }

    @Test func reducerAppliesReadStateEventsWithoutMainActorStore() {
        let selectedID = UUID(uuidString: "abababab-abab-abab-abab-abababababab")!
        let backgroundID = UUID(uuidString: "cdcdcdcd-cdcd-cdcd-cdcd-cdcdcdcdcdcd")!
        let reducer = IMConversationStoreStateReducer()
        var state = IMConversationStoreState(
            conversations: [
                Self.makeConversation(from: Self.makeSummary(id: selectedID, title: "Selected", updatedAt: 20), existing: nil),
                Self.makeConversation(from: Self.makeSummary(id: backgroundID, title: "Background", updatedAt: 10), existing: nil)
            ],
            selectedConversationID: selectedID.uuidString,
            statusMessage: nil,
            conversationSummaryNextCursor: nil,
            hasMoreConversationSummaries: false,
            isLoadingMoreConversationSummaries: false
        )

        _ = reducer.reduce(
            .applyRealtimeUnreadIncrement(conversationID: backgroundID.uuidString),
            state: &state,
            replacingSummaryContent: Self.makeConversation(from:existing:),
            summaryContent: Self.makeConversation(from:existing:),
            upsertSummaryContents: Self.upsertSummaries(_:conversations:),
            upsertSummaryContent: Self.upsertSummary(_:conversations:),
            ensureConversationIndex: Self.ensureConversationIndex(for:conversations:)
        )
        #expect(state.conversations.first { $0.id == backgroundID.uuidString }?.localUnreadDelta == 1)

        _ = reducer.reduce(
            .applyRealtimeUnreadIncrement(conversationID: selectedID.uuidString),
            state: &state,
            replacingSummaryContent: Self.makeConversation(from:existing:),
            summaryContent: Self.makeConversation(from:existing:),
            upsertSummaryContents: Self.upsertSummaries(_:conversations:),
            upsertSummaryContent: Self.upsertSummary(_:conversations:),
            ensureConversationIndex: Self.ensureConversationIndex(for:conversations:)
        )
        #expect(state.conversations.first { $0.id == selectedID.uuidString }?.unreadCount == 0)

        _ = reducer.reduce(
            .applyServerReadState(
                conversationID: backgroundID.uuidString,
                lastReadSequence: 9,
                unreadCount: 0
            ),
            state: &state,
            replacingSummaryContent: Self.makeConversation(from:existing:),
            summaryContent: Self.makeConversation(from:existing:),
            upsertSummaryContents: Self.upsertSummaries(_:conversations:),
            upsertSummaryContent: Self.upsertSummary(_:conversations:),
            ensureConversationIndex: Self.ensureConversationIndex(for:conversations:)
        )
        let background = state.conversations.first { $0.id == backgroundID.uuidString }
        #expect(background?.serverLastReadSequence == 9)
        #expect(background?.serverUnreadCount == 0)
        #expect(background?.localUnreadDelta == 0)

        _ = reducer.reduce(
            .markConversationUnread(conversationID: backgroundID.uuidString),
            state: &state,
            replacingSummaryContent: Self.makeConversation(from:existing:),
            summaryContent: Self.makeConversation(from:existing:),
            upsertSummaryContents: Self.upsertSummaries(_:conversations:),
            upsertSummaryContent: Self.upsertSummary(_:conversations:),
            ensureConversationIndex: Self.ensureConversationIndex(for:conversations:)
        )
        #expect(state.conversations.first { $0.id == backgroundID.uuidString }?.localUnreadDelta == 1)

        _ = reducer.reduce(
            .markConversationRead(
                conversationID: backgroundID.uuidString,
                latestLoadedSequence: 12
            ),
            state: &state,
            replacingSummaryContent: Self.makeConversation(from:existing:),
            summaryContent: Self.makeConversation(from:existing:),
            upsertSummaryContents: Self.upsertSummaries(_:conversations:),
            upsertSummaryContent: Self.upsertSummary(_:conversations:),
            ensureConversationIndex: Self.ensureConversationIndex(for:conversations:)
        )
        let readBackground = state.conversations.first { $0.id == backgroundID.uuidString }
        #expect(readBackground?.serverLastReadSequence == 12)
        #expect(readBackground?.unreadCount == 0)
    }

    @Test func reducerAppliesMemberSnapshotWithoutMainActorStore() {
        let conversationID = UUID(uuidString: "eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee")!
        let memberID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
        let reducer = IMConversationStoreStateReducer()
        var state = IMConversationStoreState(
            conversations: [],
            selectedConversationID: nil,
            statusMessage: "loading",
            conversationSummaryNextCursor: nil,
            hasMoreConversationSummaries: false,
            isLoadingMoreConversationSummaries: false
        )

        _ = reducer.reduce(
            .replaceMembers(
                conversationID: conversationID.uuidString,
                members: [
                    IMConversationMember(
                        id: memberID,
                        email: "member@example.com",
                        displayName: "Member",
                        avatarPreset: nil,
                        role: .member,
                        memberNickname: nil,
                        displayTitle: "Member"
                    )
                ]
            ),
            state: &state,
            replacingSummaryContent: Self.makeConversation(from:existing:),
            summaryContent: Self.makeConversation(from:existing:),
            upsertSummaryContents: Self.upsertSummaries(_:conversations:),
            upsertSummaryContent: Self.upsertSummary(_:conversations:),
            ensureConversationIndex: Self.ensureConversationIndex(for:conversations:)
        )

        #expect(state.conversations.map(\.id) == [conversationID.uuidString])
        #expect(state.conversations.first?.members.map(\.email) == ["member@example.com"])
        #expect(state.conversations.first?.memberUserIDs == [memberID])
        #expect(state.conversations.first?.memberCount == 1)
        #expect(state.statusMessage == nil)

        _ = reducer.reduce(
            .applyMemberSnapshot(
                conversationID: conversationID.uuidString,
                members: [],
                total: 8
            ),
            state: &state,
            replacingSummaryContent: Self.makeConversation(from:existing:),
            summaryContent: Self.makeConversation(from:existing:),
            upsertSummaryContents: Self.upsertSummaries(_:conversations:),
            upsertSummaryContent: Self.upsertSummary(_:conversations:),
            ensureConversationIndex: Self.ensureConversationIndex(for:conversations:)
        )

        #expect(state.conversations.first?.members.isEmpty == true)
        #expect(state.conversations.first?.memberCount == 8)
    }

    @Test func reducerUpdatesDraftWithoutMainActorStore() {
        let conversationID = UUID(uuidString: "ffffffff-ffff-ffff-ffff-ffffffffffff")!
        let reducer = IMConversationStoreStateReducer()
        var state = IMConversationStoreState(
            conversations: [
                Self.makeConversation(
                    from: Self.makeSummary(id: conversationID, title: "Draft", updatedAt: 20),
                    existing: nil
                )
            ],
            selectedConversationID: conversationID.uuidString,
            statusMessage: nil,
            conversationSummaryNextCursor: nil,
            hasMoreConversationSummaries: false,
            isLoadingMoreConversationSummaries: false
        )

        _ = reducer.reduce(
            .updateDraft(
                conversationID: conversationID.uuidString,
                text: "Need to send agenda",
                updatedAt: Date(timeIntervalSince1970: 1_700_500_001)
            ),
            state: &state,
            replacingSummaryContent: Self.makeConversation(from:existing:),
            summaryContent: Self.makeConversation(from:existing:),
            upsertSummaryContents: Self.upsertSummaries(_:conversations:),
            upsertSummaryContent: Self.upsertSummary(_:conversations:),
            ensureConversationIndex: Self.ensureConversationIndex(for:conversations:)
        )

        #expect(state.conversations.first?.draftText == "Need to send agenda")
        #expect(state.conversations.first?.draftUpdatedAt == Date(timeIntervalSince1970: 1_700_500_001))

        _ = reducer.reduce(
            .updateDraft(
                conversationID: conversationID.uuidString,
                text: "   ",
                updatedAt: Date(timeIntervalSince1970: 1_700_500_002)
            ),
            state: &state,
            replacingSummaryContent: Self.makeConversation(from:existing:),
            summaryContent: Self.makeConversation(from:existing:),
            upsertSummaryContents: Self.upsertSummaries(_:conversations:),
            upsertSummaryContent: Self.upsertSummary(_:conversations:),
            ensureConversationIndex: Self.ensureConversationIndex(for:conversations:)
        )

        #expect(state.conversations.first?.draftText == "   ")
        #expect(state.conversations.first?.draftUpdatedAt == nil)
    }

    @Test func reducerSetsStatusMessageWithoutMainActorStore() {
        let reducer = IMConversationStoreStateReducer()
        var state = IMConversationStoreState(
            conversations: [],
            selectedConversationID: nil,
            statusMessage: nil,
            conversationSummaryNextCursor: nil,
            hasMoreConversationSummaries: false,
            isLoadingMoreConversationSummaries: false
        )

        _ = reducer.reduce(
            .setStatusMessage("消息内容不能为空。"),
            state: &state,
            replacingSummaryContent: Self.makeConversation(from:existing:),
            summaryContent: Self.makeConversation(from:existing:),
            upsertSummaryContents: Self.upsertSummaries(_:conversations:),
            upsertSummaryContent: Self.upsertSummary(_:conversations:),
            ensureConversationIndex: Self.ensureConversationIndex(for:conversations:)
        )
        #expect(state.statusMessage == "消息内容不能为空。")

        _ = reducer.reduce(
            .setStatusMessage(nil),
            state: &state,
            replacingSummaryContent: Self.makeConversation(from:existing:),
            summaryContent: Self.makeConversation(from:existing:),
            upsertSummaryContents: Self.upsertSummaries(_:conversations:),
            upsertSummaryContent: Self.upsertSummary(_:conversations:),
            ensureConversationIndex: Self.ensureConversationIndex(for:conversations:)
        )
        #expect(state.statusMessage == nil)
    }

    private static func makeSummary(
        id: UUID,
        title: String,
        updatedAt: TimeInterval
    ) -> IMConversationSummaryResponseBody {
        IMConversationSummaryResponseBody(
            id: id,
            title: title,
            kind: IMConversationKind.group.rawValue,
            memberCount: 2,
            memberUserIDs: [
                UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
                UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
            ],
            lastMessage: nil,
            createdAt: Date(timeIntervalSince1970: updatedAt - 1),
            updatedAt: Date(timeIntervalSince1970: updatedAt)
        )
    }

    private static func makeConversation(
        from response: IMConversationSummaryResponseBody,
        existing: IMConversation?
    ) -> IMConversation {
        IMConversation(
            id: response.id.uuidString,
            title: response.title ?? existing?.title ?? response.id.uuidString,
            kind: IMConversationKind(rawValue: response.kind) ?? .group,
            directMessagingState: nil,
            directPeer: nil,
            notice: response.notice,
            avatarPreset: response.avatarPreset,
            muteAll: response.muteAll,
            memberCount: response.memberCount,
            memberUserIDs: response.memberUserIDs,
            members: existing?.members ?? [],
            messages: existing?.messages ?? [],
            lastMessagePreviewText: existing?.lastMessagePreviewText ?? "",
            hasMoreHistory: existing?.hasMoreHistory ?? false,
            serverLastReadSequence: response.lastReadSequence,
            serverUnreadCount: response.unreadCount,
            localUnreadDelta: existing?.localUnreadDelta ?? 0,
            isPinned: response.isPinned,
            pinnedAt: response.pinnedAt,
            isMuted: response.isMuted,
            draftText: existing?.draftText ?? "",
            draftUpdatedAt: existing?.draftUpdatedAt,
            updatedAt: response.updatedAt
        )
    }

    private static func upsertSummaries(
        _ responses: [IMConversationSummaryResponseBody],
        conversations: inout [IMConversation]
    ) {
        for response in responses {
            upsertSummary(response, conversations: &conversations)
        }
    }

    private static func upsertSummary(
        _ response: IMConversationSummaryResponseBody,
        conversations: inout [IMConversation]
    ) {
        let conversation = makeConversation(
            from: response,
            existing: conversations.first { $0.id == response.id.uuidString }
        )
        if let index = conversations.firstIndex(where: { $0.id == response.id.uuidString }) {
            conversations[index] = conversation
        } else {
            conversations.append(conversation)
        }
    }

    private static func ensureConversationIndex(
        for conversationID: String,
        conversations: inout [IMConversation]
    ) -> Int {
        if let index = conversations.firstIndex(where: { $0.id == conversationID }) {
            return index
        }
        conversations.append(
            IMConversation(
                id: conversationID,
                title: conversationID,
                kind: .group,
                directMessagingState: nil,
                directPeer: nil,
                notice: nil,
                avatarPreset: nil,
                memberCount: 0,
                memberUserIDs: [],
                members: [],
                messages: [],
                lastMessagePreviewText: "",
                hasMoreHistory: false,
                serverLastReadSequence: 0,
                serverUnreadCount: 0,
                localUnreadDelta: 0,
                isPinned: false,
                pinnedAt: nil,
                isMuted: false,
                draftText: "",
                draftUpdatedAt: nil,
                updatedAt: .distantPast
            )
        )
        return conversations.count - 1
    }
}
