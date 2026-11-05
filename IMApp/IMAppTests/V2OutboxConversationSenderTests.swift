import Foundation
import SwiftUI
import UIKit
@testable import IMV2ClientKit
import IMV2Core
import Testing
@testable import IMApp

@MainActor
@Suite("App send action handoff")
struct V2OperationConversationSenderTests {
    @Test("mentions and reply enter the immutable local send action")
    func groupMentionsReachDurableIntent() async throws {
        let f=try V2AppMessageWorkFixture();defer { f.remove() }
        let sender=V2OperationConversationSender(service:f.send)
        let mentions:[V2MentionTarget]=[.user(.init(uuid:UUID())),.everyone]
        let reply=V2MessageReplyReference(messageID:.init(uuid:UUID()))
        #expect(try await sender.send(text:"请关注",media:[],mentions:mentions,entities:[],replyTo:reply,in:f.room.rawValue) == .queuedForRetry)
        let intent=try #require(try await f.store.preparingSendIntents().first)
        #expect(intent.text=="请关注" && intent.mentions==mentions && intent.replyTo==reply)
        #expect(await f.remote.calls==0)
        try await f.store.close()
    }
    @Test("confirmation is correlated to this send, never an older committed message")
    func trackedConfirmationUsesExactIntent() async throws {
        let f = try V2AppMessageWorkFixture(); defer { f.remove() }
        let older = try await f.send.enqueueMessage(roomID: f.room, text: "older")
        try await f.store.handOffSendIntent(older)
        let work = try #require(try await f.store.dueOperationWork(now: .now, kinds: [.sendMessage]).first)
        try await f.send.execute(f.claim(work))
        let sender = V2OperationConversationSender(service: f.send)
        let current = try await sender.enqueueTracked(text: "current", mentions: [], entities: [], replyTo: nil, roomID: f.room.rawValue)
        var updates = await sender.sendConfirmations(intentID: current).makeAsyncIterator()
        let initial = try await updates.next()
        #expect(initial == .some(nil))
        try await f.store.handOffSendIntent(current)
        let currentWork = try #require(try await f.store.dueOperationWork(now: .now, kinds: [.sendMessage]).first)
        try await f.send.execute(f.claim(currentWork))
        var committed = false
        while let state = try await updates.next() {
            if state == .committed { committed = true; break }
        }
        #expect(committed)
        try await f.store.close()
    }

    @Test("first text stays in its visible chat cell as the durable send is confirmed",
          arguments: [V2ConversationKind.direct(accountKind: .regular), .group])
    func confirmedTextRemainsInVisibleCell(kind: V2ConversationKind) async throws {
        await V2UITestWindowOwnership.acquire()
        defer { V2UITestWindowOwnership.release() }
        let f = try V2AppMessageWorkFixture()
        defer { f.remove() }
        let profile: (String, [String: Any])
        if kind == .group {
            profile = ("room", ["event_type": "room.created", "room_id": f.room.rawValue, "title": "群聊",
                "owner_user_id": f.account.rawValue, "membership_revision": 1, "capacity_class": "standard",
                "created_at_ms": 1_750_000_000_000])
        } else {
            profile = ("direct_room_profile", ["room_id": f.room.rawValue, "target_user_id": UserID(uuid: UUID()).rawValue,
                "public_handle": "chat_peer", "display_name": "Peer", "account_kind": "regular",
                "revision": 1, "room_created_at_ms": 1_750_000_000_000, "updated_at_ms": 1_750_000_000_000])
        }
        let record = try V2ClientSyncRecord(sequence: 1, sourceEventID: .init(uuid: UUID()),
            projectionKind: profile.0, payload: JSONSerialization.data(withJSONObject: profile.1))
        _ = try await f.store.apply(.init(generation: 1, records: [record], nextSyncToken: .init("chat-profile"),
            receipt: .init("chat-profile"), hasMore: false, capabilityProfile: "base"))
        let source = V2GRDBConversationDataSource(localStore: f.store, requiresLocalReadAuthorization: true,
                                                  requestLatestVisible: { _ in })
        let notifier = V2ProjectionChangeNotifier(localStore: f.store)
        let detail = V2ConversationDetailStore(environment: .init(userID: f.account.rawValue,
            projections: .init(dataSource: source), messages: .init(sender: V2OperationConversationSender(service: f.send)),
            runtime: .init(projectionChangeNotifier: notifier)), context: .init(roomID: f.room.rawValue, kind: kind))
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let host = UIHostingController(rootView: NavigationStack { V2ConversationDetailView(store: detail) })
        let window = UIWindow(windowScene: scene)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }

        func visibleCell(in view: UIView) -> UICollectionViewCell? {
            if let list = view as? UICollectionView, list.numberOfSections > 0, list.numberOfItems(inSection: 0) == 1,
               let cell = list.cellForItem(at: IndexPath(item: 0, section: 0)), list.bounds.intersects(cell.frame) { return cell }
            return view.subviews.lazy.compactMap { visibleCell(in: $0) }.first
        }
        func waitUntil(_ condition: () -> Bool) async throws {
            let deadline = ContinuousClock.now + .seconds(5)
            while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(16)) }
            try #require(condition())
        }
        try await waitUntil { detail.state == .loaded }
        detail.composer.draft = "第一条消息"
        await detail.sendDraft()
        try await waitUntil { !detail.composer.pendingResourceSends.isEmpty && visibleCell(in: host.view) != nil }
        let originalCell = try #require(visibleCell(in: host.view))
        let pending = try #require(detail.composer.pendingResourceSends.first)
        try await f.store.handOffSendIntent(pending.id)
        let work = try #require(try await f.store.dueOperationWork(now: .now, kinds: [.sendMessage]).first)
        let command = try await f.store.messageSendCommand(workID: work.id)
        _ = try await f.claim(work)
        let message = MessageID(uuid: UUID())
        try await f.store.completeMessageSend(command, receipt: .init(identity: command.identity, fingerprint: command.fingerprint,
            outcome: .accepted(.init(messageID: message, roomSequence: 1)),
            resolvedAtMilliseconds: UInt64(Date().timeIntervalSince1970 * 1000)))
        try await waitUntil { detail.composer.pendingResourceSends.first?.status == "服务器已受理，等待消息同步" }
        #expect(visibleCell(in: host.view) === originalCell)
        let pendingHeight = originalCell.bounds.height
        let event = try V2ClientGroupEvent(sourceEventID: .init(uuid: UUID()), roomSequence: 1, projectionKind: "message",
            payload: JSONSerialization.data(withJSONObject: ["event_type": "message.accepted", "message_id": message.rawValue,
                "room_id": f.room.rawValue, "room_sequence": 1, "message_revision": 1, "sender_user_id": f.account.rawValue,
                "text": pending.text, "server_created_at_ms": 1_750_000_000_000]))
        _ = try await f.store.applyGroupEventPage(.init(roomID: f.room, events: [event], nextRoomSequence: 1, hasMore: false))
        try await waitUntil { detail.composer.pendingResourceSends.isEmpty && detail.messages.first?.id == message.rawValue }
        let confirmed = try #require(detail.timeline.first)
        #expect(detail.messages.first?.text == pending.text)
        #expect(V2MessageTimelineRow.committed(confirmed).id == V2MessageTimelineRow.pending(pending).id)
        // Let SwiftUI and the native list consume the confirmed snapshot.
        for _ in 0..<5 {
            try await Task.sleep(for: .milliseconds(20))
            #expect(visibleCell(in: host.view) === originalCell)
        }
        #expect(abs(originalCell.bounds.height - pendingHeight) <= 1)
        window.isHidden = true
        window.rootViewController = nil
        await notifier.finish()
        try await f.store.close()
    }

    @Test("untracked media cannot bypass resource Ready dependencies")
    func untrackedMediaRejected() async throws {
        let f=try V2AppMessageWorkFixture();defer { f.remove() }
        let sender=V2OperationConversationSender(service:f.send)
        await #expect(throws:V2OperationWorkError.dependencyUnavailable) {
            try await sender.send(text:"",media:[.init(mediaID:.init(uuid:UUID()))],in:f.room.rawValue)
        }
        #expect(try await f.store.preparingSendIntents().isEmpty)
        try await f.store.close()
    }
}
