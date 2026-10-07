import NIOCore

/// A task scheduling preference, not an actor isolation assertion. Owns the
/// actual connection loop for the full loan; no global or TCP executor changes.
package final class V2DatabaseEventLoopTaskExecutor: TaskExecutor {
    let eventLoop: any EventLoop
    init(_ eventLoop: any EventLoop) {
        self.eventLoop = eventLoop
    }

    package func enqueue(_ job: consuming ExecutorJob) {
        let job = UnownedJob(job)
        eventLoop.execute {
            job.runSynchronously(on: self.asUnownedTaskExecutor())
        }
    }
}
