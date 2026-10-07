import Synchronization

/// Caller completion and physical settlement are distinct. Resume outside the lock.
final class V2RoomRPCCompletion<Value: Sendable>: Sendable {
    private struct State: Sendable {
        var continuation: CheckedContinuation<Value, any Error>?
        var result: Result<Value, any Error>?
        var physicalSettled = false
    }
    private let state = Mutex(State())
    func install(_ continuation: CheckedContinuation<Value, any Error>) {
        let result = state.withLock { value -> Result<Value, any Error>? in
            if let result = value.result { return result }
            precondition(value.continuation == nil)
            value.continuation = continuation
            return nil
        }
        if let result { continuation.resume(with: result) }
    }
    @discardableResult func cancelCaller(with error: any Error) -> Bool { deliver(.failure(error), physical: false) }
    func finishPhysical(with result: Result<Value, any Error>) { _ = deliver(result, physical: true) }
    private func deliver(_ result: Result<Value, any Error>, physical: Bool) -> Bool {
        let action = state.withLock { value -> (Bool, CheckedContinuation<Value, any Error>?) in
            if physical {
                guard !value.physicalSettled else { return (false, nil) }
                value.physicalSettled = true
            }
            guard value.result == nil else { return (false, nil) }
            value.result = result
            let continuation = value.continuation; value.continuation = nil
            return (true, continuation)
        }
        action.1?.resume(with: result)
        return action.0
    }
}
