import Foundation
import IMV2Core

public enum V2AccountRoomChange: Equatable, Sendable {
    case resyncRequired(epoch: UUID)
}

public protocol V2AccountRoomChangeSource: Sendable {
    func nextAccountRoomChange() async throws -> V2AccountRoomChange
}

public enum V2AccountRoomChangeError: Error, Equatable, Sendable {
    case invalidNotification, wrongEpoch, notStarted
}

/// Account coverage carries one recovery boundary; room progress uses Owner delivery.
struct V2AccountRoomChangeInbox: Sendable {
    private enum State: Sendable {
        case idle, active(UUID), pending(UUID), retired(UUID)
    }
    private var state: State = .idle

    var epoch: UUID? {
        switch state {
        case .idle: nil
        case .active(let epoch), .pending(let epoch), .retired(let epoch): epoch
        }
    }

    mutating func begin(epoch raw: String) throws {
        guard let parsed = UUID(uuidString: raw) else {
            throw V2AccountRoomChangeError.invalidNotification
        }
        switch state {
        case .idle: break
        case .retired(let previous) where previous != parsed: break
        default: throw V2AccountRoomChangeError.invalidNotification
        }
        state = .active(parsed)
    }

    mutating func accept(_ reset: IMV2AccountRoomResyncRequired) throws {
        guard let epoch else { throw V2AccountRoomChangeError.notStarted }
        guard UUID(uuidString: reset.connectionEpoch) == epoch else { throw V2AccountRoomChangeError.wrongEpoch }
        guard case .active = state else { return }
        state = .pending(epoch)
    }

    mutating func next() -> V2AccountRoomChange? {
        guard case .pending(let epoch) = state else { return nil }
        state = .retired(epoch)
        return .resyncRequired(epoch: epoch)
    }
}
