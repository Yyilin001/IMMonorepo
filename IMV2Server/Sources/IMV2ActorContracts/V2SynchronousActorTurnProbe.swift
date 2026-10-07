import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Diagnostic only: a synchronous segment stays on one thread. CPU time distinguishes
/// expensive work from elapsed time while that thread was not running. No async scope.
public struct V2SynchronousActorTurnProbe: Sendable {
    private let stage: String
    private let startedAt: ContinuousClock.Instant
    private let cpuMicroseconds: Double?
    public static func start(_ stage: String) -> Self? {
        guard V2SendPathTrace.enabled else { return nil }
        return .init(stage: stage, startedAt: .now, cpuMicroseconds: threadCPU())
    }
    public func finish() {
        let ended = ContinuousClock.now
        guard startedAt.duration(to: ended) >= .milliseconds(10) else { return }
        let cpuEnded = Self.threadCPU()
        let trace = V2SendPathTrace(operations: [], segment: "host_maintenance")
        trace.record(stage, from: startedAt, to: ended)
        if let before = cpuMicroseconds, let after = cpuEnded {
            trace.record(stage + "_thread_cpu_sum", from: startedAt,
                to: startedAt + .microseconds(Int64(max(0, after - before))))
        }
        trace.finish()
    }
    private static func threadCPU() -> Double? {
        #if canImport(Darwin)
        var info = thread_basic_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<thread_basic_info_data_t>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                thread_info(pthread_mach_thread_np(pthread_self()), thread_flavor_t(THREAD_BASIC_INFO), $0, &count)
            }
        }
        guard status == KERN_SUCCESS else { return nil }
        return Double(info.user_time.seconds + info.system_time.seconds) * 1_000_000
            + Double(info.user_time.microseconds + info.system_time.microseconds)
        #elseif canImport(Glibc)
        var value = timespec()
        guard clock_gettime(CLOCK_THREAD_CPUTIME_ID, &value) == 0 else { return nil }
        return Double(value.tv_sec) * 1_000_000 + Double(value.tv_nsec) / 1_000
        #else
        return nil
        #endif
    }
}
