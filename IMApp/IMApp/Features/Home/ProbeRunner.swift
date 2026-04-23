import Foundation
import IMClientKit

struct ProbeFailureContext: Sendable {
    let message: String
    let shouldPreserveSession: Bool
    let shouldMarkServerOffline: Bool
}

enum ProbeOutcome: Sendable {
    case success(AuthUser)
    case rateLimited(ProbeFailureContext)
    case failure(ProbeFailureContext)
}

enum TrafficProbeEvent: Sendable {
    case waiting(delay: Double)
    case result(ProbeOutcome)
}

struct LoadProbeEvent: Sendable {
    let workerIndex: Int
    let outcome: ProbeOutcome
}

actor ProbeRunner {
    private let sessionClient: SessionClient

    init(sessionClient: SessionClient) {
        self.sessionClient = sessionClient
    }

    func probeOnce() async -> ProbeOutcome {
        do {
            let user = try await sessionClient.fetchMe()
            return .success(user)
        } catch {
            let shouldPreserveSession = await sessionClient.shouldPreserveSession(for: error)
            let shouldMarkServerOffline = await sessionClient.shouldMarkServerOffline(for: error)
            let context = ProbeFailureContext(
                message: error.localizedDescription,
                shouldPreserveSession: shouldPreserveSession,
                shouldMarkServerOffline: shouldMarkServerOffline
            )
            if case APIError.rateLimited = error {
                return .rateLimited(context)
            }
            return .failure(context)
        }
    }

    func runConcurrentTest(requestCount: Int) async -> [ProbeOutcome] {
        await withTaskGroup(of: ProbeOutcome.self, returning: [ProbeOutcome].self) { group in
            for _ in 0..<requestCount {
                group.addTask {
                    await self.probeOnce()
                }
            }

            var outcomes: [ProbeOutcome] = []
            for await outcome in group {
                outcomes.append(outcome)
            }
            return outcomes
        }
    }

    func makeTrafficStream() -> AsyncStream<TrafficProbeEvent> {
        AsyncStream { continuation in
            let producer = Task.detached(priority: .background) { [runner = self] in
                while !Task.isCancelled {
                    let delay = Double.random(in: 2...8)
                    continuation.yield(.waiting(delay: delay))

                    do {
                        try await Task.sleep(for: .seconds(delay))
                    } catch {
                        break
                    }

                    guard !Task.isCancelled else {
                        break
                    }

                    let outcome = await runner.probeOnce()
                    continuation.yield(.result(outcome))
                }

                continuation.finish()
            }

            continuation.onTermination = { _ in
                producer.cancel()
            }
        }
    }

    func makeLoadStream(workerCount: Int) -> AsyncStream<LoadProbeEvent> {
        AsyncStream { continuation in
            let producer = Task.detached(priority: .background) { [runner = self] in
                await withTaskGroup(of: Void.self) { group in
                    for workerIndex in 0..<workerCount {
                        group.addTask {
                            while !Task.isCancelled {
                                let outcome = await runner.probeOnce()
                                continuation.yield(
                                    LoadProbeEvent(
                                        workerIndex: workerIndex + 1,
                                        outcome: outcome
                                    )
                                )

                                do {
                                    try await Task.sleep(for: .milliseconds(Int.random(in: 150...600)))
                                } catch {
                                    break
                                }
                            }
                        }
                    }

                    await group.waitForAll()
                }

                continuation.finish()
            }

            continuation.onTermination = { _ in
                producer.cancel()
            }
        }
    }
}
