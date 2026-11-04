import Foundation
import GRDB
import IMV2Core
@testable import IMV2ClientKit
import Testing

extension V2MessageSearchTests {
    @Test("分页水位排除迟到提交，编辑和撤回立刻失效，其他账号无法续页")
    func publicationWatermarkAndAccountScope() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let binding = V2LocalInstallationBinding(value: UUID())
        let store = try GRDBV2LocalSyncStore(databaseURL: directory.appending(path: "first.sqlite"), installationBinding: binding)
        let other = try GRDBV2LocalSyncStore(databaseURL: directory.appending(path: "other.sqlite"), installationBinding: binding)
        let room = RoomID(uuid: UUID()), sender = UserID(uuid: UUID())
        let ids = (0..<7).map { _ in MessageID(uuid: UUID()) }
        for i in 0..<5 {
            let row = try acceptedRoomEvent(sourceEvent: UUID().uuidString, roomID: room, senderID: sender,
                messageID: ids[i], roomSequence: UInt64(i + 1), text: "查找", createdAtMilliseconds: Int64(i + 1) * 1000)
            try await applyRoomEvents(store, records: [row])
        }
        try await store.messageSearch.prepareMessageSearchIndex()
        try await other.messageSearch.prepareMessageSearchIndex()
        let page = try await store.messageSearch.searchMessages(.init(query: "查", limit: 1))
        #expect(page.hits.map(\.messageID) == [ids[4]])
        let cursor = try #require(page.nextCursor)
        await #expect(throws: V2MessageSearchError.cursorDoesNotMatchScope) {
            try await other.messageSearch.searchMessages(.init(query: "查", cursor: cursor))
        }
        try await applyRoomEvents(store, records: [
            acceptedRoomEvent(sourceEvent: UUID().uuidString, roomID: room, senderID: sender,
                messageID: ids[5], roomSequence: 6, text: "查找", createdAtMilliseconds: 1500),
            editedRecord(sequence: 7, sourceEvent: UUID().uuidString, roomID: room, messageID: ids[3], revision: 2, text: "仍可查找"),
            tombstoneRecord(sequence: 8, sourceEvent: UUID().uuidString, roomID: room, messageID: ids[2], revision: 2)])
        let before = try await store.messageSearch.searchMessages(.init(query: "查", cursor: cursor))
        #expect(before.hits.map(\.messageID) == [ids[1], ids[0]])
        _ = try await store.messageSearch.processPendingMessageSearchIndexJobs()
        let after = try await store.messageSearch.searchMessages(.init(query: "查", cursor: cursor))
        #expect(after.hits == before.hits)
        #expect(try await store.messageSearch.searchMessages(.init(query: "查")).hits.map(\.messageID) == [ids[4], ids[3], ids[1], ids[5], ids[0]])
        try await store.close()
        await #expect(throws: V2MessageSearchError.closed) { try await store.messageSearch.searchMessages(.init(query: "查")) }
        try await other.close()
    }

    @Test("发布后确认前中断可重放，同修订新任务不被旧确认移除")
    func replayAndConditionalAcknowledgement() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "V2.sqlite"), binding = V2LocalInstallationBinding(value: UUID())
        let store = try GRDBV2LocalSyncStore(databaseURL: url, installationBinding: binding)
        let room = RoomID(uuid: UUID()), sender = UserID(uuid: UUID()), id = MessageID(uuid: UUID())
        try await store.messageSearch.prepareMessageSearchIndex()
        try await applyRoomEvents(store, records: [acceptedRoomEvent(sourceEvent: UUID().uuidString, roomID: room,
            senderID: sender, messageID: id, roomSequence: 1, text: "回执", createdAtMilliseconds: 1000)])
        let primary = await store.databasePool, search = try #require(await store.messageSearchDatabasePool)
        try await primary.write { try $0.execute(sql: """
            CREATE TEMP TRIGGER interrupt_ack BEFORE DELETE ON v2_message_search_jobs
            BEGIN SELECT RAISE(ABORT,'interrupted ack'); END
            """) }
        await #expect(throws: DatabaseError.self) { try await store.messageSearch.processPendingMessageSearchIndexJobs() }
        let published = try await search.read { try Int64.fetchOne($0, sql: "SELECT indexed_commit FROM v2_search_documents") }
        #expect(published != nil)
        try await store.close()
        let resumed = try GRDBV2LocalSyncStore(databaseURL: url, installationBinding: binding)
        let queue = await resumed.databasePool, derived = try #require(await resumed.messageSearchDatabasePool)
        #expect(try await resumed.messageSearch.processPendingMessageSearchIndexJobs() == 1)
        #expect(try await derived.read { try Int64.fetchOne($0, sql: "SELECT indexed_commit FROM v2_search_documents") } == published)
        try await queue.write { try GRDBV2LocalSyncStore.enqueueMessageSearchIndexJob(messageID: id, db: $0) }
        try await derived.write { db in
            db.add(function: DatabaseFunction("replace_job", argumentCount: 0) { _ in
                try queue.write { try GRDBV2LocalSyncStore.enqueueMessageSearchIndexJob(messageID: id, db: $0) }
                return 0
            })
            try db.execute(sql: "CREATE TEMP TRIGGER replace_job AFTER INSERT ON v2_search_documents BEGIN SELECT replace_job(); END")
        }
        #expect(try await resumed.messageSearch.processPendingMessageSearchIndexJobs() == 1)
        #expect(try await resumed.messageSearch.messageSearchIndexProgress().pendingJobCount == 1)
        try await derived.write { try $0.execute(sql: "DROP TRIGGER replace_job") }
        #expect(try await resumed.messageSearch.processPendingMessageSearchIndexJobs() == 1)
        #expect(try await resumed.messageSearch.messageSearchIndexProgress().pendingJobCount == 0)
        try await resumed.close()
    }

    @Test("只读实例只用就绪索引，缺失和损坏只由可写实例重建")
    func readOnlyAndDerivedRecovery() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "V2.sqlite"), binding = V2LocalInstallationBinding(value: UUID())
        let user = UserID(uuid: UUID()), room = RoomID(uuid: UUID()), id = MessageID(uuid: UUID())
        let searchURL = V2LocalDatabaseArtifacts(primary: url).search
        let original = try GRDBV2LocalSyncStore(databaseURL: url, installationBinding: binding, userID: user)
        try await applyRoomEvents(original, records: [acceptedRoomEvent(sourceEvent: UUID().uuidString, roomID: room, senderID: user,
            messageID: id, roomSequence: 1, text: "待恢复", createdAtMilliseconds: 1000)])
        try await original.messageSearch.prepareMessageSearchIndex()
        try await original.close()
        let ready = try GRDBV2LocalSyncStore(localReadOnlyDatabaseURL: url, installationBinding: binding, userID: user)
        #expect(try await ready.messageSearch.searchMessages(.init(query: "恢复")).hits.map(\.messageID) == [id])
        await #expect(throws: V2MessageSearchError.readOnly) { try await ready.messageSearch.prepareMessageSearchIndex() }
        try await ready.close()
        for corrupt in [false, true] {
            for suffix in ["", "-wal", "-shm"] where FileManager.default.fileExists(atPath: searchURL.path + suffix) {
                try FileManager.default.removeItem(atPath: searchURL.path + suffix)
            }
            if corrupt { try Data("damaged index file".utf8).write(to: searchURL) }
            let read = try GRDBV2LocalSyncStore(localReadOnlyDatabaseURL: url, installationBinding: binding, userID: user)
            #expect(try await read.messageSearch.messageSearchIndexState() == .building)
            await #expect(throws: V2MessageSearchError.indexUnavailable(.building)) {
                try await read.messageSearch.searchMessages(.init(query: "恢复"))
            }
            try await read.close()
            #expect(FileManager.default.fileExists(atPath: searchURL.path) == corrupt)
            if corrupt { #expect(try Data(contentsOf: searchURL) == Data("damaged index file".utf8)) }
            let writable = try GRDBV2LocalSyncStore(databaseURL: url, installationBinding: binding, userID: user)
            #expect(try await writable.messageSearch.messageSearchIndexState() == .building)
            try await writable.messageSearch.prepareMessageSearchIndex()
            #expect(try await writable.messageSearch.searchMessages(.init(query: "恢复")).hits.map(\.messageID) == [id])
            try await writable.close()
        }
    }
}

extension V2MessageSearchTests {
    @Test("重建时接收的编辑会被追平，中断后以主库重建")
    func interruptedRebuildAndConcurrentMutation() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "V2.sqlite"), binding = V2LocalInstallationBinding(value: UUID())
        let store = try GRDBV2LocalSyncStore(databaseURL: url, installationBinding: binding)
        let room = RoomID(uuid: UUID()), user = UserID(uuid: UUID()), id = MessageID(uuid: UUID())
        try await applyRoomEvents(store, records: [acceptedRoomEvent(sourceEvent: UUID().uuidString, roomID: room,
            senderID: user, messageID: id, roomSequence: 1, text: "原文", createdAtMilliseconds: 1000)])
        let primary = await store.databasePool
        try await primary.write { try $0.execute(sql: """
            CREATE TEMP TRIGGER interrupt_rebuild BEFORE UPDATE OF state ON v2_message_search_state
            WHEN new.state='ready' BEGIN SELECT RAISE(ABORT,'interrupt rebuild'); END
            """) }
        await #expect(throws: DatabaseError.self) { try await store.messageSearch.rebuildMessageSearchIndex() }
        #expect(try await store.messageSearch.messageSearchIndexState() == .building)
        await #expect(throws: V2MessageSearchError.indexUnavailable(.building)) { try await store.messageSearch.searchMessages(.init(query: "原文")) }
        try await store.close()

        let resumed = try GRDBV2LocalSyncStore(databaseURL: url, installationBinding: binding)
        let derived = try #require(await resumed.messageSearchDatabasePool)
        let (started, signal) = AsyncStream<Void>.makeStream()
        let release = DispatchSemaphore(value: 0)
        try await derived.write { db in
            db.add(function: DatabaseFunction("pause_rebuild", argumentCount: 0) { _ in
                signal.yield(())
                guard release.wait(timeout: .now() + 10) == .success else { throw CancellationError() }
                return 0
            })
            try db.execute(sql: "CREATE TEMP TRIGGER pause_publish AFTER INSERT ON v2_search_documents WHEN new.job_id IS NULL BEGIN SELECT pause_rebuild(); END")
        }
        let rebuilding = Task { try await resumed.messageSearch.prepareMessageSearchIndex() }
        defer { release.signal(); rebuilding.cancel(); signal.finish() }
        var notices = started.makeAsyncIterator()
        _ = await notices.next()
        try await applyRoomEvents(resumed, records: [editedRecord(sequence: 2, sourceEvent: UUID().uuidString,
            roomID: room, messageID: id, revision: 2, text: "更新正文")])
        release.signal()
        try await rebuilding.value
        #expect(try await resumed.messageSearch.searchMessages(.init(query: "原文")).hits.isEmpty)
        #expect(try await resumed.messageSearch.searchMessages(.init(query: "更新")).hits.map(\.messageID) == [id])
        #expect(try await resumed.messageSearch.messageSearchIndexProgress().pendingJobCount == 0)
        try await resumed.close()
    }

    @Test("同步事务尚未提交时搜索仍可读取已提交消息")
    func readWhileSyncStoreIsOccupied() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try GRDBV2LocalSyncStore(databaseURL: directory.appending(path: "V2.sqlite"), installationBinding: .init(value: UUID()))
        let room = RoomID(uuid: UUID()), sender = UserID(uuid: UUID()), first = MessageID(uuid: UUID())
        try await applyRoomEvents(store, records: [acceptedRoomEvent(sourceEvent: UUID().uuidString, roomID: room, senderID: sender,
            messageID: first, roomSequence: 1, text: "已提交", createdAtMilliseconds: 1000)])
        try await store.messageSearch.prepareMessageSearchIndex()
        let (started, signal) = AsyncStream<Void>.makeStream()
        let release = DispatchSemaphore(value: 0)
        let primary = await store.databasePool
        try await primary.write { db in
            db.add(function: DatabaseFunction("pause_sync", argumentCount: 0) { _ in
                signal.yield(())
                guard release.wait(timeout: .now() + 10) == .success else { throw CancellationError() }
                return 0
            })
            try db.execute(sql: "CREATE TEMP TRIGGER pause_sync AFTER INSERT ON v2_message_projections BEGIN SELECT pause_sync(); END")
        }
        let record = try acceptedRoomEvent(sourceEvent: UUID().uuidString, roomID: room, senderID: sender,
            messageID: MessageID(uuid: UUID()), roomSequence: 2, text: "未提交", createdAtMilliseconds: 2000)
        let writing = Task { try await applyRoomEvents(store, records: [record]) }
        defer { release.signal(); writing.cancel(); signal.finish() }
        var notices = started.makeAsyncIterator()
        _ = await notices.next()
        #expect(try await store.messageSearch.searchMessages(.init(query: "提交")).hits.map(\.messageID) == [first])
        release.signal()
        try await writing.value
        try await store.close()
    }
}

private actor SearchCloseProbe {
    private(set) var finished = false
    func finish() { finished = true }
}

extension V2MessageSearchTests {
    @Test("关闭拒绝新查询，等待正在执行的 SQLite 查询退出")
    func closeDrainsInFlightSearch() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "V2.sqlite")
        let store = try GRDBV2LocalSyncStore(databaseURL: url, installationBinding: .init(value: UUID()))
        try await store.messageSearch.prepareMessageSearchIndex()
        let normal = try #require(await store.messageSearchDatabasePool)
        try await normal.write { db in
            try db.execute(sql: """
                ALTER TABLE v2_search_publication RENAME TO real_publication;
                CREATE VIEW v2_search_publication AS SELECT singleton,generation,pause_read(commit_sequence) AS commit_sequence FROM real_publication
                """)
        }
        let (entered, signal) = AsyncStream<Void>.makeStream()
        let release = DispatchSemaphore(value: 0)
        var configuration = Configuration()
        configuration.readonly = true
        configuration.prepareDatabase { db in
            db.add(function: DatabaseFunction("pause_read", argumentCount: 1) { args in
                signal.yield(())
                guard release.wait(timeout: .now() + 10) == .success else { throw CancellationError() }
                return args[0]
            })
        }
        let search = try DatabasePool(path: V2LocalDatabaseArtifacts(primary: url).search.path, configuration: configuration)
        let service = try await V2MessageSearchService(primary: store.databasePool, search: search, writable: false, scope: nil)
        let query = Task { try await service.searchMessages(.init(query: "等待")) }
        defer { release.signal(); signal.finish(); query.cancel() }
        var notices = entered.makeAsyncIterator()
        _ = await notices.next()
        let probe = SearchCloseProbe()
        let closing = Task { await service.close(); await probe.finish() }
        while true {
            do { _ = try await service.messageSearchIndexState() }
            catch V2MessageSearchError.closed { break }
            await Task.yield()
        }
        #expect(await !probe.finished)
        await #expect(throws: V2MessageSearchError.closed) { try await service.searchMessages(.init(query: "新请求")) }
        release.signal()
        await closing.value
        if case .success = await query.result { Issue.record("关闭后不应发布在途搜索结果") }
        try search.close()
        try await store.close()
    }

    @Test("查询发现派生表缺失时经写入者触发重建")
    func repairMissingDerivedTable() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try GRDBV2LocalSyncStore(databaseURL: directory.appending(path: "V2.sqlite"), installationBinding: .init(value: UUID()))
        let id = MessageID(uuid: UUID())
        try await applyRoomEvents(store, records: [acceptedRoomEvent(sourceEvent: UUID().uuidString, roomID: .init(uuid: UUID()),
            senderID: .init(uuid: UUID()), messageID: id, roomSequence: 1, text: "完整", createdAtMilliseconds: 1000)])
        try await store.messageSearch.prepareMessageSearchIndex()
        let pool = try #require(await store.messageSearchDatabasePool)
        try await pool.write { try $0.execute(sql: "DROP TABLE v2_search_documents") }
        await #expect(throws: V2MessageSearchError.indexUnavailable(.building)) { try await store.messageSearch.searchMessages(.init(query: "完")) }
        #expect(try await store.messageSearch.messageSearchIndexState() == .building)
        try await store.messageSearch.prepareMessageSearchIndex()
        #expect(try await store.messageSearch.searchMessages(.init(query: "完")).hits.map(\.messageID) == [id])
        try await store.close()
    }
}

extension V2MessageSearchTests {
    @Test("快照激活栅栏解除后自动接续建索引")
    func indexerResumesAfterSnapshotFence() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try GRDBV2LocalSyncStore(databaseURL: directory.appending(path: "V2.sqlite"), installationBinding: .init(value: UUID()))
        let pool = await store.databasePool
        try await pool.write { try $0.execute(sql: """
            INSERT INTO v2_snapshot_import(snapshot_id,generation,base_sequence,root_digest,next_sync_token,receipt,capability_profile,
                page_count,total_items,total_bytes,rolling_digest,activation_prepared) VALUES('pending',1,0,'','','','',0,0,0,'',1)
            """) }
        await store.messageSearch.startIndexing()
        await #expect(throws: V2ClientSyncError.resetPending) { try await store.messageSearch.prepareMessageSearchIndex() }
        try await pool.write { try $0.execute(sql: "DELETE FROM v2_snapshot_import") }
        let deadline = ContinuousClock.now + .seconds(4)
        while try await store.messageSearch.messageSearchIndexState() == .building && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(try await store.messageSearch.messageSearchIndexState() == .ready)
        try await store.close()
    }
}

extension V2MessageSearchTests {
    @Test("同一个索引文件的两个账号存储对象串行消费，取消等待不影响持有者")
    func twoStoresShareOneWriteLease() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "V2.sqlite"), binding = V2LocalInstallationBinding(value: UUID())
        let owner = try GRDBV2LocalSyncStore(databaseURL: url, installationBinding: binding)
        try await owner.messageSearch.prepareMessageSearchIndex()
        let peer = try GRDBV2LocalSyncStore(databaseURL: url, installationBinding: binding)
        let id = MessageID(uuid: UUID())
        try await applyRoomEvents(peer, records: [acceptedRoomEvent(sourceEvent: UUID().uuidString, roomID: .init(uuid: UUID()),
            senderID: .init(uuid: UUID()), messageID: id, roomSequence: 1, text: "共享索引", createdAtMilliseconds: 1000)])
        let (started, signal) = AsyncStream<Void>.makeStream()
        let release = DispatchSemaphore(value: 0)
        let pool = try #require(await owner.messageSearchDatabasePool)
        try await pool.write { db in
            db.add(function: DatabaseFunction("pause_owner", argumentCount: 0) { _ in
                signal.yield(())
                guard release.wait(timeout: .now() + 10) == .success else { throw CancellationError() }
                return 0
            })
            try db.execute(sql: "CREATE TEMP TRIGGER pause_owner AFTER INSERT ON v2_search_documents BEGIN SELECT pause_owner(); END")
        }
        let writing = Task { try await owner.messageSearch.processPendingMessageSearchIndexJobs() }
        defer { release.signal(); signal.finish(); writing.cancel() }
        var notices = started.makeAsyncIterator()
        _ = await notices.next()
        let peerTask = Task { try await peer.messageSearch.processPendingMessageSearchIndexJobs() }
        try await Task.sleep(for: .milliseconds(70))
        peerTask.cancel()
        await #expect(throws: CancellationError.self) { try await peerTask.value }
        release.signal()
        #expect(try await writing.value == 1)
        #expect(try await peer.messageSearch.processPendingMessageSearchIndexJobs() == 0)
        #expect(try await peer.messageSearch.searchMessages(.init(query: "共享")).hits.map(\.messageID) == [id])
        // 只启动 owner；在 peer 的主库连接提交下一条消息。
        await owner.messageSearch.startIndexing()
        try await Task.sleep(for: .milliseconds(30))
        let newID = MessageID(uuid: UUID())
        try await applyRoomEvents(peer, records: [acceptedRoomEvent(sourceEvent: UUID().uuidString, roomID: .init(uuid: UUID()),
            senderID: .init(uuid: UUID()), messageID: newID, roomSequence: 1, text: "跨池提交", createdAtMilliseconds: 2000)])
        release.signal() // owner 的测试触发器仍在；让这一批通过。
        let deadline = ContinuousClock.now + .seconds(3)
        while try await owner.messageSearch.messageSearchIndexProgress().pendingJobCount > 0 && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(try await peer.messageSearch.searchMessages(.init(query: "跨池")).hits.map(\.messageID) == [newID])
        try await owner.close()
        try await peer.close()
    }
}
