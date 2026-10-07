/// Execution admission precedes borrowing; the connection callback reports
/// the physical backend held across this one room execution.
package struct V2OwnerBatchBorrowControl: Sendable {
    package let connectionAcquired: @Sendable () async throws -> Void
    package let beforeFirstBegin: @Sendable () async throws -> Void
    package let interrupted: @Sendable (any Error) -> Void
    package init(connectionAcquired: @escaping @Sendable () async throws -> Void,
        beforeFirstBegin: @escaping @Sendable () async throws -> Void,
        interrupted: @escaping @Sendable (any Error) -> Void) {
        self.connectionAcquired = connectionAcquired
        self.beforeFirstBegin = beforeFirstBegin
        self.interrupted = interrupted
    }
}
