import Dispatch

#if canImport(Darwin)
package typealias V2SerialQueue = DispatchSerialQueue
#else
/// Keep synchronous SQLite work off the cooperative executor on every platform.
package final class V2SerialQueue: SerialExecutor {
    private let queue: DispatchQueue
    package init(label: String, qos: DispatchQoS) { queue = DispatchQueue(label: label, qos: qos) }
    package func enqueue(_ job: consuming ExecutorJob) {
        let job = UnownedJob(job), executor = asUnownedSerialExecutor()
        queue.async { job.runSynchronously(on: executor) }
    }
}
#endif
