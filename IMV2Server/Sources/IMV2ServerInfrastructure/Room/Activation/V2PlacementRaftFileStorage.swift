import Foundation
import IMV2ActorCluster
import NIOPosix

/// Voting-state validation remains separate from exclusive durable file I/O.
package final class V2PlacementRaftFileStorage: V2PlacementRaftStorage {
    private let file: V2ActorDurableFileStorage
    private init(file: V2ActorDurableFileStorage) { self.file = file }
    package static func bootstrap(at path: URL, initial: V2PlacementRaftPersistentState,
                                  pool: NIOThreadPool) async throws -> V2PlacementRaftFileStorage {
        guard initial.term == 0, initial.votedFor == nil, initial.log.isEmpty, initial.commitIndex == 0 else {
            throw V2PlacementRaftError.invalidState
        }
        let file = try await V2ActorDurableFileStorage.provision(at: path,
            initial: V2PlacementRaftProtobuf.encodeFile(initial), maximumBytes: V2PlacementRaftProtobuf.maximumFileBytes,
            pool: pool, validate: { _ = try V2PlacementRaftProtobuf.decodeFile($0) })
        return .init(file: file)
    }
    package static func open(at path: URL, pool: NIOThreadPool) async throws -> V2PlacementRaftFileStorage {
        let file = try await V2ActorDurableFileStorage.open(at: path,
            maximumBytes: V2PlacementRaftProtobuf.maximumFileBytes, pool: pool,
            validate: { _ = try V2PlacementRaftProtobuf.decodeFile($0) })
        return .init(file: file)
    }
    package func load() async throws -> V2PlacementRaftPersistentState {
        try await V2PlacementRaftProtobuf.decodeFile(file.load())
    }
    package func persist(_ candidate: V2PlacementRaftPersistentState,
                         replacing expected: V2PlacementRaftPersistentState) async throws {
        try await file.update { bytes in
            guard try V2PlacementRaftProtobuf.decodeFile(bytes) == expected else { throw V2PlacementRaftError.invalidState }
            try expected.validateLocalSuccessor(candidate)
            return (try V2PlacementRaftProtobuf.encodeFile(candidate), ())
        }
    }
    package func close() async throws { try await file.close() }
}
