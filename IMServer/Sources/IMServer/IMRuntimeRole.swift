import Vapor

enum IMRuntimeRole: String, Sendable {
    case gateway
    case commandAPI = "command-api"
    case queryAPI = "query-api"
    case outboxRelay = "outbox-relay"
    case streamConsumer = "stream-consumer"
    case projectionWorker = "projection-worker"
    case combined
    case ops

    var servesHTTP: Bool {
        switch self {
        case .gateway, .commandAPI, .queryAPI, .combined:
            return true
        case .outboxRelay, .streamConsumer, .projectionWorker, .ops:
            return false
        }
    }

    var servesGateway: Bool {
        self == .gateway || self == .combined
    }

    var servesCommandAPI: Bool {
        self == .commandAPI || self == .combined
    }

    var servesQueryAPI: Bool {
        self == .queryAPI || self == .combined
    }

    var runsProjectionWorker: Bool {
        self == .projectionWorker || self == .combined
    }

    var runsOutboxRelay: Bool {
        self == .outboxRelay
    }

    var runsStreamConsumer: Bool {
        self == .streamConsumer
    }
}

private struct IMRuntimeRoleStorageKey: StorageKey {
    typealias Value = IMRuntimeRole
}

extension Application {
    var imRuntimeRole: IMRuntimeRole {
        get { storage[IMRuntimeRoleStorageKey.self] ?? .combined }
        set { storage[IMRuntimeRoleStorageKey.self] = newValue }
    }
}
