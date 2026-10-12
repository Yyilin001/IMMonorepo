import Foundation
import Crypto
import IMV2ActorContracts

package enum V2PlacementRaftError: Error, Equatable {
    case invalidConfiguration, invalidState, invalidMessage, wrongGroup, unauthorizedVoter
    case notLeader, notReady, capacity, termExhausted, storageUnavailable, closed, incompleteShutdown
}

package struct V2PlacementRaftEntry: Equatable, Sendable {
    package let term: UInt64
    /// Empty payload is the leader's barrier, never a placement command.
    package let payload: Data
}

/// The controller persists a candidate copy before publishing it or replying.
/// Persisting commitIndex as well permits restart to replay only a certified prefix.
package struct V2PlacementRaftSnapshot: Equatable, Sendable {
    package let index: UInt64
    package let term: UInt64
    package let application: Data
}

package struct V2PlacementRaftPersistentState: Equatable, Sendable {
    package let groupID: UUID
    package let voterID: V2ActorHostID
    package let voters: Set<V2ActorHostID>
    package var term: UInt64 = 0
    package var votedFor: V2ActorHostID? = nil
    package var log: [V2PlacementRaftEntry] = []
    package var snapshot: V2PlacementRaftSnapshot? = nil
    package var baseIndex: UInt64 { snapshot?.index ?? 0 }
    package var lastIndex: UInt64 { baseIndex + UInt64(log.count) }
    package func term(at index: UInt64) -> UInt64? {
        if index == baseIndex { return snapshot?.term ?? 0 }
        guard index > baseIndex, index <= lastIndex else { return nil }
        return log[Int(index - baseIndex - 1)].term
    }
    package func entry(at index: UInt64) -> V2PlacementRaftEntry? {
        guard index > baseIndex, index <= lastIndex else { return nil }
        return log[Int(index - baseIndex - 1)]
    }
    package var commitIndex: UInt64 = 0
    package init(groupID: UUID, voterID: V2ActorHostID, voters: Set<V2ActorHostID>, term: UInt64 = 0,
                 votedFor: V2ActorHostID? = nil, log: [V2PlacementRaftEntry] = [], commitIndex: UInt64 = 0, snapshot: V2PlacementRaftSnapshot? = nil) {
        self.groupID = groupID; self.voterID = voterID; self.voters = voters; self.term = term
        self.votedFor = votedFor; self.log = log; self.commitIndex = commitIndex; self.snapshot = snapshot
    }
}

package struct V2PlacementRaftVoteRequest: Equatable, Sendable {
    package let groupID: UUID
    package let candidate: V2ActorHostID
    package let term: UInt64
    package let lastIndex: UInt64
    package let lastTerm: UInt64
}
package struct V2PlacementRaftVoteReply: Equatable, Sendable {
    package let groupID: UUID
    package let term: UInt64
    package let granted: Bool
}
package struct V2PlacementRaftAppendRequest: Equatable, Sendable {
    package let groupID: UUID
    package let leader: V2ActorHostID
    package let term: UInt64
    package let previousIndex: UInt64
    package let previousTerm: UInt64
    package let entries: [V2PlacementRaftEntry]
    package let leaderCommit: UInt64
    package let readID: UUID?
}
package struct V2PlacementRaftAppendReply: Equatable, Sendable {
    package let groupID: UUID
    package let term: UInt64
    package let accepted: Bool
    package let matchedIndex: UInt64
    package let readID: UUID?
}

/// Pure fixed-three-voter Raft transitions. No room lease, timer, I/O or actor
/// reentrancy occurs here. A controller must serialize copy -> persist -> publish
/// before any success reply, outbound message, committed application or read.
package struct V2PlacementRaftCore: Sendable {
    package enum Role: Equatable, Sendable { case follower, candidate, leader }
    package static let maximumEntries = 65_536
    package static let maximumLogIndex = UInt64(Int64.max) - UInt64(maximumEntries)
    package static let maximumPayloadBytes = 524_288
    package let id: V2ActorHostID
    package private(set) var state: V2PlacementRaftPersistentState
    package private(set) var role: Role = .follower
    package private(set) var electionActivity: UInt64 = 0
    package private(set) var leader: V2ActorHostID?
    private var votes: Set<V2ActorHostID> = []
    private var next: [V2ActorHostID: UInt64] = [:]
    private var matched: [V2ActorHostID: UInt64] = [:]
    private struct Read: Sendable { let term: UInt64; let index: UInt64; var votes: Set<V2ActorHostID> }
    private var reads: [UUID: Read] = [:]
    private struct SnapshotAssembly: Sendable {
        let first: V2PlacementRaftSnapshotChunk
        var bytes: Data
        func matches(_ request: V2PlacementRaftSnapshotChunk) -> Bool {
            first.groupID == request.groupID && first.leader == request.leader && first.term == request.term &&
            first.transferID == request.transferID && first.snapshotIndex == request.snapshotIndex &&
            first.snapshotTerm == request.snapshotTerm && first.digest == request.digest && first.totalBytes == request.totalBytes
        }
    }
    private var incomingSnapshot: SnapshotAssembly?
    private var snapshotTransfers: [V2ActorHostID: (transfer: V2PlacementRaftSnapshotTransfer, offset: Int)] = [:]
    package var lastIndex: UInt64 { state.lastIndex }
    private var lastTerm: UInt64 { state.log.last?.term ?? state.snapshot?.term ?? 0 }

    package init(id: V2ActorHostID, groupID: UUID, voters: Set<V2ActorHostID>,
                 persisted: V2PlacementRaftPersistentState) throws {
        guard voters.count == 3, voters.contains(id) else { throw V2PlacementRaftError.invalidConfiguration }
        guard persisted.groupID == groupID, persisted.voterID == id, persisted.voters == voters,
              persisted.votedFor.map(voters.contains) ?? true,
              persisted.log.count <= Self.maximumEntries,
              persisted.baseIndex <= Self.maximumLogIndex,
              persisted.commitIndex >= persisted.baseIndex, persisted.commitIndex <= persisted.lastIndex else { throw V2PlacementRaftError.invalidState }
        var previous: UInt64 = 0
        if let snapshot = persisted.snapshot {
            guard snapshot.index > 0, snapshot.term > 0, snapshot.term <= persisted.term,
                  try V2PlacementRaftCheckpoint.decode(snapshot.application, groupID: groupID).appliedIndex == snapshot.index else {
                throw V2PlacementRaftError.invalidState
            }
            previous = snapshot.term
        }
        for entry in persisted.log {
            guard entry.term > 0, entry.term >= previous, entry.term <= persisted.term,
                  entry.payload.count <= Self.maximumPayloadBytes else { throw V2PlacementRaftError.invalidState }
            previous = entry.term
        }
        guard persisted.term > 0 || persisted.votedFor == nil else { throw V2PlacementRaftError.invalidState }
        self.id = id; self.state = persisted
    }

    package mutating func campaign() throws -> V2PlacementRaftVoteRequest {
        guard state.term < UInt64.max else { throw V2PlacementRaftError.termExhausted }
        state.term += 1; state.votedFor = id
        role = .candidate; leader = nil; votes = [id]; reads.removeAll(); next.removeAll(); matched.removeAll()
        incomingSnapshot = nil; snapshotTransfers.removeAll()
        return .init(groupID: state.groupID, candidate: id, term: state.term, lastIndex: lastIndex, lastTerm: lastTerm)
    }

    package mutating func vote(_ request: V2PlacementRaftVoteRequest, from peer: V2ActorHostID)
        throws -> V2PlacementRaftVoteReply {
        try check(peer, group: request.groupID)
        guard request.candidate == peer, request.term > 0, request.lastIndex <= Self.maximumLogIndex,
              request.lastTerm <= request.term, (request.lastIndex == 0) == (request.lastTerm == 0) else {
            throw V2PlacementRaftError.invalidMessage
        }
        if request.term > state.term { stepDown(term: request.term) }
        let upToDate = request.lastTerm > lastTerm || (request.lastTerm == lastTerm && request.lastIndex >= lastIndex)
        let granted = request.term == state.term && upToDate && (state.votedFor == nil || state.votedFor == peer)
        if granted { state.votedFor = peer; electionActivity &+= 1 }
        return .init(groupID: state.groupID, term: state.term, granted: granted)
    }

    package mutating func receivedVote(_ reply: V2PlacementRaftVoteReply, from peer: V2ActorHostID) throws {
        try check(peer, group: reply.groupID)
        if reply.term > state.term { stepDown(term: reply.term); return }
        guard role == .candidate, reply.term == state.term, reply.granted else { return }
        votes.insert(peer)
        guard votes.count >= 2 else { return }
        guard state.log.count < Self.maximumEntries, lastIndex < Self.maximumLogIndex else { throw V2PlacementRaftError.capacity }
        role = .leader; leader = id; reads.removeAll()
        next = Dictionary(uniqueKeysWithValues: state.voters.filter { $0 != id }.map { ($0, lastIndex + 1) })
        matched = Dictionary(uniqueKeysWithValues: state.voters.map { ($0, $0 == id ? lastIndex : 0) })
        // Current-term majority must establish old-term entries before serving
        // reads. A campaign never certifies an old log using votes alone.
        state.log.append(.init(term: state.term, payload: Data()))
        matched[id] = lastIndex
    }

    package mutating func propose(_ payload: Data) throws -> UInt64 {
        guard role == .leader else { throw V2PlacementRaftError.notLeader }
        guard !payload.isEmpty, payload.count <= Self.maximumPayloadBytes else { throw V2PlacementRaftError.invalidMessage }
        guard state.log.count < Self.maximumEntries, lastIndex < Self.maximumLogIndex else { throw V2PlacementRaftError.capacity }
        state.log.append(.init(term: state.term, payload: payload)); matched[id] = lastIndex
        return lastIndex
    }

    package func appendRequest(to peer: V2ActorHostID, maximumEntries: Int = 16, readID: UUID? = nil)
        throws -> V2PlacementRaftAppendRequest {
        try check(peer, group: state.groupID)
        guard role == .leader, let nextIndex = next[peer] else { throw V2PlacementRaftError.notLeader }
        guard (1...16).contains(maximumEntries), nextIndex > 0, nextIndex <= lastIndex + 1,
              readID.map({ reads[$0]?.term == state.term }) ?? true else { throw V2PlacementRaftError.invalidMessage }
        guard nextIndex > state.baseIndex else { throw V2PlacementRaftError.notReady }
        let previous = nextIndex - 1, start = Int(previous - state.baseIndex)
        var entries: [V2PlacementRaftEntry] = [], bytes = 0
        for entry in state.log.dropFirst(start).prefix(maximumEntries) {
            // Bound the complete authenticated packet, not only entry count.
            // The first valid entry always fits; subsequent rounds catch up.
            if bytes + entry.payload.count > 700_000 { break }
            entries.append(entry); bytes += entry.payload.count
        }
        return .init(groupID: state.groupID, leader: id, term: state.term,
            previousIndex: previous, previousTerm: state.term(at: previous)!,
            entries: entries, leaderCommit: state.commitIndex, readID: readID)
    }

    package mutating func append(_ request: V2PlacementRaftAppendRequest, from peer: V2ActorHostID)
        throws -> V2PlacementRaftAppendReply {
        try check(peer, group: request.groupID)
        guard request.leader == peer, request.term > 0, request.previousIndex <= Self.maximumLogIndex,
              (request.previousIndex == 0) == (request.previousTerm == 0), request.previousTerm <= request.term,
              request.entries.count <= 16,
              request.previousIndex + UInt64(request.entries.count) <= Self.maximumLogIndex else {
            throw V2PlacementRaftError.invalidMessage
        }
        var prior = request.previousTerm
        for entry in request.entries {
            guard entry.term > 0, entry.term >= prior, entry.term <= request.term,
                  entry.payload.count <= Self.maximumPayloadBytes else { throw V2PlacementRaftError.invalidMessage }
            prior = entry.term
        }
        func reply(_ accepted: Bool, _ index: UInt64 = 0) -> V2PlacementRaftAppendReply {
            .init(groupID: state.groupID, term: state.term, accepted: accepted, matchedIndex: index, readID: request.readID)
        }
        guard request.term >= state.term else { return reply(false) }
        if request.term > state.term { stepDown(term: request.term) }
        else if role != .follower { stepDown(term: state.term) }
        leader = peer
        electionActivity &+= 1
        guard request.previousIndex >= state.baseIndex, request.previousIndex <= lastIndex,
              state.term(at: request.previousIndex) == request.previousTerm,
              request.previousIndex - state.baseIndex + UInt64(request.entries.count) <= UInt64(Self.maximumEntries) else {
            return reply(false)
        }
        var replacement: Int?
        for (offset, entry) in request.entries.enumerated() {
            let index = Int(request.previousIndex - state.baseIndex) + offset
            if index >= state.log.count { replacement = offset; break }
            let local = state.log[index]
            if local.term == entry.term {
                // Equal term and index cannot denote two different commands.
                guard local.payload == entry.payload else { return reply(false) }
            } else {
                guard state.baseIndex + UInt64(index + 1) > state.commitIndex else { return reply(false) }
                replacement = offset; break
            }
        }
        if let replacement {
            let keep = Int(request.previousIndex - state.baseIndex) + replacement
            state.log.removeSubrange(keep...)
            state.log.append(contentsOf: request.entries.dropFirst(replacement))
        }
        let confirmed = request.previousIndex + UInt64(request.entries.count)
        // An empty heartbeat cannot certify a follower's unverified suffix.
        state.commitIndex = max(state.commitIndex, min(request.leaderCommit, confirmed))
        return reply(true, confirmed)
    }

    package mutating func receivedAppend(_ reply: V2PlacementRaftAppendReply, from peer: V2ActorHostID,
                                         for request: V2PlacementRaftAppendRequest) throws {
        try check(peer, group: reply.groupID)
        guard request.groupID == state.groupID, request.leader == id, reply.readID == request.readID else {
            throw V2PlacementRaftError.invalidMessage
        }
        if reply.term > state.term { stepDown(term: reply.term); return }
        guard role == .leader, reply.term == state.term, request.term == state.term else { return }
        let sentThrough = request.previousIndex + UInt64(request.entries.count)
        guard sentThrough <= lastIndex else { throw V2PlacementRaftError.invalidMessage }
        if reply.accepted {
            guard reply.matchedIndex == sentThrough else { throw V2PlacementRaftError.invalidMessage }
            matched[peer] = max(matched[peer, default: 0], sentThrough)
            next[peer] = max(next[peer, default: 1], sentThrough + 1)
            if let readID = request.readID, var read = reads[readID], read.term == state.term {
                read.votes.insert(peer); reads[readID] = read
            }
            for index in stride(from: lastIndex, through: state.commitIndex + 1, by: -1) {
                if state.term(at: index) == state.term &&
                    state.voters.filter({ matched[$0, default: 0] >= index }).count >= 2 {
                    state.commitIndex = index; break
                }
            }
        } else if next[peer] == request.previousIndex + 1 && sentThrough > matched[peer, default: 0] {
            next[peer] = max(1, request.previousIndex)
        }
    }

    package mutating func replication(to peer: V2ActorHostID, readID: UUID? = nil) throws -> V2PlacementRaftReplication {
        try check(peer, group: state.groupID)
        guard role == .leader, let nextIndex = next[peer] else { throw V2PlacementRaftError.notLeader }
        if nextIndex > state.baseIndex { return .append(try appendRequest(to: peer, readID: readID)) }
        guard let snapshot = state.snapshot else { throw V2PlacementRaftError.invalidState }
        if snapshotTransfers[peer]?.transfer.snapshot != snapshot {
            snapshotTransfers[peer] = (.init(groupID: state.groupID, leader: id, term: state.term, snapshot: snapshot), 0)
        }
        let outgoing = snapshotTransfers[peer]!
        return .snapshot(try outgoing.transfer.chunk(at: outgoing.offset))
    }

    package mutating func snapshot(_ request: V2PlacementRaftSnapshotChunk, from peer: V2ActorHostID)
        throws -> V2PlacementRaftSnapshotReply {
        try check(peer, group: request.groupID)
        guard request.leader == peer, request.term > 0, request.snapshotIndex > 0,
              request.snapshotIndex <= Self.maximumLogIndex, request.snapshotTerm > 0,
              request.snapshotTerm <= request.term, request.digest.count == 32,
              request.totalBytes > 0, request.totalBytes <= V2PlacementRaftCheckpoint.maximumBytes,
              request.offset >= 0, request.offset < request.totalBytes,
              !request.chunk.isEmpty, request.chunk.count <= V2PlacementRaftSnapshotChunk.maximumChunkBytes,
              request.chunk.count <= request.totalBytes - request.offset else { throw V2PlacementRaftError.invalidMessage }
        func reply(_ accepted: Bool, offset: Int = 0, installed: Bool = false) -> V2PlacementRaftSnapshotReply {
            .init(groupID: state.groupID, term: state.term, transferID: request.transferID,
                  snapshotIndex: request.snapshotIndex, accepted: accepted, nextOffset: offset, installed: installed)
        }
        guard request.term >= state.term else { return reply(false) }
        if request.term > state.term || role != .follower { stepDown(term: request.term) }
        // Two different claimed leaders in one term cannot interleave a buffer.
        guard leader == nil || leader == peer else { return reply(false) }
        leader = peer; electionActivity &+= 1
        if request.snapshotIndex <= state.commitIndex {
            if let knownTerm = state.term(at: request.snapshotIndex), knownTerm != request.snapshotTerm { return reply(false) }
            if request.snapshotIndex == state.baseIndex,
               let snapshot = state.snapshot, Data(SHA256.hash(data: snapshot.application)) != request.digest { return reply(false) }
            return reply(true, offset: request.totalBytes, installed: true)
        }
        if incomingSnapshot?.matches(request) != true {
            guard request.offset == 0 else { return reply(false) }
            incomingSnapshot = .init(first: request, bytes: Data())
        }
        guard var incoming = incomingSnapshot else { throw V2PlacementRaftError.invalidState }
        if request.offset < incoming.bytes.count {
            let end = request.offset + request.chunk.count
            guard end <= incoming.bytes.count,
                  incoming.bytes.subdata(in: request.offset..<end) == request.chunk else { return reply(false) }
            return reply(true, offset: incoming.bytes.count)
        }
        guard request.offset == incoming.bytes.count else { return reply(false, offset: incoming.bytes.count) }
        incoming.bytes.append(request.chunk)
        guard incoming.bytes.count == request.totalBytes else {
            incomingSnapshot = incoming
            return reply(true, offset: incoming.bytes.count)
        }
        guard Data(SHA256.hash(data: incoming.bytes)) == request.digest else {
            incomingSnapshot = nil
            throw V2PlacementRaftError.invalidMessage
        }
        let decoded = try V2PlacementRaftCheckpoint.decode(incoming.bytes, groupID: state.groupID)
        guard decoded.appliedIndex == request.snapshotIndex else { throw V2PlacementRaftError.invalidMessage }
        var candidate = state
        // Preserve a suffix only if the snapshot boundary matches our log.
        // Otherwise it belongs to an uncommitted, superseded branch.
        if state.term(at: request.snapshotIndex) == request.snapshotTerm {
            candidate.log = Array(state.log.dropFirst(Int(request.snapshotIndex - state.baseIndex)))
        } else { candidate.log = [] }
        candidate.snapshot = .init(index: request.snapshotIndex, term: request.snapshotTerm, application: incoming.bytes)
        candidate.commitIndex = request.snapshotIndex
        try state.validateLocalSuccessor(candidate)
        state = candidate; incomingSnapshot = nil
        return reply(true, offset: request.totalBytes, installed: true)
    }

    package mutating func receivedSnapshot(_ reply: V2PlacementRaftSnapshotReply, from peer: V2ActorHostID,
                                           for request: V2PlacementRaftSnapshotChunk) throws {
        try check(peer, group: reply.groupID)
        guard request.groupID == state.groupID, request.leader == id, reply.transferID == request.transferID,
              reply.snapshotIndex == request.snapshotIndex, reply.nextOffset >= 0,
              reply.nextOffset <= request.totalBytes else { throw V2PlacementRaftError.invalidMessage }
        if reply.term > state.term { stepDown(term: reply.term); return }
        guard role == .leader, reply.term == state.term, request.term == state.term,
              let outgoing = snapshotTransfers[peer], outgoing.transfer.transferID == request.transferID else { return }
        if reply.installed {
            guard reply.accepted, reply.nextOffset == request.totalBytes else { throw V2PlacementRaftError.invalidMessage }
            matched[peer] = max(matched[peer, default: 0], request.snapshotIndex)
            next[peer] = max(next[peer, default: 1], request.snapshotIndex + 1)
            snapshotTransfers.removeValue(forKey: peer)
        } else if reply.accepted {
            guard reply.nextOffset >= request.offset + request.chunk.count,
                  reply.nextOffset < request.totalBytes else { throw V2PlacementRaftError.invalidMessage }
            snapshotTransfers[peer] = (outgoing.transfer, max(outgoing.offset, reply.nextOffset))
        } else if outgoing.offset == request.offset { snapshotTransfers.removeValue(forKey: peer) }
    }

    /// Only a checkpoint of this exact durable committed prefix may replace
    /// the prefix. Uncommitted suffix entries retain their absolute indexes.
    package mutating func compact(_ checkpoint: Data, through index: UInt64) throws {
        guard index == state.commitIndex, index > state.baseIndex,
              let term = state.term(at: index) else { throw V2PlacementRaftError.invalidState }
        let decoded = try V2PlacementRaftCheckpoint.decode(checkpoint, groupID: state.groupID)
        guard decoded.appliedIndex == index else { throw V2PlacementRaftError.invalidState }
        var application = V2PlacementRaftApplication(groupID: state.groupID)
        try application.apply(state)
        guard try application.checkpoint() == checkpoint else { throw V2PlacementRaftError.invalidState }
        let count = Int(index - state.baseIndex)
        state.log.removeFirst(count)
        state.snapshot = .init(index: index, term: term, application: checkpoint)
    }

    package mutating func beginRead() throws -> UUID {
        guard role == .leader else { throw V2PlacementRaftError.notLeader }
        guard state.commitIndex > 0, state.term(at: state.commitIndex) == state.term else {
            throw V2PlacementRaftError.notReady
        }
        guard reads.count < 128 else { throw V2PlacementRaftError.capacity }
        let id = UUID(); reads[id] = Read(term: state.term, index: state.commitIndex, votes: [self.id]); return id
    }
    /// Caller must additionally apply the committed prefix through this index.
    package func confirmedRead(_ id: UUID) -> UInt64? {
        guard role == .leader, let read = reads[id], read.term == state.term, read.votes.count >= 2 else { return nil }
        return read.index
    }
    package mutating func finishRead(_ id: UUID) { reads.removeValue(forKey: id) }

    private func check(_ peer: V2ActorHostID, group: UUID) throws {
        guard group == state.groupID else { throw V2PlacementRaftError.wrongGroup }
        guard peer != id, state.voters.contains(peer) else { throw V2PlacementRaftError.unauthorizedVoter }
    }
    private mutating func stepDown(term: UInt64) {
        if term > state.term { state.term = term; state.votedFor = nil }
        role = .follower; leader = nil; votes.removeAll(); reads.removeAll(); matched.removeAll(); next.removeAll()
        incomingSnapshot = nil; snapshotTransfers.removeAll()
    }
}
