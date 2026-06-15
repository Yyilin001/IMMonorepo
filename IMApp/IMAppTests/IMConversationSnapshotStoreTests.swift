import Foundation
@testable import IMClientKit
import Testing
@testable import IMApp

@MainActor
struct IMConversationSnapshotStoreTests {
    private let currentUserID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private let peerUserID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!

    @Test func snapshotEngineCommitsListSnapshotAndBuffersNewestEvent() async throws {
        let initialSnapshot = IMConversationListSnapshot(
            generation: 0,
            filter: .all,
            rows: []
        )
        let engine = IMConversationSnapshotEngine(initialListSnapshot: initialSnapshot)
        let stream = await engine.listSnapshotEvents()
        var events = stream.makeAsyncIterator()

        #expect(await engine.currentListSnapshot() == initialSnapshot)
        #expect(await engine.currentListCommitRevision() == 0)

        let initialEvent = try #require(await events.next())
        #expect(initialEvent.snapshot == initialSnapshot)
        #expect(initialEvent.revision == 0)

        let repeatedCommit = await engine.commitListSnapshot(initialSnapshot)
        #expect(!repeatedCommit.didCommit)
        #expect(repeatedCommit.revision == 0)

        let firstSnapshot = IMConversationListSnapshot(
            generation: 1,
            filter: .groups,
            rows: []
        )
        let firstCommit = await engine.commitListSnapshot(firstSnapshot)
        #expect(firstCommit.didCommit)
        #expect(firstCommit.revision == 1)

        let secondSnapshot = IMConversationListSnapshot(
            generation: 2,
            filter: .unread,
            rows: []
        )
        let secondCommit = await engine.commitListSnapshot(secondSnapshot)
        #expect(secondCommit.didCommit)
        #expect(secondCommit.revision == 2)
        #expect(await engine.currentListSnapshot() == secondSnapshot)
        #expect(await engine.currentListCommitRevision() == 2)

        let latestEvent = try #require(await events.next())
        #expect(latestEvent.snapshot == secondSnapshot)
        #expect(latestEvent.revision == 2)
    }

    @Test func snapshotEngineCommitsChatPageSnapshotAndBuffersNewestEvent() async throws {
        let conversationID = UUID(uuidString: "abababab-abab-abab-abab-abababababab")!.uuidString
        let initialListSnapshot = IMConversationListSnapshot(
            generation: 0,
            filter: .all,
            rows: []
        )
        let initialChatSnapshot = makeEmptyChatPageSnapshot(
            conversationID: conversationID,
            generation: 0
        )
        let engine = IMConversationSnapshotEngine(initialListSnapshot: initialListSnapshot)
        let stream = await engine.chatPageSnapshotEvents(
            for: conversationID,
            defaultSnapshot: initialChatSnapshot
        )
        var events = stream.makeAsyncIterator()

        #expect(
            await engine.currentChatPageSnapshot(
                for: conversationID,
                defaultSnapshot: initialChatSnapshot
            ) == initialChatSnapshot
        )
        #expect(await engine.currentChatPageCommitRevision(for: conversationID) == 0)

        let initialEvent = try #require(await events.next())
        #expect(initialEvent.conversationID == conversationID)
        #expect(initialEvent.snapshot == initialChatSnapshot)
        #expect(initialEvent.revision == 0)

        let repeatedCommit = await engine.commitChatPageSnapshot(
            initialChatSnapshot,
            conversationID: conversationID
        )
        #expect(repeatedCommit.didCommit)
        #expect(repeatedCommit.revision == 1)

        let sameSnapshotCommit = await engine.commitChatPageSnapshot(
            initialChatSnapshot,
            conversationID: conversationID
        )
        #expect(!sameSnapshotCommit.didCommit)
        #expect(sameSnapshotCommit.revision == 1)

        let firstSnapshot = makeEmptyChatPageSnapshot(
            conversationID: conversationID,
            generation: 1
        )
        let firstCommit = await engine.commitChatPageSnapshot(
            firstSnapshot,
            conversationID: conversationID
        )
        #expect(firstCommit.didCommit)
        #expect(firstCommit.revision == 2)

        let secondSnapshot = makeEmptyChatPageSnapshot(
            conversationID: conversationID,
            generation: 2
        )
        let secondCommit = await engine.commitChatPageSnapshot(
            secondSnapshot,
            conversationID: conversationID
        )
        #expect(secondCommit.didCommit)
        #expect(secondCommit.revision == 3)
        #expect(
            await engine.currentChatPageSnapshot(
                for: conversationID,
                defaultSnapshot: initialChatSnapshot
            ) == secondSnapshot
        )
        #expect(await engine.currentChatPageCommitRevision(for: conversationID) == 3)

        let latestEvent = try #require(await events.next())
        #expect(latestEvent.conversationID == conversationID)
        #expect(latestEvent.snapshot == secondSnapshot)
        #expect(latestEvent.revision == 3)
    }

    @Test func snapshotEngineBuildsAndCommitsListSnapshotFromCapturedState() async throws {
        let conversationID = UUID(uuidString: "babababa-baba-baba-baba-babababababa")!
        let conversationStore = IMConversationStore()
        conversationStore.replaceConversationSummaries([
            makeSummary(
                id: conversationID,
                title: "Actor Built Room",
                kind: .group,
                unreadCount: 5
            )
        ])

        let state = IMConversationSnapshotBuildState(conversationStore: conversationStore)
        let engine = IMConversationSnapshotEngine(
            initialListSnapshot: IMConversationListSnapshot(
                generation: 0,
                filter: .all,
                rows: []
            )
        )
        let result = await engine.buildAndCommitListSnapshot(
            state: state,
            request: IMConversationListSnapshotBuildRequest(
                filter: .all,
                identityPresentationsByConversationID: [
                    conversationID.uuidString: IMConversationIdentityPresentation(
                        title: "Projected Actor Built Room",
                        detailSummary: "",
                        rowSecondaryLabel: "actor"
                    )
                ]
            )
        )

        #expect(result.commit.didCommit)
        #expect(result.commit.revision == 1)
        #expect(result.snapshot.generation == state.conversationMutationGeneration)
        let row = try #require(result.snapshot.rows.first)
        #expect(row.id == conversationID.uuidString)
        #expect(row.title == "Projected Actor Built Room")
        #expect(row.rowSecondaryLabel == "actor")
        #expect(row.unreadCount == 5)
        #expect(await engine.currentListSnapshot() == result.snapshot)
    }

    @Test func snapshotEngineBuildsAndCommitsChatPageSnapshotFromCapturedState() async throws {
        let conversationID = UUID(uuidString: "cdcdcdcd-cdcd-cdcd-cdcd-cdcdcdcdcdcd")!
        let conversationStore = IMConversationStore()
        conversationStore.replaceConversationSummaries([
            makeSummary(
                id: conversationID,
                title: "Actor Chat",
                kind: .direct,
                unreadCount: 0
            )
        ])
        conversationStore.setLoadingMessages(true)
        conversationStore.queueOutgoingText(
            "queued",
            conversationID: conversationID.uuidString,
            senderUserID: currentUserID
        )

        let state = IMConversationSnapshotBuildState(conversationStore: conversationStore)
        let engine = IMConversationSnapshotEngine(
            initialListSnapshot: IMConversationListSnapshot(
                generation: 0,
                filter: .all,
                rows: []
            )
        )
        let result = await engine.buildAndCommitChatPageSnapshot(
            state: state,
            request: IMChatPageSnapshotCommitRequest(
                conversationID: conversationID.uuidString,
                currentUserID: currentUserID,
                blockedUserIDs: []
            )
        )

        #expect(result.commit.didCommit)
        #expect(result.commit.revision == 1)
        #expect(result.snapshot.metadata.title == "Actor Chat")
        #expect(result.snapshot.isLoadingMessages)
        #expect(!result.snapshot.shouldShowLoadingState)
        #expect(result.snapshot.queueSummary.queuedCount == 1)
        #expect(result.snapshot.latestTimelineItemIsCurrentUserOutgoing)
        #expect(result.snapshot.timelineRows.count == 1)
        #expect(
            await engine.currentChatPageSnapshot(
                for: conversationID.uuidString,
                defaultSnapshot: makeEmptyChatPageSnapshot(
                    conversationID: conversationID.uuidString,
                    generation: 0
                )
            ) == result.snapshot
        )
    }

    @Test func snapshotEngineBuildsChatPageSnapshotFromActorOwnedConversationState() async throws {
        let conversationID = UUID(uuidString: "cececece-cece-cece-cece-cececececece")!
        let conversationStore = IMConversationStore()
        conversationStore.replaceConversationSummaries([
            makeSummary(
                id: conversationID,
                title: "Actor Owned State",
                kind: .direct,
                unreadCount: 0
            )
        ])
        conversationStore.setLoadingMessages(true)
        conversationStore.setStatusMessage("聊天页状态提示")

        let state = IMConversationSnapshotBuildState(conversationStore: conversationStore)
        let engine = IMConversationSnapshotEngine(
            initialListSnapshot: IMConversationListSnapshot(
                generation: 0,
                filter: .all,
                rows: []
            )
        )
        await engine.reduceState(.replaceConversationState(state))

        let result = await engine.buildAndCommitChatPageSnapshot(
            request: IMChatPageSnapshotCommitRequest(
                conversationID: conversationID.uuidString,
                currentUserID: currentUserID,
                blockedUserIDs: []
            )
        )

        #expect(await engine.currentConversationState() == state)
        #expect(result.commit.didCommit)
        #expect(result.snapshot.metadata.title == "Actor Owned State")
        #expect(result.snapshot.statusMessage == "聊天页状态提示")
        #expect(result.snapshot.isLoadingMessages)
        #expect(result.snapshot.generation == state.conversationMutationGeneration)
    }

    @Test func snapshotEngineBuildsAndCommitsSnapshotBatchFromCapturedState() async throws {
        let firstConversationID = UUID(uuidString: "d1d1d1d1-d1d1-d1d1-d1d1-d1d1d1d1d1d1")!
        let secondConversationID = UUID(uuidString: "d2d2d2d2-d2d2-d2d2-d2d2-d2d2d2d2d2d2")!
        let conversationStore = IMConversationStore()
        conversationStore.replaceConversationSummaries([
            makeSummary(
                id: firstConversationID,
                title: "Actor Batch One",
                kind: .group,
                unreadCount: 2
            ),
            makeSummary(
                id: secondConversationID,
                title: "Actor Batch Two",
                kind: .direct,
                unreadCount: 0
            )
        ])
        conversationStore.setLoadingMessages(true)

        let state = IMConversationSnapshotBuildState(conversationStore: conversationStore)
        let engine = IMConversationSnapshotEngine(
            initialListSnapshot: IMConversationListSnapshot(
                generation: 0,
                filter: .all,
                rows: []
            )
        )
        let result = await engine.buildAndCommitSnapshotBatch(
            state: state,
            list: IMConversationListSnapshotBuildRequest(
                filter: .all,
                identityPresentationsByConversationID: [
                    firstConversationID.uuidString: IMConversationIdentityPresentation(
                        title: "Projected Actor Batch One",
                        detailSummary: "",
                        rowSecondaryLabel: "batch"
                    ),
                    secondConversationID.uuidString: IMConversationIdentityPresentation(
                        title: "Projected Actor Batch Two",
                        detailSummary: "",
                        rowSecondaryLabel: "batch"
                    )
                ]
            ),
            chatPages: [
                IMChatPageSnapshotCommitRequest(
                    conversationID: firstConversationID.uuidString,
                    currentUserID: currentUserID,
                    blockedUserIDs: []
                ),
                IMChatPageSnapshotCommitRequest(
                    conversationID: secondConversationID.uuidString,
                    currentUserID: currentUserID,
                    blockedUserIDs: []
                )
            ]
        )

        #expect(result.commit.didCommit)
        #expect(result.commit.list?.revision == 1)
        #expect(result.commit.chatPages[firstConversationID.uuidString]?.revision == 1)
        #expect(result.commit.chatPages[secondConversationID.uuidString]?.revision == 1)
        let listSnapshot = try #require(result.listSnapshot)
        let firstChatSnapshot = try #require(result.chatPageSnapshots[firstConversationID.uuidString])
        let secondChatSnapshot = try #require(result.chatPageSnapshots[secondConversationID.uuidString])
        #expect(listSnapshot.rows.map(\.title) == [
            "Projected Actor Batch One",
            "Projected Actor Batch Two"
        ])
        #expect(firstChatSnapshot.metadata.title == "Actor Batch One")
        #expect(secondChatSnapshot.metadata.title == "Actor Batch Two")
        #expect(await engine.currentListSnapshot() == listSnapshot)
        #expect(
            await engine.currentChatPageSnapshot(
                for: firstConversationID.uuidString,
                defaultSnapshot: makeEmptyChatPageSnapshot(
                    conversationID: firstConversationID.uuidString,
                    generation: 0
                )
            ) == firstChatSnapshot
        )
    }

    @Test func listSnapshotRefreshCommitsCurrentStoreState() async throws {
        let conversationID = UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!
        let conversationStore = IMConversationStore()
        let snapshotStore = IMConversationSnapshotStore()

        conversationStore.replaceConversationSummaries([
            makeSummary(
                id: conversationID,
                title: "Project Room",
                kind: .group,
                unreadCount: 2
            )
        ])

        let initialCommit = await snapshotStore.commitListSnapshot(
            from: conversationStore,
            filter: .all,
            identityForConversation: { conversation in
                IMConversationIdentityPresentation(
                    title: "Projected \(conversation.title)",
                    detailSummary: "",
                    rowSecondaryLabel: nil
                )
            }
        )
        #expect(initialCommit.didCommit)
        #expect(initialCommit.revision == 1)
        let committedEvent = await snapshotStore.currentListSnapshotEvent()
        #expect(committedEvent.revision == 1)

        let row = try #require(committedEvent.snapshot.rows.first)
        #expect(row.id == conversationID.uuidString)
        #expect(row.title == "Projected Project Room")
        #expect(row.unreadCount == 2)

        let repeatedCommit = await snapshotStore.commitListSnapshot(
            from: conversationStore,
            filter: .all,
            identityForConversation: { conversation in
                IMConversationIdentityPresentation(
                    title: "Projected \(conversation.title)",
                    detailSummary: "",
                    rowSecondaryLabel: nil
                )
            }
        )
        #expect(!repeatedCommit.didCommit)
        #expect(repeatedCommit.revision == 1)
        #expect(await snapshotStore.currentListSnapshotEvent().revision == 1)

        conversationStore.setConversationSearchText("missing")

        #expect(await snapshotStore.currentListSnapshotEvent().snapshot.rows.map(\.id) == [conversationID.uuidString])

        let filteredCommit = await snapshotStore.commitListSnapshot(
            from: conversationStore,
            filter: .all,
            identityForConversation: { conversation in
                IMConversationIdentityPresentation(
                    title: conversation.title,
                    detailSummary: "",
                    rowSecondaryLabel: nil
                )
            }
        )
        #expect(filteredCommit.didCommit)
        #expect(filteredCommit.revision == 2)
        let filteredEvent = await snapshotStore.currentListSnapshotEvent()
        #expect(filteredEvent.revision == 2)

        #expect(filteredEvent.snapshot.rows.isEmpty)
    }

    @Test func chatSnapshotRefreshCommitsLoadingAndQueueState() async {
        let conversationID = UUID(uuidString: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")!
        let conversationStore = IMConversationStore()
        let snapshotStore = IMConversationSnapshotStore()

        conversationStore.replaceConversationSummaries([
            makeSummary(
                id: conversationID,
                title: "Direct",
                kind: .direct,
                unreadCount: 0
            )
        ])
        conversationStore.setLoadingMessages(true)

        let initialCommit = await snapshotStore.commitChatPageSnapshot(
            from: conversationStore,
            conversationID: conversationID.uuidString,
            currentUserID: currentUserID,
            blockedUserIDs: []
        )
        #expect(initialCommit.didCommit)
        #expect(initialCommit.revision == 1)
        let initialEvent = await snapshotStore.currentChatPageSnapshotEvent(for: conversationID.uuidString)
        #expect(initialEvent.revision == 1)

        #expect(initialEvent.snapshot.shouldShowLoadingState)

        let repeatedCommit = await snapshotStore.commitChatPageSnapshot(
            from: conversationStore,
            conversationID: conversationID.uuidString,
            currentUserID: currentUserID,
            blockedUserIDs: []
        )
        #expect(!repeatedCommit.didCommit)
        #expect(repeatedCommit.revision == 1)
        #expect(await snapshotStore.currentChatPageSnapshotEvent(for: conversationID.uuidString).revision == 1)

        conversationStore.setLoadingMessages(false)
        conversationStore.queueOutgoingText(
            "queued",
            conversationID: conversationID.uuidString,
            senderUserID: currentUserID
        )

        let staleSnapshot = await snapshotStore.currentChatPageSnapshotEvent(for: conversationID.uuidString).snapshot
        #expect(staleSnapshot.shouldShowLoadingState)
        #expect(staleSnapshot.queueSummary.queuedCount == 0)

        let refreshedCommit = await snapshotStore.commitChatPageSnapshot(
            from: conversationStore,
            conversationID: conversationID.uuidString,
            currentUserID: currentUserID,
            blockedUserIDs: []
        )
        #expect(refreshedCommit.didCommit)
        #expect(refreshedCommit.revision == 2)
        let refreshedEvent = await snapshotStore.currentChatPageSnapshotEvent(for: conversationID.uuidString)
        #expect(refreshedEvent.revision == 2)

        let refreshedSnapshot = refreshedEvent.snapshot
        #expect(!refreshedSnapshot.shouldShowLoadingState)
        #expect(refreshedSnapshot.queueSummary.queuedCount == 1)
        #expect(refreshedSnapshot.latestTimelineItemIsCurrentUserOutgoing)
    }

    @Test func listSnapshotEventsYieldCurrentSnapshotAndCommittedRevisions() async throws {
        let conversationID = UUID(uuidString: "cccccccc-cccc-cccc-cccc-cccccccccccc")!
        let conversationStore = IMConversationStore()
        let snapshotStore = IMConversationSnapshotStore()
        let stream = await snapshotStore.listSnapshotEvents()
        var events = stream.makeAsyncIterator()

        let initialEvent = try #require(await events.next())
        #expect(initialEvent.revision == 0)
        #expect(initialEvent.snapshot.rows.isEmpty)

        conversationStore.replaceConversationSummaries([
            makeSummary(
                id: conversationID,
                title: "Streamed Room",
                kind: .group,
                unreadCount: 1
            )
        ])

        let commit = await snapshotStore.commitListSnapshot(
            from: conversationStore,
            filter: .all,
            identityForConversation: { conversation in
                IMConversationIdentityPresentation(
                    title: conversation.title,
                    detailSummary: "",
                    rowSecondaryLabel: nil
                )
            }
        )
        #expect(commit.didCommit)
        #expect(commit.revision == 1)

        let committedEvent = try #require(await events.next())
        #expect(committedEvent.revision == 1)
        #expect(committedEvent.snapshot.rows.map(\.id) == [conversationID.uuidString])
    }

    @Test func listSnapshotEventsBufferOnlyNewestEventWhenConsumerLags() async throws {
        let conversationID = UUID(uuidString: "12121212-1212-1212-1212-121212121212")!
        let conversationStore = IMConversationStore()
        let snapshotStore = IMConversationSnapshotStore()
        let stream = await snapshotStore.listSnapshotEvents()
        var events = stream.makeAsyncIterator()

        conversationStore.replaceConversationSummaries([
            makeSummary(
                id: conversationID,
                title: "Buffered Room",
                kind: .group,
                unreadCount: 1
            )
        ])

        let firstCommit = await snapshotStore.commitListSnapshot(
            from: conversationStore,
            filter: .all,
            identityForConversation: { conversation in
                IMConversationIdentityPresentation(
                    title: conversation.title,
                    detailSummary: "",
                    rowSecondaryLabel: nil
                )
            }
        )
        #expect(firstCommit.revision == 1)

        conversationStore.setConversationSearchText("missing")

        let secondCommit = await snapshotStore.commitListSnapshot(
            from: conversationStore,
            filter: .all,
            identityForConversation: { conversation in
                IMConversationIdentityPresentation(
                    title: conversation.title,
                    detailSummary: "",
                    rowSecondaryLabel: nil
                )
            }
        )
        #expect(secondCommit.revision == 2)

        let latestEvent = try #require(await events.next())
        #expect(latestEvent.revision == 2)
        #expect(latestEvent.snapshot.rows.isEmpty)
    }

    @Test func chatPageSnapshotEventsYieldCurrentSnapshotAndCommittedRevisions() async throws {
        let conversationID = UUID(uuidString: "dddddddd-dddd-dddd-dddd-dddddddddddd")!
        let conversationStore = IMConversationStore()
        let snapshotStore = IMConversationSnapshotStore()
        let stream = await snapshotStore.chatPageSnapshotEvents(for: conversationID.uuidString)
        var events = stream.makeAsyncIterator()

        let initialEvent = try #require(await events.next())
        #expect(initialEvent.conversationID == conversationID.uuidString)
        #expect(initialEvent.revision == 0)
        #expect(initialEvent.snapshot.conversationID == conversationID.uuidString)
        #expect(initialEvent.snapshot.timelineRows.isEmpty)

        conversationStore.replaceConversationSummaries([
            makeSummary(
                id: conversationID,
                title: "Streamed Chat",
                kind: .direct,
                unreadCount: 0
            )
        ])

        let commit = await snapshotStore.commitChatPageSnapshot(
            from: conversationStore,
            conversationID: conversationID.uuidString,
            currentUserID: currentUserID,
            blockedUserIDs: []
        )
        #expect(commit.didCommit)
        #expect(commit.revision == 1)

        let committedEvent = try #require(await events.next())
        #expect(committedEvent.conversationID == conversationID.uuidString)
        #expect(committedEvent.revision == 1)
        #expect(committedEvent.snapshot.metadata.title == "Streamed Chat")
    }

    @Test func chatPageSnapshotEventsBufferOnlyNewestEventWhenConsumerLags() async throws {
        let conversationID = UUID(uuidString: "34343434-3434-3434-3434-343434343434")!
        let conversationStore = IMConversationStore()
        let snapshotStore = IMConversationSnapshotStore()
        let stream = await snapshotStore.chatPageSnapshotEvents(for: conversationID.uuidString)
        var events = stream.makeAsyncIterator()

        conversationStore.replaceConversationSummaries([
            makeSummary(
                id: conversationID,
                title: "Buffered Chat",
                kind: .direct,
                unreadCount: 0
            )
        ])

        let firstCommit = await snapshotStore.commitChatPageSnapshot(
            from: conversationStore,
            conversationID: conversationID.uuidString,
            currentUserID: currentUserID,
            blockedUserIDs: []
        )
        #expect(firstCommit.revision == 1)

        conversationStore.setLoadingMessages(true)

        let secondCommit = await snapshotStore.commitChatPageSnapshot(
            from: conversationStore,
            conversationID: conversationID.uuidString,
            currentUserID: currentUserID,
            blockedUserIDs: []
        )
        #expect(secondCommit.revision == 2)

        let latestEvent = try #require(await events.next())
        #expect(latestEvent.revision == 2)
        #expect(latestEvent.snapshot.shouldShowLoadingState)
    }

    @Test func snapshotBatchCommitsAllChangesBeforeYieldingEvents() async throws {
        let conversationID = UUID(uuidString: "eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee")!
        let conversationStore = IMConversationStore()
        let snapshotStore = IMConversationSnapshotStore()
        let listStream = await snapshotStore.listSnapshotEvents()
        var listEvents = listStream.makeAsyncIterator()
        let chatStream = await snapshotStore.chatPageSnapshotEvents(for: conversationID.uuidString)
        var chatEvents = chatStream.makeAsyncIterator()

        _ = try #require(await listEvents.next())
        _ = try #require(await chatEvents.next())

        conversationStore.replaceConversationSummaries([
            makeSummary(
                id: conversationID,
                title: "Batch Room",
                kind: .group,
                unreadCount: 3
            )
        ])
        conversationStore.setLoadingMessages(true)

        let result = await snapshotStore.commitSnapshotBatchResult(
            from: conversationStore,
            list: IMConversationListSnapshotCommitRequest(
                filter: .all,
                identityForConversation: { conversation in
                    IMConversationIdentityPresentation(
                        title: "Projected \(conversation.title)",
                        detailSummary: "",
                        rowSecondaryLabel: nil
                    )
                }
            ),
            chatPages: [
                IMChatPageSnapshotCommitRequest(
                    conversationID: conversationID.uuidString,
                    currentUserID: currentUserID,
                    blockedUserIDs: []
                )
            ]
        )
        let commit = result.commit

        #expect(commit.didCommit)
        #expect(commit.list?.revision == 1)
        #expect(commit.chatPages[conversationID.uuidString]?.revision == 1)
        #expect(result.listSnapshot?.rows.first?.title == "Projected Batch Room")
        #expect(result.chatPageSnapshots[conversationID.uuidString]?.metadata.title == "Batch Room")

        let listEvent = try #require(await listEvents.next())
        #expect(listEvent.revision == 1)
        #expect(listEvent.snapshot.rows.first?.title == "Projected Batch Room")
        let currentChatEvent = await snapshotStore.currentChatPageSnapshotEvent(for: conversationID.uuidString)
        #expect(currentChatEvent.snapshot.metadata.title == "Batch Room")
        #expect(currentChatEvent.snapshot.shouldShowLoadingState)

        let chatEvent = try #require(await chatEvents.next())
        #expect(chatEvent.revision == 1)
        #expect(chatEvent.snapshot.metadata.title == "Batch Room")
        #expect(await snapshotStore.currentListSnapshotEvent().snapshot.rows.first?.title == "Projected Batch Room")
    }

    @Test func snapshotBatchDeduplicatesRepeatedChatRequests() async throws {
        let conversationID = UUID(uuidString: "ffffffff-ffff-ffff-ffff-ffffffffffff")!
        let conversationStore = IMConversationStore()
        let snapshotStore = IMConversationSnapshotStore()
        let chatStream = await snapshotStore.chatPageSnapshotEvents(for: conversationID.uuidString)
        var chatEvents = chatStream.makeAsyncIterator()

        _ = try #require(await chatEvents.next())

        conversationStore.replaceConversationSummaries([
            makeSummary(
                id: conversationID,
                title: "Repeated Chat",
                kind: .direct,
                unreadCount: 0
            )
        ])

        let request = IMChatPageSnapshotCommitRequest(
            conversationID: conversationID.uuidString,
            currentUserID: currentUserID,
            blockedUserIDs: []
        )
        let commit = await snapshotStore.commitSnapshotBatch(
            from: conversationStore,
            chatPages: [request, request]
        )

        #expect(commit.chatPages[conversationID.uuidString]?.didCommit == true)
        #expect(commit.chatPages[conversationID.uuidString]?.revision == 1)

        let chatEvent = try #require(await chatEvents.next())
        #expect(chatEvent.revision == 1)
        #expect(chatEvent.snapshot.metadata.title == "Repeated Chat")

        let repeatedCommit = await snapshotStore.commitSnapshotBatch(
            from: conversationStore,
            chatPages: [request, request]
        )
        #expect(repeatedCommit.chatPages[conversationID.uuidString]?.didCommit == false)
        #expect(repeatedCommit.chatPages[conversationID.uuidString]?.revision == 1)
    }

    @Test func snapshotCommitExecutorCommitsListAndChatPlan() async {
        let conversationID = UUID(uuidString: "17171717-1717-1717-1717-171717171717")!
        let conversationStore = IMConversationStore()
        let snapshotStore = IMConversationSnapshotStore()
        let executor = IMConversationSnapshotCommitExecutor()

        conversationStore.replaceConversationSummaries([
            makeSummary(
                id: conversationID,
                title: "Executable Room",
                kind: .group,
                unreadCount: 4
            )
        ])
        conversationStore.setLoadingMessages(true)

        let plan = IMConversationSnapshotCommitPlan(
            invalidations: [.appear, .filterChanged(.groups)],
            list: IMConversationListSnapshotCommitPlan(filter: .groups),
            chatPages: [
                IMChatPageSnapshotCommitRequest(
                    conversationID: conversationID.uuidString,
                    currentUserID: currentUserID,
                    blockedUserIDs: []
                )
            ]
        )

        let execution = await executor.commitListAndChatSnapshots(
            plan: plan,
            from: conversationStore,
            to: snapshotStore,
            identityForConversation: { conversation in
                IMConversationIdentityPresentation(
                    title: "Projected \(conversation.title)",
                    detailSummary: "",
                    rowSecondaryLabel: nil
                )
            }
        )

        #expect(execution.plan == plan)
        #expect(execution.batchCommit.list?.didCommit == true)
        #expect(execution.batchCommit.list?.revision == 1)
        #expect(execution.batchCommit.chatPages[conversationID.uuidString]?.didCommit == true)
        #expect(execution.batchCommit.chatPages[conversationID.uuidString]?.revision == 1)
        #expect(execution.listSnapshot?.rows.first?.title == "Projected Executable Room")
        #expect(execution.chatPageSnapshots[conversationID.uuidString]?.metadata.title == "Executable Room")
        #expect(execution.chatPageSnapshots[conversationID.uuidString]?.shouldShowLoadingState == true)
        #expect(await snapshotStore.currentListSnapshotEvent().snapshot.rows.first?.title == "Projected Executable Room")
        let currentChatEvent = await snapshotStore.currentChatPageSnapshotEvent(for: conversationID.uuidString)
        #expect(currentChatEvent.snapshot.metadata.title == "Executable Room")
        #expect(currentChatEvent.snapshot.shouldShowLoadingState)
    }

    @Test func snapshotCommitExecutorCommitsChatOnlyPlanWithoutListMutation() async {
        let conversationID = UUID(uuidString: "18181818-1818-1818-1818-181818181818")!
        let conversationStore = IMConversationStore()
        let snapshotStore = IMConversationSnapshotStore()
        let executor = IMConversationSnapshotCommitExecutor()

        conversationStore.replaceConversationSummaries([
            makeSummary(
                id: conversationID,
                title: "Chat Only",
                kind: .direct,
                unreadCount: 0
            )
        ])

        let plan = IMConversationSnapshotCommitPlan(
            invalidations: [.messagesLoadingChanged(false)],
            list: nil,
            chatPages: [
                IMChatPageSnapshotCommitRequest(
                    conversationID: conversationID.uuidString,
                    currentUserID: currentUserID,
                    blockedUserIDs: [peerUserID]
                )
            ]
        )

        let execution = await executor.commitChatSnapshots(
            plan: plan,
            from: conversationStore,
            to: snapshotStore
        )

        #expect(execution.plan == plan)
        #expect(execution.batchCommit.list == nil)
        #expect(await snapshotStore.currentListSnapshotEvent().revision == 0)
        #expect(execution.batchCommit.chatPages[conversationID.uuidString]?.didCommit == true)
        #expect(execution.batchCommit.chatPages[conversationID.uuidString]?.revision == 1)
        #expect(execution.listSnapshot == nil)
        #expect(execution.chatPageSnapshots[conversationID.uuidString]?.metadata.title == "Chat Only")
        #expect(await snapshotStore.currentChatPageSnapshotEvent(for: conversationID.uuidString).snapshot.metadata.title == "Chat Only")
    }

    @Test func snapshotEngineCommitReducerCoalescesPendingPlansBeforeDrain() async {
        let firstConversationID = UUID(uuidString: "10101010-1010-1010-1010-101010101010")!
        let secondConversationID = UUID(uuidString: "20202020-2020-2020-2020-202020202020")!
        let engine = IMConversationSnapshotEngine(
            initialListSnapshot: IMConversationListSnapshot(
                generation: 0,
                filter: .all,
                rows: []
            )
        )
        let scopeID = IMConversationSnapshotCommitScopeID()

        let firstSchedule = await engine.enqueueCommitEvent(
            IMConversationSnapshotCommitEvent(
                .appear,
                list: IMConversationListSnapshotCommitPlan(filter: .all),
                chatPages: [
                    IMChatPageSnapshotCommitRequest(
                        conversationID: firstConversationID.uuidString,
                        currentUserID: currentUserID,
                        blockedUserIDs: []
                    )
                ]
            ),
            scopeID: scopeID
        )
        #expect(firstSchedule)

        let secondSchedule = await engine.enqueueCommitEvent(
            IMConversationSnapshotCommitEvent(
                .filterChanged(.groups),
                list: IMConversationListSnapshotCommitPlan(filter: .groups),
                chatPages: [
                    IMChatPageSnapshotCommitRequest(
                        conversationID: firstConversationID.uuidString,
                        currentUserID: peerUserID,
                        blockedUserIDs: [currentUserID]
                    ),
                    IMChatPageSnapshotCommitRequest(
                        conversationID: secondConversationID.uuidString,
                        currentUserID: currentUserID,
                        blockedUserIDs: []
                    )
                ]
            ),
            scopeID: scopeID
        )
        #expect(!secondSchedule)

        let plan = await engine.drainCommitPlan(scopeID: scopeID)
        #expect(plan.invalidations == [.appear, .filterChanged(.groups)])
        #expect(plan.reasonSummary == "appear,filterChanged:groups")
        #expect(plan.list?.filter == .groups)
        #expect(plan.chatPages.map(\.conversationID) == [
            firstConversationID.uuidString,
            secondConversationID.uuidString
        ])
        #expect(plan.chatPages.first?.currentUserID == peerUserID)
        #expect(plan.chatPages.first?.blockedUserIDs == [currentUserID])

        let thirdSchedule = await engine.enqueueCommitEvent(
            IMConversationSnapshotCommitEvent(.task("afterDrain")),
            scopeID: scopeID
        )
        #expect(thirdSchedule)
    }

    @Test func snapshotEngineCommitReducerCancelClearsScheduledFlush() async {
        let engine = IMConversationSnapshotEngine(
            initialListSnapshot: IMConversationListSnapshot(
                generation: 0,
                filter: .all,
                rows: []
            )
        )
        let scopeID = IMConversationSnapshotCommitScopeID()

        let firstSchedule = await engine.enqueueCommitEvent(
            IMConversationSnapshotCommitEvent(
                .task("willCancel"),
                list: IMConversationListSnapshotCommitPlan(filter: .unread)
            ),
            scopeID: scopeID
        )
        #expect(firstSchedule)

        await engine.cancelPendingCommitPlan(scopeID: scopeID)

        let secondSchedule = await engine.enqueueCommitEvent(
            IMConversationSnapshotCommitEvent(
                .task("afterCancel"),
                list: IMConversationListSnapshotCommitPlan(filter: .groups)
            ),
            scopeID: scopeID
        )
        #expect(secondSchedule)

        let plan = await engine.drainCommitPlan(scopeID: scopeID)
        #expect(plan.invalidations == [.task("afterCancel")])
        #expect(plan.list?.filter == .groups)
        #expect(plan.chatPages.isEmpty)
    }

    @Test func snapshotCommitCoordinatorFlushesCoalescedPlanOnce() async throws {
        let firstConversationID = UUID(uuidString: "30303030-3030-3030-3030-303030303030")!
        let secondConversationID = UUID(uuidString: "40404040-4040-4040-4040-404040404040")!
        let coordinator = IMConversationSnapshotCommitCoordinator(flushDelayNanoseconds: 10_000_000)
        let snapshotStore = IMConversationSnapshotStore()
        let scopeID = IMConversationSnapshotCommitScopeID()
        let recorder = IMConversationSnapshotFlushRecorder()

        await coordinator.schedule(
            IMConversationSnapshotCommitEvent(
                .conversationGenerationChanged(10),
                list: IMConversationListSnapshotCommitPlan(filter: .all),
                chatPages: [
                    IMChatPageSnapshotCommitRequest(
                        conversationID: firstConversationID.uuidString,
                        currentUserID: currentUserID,
                        blockedUserIDs: []
                    )
                ]
            ),
            scopeID: scopeID,
            to: snapshotStore,
            flush: { plan in
                recorder.record(plan)
            }
        )
        await coordinator.schedule(
            IMConversationSnapshotCommitEvent(
                .selectedConversationChanged(firstConversationID.uuidString),
                list: IMConversationListSnapshotCommitPlan(filter: .unread),
                chatPages: [
                    IMChatPageSnapshotCommitRequest(
                        conversationID: firstConversationID.uuidString,
                        currentUserID: peerUserID,
                        blockedUserIDs: [currentUserID]
                    ),
                    IMChatPageSnapshotCommitRequest(
                        conversationID: secondConversationID.uuidString,
                        currentUserID: currentUserID,
                        blockedUserIDs: []
                    )
                ]
            ),
            scopeID: scopeID,
            to: snapshotStore,
            flush: { plan in
                recorder.record(plan)
            }
        )

        try await Task.sleep(nanoseconds: 80_000_000)

        #expect(recorder.plans.count == 1)
        let plan = try #require(recorder.plans.first)
        #expect(plan.invalidations == [
            .conversationGenerationChanged(10),
            .selectedConversationChanged(firstConversationID.uuidString)
        ])
        #expect(plan.list?.filter == .unread)
        #expect(plan.chatPages.map(\.conversationID) == [
            firstConversationID.uuidString,
            secondConversationID.uuidString
        ])
        #expect(plan.chatPages.first?.currentUserID == peerUserID)
    }

    @Test func snapshotCommitCoordinatorCancelDropsPendingPlanAndReschedules() async throws {
        let coordinator = IMConversationSnapshotCommitCoordinator(flushDelayNanoseconds: 30_000_000)
        let snapshotStore = IMConversationSnapshotStore()
        let scopeID = IMConversationSnapshotCommitScopeID()
        let recorder = IMConversationSnapshotFlushRecorder()

        await coordinator.schedule(
            IMConversationSnapshotCommitEvent(
                .task("willCancel"),
                list: IMConversationListSnapshotCommitPlan(filter: .all)
            ),
            scopeID: scopeID,
            to: snapshotStore,
            flush: { plan in
                recorder.record(plan)
            }
        )
        await coordinator.cancelPending(
            scopeID: scopeID,
            in: snapshotStore
        )
        try await Task.sleep(nanoseconds: 80_000_000)

        #expect(recorder.plans.isEmpty)

        await coordinator.schedule(
            IMConversationSnapshotCommitEvent(
                .task("afterCancel"),
                list: IMConversationListSnapshotCommitPlan(filter: .groups)
            ),
            scopeID: scopeID,
            to: snapshotStore,
            flush: { plan in
                recorder.record(plan)
            }
        )
        try await Task.sleep(nanoseconds: 80_000_000)

        #expect(recorder.plans.count == 1)
        #expect(recorder.plans.first?.invalidations == [.task("afterCancel")])
        #expect(recorder.plans.first?.list?.filter == .groups)
    }

    @Test func snapshotCommitPipelineCoalescesAndExecutesListAndChatCommitOnce() async throws {
        let firstConversationID = UUID(uuidString: "50505050-5050-5050-5050-505050505050")!
        let secondConversationID = UUID(uuidString: "60606060-6060-6060-6060-606060606060")!
        let conversationStore = IMConversationStore()
        let snapshotStore = IMConversationSnapshotStore()
        let pipeline = IMConversationSnapshotCommitPipeline(
            coordinator: IMConversationSnapshotCommitCoordinator(flushDelayNanoseconds: 10_000_000)
        )
        let recorder = IMConversationSnapshotExecutionRecorder()

        conversationStore.replaceConversationSummaries([
            makeSummary(
                id: firstConversationID,
                title: "First Pipeline Room",
                kind: .group,
                unreadCount: 2
            ),
            makeSummary(
                id: secondConversationID,
                title: "Second Pipeline Room",
                kind: .direct,
                unreadCount: 0
            )
        ])

        await pipeline.scheduleListAndChatCommit(
            IMConversationSnapshotCommitEvent(
                .conversationGenerationChanged(1),
                list: IMConversationListSnapshotCommitPlan(filter: .all),
                chatPages: [
                    IMChatPageSnapshotCommitRequest(
                        conversationID: firstConversationID.uuidString,
                        currentUserID: currentUserID,
                        blockedUserIDs: []
                    )
                ]
            ),
            from: conversationStore,
            to: snapshotStore,
            identityForConversation: { conversation in
                IMConversationIdentityPresentation(
                    title: "Projected \(conversation.title)",
                    detailSummary: "",
                    rowSecondaryLabel: nil
                )
            },
            didCommit: { execution in
                recorder.record(execution)
            }
        )
        await pipeline.scheduleListAndChatCommit(
            IMConversationSnapshotCommitEvent(
                .filterChanged(.groups),
                list: IMConversationListSnapshotCommitPlan(filter: .groups),
                chatPages: [
                    IMChatPageSnapshotCommitRequest(
                        conversationID: firstConversationID.uuidString,
                        currentUserID: peerUserID,
                        blockedUserIDs: [currentUserID]
                    ),
                    IMChatPageSnapshotCommitRequest(
                        conversationID: secondConversationID.uuidString,
                        currentUserID: currentUserID,
                        blockedUserIDs: []
                    )
                ]
            ),
            from: conversationStore,
            to: snapshotStore,
            identityForConversation: { conversation in
                IMConversationIdentityPresentation(
                    title: "Projected \(conversation.title)",
                    detailSummary: "",
                    rowSecondaryLabel: nil
                )
            },
            didCommit: { execution in
                recorder.record(execution)
            }
        )

        try await Task.sleep(nanoseconds: 80_000_000)

        #expect(recorder.executions.count == 1)
        let execution = try #require(recorder.executions.first)
        #expect(execution.plan.invalidations == [
            .conversationGenerationChanged(1),
            .filterChanged(.groups)
        ])
        #expect(execution.plan.list?.filter == .groups)
        #expect(execution.plan.chatPages.map(\.conversationID) == [
            firstConversationID.uuidString,
            secondConversationID.uuidString
        ])
        #expect(execution.plan.chatPages.first?.currentUserID == peerUserID)
        #expect(execution.plan.chatPages.first?.blockedUserIDs == [currentUserID])
        #expect(execution.batchCommit.list?.didCommit == true)
        #expect(execution.batchCommit.chatPages[firstConversationID.uuidString]?.didCommit == true)
        #expect(execution.batchCommit.chatPages[secondConversationID.uuidString]?.didCommit == true)
        #expect(execution.listSnapshot?.rows.map(\.title) == ["Projected First Pipeline Room"])
        #expect(execution.chatPageSnapshots[firstConversationID.uuidString]?.metadata.title == "First Pipeline Room")
        #expect(execution.chatPageSnapshots[secondConversationID.uuidString]?.metadata.title == "Second Pipeline Room")
        #expect(await snapshotStore.currentListSnapshotEvent().snapshot.rows.map(\.title) == ["Projected First Pipeline Room"])
        #expect(await snapshotStore.currentChatPageSnapshotEvent(for: firstConversationID.uuidString).snapshot.metadata.title == "First Pipeline Room")
        #expect(await snapshotStore.currentChatPageSnapshotEvent(for: secondConversationID.uuidString).snapshot.metadata.title == "Second Pipeline Room")
    }

    @Test func snapshotCommitPipelineCancelDropsPendingExecutionAndReschedules() async throws {
        let conversationID = UUID(uuidString: "70707070-7070-7070-7070-707070707070")!
        let conversationStore = IMConversationStore()
        let snapshotStore = IMConversationSnapshotStore()
        let pipeline = IMConversationSnapshotCommitPipeline(
            coordinator: IMConversationSnapshotCommitCoordinator(flushDelayNanoseconds: 30_000_000)
        )
        let recorder = IMConversationSnapshotExecutionRecorder()

        conversationStore.replaceConversationSummaries([
            makeSummary(
                id: conversationID,
                title: "Pipeline Cancel",
                kind: .direct,
                unreadCount: 0
            )
        ])

        await pipeline.scheduleChatCommit(
            IMConversationSnapshotCommitEvent(
                .task("willCancel"),
                chatPages: [
                    IMChatPageSnapshotCommitRequest(
                        conversationID: conversationID.uuidString,
                        currentUserID: currentUserID,
                        blockedUserIDs: []
                    )
                ]
            ),
            from: conversationStore,
            to: snapshotStore,
            didCommit: { execution in
                recorder.record(execution)
            }
        )
        await pipeline.cancelPending(in: snapshotStore)
        try await Task.sleep(nanoseconds: 80_000_000)

        #expect(recorder.executions.isEmpty)
        #expect(await snapshotStore.currentChatPageSnapshotEvent(for: conversationID.uuidString).revision == 0)

        await pipeline.scheduleChatCommit(
            IMConversationSnapshotCommitEvent(
                .task("afterCancel"),
                chatPages: [
                    IMChatPageSnapshotCommitRequest(
                        conversationID: conversationID.uuidString,
                        currentUserID: currentUserID,
                        blockedUserIDs: []
                    )
                ]
            ),
            from: conversationStore,
            to: snapshotStore,
            didCommit: { execution in
                recorder.record(execution)
            }
        )
        try await Task.sleep(nanoseconds: 80_000_000)

        #expect(recorder.executions.count == 1)
        #expect(recorder.executions.first?.plan.invalidations == [.task("afterCancel")])
        #expect(recorder.executions.first?.batchCommit.chatPages[conversationID.uuidString]?.didCommit == true)
        #expect(await snapshotStore.currentChatPageSnapshotEvent(for: conversationID.uuidString).revision == 1)
    }

    private func makeSummary(
        id: UUID,
        title: String,
        kind: IMConversationKind,
        unreadCount: Int
    ) -> IMConversationSummaryResponseBody {
        IMConversationSummaryResponseBody(
            id: id,
            title: title,
            kind: kind.rawValue,
            memberCount: 2,
            memberUserIDs: [currentUserID, peerUserID],
            lastMessage: nil,
            lastReadSequence: 0,
            unreadCount: unreadCount,
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 2)
        )
    }

    private func makeEmptyChatPageSnapshot(
        conversationID: String,
        generation: UInt64
    ) -> IMChatPageSnapshot {
        IMChatPageSnapshotBuilder().build(
            conversationID: conversationID,
            generation: generation,
            conversations: [],
            queueSummary: IMConversationQueueSummary(
                queuedCount: 0,
                sendingCount: 0,
                retryableIssueCount: 0
            ),
            receiptSummary: nil,
            isLoadingMessages: false,
            isLoadingMembers: false,
            currentUserID: nil,
            blockedUserIDs: []
        )
    }
}

@MainActor
private final class IMConversationSnapshotFlushRecorder {
    private(set) var plans: [IMConversationSnapshotCommitPlan] = []

    func record(_ plan: IMConversationSnapshotCommitPlan) {
        plans.append(plan)
    }
}

@MainActor
private final class IMConversationSnapshotExecutionRecorder {
    private(set) var executions: [IMConversationSnapshotCommitExecution] = []

    func record(_ execution: IMConversationSnapshotCommitExecution) {
        executions.append(execution)
    }
}
