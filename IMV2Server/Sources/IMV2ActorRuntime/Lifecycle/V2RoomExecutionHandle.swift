import Foundation
import IMV2ActorContracts
import Synchronization

/// The wire adapter decodes once. Local callers pass their model directly.
struct V2RoomInvocation<Request: Sendable>: Sendable {
    let byteCount: Int
    let request: Request
    init(_ request: Request) {
        self.request = request
        byteCount = V2ActorPayloadBudget.retainedBytes(of: request)
    }

}

/// Process drain closes every room's new admission before scanning any room.
final class V2RoomHostAdmission: Sendable {
    private let accepting = Atomic(false)
    var isAccepting: Bool { accepting.load(ordering: .acquiring) }
    func open() { accepting.store(true, ordering: .releasing) }
    func close() { accepting.store(false, ordering: .releasing) }
}

/// Local authority for one exact activation. Host lifecycle writes and room
/// execution reads share only this room's short synchronous critical section.
final class V2RoomExecutionAuthority: Sendable {
    private struct State {
        var phase: V2RoomActivationPhase = .restoring
        var safetyUntil: ContinuousClock.Instant
        var inFlight = 0
    }
    private let state: Mutex<State>
    private let qualification: V2ActorServiceQualification
    private let generation: UUID
    private let hostAdmission: V2RoomHostAdmission?

    init(
        safetyUntil: ContinuousClock.Instant, qualification: V2ActorServiceQualification,
        generation: UUID, hostAdmission: V2RoomHostAdmission? = nil
    ) {
        state = Mutex(State(safetyUntil: safetyUntil))
        self.qualification = qualification
        self.generation = generation
        self.hostAdmission = hostAdmission
    }
    func setPhase(_ phase: V2RoomActivationPhase) { state.withLock { $0.phase = phase } }
    func renew(until: ContinuousClock.Instant) { state.withLock { $0.safetyUntil = until } }
    var inFlight: Int { state.withLock { $0.inFlight } }
    func deadline() -> ContinuousClock.Instant? {
        state.withLock { value in
            guard value.phase == .ready || value.phase == .draining,
                let proof = qualification.snapshot(), proof.generation == generation,
                .now < min(value.safetyUntil, proof.validUntil)
            else { return nil }
            return min(value.safetyUntil, proof.validUntil)
        }
    }
    func admit() throws {
        try state.withLock { value in
            guard hostAdmission?.isAccepting != false, value.phase == .ready else {
                throw V2RoomCallFailure.notAccepted(.retired)
            }
            guard let proof = qualification.snapshot(), proof.generation == generation,
                .now < min(value.safetyUntil, proof.validUntil)
            else { throw V2RoomCallFailure.notAccepted(.leaseLost) }
            value.inFlight += 1
        }
    }
    func finish() {
        state.withLock {
            precondition($0.inFlight > 0)
            $0.inFlight -= 1
        }
    }
}

/// Never decoded from RPC, never reused by a later activation of the room.
public final class V2RoomExecutionHandle<Request: Sendable, Response: Sendable>:
    Sendable
{
    public let token: V2RoomActivationToken
    private let lane: V2RoomTurnLane<Request, Response>
    private let authority: V2RoomExecutionAuthority
    init(
        token: V2RoomActivationToken, lane: V2RoomTurnLane<Request, Response>,
        authority: V2RoomExecutionAuthority
    ) {
        self.token = token
        self.lane = lane
        self.authority = authority
    }
    public func invoke(request: Request, deadline: ContinuousClock.Instant) async throws -> Response {
        try await invoke(decodedInvocation: V2RoomInvocation(request), deadline: deadline)
    }
    func invoke(decodedInvocation: V2RoomInvocation<Request>,
                deadline: ContinuousClock.Instant) async throws -> Response {
        try Task.checkCancellation()
        guard deadline > .now else { throw V2RoomCallFailure.notAccepted(.deadlineExceeded) }
        try authority.admit()
        defer { authority.finish() }
        V2SendPathTrace.current?.mark("host_invoke_enter")
        V2SendPathTrace.current?.mark("host_lane_dispatch")
        let result = try await lane.submit(decodedInvocation: decodedInvocation, deadline: deadline)
        V2SendPathTrace.current?.mark("host_lane_return")
        return result
    }
}
