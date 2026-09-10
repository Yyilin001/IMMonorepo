@preconcurrency import Dispatch
import Synchronization
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// 各服务端可执行文件共用的单次进程终止边界。
///
/// 信号源保存在进程全局状态中，且在收到 SIGTERM 后刻意不取消：
/// Linux 进程处于并发压力下取消并释放基于 epoll 的 Dispatch 源时，
/// libdispatch 曾出现过 use-after-free。该源由操作系统在进程退出时回收，
/// 互斥锁只用于在重复 SIGTERM 时保护等待的 continuation。
public enum V2ProcessTerminationSignal {
    private struct State: Sendable {
        var source: DispatchSourceSignal?
        var continuation: CheckedContinuation<Void, Never>?
        var isInstalled = false
        var didReceiveSignal = false
    }

    private static let state = Mutex(State())
    private static let queue = DispatchQueue(label: "im.v2.process-termination")

    /// 在可执行文件创建 NIO、Vapor 或数据库工作线程之前安装进程全局信号源。
    ///
    /// Linux 的信号处置由进程共享，但投递可能落在任意未屏蔽线程；
    /// 若把安装推迟到启动末尾，在高线程数运行时可能出现 SIGTERM 被忽略、
    /// 未能唤醒 Dispatch 源的情况。重复调用是安全的，只有首次生效。
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

    /// 等待进程终止信号，首次调用时自动完成安装。
    ///
    /// 信号若已到达则立即返回，否则挂起当前任务直到收到 SIGTERM。
    /// 同一进程只允许一个等待者：重复安装等待者会直接失败。
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

    /// 处理一次信号到达，只唤醒首个等待者且仅唤醒一次。
    ///
    /// 后续重复信号不会产生额外效果。
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
