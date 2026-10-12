import Foundation
import IMV2ActorContracts

/// Dedicated control admission: room saturation, SQL work and room shutdown do
/// not prevent a stable voter from receiving authenticated election messages.
/// The node closes admission and awaits this service before stopping storage.
package actor V2PlacementRaftInboundService: V2ActorHostInboundServing {
    private let authenticator: V2ActorSessionAuthenticator
    private let signer: V2ActorSigningIdentity
    private let limits: V2ActorAuthenticationLimits
    private let endpoint: V2PlacementRaftEndpoint
    private let maximumRequests: Int
    private var accepting = true
    private var active = 0
    private var activeClientRequests = 0
    private var drained: [CheckedContinuation<Void, Never>] = []

    package init(identity: V2ActorHostIdentity, signer: V2ActorSigningIdentity, trust: V2ActorTrustStore,
                 limits: V2ActorAuthenticationLimits, endpoint: V2PlacementRaftEndpoint, maximumRequests: Int = 128) throws {
        guard (4...1024).contains(maximumRequests) else { throw V2PlacementRaftError.invalidConfiguration }
        self.authenticator = .init(host: identity, trust: trust, limits: limits)
        self.signer = signer; self.limits = limits; self.endpoint = endpoint; self.maximumRequests = maximumRequests
    }
    package func openSession(_ packet: V2ActorSignedPacket) async throws -> V2ActorSignedPacket {
        try begin()
        defer { finish() }
        let grant = try await authenticator.openSession(packet)
        return try signer.sign(grant, maximumBytes: limits.maximumReplyBytes)
    }
    package func exchange(_ packet: V2ActorSignedPacket, boundToken: V2RoomActivationToken?) async throws -> V2ActorSignedPacket {
        try begin()
        defer { finish() }
        guard boundToken == nil else { throw V2ActorAuthenticationError.wrongRecipient }
        let verified = try await authenticator.accept(packet)
        let response: V2ActorRPCResponse
        do {
            switch verified.call.request {
            case .placementRaft(let request):
                response = .placementRaft(try await endpoint.exchangeRaft(request, serviceID: verified.call.serviceID,
                    callerIncarnation: verified.call.callerIncarnation, deadline: verified.deadline))
            case .placementWrite(let request):
                // Both client reads and writes may wait for a quorum. Bound
                // their combined occupancy so replica traffic can still enter.
                try beginClientRequest()
                defer { activeClientRequests -= 1 }
                response = .placementWrite(try await endpoint.writePlacement(request, serviceID: verified.call.serviceID,
                    callerIncarnation: verified.call.callerIncarnation, deadline: verified.deadline))
            case .placementRead(let request):
                try beginClientRequest()
                defer { activeClientRequests -= 1 }
                response = .placementRead(try await endpoint.readPlacement(request, serviceID: verified.call.serviceID,
                    deadline: verified.deadline))
            default: throw V2ActorAuthenticationError.forbidden
            }
        } catch { response = .failure(.outcomeUnknown) }
        let reply = V2ActorAuthenticatedReply(call: verified.call, response: response)
        if let mac = verified.sessionMAC { return try mac.seal(reply, reply: true, maximumBytes: limits.maximumReplyBytes) }
        return try signer.sign(reply, maximumBytes: limits.maximumReplyBytes)
    }
    package func beginDrain() { accepting = false }
    package func quiesce(deadline: ContinuousClock.Instant) async -> Bool {
        accepting = false
        while active > 0 && ContinuousClock.now < deadline {
            do { try await Task.sleep(for: .milliseconds(5)) } catch { return false }
        }
        return active == 0
    }
    package func stop() async {
        accepting = false
        if active > 0 { await withCheckedContinuation { drained.append($0) } }
    }
    private func beginClientRequest() throws {
        guard activeClientRequests < max(1, min(16, maximumRequests / 4)) else {
            throw V2ActorAuthenticationError.overloaded
        }
        activeClientRequests += 1
    }
    private func begin() throws {
        guard accepting, active < maximumRequests else { throw V2ActorAuthenticationError.overloaded }
        active += 1
    }
    private func finish() {
        active -= 1
        if active == 0 {
            let pending = drained; drained.removeAll()
            for continuation in pending { continuation.resume() }
        }
    }
}
