import ConsoleKit
@preconcurrency import Dispatch
import Foundation
import Vapor

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

struct IMProjectionWorkerCommand: AsyncCommand {
    struct Signature: CommandSignature {
        init() {}
    }

    var help: String {
        "Run the IM projection/search worker without starting HTTP or TCP listeners."
    }

    func run(using context: CommandContext, signature: Signature) async throws {
        let app = context.application

        app.logger.notice(
            "IM projection worker started",
            metadata: [
                "node_id": .string(app.imNodeID),
                "role": .string(app.imRuntimeRole.rawValue)
            ]
        )

        await waitForShutdownSignal()

        app.logger.notice(
            "IM projection worker stopping",
            metadata: [
                "node_id": .string(app.imNodeID),
                "role": .string(app.imRuntimeRole.rawValue)
            ]
        )
    }

    private func waitForShutdownSignal() async {
        await withCheckedContinuation { continuation in
            signal(SIGINT, SIG_IGN)
            signal(SIGTERM, SIG_IGN)

            let queue = DispatchQueue(label: "imserver.worker.signal")
            let intSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: queue)
            let termSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: queue)
            let state = ContinuationResumeState()

            let finish: @Sendable () -> Void = {
                state.resumeOnce {
                    intSource.cancel()
                    termSource.cancel()
                    continuation.resume()
                }
            }

            intSource.setEventHandler(handler: finish)
            termSource.setEventHandler(handler: finish)
            intSource.resume()
            termSource.resume()
        }
    }
}

private final class ContinuationResumeState: @unchecked Sendable {
    private let lock = NSLock()
    private var resumed = false

    func resumeOnce(_ body: () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard !resumed else {
            return
        }
        resumed = true
        body()
    }
}
