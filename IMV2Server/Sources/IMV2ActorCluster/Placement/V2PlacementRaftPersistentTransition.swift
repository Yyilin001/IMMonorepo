import Foundation

extension V2PlacementRaftPersistentState {
    /// Native durable CAS also protects the committed overlap when the prefix
    /// becomes a checkpoint. A caller cannot use compaction to rewrite history.
    package func validateLocalSuccessor(_ candidate: Self) throws {
        _ = try V2PlacementRaftCore(id: candidate.voterID, groupID: groupID, voters: voters, persisted: candidate)
        guard candidate.groupID == groupID, candidate.voterID == voterID, candidate.voters == voters,
              candidate.term >= term, candidate.commitIndex >= commitIndex,
              candidate.baseIndex >= baseIndex,
              candidate.term != term || votedFor == nil || candidate.votedFor == votedFor else {
            throw V2PlacementRaftError.invalidState
        }
        if candidate.baseIndex > baseIndex {
            guard let snapshot = candidate.snapshot else { throw V2PlacementRaftError.invalidState }
            if snapshot.index <= commitIndex {
                guard snapshot.term == self.term(at: snapshot.index) else { throw V2PlacementRaftError.invalidState }
                var certified = self; certified.commitIndex = snapshot.index
                var application = V2PlacementRaftApplication(groupID: groupID)
                try application.apply(certified)
                guard try application.checkpoint() == snapshot.application else { throw V2PlacementRaftError.invalidState }
            } else {
                // Authenticated leader installation may advance beyond our
                // retained log. It still cannot discard known committed facts.
                guard snapshot.term >= (self.term(at: commitIndex) ?? 0) else { throw V2PlacementRaftError.invalidState }
                var local = V2PlacementRaftApplication(groupID: groupID)
                try local.apply(self)
                if local.snapshot != nil {
                    let old = try V2PlacementRaftCheckpoint.decode(local.checkpoint(), groupID: groupID)
                    let next = try V2PlacementRaftCheckpoint.decode(snapshot.application, groupID: groupID)
                    guard next.genesis == old.genesis, next.receipts.count >= old.receipts.count else { throw V2PlacementRaftError.invalidState }
                    for (a, b) in zip(old.receipts, next.receipts) {
                        guard a.requestID == b.requestID, a.command == b.command, a.revision == b.revision else {
                            throw V2PlacementRaftError.invalidState
                        }
                    }
                }
            }
        } else {
            guard candidate.snapshot == snapshot else { throw V2PlacementRaftError.invalidState }
        }
        if commitIndex > candidate.baseIndex {
            for index in (candidate.baseIndex + 1)...commitIndex {
                guard entry(at: index) == candidate.entry(at: index) else { throw V2PlacementRaftError.invalidState }
            }
        }
    }
}
