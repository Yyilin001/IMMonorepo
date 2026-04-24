import Foundation

struct OutgoingQueueState: Sendable, Equatable {
    var pendingOutgoingRequestIDs: [UUID: String] = [:]

    mutating func reset() {
        pendingOutgoingRequestIDs = [:]
    }

    mutating func registerPendingRequest(_ requestID: UUID, localMessageID: String) {
        pendingOutgoingRequestIDs[requestID] = localMessageID
    }

    mutating func removePendingRequest(_ requestID: UUID) -> String? {
        pendingOutgoingRequestIDs.removeValue(forKey: requestID)
    }

    mutating func removePendingRequests(for localMessageID: String) {
        pendingOutgoingRequestIDs = pendingOutgoingRequestIDs.filter { $0.value != localMessageID }
    }

    mutating func drainPendingMessageIDs() -> [String] {
        let pendingMessageIDs = Array(pendingOutgoingRequestIDs.values)
        pendingOutgoingRequestIDs.removeAll()
        return pendingMessageIDs
    }
}
