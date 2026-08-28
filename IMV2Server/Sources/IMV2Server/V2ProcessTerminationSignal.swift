@preconcurrency import Dispatch
import Synchronization
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// A one-shot process termination boundary shared by the server executables.
///
/// The signal source is retained in process-global state and deliberately is
/// not cancelled after SIGTERM.  Cancelling and releasing epoll-backed
/// Dispatch sources while a Linux process is under concurrency pressure has
/// had use-after-free failures in libdispatch.  The operating system reclaims
/// this one source when the process exits; the mutex only protects the
/// continuation against a repeated SIGTERM.
public enum V2ProcessTerminationSignal {
    private struct State: Sendable {
        var source: DispatchSourceSignal?
        var continuation: CheckedContinuation<Void, Never>?
        var isInstalled = false
        var didReceiveSignal = false
    }

    private static let state = Mutex(State())
    private static let queue = DispatchQueue(label: "im.v2.process-termination")

    /// Installs the process-global source before an executable creates NIO,
    /// Vapor or database worker threads. Linux signal disposition is shared
    /// by the process, but delivery can target any unblocked thread; delaying
    /// this setup until the end of startup can therefore leave SIGTERM ignored
    /// without waking the Dispatch source under a highly threaded runtime.
    public static func install() {
        let shouldInstall = state.withLock { state -> Bool in
            guard !state.isInstalled else { return false }
            state.isInstalled = true
            return true
        }
        guard shouldInstall else { return }

        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: queue)
        source.setEventHandler { receiveOnce() }
        state.withLock { $0.source = source }
        source.resume()
    }

    public static func wait() async {
        install()
        await withCheckedContinuation { continuation in
            let resumeImmediately = state.withLock { state -> Bool in
                guard !state.didReceiveSignal else { return true }
                precondition(state.continuation == nil, "process termination waiter installed more than once")
                state.continuation = continuation
                return false
            }
            if resumeImmediately { continuation.resume() }
        }
    }

    private static func receiveOnce() {
        let continuation = state.withLock { state -> CheckedContinuation<Void, Never>? in
            guard !state.didReceiveSignal else { return nil }
            state.didReceiveSignal = true
            let continuation = state.continuation
            state.continuation = nil
            return continuation
        }
        continuation?.resume()
    }
}
