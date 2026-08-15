import Foundation
import IMV2Core

public struct V2AuthenticatedConnectionAdmissionPolicy: Equatable, Sendable {
    public let maximumConnectionsPerDevice: Int
    public let maximumConnectionsPerUser: Int

    public init(maximumConnectionsPerDevice: Int, maximumConnectionsPerUser: Int) {
        precondition(
            maximumConnectionsPerDevice > 0 &&
            maximumConnectionsPerUser >= maximumConnectionsPerDevice
        )
        self.maximumConnectionsPerDevice = maximumConnectionsPerDevice
        self.maximumConnectionsPerUser = maximumConnectionsPerUser
    }
}

public enum V2AuthenticatedConnectionLeaseOutcome: Equatable, Sendable {
    case accepted(expiresAt: Date)
    case rejected
}

public protocol V2AuthenticatedGatewayCommandAdmitting: Sendable {
    func admit(identity: V2AuthenticatedConnection, now: Date) async -> Bool
}

public struct V2GatewayCommandRateLimitPolicy: Equatable, Sendable {
    public let deviceCommandsPerSecond: Double
    public let deviceBurst: Int
    public let userCommandsPerSecond: Double
    public let userBurst: Int
    public let maximumTrackedIdentities: Int

    public init(
        deviceCommandsPerSecond: Int,
        deviceBurst: Int,
        userCommandsPerSecond: Int,
        userBurst: Int,
        maximumTrackedIdentities: Int
    ) {
        precondition(
            deviceCommandsPerSecond > 0 && deviceBurst > 0 &&
            userCommandsPerSecond > 0 && userBurst >= deviceBurst &&
            maximumTrackedIdentities >= 2
        )
        self.deviceCommandsPerSecond = Double(deviceCommandsPerSecond)
        self.deviceBurst = deviceBurst
        self.userCommandsPerSecond = Double(userCommandsPerSecond)
        self.userBurst = userBurst
        self.maximumTrackedIdentities = maximumTrackedIdentities
    }
}

/// A process overload boundary, not a product/abuse quota. It is deliberately
/// shared by every authenticated session on one replica and charges both the
/// device and user buckets atomically. The identity map has a hard LRU bound,
/// so reconnect churn cannot turn the limiter itself into a memory leak.
public actor V2AuthenticatedGatewayCommandRateLimiter: V2AuthenticatedGatewayCommandAdmitting {
    private enum TrackedIdentity: Hashable, Sendable {
        case device(DeviceID)
        case user(UserID)
    }

    private struct Bucket: Sendable {
        var tokens: Double
        var refilledAt: Date
    }

    private struct LRUNode: Sendable {
        var previous: TrackedIdentity?
        var next: TrackedIdentity?
    }

    private let policy: V2GatewayCommandRateLimitPolicy
    private var devices: [DeviceID: Bucket] = [:]
    private var users: [UserID: Bucket] = [:]
    private var lruNodes: [TrackedIdentity: LRUNode] = [:]
    private var leastRecentlyUsed: TrackedIdentity?
    private var mostRecentlyUsed: TrackedIdentity?

    public init(policy: V2GatewayCommandRateLimitPolicy) { self.policy = policy }

    public func admit(identity: V2AuthenticatedConnection, now: Date) -> Bool {
        var device = refilled(
            devices[identity.deviceID],
            capacity: policy.deviceBurst,
            rate: policy.deviceCommandsPerSecond,
            now: now
        )
        var user = refilled(
            users[identity.userID],
            capacity: policy.userBurst,
            rate: policy.userCommandsPerSecond,
            now: now
        )
        guard device.tokens >= 1, user.tokens >= 1 else {
            ensureCapacity(deviceID: identity.deviceID, userID: identity.userID)
            devices[identity.deviceID] = device
            users[identity.userID] = user
            touch(.device(identity.deviceID))
            touch(.user(identity.userID))
            return false
        }
        device.tokens -= 1
        user.tokens -= 1
        ensureCapacity(deviceID: identity.deviceID, userID: identity.userID)
        devices[identity.deviceID] = device
        users[identity.userID] = user
        touch(.device(identity.deviceID))
        touch(.user(identity.userID))
        return true
    }

    private func refilled(
        _ existing: Bucket?,
        capacity: Int,
        rate: Double,
        now: Date
    ) -> Bucket {
        guard var bucket = existing else {
            return .init(tokens: Double(capacity), refilledAt: now)
        }
        let elapsed = now.timeIntervalSince(bucket.refilledAt)
        if elapsed > 0 {
            bucket.tokens = min(Double(capacity), bucket.tokens + elapsed * rate)
            bucket.refilledAt = now
        }
        return bucket
    }

    private func ensureCapacity(deviceID: DeviceID, userID: UserID) {
        let additions = (devices[deviceID] == nil ? 1 : 0) + (users[userID] == nil ? 1 : 0)
        while devices.count + users.count + additions > policy.maximumTrackedIdentities {
            precondition(evictLeastRecentlyUsed(excluding: deviceID, userID: userID))
        }
    }

    private func evictLeastRecentlyUsed(excluding deviceID: DeviceID, userID: UserID) -> Bool {
        let excludedDevice = TrackedIdentity.device(deviceID)
        let excludedUser = TrackedIdentity.user(userID)
        var candidate = leastRecentlyUsed
        while candidate == excludedDevice || candidate == excludedUser {
            candidate = candidate.flatMap { lruNodes[$0]?.next }
        }
        guard let candidate else { return false }
        removeLRUNode(candidate)
        switch candidate {
        case .device(let deviceID): devices.removeValue(forKey: deviceID)
        case .user(let userID): users.removeValue(forKey: userID)
        }
        return true
    }

    private func touch(_ identity: TrackedIdentity) {
        if lruNodes[identity] != nil {
            removeLRUNode(identity)
        }
        lruNodes[identity] = .init(previous: mostRecentlyUsed, next: nil)
        if let mostRecentlyUsed {
            lruNodes[mostRecentlyUsed]?.next = identity
        } else {
            leastRecentlyUsed = identity
        }
        mostRecentlyUsed = identity
    }

    private func removeLRUNode(_ identity: TrackedIdentity) {
        guard let node = lruNodes.removeValue(forKey: identity) else { return }
        if let previous = node.previous {
            lruNodes[previous]?.next = node.next
        } else {
            leastRecentlyUsed = node.next
        }
        if let next = node.next {
            lruNodes[next]?.previous = node.previous
        } else {
            mostRecentlyUsed = node.previous
        }
    }

    func trackedIdentityCount() -> Int { devices.count + users.count }
}
