import Foundation
import Dispatch
import Darwin

/// SQLite 是同步 C API。专用串行 executor 避免长 SQL 占用主线程或 cooperative pool。
final class DatabaseExecutor: SerialExecutor {
    private let queue: DispatchQueue
    init(_ label: String) { queue = DispatchQueue(label: label, qos: .utility) }
    func enqueue(_ job: consuming ExecutorJob) {
        let job = UnownedJob(job), executor = asUnownedSerialExecutor()
        queue.async { job.runSynchronously(on: executor) }
    }
}

/// 仅此小型同步边界使用 unchecked：所有可变成员均由同一 NSLock 保护。
final class OperationControl: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private let deadline: UInt64?
    private let parents: [OperationControl]
    init(timeout: Double? = nil, parents: [OperationControl] = []) {
        self.parents = parents
        deadline = timeout.map { DispatchTime.now().uptimeNanoseconds &+ UInt64(min($0, 86_400) * 1e9) }
    }
    func cancel() { lock.withLock { cancelled = true } }
    func check() throws {
        for parent in parents { try parent.check() }
        if lock.withLock({ cancelled }) { throw CancellationError() }
        if let deadline, DispatchTime.now().uptimeNanoseconds >= deadline { throw SearchIndexError.timeout }
    }
    var interrupted: Bool { (try? check()) == nil }
}

/// 在进入 actor 邮箱前限流，防止调用者创建的并发请求挤满内存。
final class AdmissionGate: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes = 0
    private var count = 0
    private var closed = false
    private var peakCount = 0
    private var peakBytes = 0
    private var rejections: Int64 = 0
    private let maximum: Int
    init(maximum: Int) { self.maximum = maximum }
    func acquire(_ amount: Int) throws {
        try lock.withLock {
            guard !closed else { throw SearchIndexError.closed }
            guard count < 16, amount <= maximum - bytes else { rejections += 1; throw SearchIndexError.backpressure }
            count += 1; bytes += amount
            peakCount = max(peakCount, count); peakBytes = max(peakBytes, bytes)
        }
    }
    func release(_ amount: Int) { lock.withLock { count -= 1; bytes -= amount } }
    func close() { lock.withLock { closed = true } }
    func snapshot(reset: Bool) -> AdmissionMetrics {
        lock.withLock {
            let result = AdmissionMetrics(requests: count, bytes: bytes, peakRequests: peakCount, peakBytes: peakBytes, rejections: rejections)
            if reset { peakCount = count; peakBytes = bytes; rejections = 0 }
            return result
        }
    }
}

/// 一个进程/实例独占本索引。锁文件保留，避免 unlink 后其他实例锁到不同 inode。
public final class SearchIndexWriteLease: Sendable {
    private let descriptor: Int32
    public init(path: String) throws {
        guard !path.isEmpty, !path.utf8.contains(0) else { throw SearchIndexError.invalidArgument("invalid index path") }
        let descriptor = Darwin.open(path + ".lock", O_CREAT | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw SearchIndexError.invalidArgument("cannot create store lock") }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            Darwin.close(descriptor)
            if code == EWOULDBLOCK { throw SearchIndexError.alreadyOpen }
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        self.descriptor = descriptor
    }
    deinit { flock(descriptor, LOCK_UN); Darwin.close(descriptor) }
}
