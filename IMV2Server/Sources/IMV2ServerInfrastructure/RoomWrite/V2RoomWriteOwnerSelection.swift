import Foundation
import IMV2ServerContracts

/// Immutable owner and activation selection for one write-store value copy.
/// SQL still verifies these selected facts after taking the operation lock.
struct V2RoomWriteOwnerSelection: Sendable {
    private(set) var routes: [UUID: V2RoomShardRoute]?
    private(set) var activation: V2RoomActivationWriteScope?
    private(set) var forwardSource: UUID?

    init() {
        routes = nil
        activation = nil
        forwardSource = nil
    }

    private init(routes: [UUID: V2RoomShardRoute]?,
                 activation: V2RoomActivationWriteScope?, forwardSource: UUID?) {
        self.routes = routes
        self.activation = activation
        self.forwardSource = forwardSource
    }

    func withActivation(_ activation: V2RoomActivationWriteScope) -> Self {
        var copy = self
        copy.activation = activation
        return copy
    }

    func selectingRoutes(_ routes: [UUID: V2RoomShardRoute]) throws -> Self {
        if let forwardSource {
            guard let selected = routes[forwardSource],
                  selected == self.routes?[forwardSource] else {
                throw V2RoomOwnerFenceError.ownerChanged
            }
        }
        var copy = self
        copy.routes = routes
        return copy
    }

    func selectingForwardSource(_ source: UUID, route: V2RoomShardRoute) throws -> Self {
        guard var routes, forwardSource == nil || forwardSource == source,
              routes[source] == nil || routes[source] == route else {
            throw V2RoomOwnerFenceError.ownerChanged
        }
        routes[source] = route
        var copy = self
        copy.routes = routes
        copy.forwardSource = source
        return copy
    }

    static func actorForwardPair(
        activation: V2RoomActivationWriteScope,
        routes: [UUID: V2RoomShardRoute],
        source: UUID,
        target: UUID
    ) throws -> Self {
        guard Set(routes.keys) == Set([source, target]),
              let sourceRoute = routes[source], let targetRoute = routes[target] else {
            throw V2RoomOwnerFenceError.ownerChanged
        }
        for (room, route) in [(source, sourceRoute), (target, targetRoute)] {
            let token = try activation.token(for: room)
            guard route.shardID == token.owner.shardID, route.epoch == token.owner.epoch else {
                throw V2RoomOwnerFenceError.ownerChanged
            }
        }
        return .init(routes: routes, activation: activation, forwardSource: source)
    }
}
