import Foundation
import IMV2Core
@testable import IMV2ClientKit
import Testing

@Suite("Connection author view and foreground page ownership", .timeLimit(.minutes(1)))
struct V2AuthorPresentationPageCoordinatorTests {
    @Test("a list starts on the account connection without a room subscription")
    func listOnlyConnection() async throws {
        let f = Fixture(), page = await f.profiles.activateVisiblePage()
        let key = V2ProfileViewLookupKey(userID: f.author, context: .relationship)
        let row = try await f.profiles.retainVisibleInterest(for: key, activation: page)
        let demand = Task { try await f.profiles.presentation(for: key, activation: page) }
        try await wait { await f.profiles.diagnostics().waitingConsumers == 1 }
        let runtime = Task { try await f.rooms.run(connectionID: UUID()) }
        let running = Task { try await f.pages.run(messageRoomID: nil, activation: page) }
        try await wait { await f.wire.interests.last?.keys == [key] }
        #expect(await f.wire.views.last?.messageRoomIDs == [])
        #expect(await f.wire.ordinaryCalls == 0)
        try await f.wire.emit(f.value(revision: 1, for: key))
        #expect(try await demand.value?.lease.key == key)
        try await wait { await f.wire.receipts.count == 1 }
        running.cancel(); _ = await running.result
        #expect(await f.wire.unsubscribedRooms == 0)
        await f.profiles.releaseVisibleInterest(row)
        runtime.cancel(); _ = await runtime.result
        await f.pages.close(); await f.profiles.close()
    }

    @Test("joining and leaving pages share one receiver and preserve only independently granted page access")
    func pagesShareConnectionWithoutSharingGrants() async throws {
        let f = Fixture(), first = await f.profiles.activateVisiblePage()
        let rowA = try await f.profiles.retainVisibleInterest(for: f.key, activation: first)
        let demandA = Task { try await f.profiles.presentation(for: f.key, activation: first) }
        try await wait { await f.profiles.diagnostics().waitingConsumers == 1 }
        let runtime = Task { try await f.rooms.run(connectionID: UUID()) }
        let a = Task { try await f.pages.run(messageRoomID: f.room, activation: first) }
        try await wait { await f.wire.receiving }
        try await f.wire.emit(f.value(revision: 1)); _ = try await demandA.value
        try await wait { await f.wire.receipts.count == 1 }
        let initialView = try #require(await f.wire.current)
        let second = await f.profiles.activateVisiblePage()
        let otherContext = V2ProfileViewLookupKey(userID: f.author, context: .relationship)
        let rowB = try await f.profiles.retainVisibleInterest(for: f.key, activation: second)
        let rowC = try await f.profiles.retainVisibleInterest(for: otherContext, activation: second)
        let b = Task { try await f.pages.run(messageRoomID: nil, activation: second) }
        try await wait { await f.wire.interests.last.map { Set($0.keys) } == Set([f.key, otherContext]) }
        #expect(await f.pages.diagnostics().pages == 2)
        #expect(await f.wire.current?.viewID != initialView.viewID)
        #expect(await f.wire.current?.messageRoomIDs == [f.room])
        #expect(await f.profiles.cachedPresentation(for: f.key, activation: first)?.view.revision.rawValue == 1)
        #expect(await f.profiles.cachedPresentation(for: f.key, activation: second) == nil)
        let demandB = Task { try await f.profiles.presentation(for: f.key, activation: second) }
        try await wait { await f.profiles.diagnostics().waitingConsumers == 1 }
        try await f.wire.emit(f.value(revision: 2)); _ = try await demandB.value
        try await wait { await f.wire.receiving }
        await f.wire.setHoldReceive(true)
        let cancellations = await f.wire.cancelledReceivers
        b.cancel()
        try await wait { await f.wire.cancelledReceivers > cancellations }
        try await wait { await f.profiles.cachedPresentation(for: f.key, activation: second) == nil }
        #expect(await f.profiles.cachedPresentation(for: f.key, activation: first)?.view.revision.rawValue == 2)
        let secondView = try #require(await f.wire.current)
        await f.wire.makeReceiverCooperative()
        try await f.wire.emit(f.value(revision: 3))
        _ = await b.result
        try await wait { await f.wire.isReceivingDifferentView(than: secondView.viewID) }
        #expect(await f.profiles.cachedPresentation(for: f.key, activation: first)?.view.revision.rawValue == 2)
        #expect(await f.profiles.cachedPresentation(for: f.key, activation: second) == nil)
        try await f.wire.emit(f.value(revision: 4))
        try await wait { await f.profiles.cachedPresentation(for: f.key, activation: first)?.view.revision.rawValue == 4 }
        #expect(await f.wire.maximumReceivers == 1)
        a.cancel(); _ = await a.result
        for row in [rowA, rowB, rowC] { await f.profiles.releaseVisibleInterest(row) }
        runtime.cancel(); _ = await runtime.result
        await f.pages.close(); await f.profiles.close()
    }

    @Test("two chat scenes advertise both message rooms and retain the surviving ordinary subscription")
    func multipleMessageRooms() async throws {
        let f = Fixture(), first = await f.profiles.activateVisiblePage(), second = await f.profiles.activateVisiblePage()
        let otherRoom = RoomID(uuid: UUID())
        let runtime = Task { try await f.rooms.run(connectionID: UUID()) }
        let a = Task { try await f.pages.run(messageRoomID: f.room, activation: first) }
        try await wait { await f.wire.receiving }
        let b = Task { try await f.pages.run(messageRoomID: otherRoom, activation: second) }
        try await wait { await f.wire.current.map { Set($0.messageRoomIDs) } == Set([f.room, otherRoom]) }
        #expect(await f.pages.diagnostics().pages == 2)
        await #expect(throws: V2ProfilePresentationError.overloaded) {
            try await f.pages.run(messageRoomID: nil, activation: first)
        }
        b.cancel(); _ = await b.result
        try await wait { await f.wire.current?.messageRoomIDs == [f.room] }
        try await wait { await f.wire.unsubscribedRooms == 1 }
        #expect(await f.pages.diagnostics().pages == 1)
        a.cancel(); _ = await a.result
        runtime.cancel(); _ = await runtime.result
        await f.pages.close(); await f.profiles.close()
    }

    @Test("connection admission bounds pages and message rooms while leaving existing pages usable", arguments: [false, true])
    func pageAdmissionBudget(chatRooms: Bool) async throws {
        let f = Fixture(), limit = chatRooms ? 8 : 16
        let runtime = Task { try await f.rooms.run(connectionID: UUID()) }
        var pages: [Task<Void, Error>] = []
        for index in 0..<limit {
            let activation = await f.profiles.activateVisiblePage()
            let room: RoomID? = chatRooms ? .init(uuid: UUID()) : nil
            pages.append(Task { try await f.pages.run(messageRoomID: room, activation: activation) })
            try await wait { await f.pages.diagnostics().pages == index + 1 }
        }
        let excess = await f.profiles.activateVisiblePage()
        await #expect(throws: V2ProfilePresentationError.overloaded) {
            try await f.pages.run(messageRoomID: chatRooms ? .init(uuid: UUID()) : nil, activation: excess)
        }
        #expect(await f.pages.diagnostics().pages == limit)
        await f.pages.close()
        for page in pages { _ = await page.result }
        #expect(await f.pages.diagnostics().running == false)
        #expect(await f.wire.maximumReceivers <= 1)
        runtime.cancel(); _ = await runtime.result
        await f.profiles.close()
    }

    @Test("suspending all pages drains the actual old request before readmitting a foreground page")
    func suspendHoldsAdmissionUntilDrain() async throws {
        let f = Fixture(holdAuthor: true), first = await f.profiles.activateVisiblePage()
        let runtime = Task { try await f.rooms.run(connectionID: UUID()) }
        let a = Task { try await f.pages.run(messageRoomID: nil, activation: first) }
        try await wait { await f.wire.subscribed.count == 1 }
        let completion = Completion()
        let suspend = Task { await f.pages.suspend(); await completion.finish() }
        try await wait { await f.wire.cancelledAuthorRequests == 1 }
        let second = await f.profiles.activateVisiblePage()
        let b = Task { try await f.pages.run(messageRoomID: nil, activation: second) }
        #expect(await f.wire.views.count == 1)
        #expect(await completion.count == 0)
        await f.wire.releaseAuthor()
        await suspend.value; _ = await a.result
        try await wait { await f.wire.subscribed.count == 2 }
        #expect(await f.pages.diagnostics().pages == 1)
        b.cancel(); _ = await b.result
        await f.pages.suspend()
        #expect(await f.pages.diagnostics().running == false)
        runtime.cancel(); _ = await runtime.result
        await f.pages.close(); await f.profiles.close()
    }

    @Test("visible row references preserve every full context and clear each key after its final release")
    func visibleAuthorsFollowRows() async throws {
        let f = Fixture(), activation = await f.profiles.activateVisiblePage()
        let first = try await f.profiles.retainVisibleInterest(for: f.key, activation: activation)
        let duplicate = try await f.profiles.retainVisibleInterest(for: f.key, activation: activation)
        let otherRoom = V2ProfileViewLookupKey(userID: .init(uuid: UUID()), context: .room(.init(uuid: UUID())))
        let unrelated = try await f.profiles.retainVisibleInterest(for: otherRoom, activation: activation)
        let runtime = Task { try await f.rooms.run(connectionID: UUID()) }
        let page = Task { try await f.pages.run(messageRoomID: f.room, activation: activation) }
        try await wait { await f.wire.interests.count == 1 }
        #expect(await f.wire.interests.first.map { Set($0.keys) } == Set([f.key, otherRoom]))
        await f.profiles.releaseVisibleInterest(first)
        #expect(try await f.profiles.visibleAuthorIDs(for: activation, roomID: f.room) == [f.author])
        await f.profiles.releaseVisibleInterest(duplicate)
        try await wait { await f.wire.interests.count == 2 }
        #expect(await f.wire.interests.last?.keys == [otherRoom])
        #expect(await f.wire.interests.map(\.sequence) == [1, 2])
        await f.profiles.releaseVisibleInterest(unrelated)
        try await wait { await f.wire.interests.count == 3 }
        #expect(await f.wire.interests.last?.keys.isEmpty == true)
        page.cancel(); _ = await page.result
        runtime.cancel(); _ = await runtime.result
        await f.pages.close(); await f.profiles.close()
    }

    @Test("page cancellation drains the actual visible-interest request before ending the remote view")
    func interestRequestOwnsLifetime() async throws {
        let f = Fixture(), activation = await f.profiles.activateVisiblePage()
        await f.wire.setHoldInterests(true)
        let runtime = Task { try await f.rooms.run(connectionID: UUID()) }
        let page = Task { try await f.pages.run(messageRoomID: f.room, activation: activation) }
        try await wait { await f.wire.interests.count == 1 }
        page.cancel()
        let completion = Completion()
        let closing = Task { await f.pages.close(); await completion.finish() }
        try await wait { await f.pages.diagnostics().closed }
        #expect(await completion.count == 0)
        #expect(await f.wire.stops.isEmpty)
        await f.wire.releaseInterests()
        _ = await page.result; await closing.value
        #expect(await f.wire.stops.count == 1)
        runtime.cancel(); _ = await runtime.result
        await f.profiles.close()
    }
    @Test("cancelled pages retain their cleanup until the exact stop completes and preserve another room consumer")
    func stopDrainsBeforeClose() async throws {
        let f = Fixture(), activation = await f.profiles.activate()
        await f.wire.setHoldStop(true)
        let other = try await f.rooms.acquire(roomID: f.room, channels: [.roomEvents])
        let runtime = Task { try await f.rooms.run(connectionID: UUID()) }
        let page = Task { try await f.pages.run(messageRoomID: f.room, activation: activation) }
        try await wait { await f.wire.receiving }
        page.cancel()
        try await wait { await f.wire.stops.count == 1 }
        let completion = Completion()
        let close1 = Task { await f.pages.close(); await completion.finish() }
        let close2 = Task { await f.pages.close(); await completion.finish() }
        try await wait { await f.pages.diagnostics().closed }
        #expect(await f.wire.current == nil)
        #expect(await completion.count == 0)
        #expect(await f.wire.unsubscribedRooms == 0)
        await f.wire.releaseStop()
        _ = await page.result; await close1.value; await close2.value
        #expect(await completion.count == 2)
        #expect(await f.wire.stops == f.wire.ended)
        #expect(await f.wire.unsubscribedRooms == 0)
        await f.rooms.release(roomID: f.room, consumerID: other.id)
        runtime.cancel(); _ = await runtime.result
        await f.profiles.close()
    }

    @Test("author access is independent of ordinary ACK; renewal keeps the live page grant")
    func renewalAndIngest() async throws {
        let f = Fixture(lifetime: .milliseconds(180), holdOrdinary: true)
        let activation = await f.profiles.activate()
        let demand = Task { try await f.profiles.presentation(for: f.key, activation: activation) }
        try await wait { await f.profiles.diagnostics().waitingConsumers == 1 }
        let page = Task { try await f.pages.run(messageRoomID: f.room, activation: activation) }
        let runtime = Task { try await f.rooms.run(connectionID: UUID()) }
        try await wait { await f.wire.ordinaryCalls == 1 }
        try await wait { await f.wire.subscribed.count == 1 }
        try await f.wire.emit(f.value(revision: 1))
        #expect(try await demand.value?.view.revision.rawValue == 1)
        await f.wire.releaseOrdinary()
        try await wait { await f.wire.receipts.count == 1 }
        #expect(await f.wire.receipts.first?.userIDs == [f.key.userID])
        try await wait { await f.wire.subscribed.count >= 2 }
        #expect(await f.profiles.cachedPresentation(for: f.key, activation: activation)?.view.revision.rawValue == 1)
        let views = await f.wire.views
        #expect(views[0].viewID != views[1].viewID)
        #expect(await f.wire.maximumReceivers == 1)
        page.cancel(); _ = await page.result
        #expect(await f.profiles.cachedPresentation(for: f.key, activation: activation) == nil)
        runtime.cancel(); _ = await runtime.result
        await f.pages.close(); await f.profiles.close()
    }

    @Test("normal Host grants retain the full configured renewal jitter", arguments: [18, 20])
    func normalGrantKeepsRenewalJitter(seconds: Int) {
        let now = ContinuousClock.now, expires = now + .seconds(seconds)
        let early = V2AuthorPresentationPageCoordinator.renewalDeadline(expires: expires, now: now, lead: .seconds(6))
        let late = V2AuthorPresentationPageCoordinator.renewalDeadline(expires: expires, now: now, lead: .seconds(4))
        #expect(early.duration(to: late) == .seconds(2))
        #expect(early == expires - .seconds(6))
        #expect(late == expires - .seconds(4))
    }

    @Test("short renewal grants leave half their remaining lifetime before restarting")
    func shortGrantBoundsRenewalAdvance() {
        let now = ContinuousClock.now
        #expect(V2AuthorPresentationPageCoordinator.renewalDeadline(expires: now + .seconds(2), now: now, lead: .seconds(6)) == now + .seconds(1))
        #expect(V2AuthorPresentationPageCoordinator.renewalDeadline(expires: now - .seconds(1), now: now, lead: .seconds(6)) == now)
    }

    @Test("a short acknowledged grant renews before its deadline without waiting for the view limit")
    func shortGrantRenewsView() async throws {
        let f = Fixture(renewalLead: .milliseconds(500)), activation = await f.profiles.activateVisiblePage()
        let row = try await f.profiles.retainVisibleInterest(for: f.key, activation: activation)
        let runtime = Task { try await f.rooms.run(connectionID: UUID()) }
        let page = Task { try await f.pages.run(messageRoomID: f.room, activation: activation) }
        var failure: (any Error)?
        do {
            try await wait {
                let receiving = await f.wire.receiving, count = await f.wire.interests.count
                return receiving && count == 1
            }
            let first = try #require(await f.wire.current)
            let deadline = ContinuousClock.now + .seconds(2)
            try await f.wire.emit(f.value(revision: 1), presentationDeadline: deadline)
            try await wait { await f.wire.receipts.count == 1 }
            try await wait { await f.wire.isReceivingDifferentView(than: first.viewID) }
            #expect(ContinuousClock.now < deadline)
            #expect(await f.profiles.cachedPresentation(for: f.key, activation: activation)?.view.revision.rawValue == 1)
            try await f.wire.emit(f.value(revision: 2))
            try await wait { await f.profiles.cachedPresentation(for: f.key, activation: activation)?.view.revision.rawValue == 2 }
            #expect(await f.wire.ordinaryCalls == 1)
            #expect(await f.wire.maximumReceivers == 1)
        } catch { failure = error }
        page.cancel(); _ = await page.result
        await f.profiles.releaseVisibleInterest(row)
        runtime.cancel(); _ = await runtime.result
        await f.pages.close(); await f.profiles.close()
        if let failure { throw failure }
    }

    @Test("retryable renewal failure preserves an issued grant only until its original deadline", arguments: [false, true])
    func retryableFailurePreservesGrant(expiresDuringRetry: Bool) async throws {
        let f = Fixture(), activation = await f.profiles.activateVisiblePage()
        let row = try await f.profiles.retainVisibleInterest(for: f.key, activation: activation)
        let runtime = Task { try await f.rooms.run(connectionID: UUID()) }
        let page = Task { try await f.pages.run(messageRoomID: f.room, activation: activation) }
        var failure: (any Error)?
        do {
            try await wait { await f.wire.receiving }
            let deadline = ContinuousClock.now + (expiresDuringRetry ? .milliseconds(500) : .seconds(30))
            try await f.wire.emit(f.value(revision: 1), presentationDeadline: deadline)
            try await wait {
                let count = await f.wire.receipts.count, receiving = await f.wire.receiving
                return count == 1 && receiving
            }
            try await f.wire.failReceiver(.server(code: "RATE_LIMITED", retryable: true, retryAfterSeconds: 1, currentRevision: nil))
            try await wait { await f.wire.stops.count == 1 }
            #expect(await f.profiles.cachedSnapshot(for: f.key, activation: activation)?.deadline == deadline)
            if expiresDuringRetry {
                try await ContinuousClock().sleep(until: deadline)
                #expect(await f.profiles.cachedSnapshot(for: f.key, activation: activation) == nil)
                #expect(await f.wire.subscribed.count == 1)
            }
            try await wait {
                let count = await f.wire.subscribed.count, receiving = await f.wire.receiving
                return count == 2 && receiving
            }
            if !expiresDuringRetry {
                #expect(await f.profiles.cachedSnapshot(for: f.key, activation: activation)?.deadline == deadline)
            }
            try await f.wire.emit(f.value(revision: 2))
            try await wait { await f.profiles.cachedPresentation(for: f.key, activation: activation)?.view.revision.rawValue == 2 }
            #expect(await f.wire.maximumReceivers == 1)
        } catch { failure = error }
        page.cancel(); _ = await page.result
        #expect(await f.profiles.cachedPresentation(for: f.key, activation: activation) == nil)
        await f.profiles.releaseVisibleInterest(row)
        runtime.cancel(); _ = await runtime.result
        await f.pages.close(); await f.profiles.close()
        if let failure { throw failure }
    }

    @Test("an explicit refusal revokes an already-issued author grant")
    func refusalRevokesExistingGrant() async throws {
        let f = Fixture(), activation = await f.profiles.activateVisiblePage()
        let row = try await f.profiles.retainVisibleInterest(for: f.key, activation: activation)
        let runtime = Task { try await f.rooms.run(connectionID: UUID()) }
        let page = Task { try await f.pages.run(messageRoomID: f.room, activation: activation) }
        var failure: (any Error)?
        do {
            try await wait { await f.wire.receiving }
            try await f.wire.emit(f.value(revision: 1))
            try await wait {
                let count = await f.wire.receipts.count, receiving = await f.wire.receiving
                return count == 1 && receiving
            }
            try await f.wire.failReceiver(.server(code: "FORBIDDEN", retryable: false, retryAfterSeconds: 0, currentRevision: nil))
            try await wait { await f.profiles.cachedSnapshot(for: f.key, activation: activation) == nil }
            #expect(await f.wire.subscribed.count == 1)
        } catch { failure = error }
        page.cancel(); _ = await page.result
        await f.profiles.releaseVisibleInterest(row)
        runtime.cancel(); _ = await runtime.result
        await f.pages.close(); await f.profiles.close()
        if let failure { throw failure }
    }

    @Test("an unobserved short candidate cannot renew the account view")
    func unacknowledgedGrantDoesNotRenew() async throws {
        let f = Fixture(renewalLead: .milliseconds(500)), activation = await f.profiles.activateVisiblePage()
        let row = try await f.profiles.retainVisibleInterest(for: f.key, activation: activation)
        let runtime = Task { try await f.rooms.run(connectionID: UUID()) }
        let page = Task { try await f.pages.run(messageRoomID: f.room, activation: activation) }
        var failure: (any Error)?
        do {
            try await wait { await f.wire.receiving }
            let view = try #require(await f.wire.current)
            try await f.wire.emit(f.value(revision: 1))
            try await wait { await f.wire.receipts.count == 1 }
            let other = V2ProfileViewLookupKey(userID: f.author, context: .relationship)
            try await f.wire.emit(f.value(revision: 1, for: other),
                presentationDeadline: .now + .milliseconds(150), sequence: 2)
            try await Task.sleep(for: .milliseconds(250))
            #expect(await f.wire.current?.viewID == view.viewID)
            #expect(await f.wire.receipts.count == 1)
            #expect(await f.wire.views.count == 1)
        } catch { failure = error }
        page.cancel(); _ = await page.result
        await f.profiles.releaseVisibleInterest(row)
        runtime.cancel(); _ = await runtime.result
        await f.pages.close(); await f.profiles.close()
        if let failure { throw failure }
    }

    @Test("page join and concurrent close retain a non-cooperative subscription until its actual ACK")
    func replacementDrainsActualSubscription() async throws {
        let f = Fixture(holdAuthor: true)
        let first = await f.profiles.activate(), second = await f.profiles.activate()
        let runtime = Task { try await f.rooms.run(connectionID: UUID()) }
        let a = Task { try await f.pages.run(messageRoomID: f.room, activation: first) }
        try await wait { await f.wire.subscribed.count == 1 }
        let b = Task { try await f.pages.run(messageRoomID: f.room, activation: second) }
        try await wait { await f.wire.cancelledAuthorRequests == 1 }
        #expect(await f.wire.views.count == 1)
        let completion = Completion()
        let close1 = Task { await f.pages.close(); await completion.finish() }
        let close2 = Task { await f.pages.close(); await completion.finish() }
        try await wait { await f.pages.diagnostics().closed }
        await #expect(throws: (any Error).self) { try await f.pages.run(messageRoomID: f.room, activation: second) }
        #expect(await completion.count == 0)
        await f.wire.releaseAuthor()
        _ = await a.result; _ = await b.result
        await close1.value; await close2.value
        #expect(await completion.count == 2)
        #expect(await f.wire.views.count == 1)
        #expect(await f.wire.ended.count == 1)
        runtime.cancel(); _ = await runtime.result
        await f.profiles.close()
    }

    @Test("reconnect and membership revocation end the old nonce while keeping the visible room intent")
    func reconnectAndRevocation() async throws {
        let f = Fixture(), activation = await f.profiles.activate()
        let demand = Task { try await f.profiles.presentation(for: f.key, activation: activation) }
        try await wait { await f.profiles.diagnostics().waitingConsumers == 1 }
        let page = Task { try await f.pages.run(messageRoomID: f.room, activation: activation) }
        let firstID = UUID(), secondID = UUID()
        let first = Task { try await f.rooms.run(connectionID: firstID) }
        try await wait { await f.wire.subscribed.count == 1 }
        try await f.wire.emit(f.value(revision: 1)); _ = try await demand.value
        first.cancel(); _ = await first.result
        try await wait { await f.wire.ended.count == 1 }
        try await wait { await f.profiles.cachedPresentation(for: f.key, activation: activation) == nil }
        let second = Task { try await f.rooms.run(connectionID: secondID) }
        try await wait { await f.wire.subscribed.count == 2 }
        try await f.wire.emit(f.value(revision: 2))
        try await wait { await f.profiles.cachedPresentation(for: f.key, activation: activation)?.view.revision.rawValue == 2 }
        #expect(await f.wire.generations == [firstID, secondID])
        await f.wire.setAuthorized(false); await f.rooms.requestReconciliation()
        try await wait { await f.wire.subscribed.count == 3 }
        try await wait { await f.profiles.cachedPresentation(for: f.key, activation: activation) == nil }
        await f.wire.setAuthorized(true); await f.rooms.requestReconciliation()
        try await wait { await f.wire.subscribed.count == 4 }
        page.cancel(); _ = await page.result
        second.cancel(); _ = await second.result
        await f.pages.close(); await f.profiles.close()
    }

    @Test("a denied independent author view does not revoke ordinary room authority")
    func deniedSubscribe() async throws {
        let f = Fixture(denyAuthor: true), activation = await f.profiles.activate()
        let otherScene = try await f.rooms.acquire(roomID: f.room, channels: [.roomEvents])
        let runtime = Task { try await f.rooms.run(connectionID: UUID()) }
        let page = Task { try await f.pages.run(messageRoomID: f.room, activation: activation) }
        try await wait { await f.wire.ended.count == 1 }
        var snapshots = otherScene.updates.makeAsyncIterator()
        while let value = await snapshots.next() {
            #expect(value.state != .revoked)
            if value.state == .subscribed { break }
        }
        #expect(await f.wire.views.count == 1)
        #expect(await f.wire.unsubscribedRooms == 0)
        await f.wire.setDenyAuthor(false); await f.rooms.authorityDidChange()
        try await wait { await f.wire.subscribed.count == 2 }
        page.cancel(); _ = await page.result
        await f.rooms.release(roomID: f.room, consumerID: otherScene.id)
        runtime.cancel(); _ = await runtime.result
        await f.pages.close(); await f.profiles.close()
    }

    @Test("an unnegotiated connection is tried once and retried only after a new connection")
    func noCapability() async throws {
        let f = Fixture(unsupported: true), activation = await f.profiles.activate()
        let page = Task { try await f.pages.run(messageRoomID: f.room, activation: activation) }
        let first = Task { try await f.rooms.run(connectionID: UUID()) }
        try await wait { await f.wire.begins == 1 }
        for _ in 0..<4 { await f.rooms.requestReconciliation() }
        #expect(await f.wire.begins == 1)
        let next = Task { try await f.rooms.run(connectionID: UUID()) }
        _ = await first.result
        try await wait { await f.wire.begins == 2 }
        #expect(await f.wire.subscribed.isEmpty)
        page.cancel(); _ = await page.result
        next.cancel(); _ = await next.result
        await f.pages.close(); await f.profiles.close()
    }

    @Test("a non-cooperative receiver holds close and cannot publish its delayed delta after cancellation")
    func delayedReceive() async throws {
        let f = Fixture(holdReceive: true), activation = await f.profiles.activate()
        let demand = Task { try await f.profiles.presentation(for: f.key, activation: activation) }
        try await wait { await f.profiles.diagnostics().waitingConsumers == 1 }
        let runtime = Task { try await f.rooms.run(connectionID: UUID()) }
        let page = Task { try await f.pages.run(messageRoomID: f.room, activation: activation) }
        try await wait { await f.wire.receiving }
        let completion = Completion()
        let closing = Task { await f.pages.close(); await completion.finish() }
        try await wait { await f.wire.cancelledReceivers == 1 }
        #expect(await completion.count == 0)
        try await f.wire.emit(f.value(revision: 4))
        await closing.value; _ = await page.result
        #expect(await f.profiles.cachedPresentation(for: f.key, activation: activation) == nil)
        await f.profiles.deactivate(activation); _ = await demand.result
        runtime.cancel(); _ = await runtime.result
        await f.profiles.close()
    }

    @Test("a cancelled view's late retry-after delays the joined pages on the same account")
    func lateThrottle() async throws {
        let f = Fixture(holdAuthor: true)
        let a = await f.profiles.activate(), b = await f.profiles.activate()
        let runtime = Task { try await f.rooms.run(connectionID: UUID()) }
        let first = Task { try await f.pages.run(messageRoomID: f.room, activation: a) }
        try await wait { await f.wire.subscribed.count == 1 }
        let replacement = Task { try await f.pages.run(messageRoomID: f.room, activation: b) }
        try await wait { await f.wire.cancelledAuthorRequests == 1 }
        await f.wire.failNextAuthor(.server(code: "RATE_LIMITED", retryable: true, retryAfterSeconds: 1, currentRevision: nil))
        await f.wire.releaseAuthor()
        try await wait { await f.wire.subscribed.count == 2 }
        #expect(await f.pages.diagnostics().pages == 2)
        let failureAt = try #require(await f.wire.failureAt), views = await f.wire.views
        #expect(views[1].started >= failureAt + .seconds(1))
        first.cancel(); replacement.cancel()
        _ = await first.result; _ = await replacement.result
        runtime.cancel(); _ = await runtime.result
        await f.pages.close(); await f.profiles.close()
    }

    @Test("close revokes visible grants before a non-cooperative receiver finishes")
    func earlyRevocationDuringDrain() async throws {
        let f = Fixture(holdReceive: true), activation = await f.profiles.activate()
        let demand = Task { try await f.profiles.presentation(for: f.key, activation: activation) }
        try await wait { await f.profiles.diagnostics().waitingConsumers == 1 }
        let runtime = Task { try await f.rooms.run(connectionID: UUID()) }
        let page = Task { try await f.pages.run(messageRoomID: f.room, activation: activation) }
        try await wait { await f.wire.receiving }
        try await f.wire.emit(f.value(revision: 1)); _ = try await demand.value
        try await wait { await f.wire.receiving }
        #expect(await f.profiles.cachedPresentation(for: f.key, activation: activation) != nil)
        let completion = Completion()
        let closing = Task { await f.pages.close(); await completion.finish() }
        try await wait { await f.wire.cancelledReceivers == 1 }
        try await wait { await f.profiles.cachedPresentation(for: f.key, activation: activation) == nil }
        #expect(await completion.count == 0)
        try await f.wire.emit(f.value(revision: 2))
        await closing.value; _ = await page.result
        #expect(await f.profiles.cachedPresentation(for: f.key, activation: activation) == nil)
        runtime.cancel(); _ = await runtime.result
        await f.profiles.close()
    }

    @Test("a buffered subscription snapshot cannot hide permission loss and recovery on the same connection")
    func coalescedAuthorityGenerations() async throws {
        let f = Fixture(holdReceive: true), activation = await f.profiles.activate()
        let demand = Task { try await f.profiles.presentation(for: f.key, activation: activation) }
        try await wait { await f.profiles.diagnostics().waitingConsumers == 1 }
        let runtime = Task { try await f.rooms.run(connectionID: UUID()) }
        let page = Task { try await f.pages.run(messageRoomID: f.room, activation: activation) }
        try await wait { await f.wire.receiving }
        await f.wire.setAuthorized(false); await f.rooms.authorityDidChange()
        try await wait { await f.wire.cancelledReceivers == 1 }
        try await wait { await f.wire.unsubscribedRooms == 1 }
        await f.wire.setAuthorized(true); await f.rooms.authorityDidChange()
        try await wait { await f.wire.ordinaryCalls == 2 }
        // The consumer is still draining its old non-cooperative receiver while
        // the snapshot stream retains only the newest, subscribed value.
        try await f.wire.emit(f.value(revision: 1))
        try await wait { await f.wire.subscribed.count == 2 }
        #expect(await f.profiles.cachedPresentation(for: f.key, activation: activation) == nil)
        #expect(await f.profiles.diagnostics().waitingConsumers == 1)
        try await f.wire.emit(f.value(revision: 2))
        #expect(try await demand.value?.view.revision.rawValue == 2)
        await f.wire.makeReceiverCooperative()
        page.cancel(); _ = await page.result
        runtime.cancel(); _ = await runtime.result
        await f.pages.close(); await f.profiles.close()
    }
}

private struct Fixture {
    let actor = UserID(uuid: UUID()), device = DeviceID(uuid: UUID()), room = RoomID(uuid: UUID()), author = UserID(uuid: UUID())
    let wire: PageWire
    let profiles: V2ProfilePresentationRepository
    let rooms: V2RoomSubscriptionCoordinator
    let pages: V2AuthorPresentationPageCoordinator
    var key: V2ProfileViewLookupKey { .init(userID: author, context: .room(room)) }
    init(lifetime: Duration = .seconds(30), renewalLead: Duration = .milliseconds(20), holdOrdinary: Bool = false, holdAuthor: Bool = false,
         denyAuthor: Bool = false, unsupported: Bool = false, holdReceive: Bool = false) {
        let wire = PageWire(lifetime: lifetime, holdOrdinary: holdOrdinary, holdAuthor: holdAuthor,
                            denyAuthor: denyAuthor, unsupported: unsupported, holdReceive: holdReceive)
        self.wire = wire
        let profiles = V2ProfilePresentationRepository(actorUserID: actor, deviceID: device, reader: SlowHTTP())
        self.profiles = profiles
        let rooms = V2RoomSubscriptionCoordinator(subscriptions: wire, activity: wire, groupEvents: wire,
            activityEvents: wire, isAuthorized: { _ in await wire.authorized }, roomCursor: { _ in 7 }, retryDelay: .milliseconds(5))
        self.rooms = rooms
        pages = .init(rooms: rooms, source: wire, subscriptions: wire, profiles: profiles,
            renewalLead: { renewalLead }, retryDelay: .milliseconds(5))
    }
    func value(revision: UInt64, for lookup: V2ProfileViewLookupKey? = nil) throws -> V2AuthorizedProfilePresentation {
        let date = Date(timeIntervalSince1970: 2_000_000_000), rev = try #require(V2ProfileRevision(rawValue: revision))
        let view = try V2ProfileView(userID: author,
            publicIdentity: .init(userID: author, handle: .init("author"), displayName: "Author \(revision)", accountKind: .regular),
            avatar: nil, state: .active, revision: rev, visibilityRevision: rev)
        return try .init(view: view, lease: .init(actorUserID: actor, deviceID: device, key: lookup ?? key,
            profileRevision: rev, visibilityRevision: rev, contextRevision: revision,
            observedAt: date, validUntil: date.addingTimeInterval(120)))
    }
}
private struct SlowHTTP: V2ProfilePresentationReading {
    func readPresentations(_ keys: [V2ProfileViewLookupKey]) async throws -> V2ProfilePresentationBatch {
        try await Task.sleep(for: .seconds(60)); throw CancellationError()
    }
}
private actor Completion { var count = 0; func finish() { count += 1 } }
private struct WaitExpired: Error {}
private func wait(_ predicate: () async -> Bool) async throws {
    let until = ContinuousClock.now + .seconds(3)
    while !(await predicate()) { guard .now < until else { throw WaitExpired() }; try await Task.sleep(for: .milliseconds(1)) }
}

private actor PageWire: V2AuthorPresentationSource, V2ClientAuthorPresentationSubscriptionTransport,
    V2ClientGroupEventSubscriptionTransport, V2ClientLiveActivityTransport,
    V2GroupEventAvailabilityHintSource, V2LiveActivityEventSource {
    let lifetime: Duration, unsupported: Bool
    var holdReceive: Bool
    var authorized = true, denyAuthor: Bool
    var nextAuthorError: V2RealtimeTransportError?, failureAt: ContinuousClock.Instant?
    var holdOrdinary: Bool, holdAuthor: Bool
    var ordinaryWaiter: CheckedContinuation<Void, Never>?, authorWaiter: CheckedContinuation<Void, Never>?
    var holdStop = false, stops: [UUID] = []
    var receipts: [V2AuthorPresentationReceipt] = []
    var stopWaiter: CheckedContinuation<Void, Never>?
    var waiter: (UUID, CheckedContinuation<V2ReceivedAuthorPresentationDelta, Error>)?
    var pending: [V2ReceivedAuthorPresentationDelta] = []
    var current: V2AuthorPresentationView?
    var views: [V2AuthorPresentationView] = [], subscribed: [UUID] = [], ended: [UUID] = [], generations: [UUID?] = []
    var ordinaryCalls = 0, begins = 0, cancelledAuthorRequests = 0, cancelledReceivers = 0, maximumReceivers = 0, unsubscribedRooms = 0
    var receiving: Bool { waiter != nil }
    func isReceivingDifferentView(than id: UUID) -> Bool { current?.viewID != id && receiving }
    init(lifetime: Duration, holdOrdinary: Bool, holdAuthor: Bool, denyAuthor: Bool, unsupported: Bool, holdReceive: Bool) {
        self.lifetime = lifetime; self.holdOrdinary = holdOrdinary; self.holdAuthor = holdAuthor
        self.denyAuthor = denyAuthor; self.unsupported = unsupported; self.holdReceive = holdReceive
    }
    func setAuthorized(_ value: Bool) { authorized = value }
    func setHoldStop(_ value: Bool) { holdStop = value }
    func releaseStop() { holdStop = false; stopWaiter?.resume(); stopWaiter = nil }
    func setDenyAuthor(_ value: Bool) { denyAuthor = value }
    func failNextAuthor(_ error: V2RealtimeTransportError) { nextAuthorError = error }
    func makeReceiverCooperative() { holdReceive = false }
    func setHoldReceive(_ value: Bool) { holdReceive = value }
    func releaseOrdinary() { holdOrdinary = false; ordinaryWaiter?.resume(); ordinaryWaiter = nil }
    func releaseAuthor() { holdAuthor = false; authorWaiter?.resume(); authorWaiter = nil }
    func beginAuthorPresentationView(messageRoomIDs: [RoomID]) throws -> V2AuthorPresentationView {
        begins += 1
        if unsupported { throw V2TLSFrameConnectionError.notConnected }
        #expect(current == nil)
        let now = ContinuousClock.now
        let view = V2AuthorPresentationView(streamID: UUID(), viewID: UUID(), messageRoomIDs: messageRoomIDs, renewBy: now + lifetime, started: now)
        current = view; views.append(view); generations.append(V2ConnectionRequestScope.connectionID)
        return view
    }
    func endAuthorPresentationView(_ view: V2AuthorPresentationView) {
        ended.append(view.viewID)
        if current == view { current = nil; pending = []; waiter?.1.resume(throwing: CancellationError()); waiter = nil }
    }
    func acknowledgeAuthorPresentation(_ receipt: V2AuthorPresentationReceipt) throws {
        #expect(current?.viewID == receipt.viewID)
        receipts.append(receipt)
    }
    var interests: [V2AuthorPresentationInterests] = []
    private var holdInterests = false
    private var interestsWaiter: CheckedContinuation<Void, Never>?
    func setHoldInterests(_ value: Bool) { holdInterests = value }
    func releaseInterests() { holdInterests = false; interestsWaiter?.resume(); interestsWaiter = nil }
    func replaceAuthorPresentationInterests(_ value: V2AuthorPresentationInterests) async throws {
        #expect(current?.viewID == value.viewID)
        interests.append(value)
        if holdInterests { await withCheckedContinuation { interestsWaiter = $0 } }
    }
    func stopAuthorPresentation(_ view: V2AuthorPresentationView) async throws {
        try Task.checkCancellation()
        #expect(ended.contains(view.viewID))
        #expect(V2ConnectionRequestScope.connectionID != nil)
        stops.append(view.viewID)
        if holdStop { await withCheckedContinuation { stopWaiter = $0 } }
    }
    func subscribeToGroupEvents(roomID: RoomID, afterRoomSequence: UInt64) async throws -> V2ClientGroupEventSubscription {
        ordinaryCalls += 1
        if holdOrdinary { await withCheckedContinuation { ordinaryWaiter = $0 } }
        return try .init(roomID: roomID, highWatermark: afterRoomSequence)
    }
    func startAuthorPresentation(_ view: V2AuthorPresentationView) async throws {
        #expect(current == view)
        subscribed.append(view.viewID)
        if holdAuthor {
            await withTaskCancellationHandler(operation: {
                await withCheckedContinuation { authorWaiter = $0 }
            }, onCancel: { Task { await self.noteCancelledAuthor() } })
        }
        if denyAuthor { throw V2RealtimeTransportError.server(code: "FORBIDDEN", retryable: false, retryAfterSeconds: 0, currentRevision: nil) }
        if let error = nextAuthorError { nextAuthorError = nil; failureAt = .now; throw error }
    }
    private func noteCancelledAuthor() { cancelledAuthorRequests += 1 }
    func nextAuthorPresentationDelta(for view: V2AuthorPresentationView) async throws -> V2ReceivedAuthorPresentationDelta {
        try Task.checkCancellation()
        guard current == view else { throw V2ProfilePresentationError.inactive }
        if !pending.isEmpty { return pending.removeFirst() }
        let id = UUID()
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()); return }
                #expect(waiter == nil); maximumReceivers = max(maximumReceivers, 1)
                waiter = (id, continuation)
            }
        }, onCancel: { Task { await self.cancelReceiver(id) } })
    }
    private func cancelReceiver(_ id: UUID) {
        guard waiter?.0 == id else { return }
        cancelledReceivers += 1
        if !holdReceive { waiter?.1.resume(throwing: CancellationError()); waiter = nil }
    }
    func failReceiver(_ error: V2RealtimeTransportError) throws {
        let waiting = try #require(waiter)
        waiter = nil; waiting.1.resume(throwing: error)
    }
    func emit(_ value: V2AuthorizedProfilePresentation, presentationDeadline: ContinuousClock.Instant? = nil,
              sequence: UInt64 = 1) throws {
        let view = try #require(current)
        let delta = V2ReceivedAuthorPresentationDelta(view: view, sequence: sequence, entries: [
            .presentation(value, avatar: nil, presentationDeadline: presentationDeadline ?? view.started + .seconds(60), avatarDeadline: nil)
        ])
        if let waiting = waiter { waiter = nil; waiting.1.resume(returning: delta) } else { pending.append(delta) }
    }
    func unsubscribeFromGroupEvents(roomID: RoomID) { unsubscribedRooms += 1 }
    func subscribeTyping(roomID: RoomID) {}
    func unsubscribeTyping(roomID: RoomID) {}
    func setTyping(roomID: RoomID, isTyping: Bool) {}
    func subscribePresence(roomID: RoomID) throws -> V2PresenceState { throw CancellationError() }
    func unsubscribePresence(roomID: RoomID) {}
    func liveActivityPreferences() throws -> V2LiveActivityPreferences { throw CancellationError() }

    func nextGroupEventAvailabilityHint() async throws -> V2GroupEventAvailabilityHint {
        try await Task.sleep(for: .seconds(60)); throw CancellationError()
    }
    func nextLiveActivityEvent() async throws -> V2LiveActivityEvent {
        try await Task.sleep(for: .seconds(60)); throw CancellationError()
    }
}
