import Foundation
import IMV2Core
@testable import IMV2Server
import Synchronization
import Testing

@Suite("Real NATS room wake transport")
struct V2RealNATSRoomWakeTests {
    @Test("a real server restart invalidates coverage and automatically restores subscriptions",
          .enabled(if: ProcessInfo.processInfo.environment["IMV2_REAL_NATS_BINARY"] != nil))
    func serverRestart() async throws {
        let binary = try #require(ProcessInfo.processInfo.environment["IMV2_REAL_NATS_BINARY"])
        let port = ProcessInfo.processInfo.environment["IMV2_REAL_NATS_RESTART_PORT"] ?? "54230"
        let url = try #require(URL(string: "nats://127.0.0.1:\(port)"))
        let prefix = "imv2.restart." + UUID().uuidString.lowercased()
        let directory = FileManager.default.temporaryDirectory.appending(path: "nats-restart-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let log = directory.appending(path: "server.log")
        func launch() throws -> Process {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: binary)
            process.arguments = ["-a", "127.0.0.1", "-p", port, "-DV", "-l", log.path]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            return process
        }
        var server = try launch()
        defer {
            if server.isRunning { server.terminate(); server.waitUntilExit() }
            try? FileManager.default.removeItem(at: directory)
        }
        let received = Mutex<[UInt64]>([]), losses = Mutex(0)
        let configuration = try V2NATSGroupEventWakeConfiguration(url: url, subjectPrefix: prefix,
            routingKey: Data(repeating: 19, count: 32), acknowledgementTimeout: 2)
        let receiver = V2NATSGroupEventWakeBroker(configuration: configuration,
            coverageLost: { losses.withLock { $0 += 1 } }, receiveWake: {
                if case .wake(let wake) = $0 { received.withLock { $0.append(wake.highWatermark) } }
            })
        let publisher = V2NATSGroupEventWakeBroker(configuration: configuration, receiveWake: { _ in })
        let room = RoomID(uuid: UUID())
        do {
            try await waitUntil { (try? String(contentsOf: log, encoding: .utf8).contains("Server is ready")) == true }
            try await receiver.activate(roomID: room)
            try await publisher.publish(.init(roomID: room, highWatermark: 1))
            try await waitUntil { received.withLock { $0.contains(1) } }
            server.terminate()
            try await waitUntil { !server.isRunning }
            try await waitUntil { losses.withLock { $0 == 1 } }
            try FileManager.default.removeItem(at: log)
            server = try launch()
            // Observe the real server's subscription trace before publishing.
            // No second activate call is allowed to repair the receiver.
            try await waitUntil {
                guard let trace = try? String(contentsOf: log, encoding: .utf8) else { return false }
                return trace.contains("SUB \(prefix)")
            }
            try await publisher.publish(.init(roomID: room, highWatermark: 2))
            try await waitUntil { received.withLock { $0.contains(2) } }
            #expect(received.withLock { $0 } == [1, 2])
            #expect(losses.withLock { $0 } == 1)
        } catch {
            await receiver.shutdown(); await publisher.shutdown()
            throw error
        }
        await receiver.shutdown(); await publisher.shutdown()
    }

    private func waitUntil(_ predicate: () throws -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while try !predicate() {
            guard ContinuousClock.now < deadline else { throw RealNATSTestFailure.deliveryTimeout }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    @Test("independent gateway adapters receive a room wake through a real server",
          .enabled(if: ProcessInfo.processInfo.environment["IMV2_REAL_NATS_URL"] != nil))
    func independentAdapters() async throws {
        let address = try #require(ProcessInfo.processInfo.environment["IMV2_REAL_NATS_URL"])
        let url = try #require(URL(string: address))
        let prefix = "imv2.integration." + UUID().uuidString.lowercased()
        let room = RoomID(uuid: UUID())
        let first = Mutex<[V2GroupEventWake]>([]), second = Mutex<[V2GroupEventWake]>([])
        let configuration = try V2NATSGroupEventWakeConfiguration(url: url, subjectPrefix: prefix,
            routingKey: Data(repeating: 19, count: 32), acknowledgementTimeout: 2)
        let publisher = V2NATSGroupEventWakeBroker(configuration: configuration, receiveWake: { _ in })
        let receiverA = V2NATSGroupEventWakeBroker(configuration: configuration, receiveWake: {
            if case .wake(let wake) = $0 { first.withLock { $0.append(wake) } }
        })
        let receiverB = V2NATSGroupEventWakeBroker(configuration: configuration, receiveWake: {
            if case .wake(let wake) = $0 { second.withLock { $0.append(wake) } }
        })
        do {
            async let a: Void = receiverA.activate(roomID: room)
            async let b: Void = receiverB.activate(roomID: room)
            _ = try await (a, b)
            let wake = V2GroupEventWake(roomID: room, highWatermark: 42)
            try await publisher.publish(wake)
            let clock = ContinuousClock(), deadline = ContinuousClock.now.advanced(by: .seconds(5))
            while first.withLock({ $0.isEmpty }) || second.withLock({ $0.isEmpty }) {
                guard clock.now < deadline else { throw RealNATSTestFailure.deliveryTimeout }
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(first.withLock { $0 } == [wake])
            #expect(second.withLock { $0 } == [wake])
        } catch {
            await publisher.shutdown(); await receiverA.shutdown(); await receiverB.shutdown()
            throw error
        }
        await publisher.shutdown(); await receiverA.shutdown(); await receiverB.shutdown()
    }
}

private enum RealNATSTestFailure: Error { case deliveryTimeout }
