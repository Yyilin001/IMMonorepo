import Foundation
import IMV2ActorContracts
import NIOPosix
import Testing
@testable import IMV2ActorCluster
@testable import IMV2ServerInfrastructure

@Suite("Raft voting state on actual disk")
struct V2PlacementRaftFileStorageTests {
    private func withDisk(_ body: (URL, NIOThreadPool) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("imv2-raft-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        let pool = NIOThreadPool(numberOfThreads: 4)
        pool.start()
        do {
            try await body(directory.appendingPathComponent("voter.pb"), pool)
            try await pool.shutdownGracefully()
            try FileManager.default.removeItem(at: directory)
        } catch {
            try? await pool.shutdownGracefully()
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }
    @Test("Actual fsync compaction reopens with absolute indexes and the original success receipt")
    func compactedDiskRestart() async throws {
        try await withDisk { path, pool in
            let base = initial(), host = V2ActorHostIdentity(hostID: base.voterID, incarnationID: UUID())
            let snapshot = try V2ActorPlacementSnapshot(clusterID: base.groupID, revision: 1,
                slots: [.init(owner: .init(host: host, epoch: 1), transfer: nil)])
            let id = UUID(), command = V2ActorPlacementCommand.retireHost(host)
            let store = try await V2PlacementRaftFileStorage.bootstrap(at: path, initial: base, pool: pool)
            var committed = base; committed.term = 1
            committed.log = try [.init(term: 1, payload: V2PlacementRaftApplication.encode(.bootstrap(snapshot))),
                .init(term: 1, payload: V2PlacementRaftApplication.encode(.command(command, expected: snapshot, requestID: id)))]
            committed.commitIndex = 2
            try await store.persist(committed, replacing: base)
            var app = V2PlacementRaftApplication(groupID: base.groupID); try app.apply(committed)
            let result = try #require(try app.receipt(for: command, requestID: id))
            let voter = try await V2PlacementRaftVoter.open(id: base.voterID, groupID: base.groupID, voters: base.voters, storage: store)
            try await voter.compact(app.checkpoint(), through: 2)
            let compacted = try await voter.committedState()
            #expect(compacted.baseIndex == 2 && compacted.lastIndex == 2 && compacted.log.isEmpty)
            await voter.stop(); try await store.close()
            let reopened = try await V2PlacementRaftFileStorage.open(at: path, pool: pool)
            let disk = try await reopened.load()
            #expect(disk == compacted)
            var restored = V2PlacementRaftApplication(groupID: base.groupID); try restored.apply(disk)
            #expect(restored.appliedIndex == 2 && restored.snapshot == result)
            #expect(try restored.receipt(for: command, requestID: id) == result)
            var erased = disk; erased.snapshot = nil
            await #expect(throws: V2PlacementRaftError.invalidState) { try await reopened.persist(erased, replacing: disk) }
            #expect(try await reopened.load() == disk)
            try await reopened.close()
        }
    }

    @Test("Remote checkpoint advances a lagging disk voter and reopens with the certified state")
    func remoteSnapshotDiskRestart() async throws {
        try await withDisk { path, pool in
            let base = initial(), leader = try #require(base.voters.first { $0 != base.voterID })
            let host = V2ActorHostIdentity(hostID: leader, incarnationID: UUID())
            let genesis = try V2ActorPlacementSnapshot(clusterID: base.groupID, revision: 1,
                slots: [.init(owner: .init(host: host, epoch: 1), transfer: nil)])
            var committed = base; committed.term = 1
            committed.log = try [.init(term: 1, payload: V2PlacementRaftApplication.encode(.bootstrap(genesis))),
                .init(term: 1, payload: Data())]
            committed.commitIndex = 2
            var application = V2PlacementRaftApplication(groupID: base.groupID); try application.apply(committed)
            let transfer = try V2PlacementRaftSnapshotTransfer(groupID: base.groupID, leader: leader, term: 2,
                snapshot: .init(index: 2, term: 1, application: application.checkpoint()))
            let store = try await V2PlacementRaftFileStorage.bootstrap(at: path, initial: base, pool: pool)
            let voter = try await V2PlacementRaftVoter.open(id: base.voterID, groupID: base.groupID, voters: base.voters, storage: store)
            #expect(try await voter.snapshot(transfer.chunk(at: 0), from: leader).installed)
            let installed = try await store.load()
            #expect(installed.term == 2 && installed.baseIndex == 2 && installed.commitIndex == 2)
            await voter.stop(); try await store.close()
            let reopened = try await V2PlacementRaftFileStorage.open(at: path, pool: pool)
            let disk = try await reopened.load()
            #expect(disk == installed)
            var restored = V2PlacementRaftApplication(groupID: base.groupID); try restored.apply(disk)
            #expect(restored.snapshot == genesis && restored.appliedIndex == 2)
            try await reopened.close()
        }
    }

    private func initial() -> V2PlacementRaftPersistentState {
        let a = V2ActorHostID(uuid: UUID()), b = V2ActorHostID(uuid: UUID()), c = V2ActorHostID(uuid: UUID())
        return .init(groupID: UUID(), voterID: a, voters: [a, b, c])
    }

    @Test("Restart retains term, vote and committed prefix; local identity cannot be reassigned")
    func restart() async throws {
        try await withDisk { path, pool in
            let base = initial()
            let store = try await V2PlacementRaftFileStorage.bootstrap(at: path, initial: base, pool: pool)
            var committed = base
            committed.term = 2; committed.votedFor = base.voterID
            committed.log = [.init(term: 2, payload: Data([1, 2, 3]))]; committed.commitIndex = 1
            try await store.persist(committed, replacing: base)
            try await store.close()
            let reopened = try await V2PlacementRaftFileStorage.open(at: path, pool: pool)
            #expect(try await reopened.load() == committed)
            let another = try #require(base.voters.first { $0 != base.voterID })
            await #expect(throws: V2PlacementRaftError.invalidState) {
                _ = try await V2PlacementRaftVoter.open(id: another, groupID: base.groupID, voters: base.voters, storage: reopened)
            }
            var erased = committed; erased.log = []; erased.commitIndex = 0
            await #expect(throws: V2PlacementRaftError.invalidState) { try await reopened.persist(erased, replacing: committed) }
            var revote = committed; revote.votedFor = another
            await #expect(throws: V2PlacementRaftError.invalidState) { try await reopened.persist(revote, replacing: committed) }
            #expect(try await reopened.load() == committed)
            try await reopened.close()
        }
    }

    @Test("Only one file owner; provisioning never overwrites history")
    func exclusiveOwnership() async throws {
        try await withDisk { path, pool in
            let base = initial()
            let store = try await V2PlacementRaftFileStorage.bootstrap(at: path, initial: base, pool: pool)
            await #expect(throws: (any Error).self) { _ = try await V2PlacementRaftFileStorage.open(at: path, pool: pool) }
            try await store.close()
            await #expect(throws: (any Error).self) {
                _ = try await V2PlacementRaftFileStorage.bootstrap(at: path, initial: initial(), pool: pool)
            }
            let reopened = try await V2PlacementRaftFileStorage.open(at: path, pool: pool)
            #expect(try await reopened.load() == base)
            try await reopened.close()
        }
    }

    @Test("Missing or corrupt history fails closed and releases the lock")
    func corruptHistory() async throws {
        try await withDisk { path, pool in
            await #expect(throws: (any Error).self) { _ = try await V2PlacementRaftFileStorage.open(at: path, pool: pool) }
            #expect(!FileManager.default.fileExists(atPath: path.path))
            let base = initial()
            let store = try await V2PlacementRaftFileStorage.bootstrap(at: path, initial: base, pool: pool)
            try await store.close()
            var bytes = try Data(contentsOf: path); bytes[bytes.count - 1] ^= 1
            try bytes.write(to: path)
            await #expect(throws: (any Error).self) { _ = try await V2PlacementRaftFileStorage.open(at: path, pool: pool) }
            #expect(try Data(contentsOf: path) == bytes)
            try V2PlacementRaftProtobuf.encodeFile(base).write(to: path)
            let repaired = try await V2PlacementRaftFileStorage.open(at: path, pool: pool)
            #expect(try await repaired.load() == base)
            try await repaired.close()
        }
    }

    @Test("Concurrent disk CAS cannot acknowledge two competing promises on a multi-worker pool")
    func competingPromises() async throws {
        try await withDisk { path, pool in
            let base = initial()
            let store = try await V2PlacementRaftFileStorage.bootstrap(at: path, initial: base, pool: pool)
            let candidates = base.voters.filter { $0 != base.voterID }
            let successful = await withTaskGroup(of: Bool.self) { tasks in
                for id in candidates {
                    var candidate = base; candidate.term = 1; candidate.votedFor = id
                    tasks.addTask {
                        do { try await store.persist(candidate, replacing: base); return true } catch { return false }
                    }
                }
                var count = 0
                for await value in tasks where value { count += 1 }
                return count
            }
            #expect(successful == 1)
            let persisted = try await store.load()
            #expect(persisted.term == 1 && persisted.votedFor != nil)
            try await store.close()
            await #expect(throws: V2PlacementRaftError.closed) { _ = try await store.load() }
            let reopened = try await V2PlacementRaftFileStorage.open(at: path, pool: pool)
            #expect(try await reopened.load() == persisted)
            try await reopened.close()
        }
    }
    @Test("Three real disk voters preserve commits across partition, leader change and restart")
    func threeVoters() async throws {
        try await withDisk { path, pool in
            let base = initial(), ids = base.voters.sorted { $0.rawValue < $1.rawValue }
            var stores: [V2PlacementRaftFileStorage] = []
            var voters: [V2PlacementRaftVoter] = []
            do {
                for id in ids {
                    let state = V2PlacementRaftPersistentState(groupID: base.groupID, voterID: id, voters: base.voters)
                    let store = try await V2PlacementRaftFileStorage.bootstrap(
                        at: path.deletingLastPathComponent().appendingPathComponent(id.rawValue + ".pb"), initial: state, pool: pool)
                    stores.append(store)
                    voters.append(try await .open(id: id, groupID: base.groupID, voters: base.voters, storage: store))
                }
                let election = try await voters[0].campaign()
                let vote = try await voters[1].vote(election, from: ids[0])
                try await voters[0].receivedVote(vote, from: ids[1])
                try await replicate(voters[0], id: ids[0], to: voters[1], peer: ids[1])
                #expect(await voters[0].inspection().state.commitIndex == 1)
                let index = try await voters[0].propose(Data([7, 8, 9]))
                #expect(await voters[0].inspection().state.commitIndex < index)
                try await replicate(voters[0], id: ids[0], to: voters[1], peer: ids[1])
                try await replicate(voters[0], id: ids[0], to: voters[1], peer: ids[1])
                #expect(await voters[1].inspection().state.commitIndex == index)
                // The old leader can create a read round but an isolated self
                // never supplies the fresh majority needed to serve it.
                let read = try await voters[0].beginRead()
                #expect(try await voters[0].confirmedRead(read) == nil)
                let newElection = try await voters[1].campaign()
                let newVote = try await voters[2].vote(newElection, from: ids[1])
                try await voters[1].receivedVote(newVote, from: ids[2])
                for _ in 0..<4 { try await replicate(voters[1], id: ids[1], to: voters[2], peer: ids[2]) }
                let committed = await voters[1].inspection().state
                #expect(committed.commitIndex == index + 1)
                #expect(committed.log[Int(index) - 1].payload == Data([7, 8, 9]))
                try await replicate(voters[0], id: ids[0], to: voters[2], peer: ids[2])
                #expect(await voters[0].inspection().role == .follower)
                #expect(try await voters[0].confirmedRead(read) == nil)
                await voters[1].stop()
                try await stores[1].close()
                let reopened = try await V2PlacementRaftFileStorage.open(
                    at: path.deletingLastPathComponent().appendingPathComponent(ids[1].rawValue + ".pb"), pool: pool)
                stores[1] = reopened
                voters[1] = try await .open(id: ids[1], groupID: base.groupID, voters: base.voters, storage: reopened)
                #expect(await voters[1].inspection().state == committed)
                #expect(await voters[1].inspection().role == .follower)
                for voter in voters { await voter.stop() }
                for store in stores { try await store.close() }
            } catch {
                for voter in voters { await voter.stop() }
                for store in stores { try? await store.close() }
                throw error
            }
        }
    }
    private func replicate(_ leader: V2PlacementRaftVoter, id: V2ActorHostID,
                           to follower: V2PlacementRaftVoter, peer: V2ActorHostID) async throws {
        let request = try await leader.appendRequest(to: peer)
        let reply = try await follower.append(request, from: id)
        try await leader.receivedAppend(reply, from: peer, for: request)
    }

}
