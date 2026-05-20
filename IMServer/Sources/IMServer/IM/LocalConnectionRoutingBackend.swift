import Foundation
import Vapor

struct LocalPresenceStore: PresenceStore {
    let nodeID: String

    var backendName: String { "local" }

    func start(app: Application) async throws {}
    func shutdown() async {}
    func activatePresence(forUserID userID: UUID) async throws {}
    func deactivatePresence(forUserID userID: UUID) async throws {}
    func activatePresence(forSessionID sessionID: UUID, userID: UUID) async throws {}
    func deactivatePresence(forSessionID sessionID: UUID, userID: UUID) async throws {}
    func routeNodeIDs(forUserIDs userIDs: [UUID]) async throws -> [UUID: Set<String>] { [:] }
    func routeNodeIDs(forSessionIDs sessionIDs: [UUID]) async throws -> [UUID: Set<String>] { [:] }
    func activeNodeIDs() async throws -> Set<String> { [] }
}

struct LocalNodeMessageDispatchService: NodeMessageDispatchService {
    func start(app: Application) async throws {}
    func shutdown() async {}
    func dispatch(_ envelope: NodeMessageDispatchEnvelope, toNodeID nodeID: String) async throws {}
}

struct LocalConnectionRoutingBackend: ConnectionRoutingBackend {
    let nodeID: String
    let presenceStore: any PresenceStore
    let dispatchService: any NodeMessageDispatchService

    init(nodeID: String) {
        self.nodeID = nodeID
        self.presenceStore = LocalPresenceStore(nodeID: nodeID)
        self.dispatchService = LocalNodeMessageDispatchService()
    }

    var backendName: String { "local" }

    func start(app: Application) async throws {
        try await presenceStore.start(app: app)
        try await dispatchService.start(app: app)
    }

    func shutdown() async {
        await dispatchService.shutdown()
        await presenceStore.shutdown()
    }
}
