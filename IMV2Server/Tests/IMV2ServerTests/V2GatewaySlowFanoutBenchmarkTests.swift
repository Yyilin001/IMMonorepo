import Dispatch
import Foundation
#if canImport(Darwin)
import Darwin
#endif
@preconcurrency import NIOCore
@preconcurrency import NIOPosix
@preconcurrency import NIOSSL
@preconcurrency import NIOTLS
import Synchronization
@testable import IMV2Server
import Testing

/// 手动容量实验：真实 TLS 套接字 + 生产前台写队列，不接入认证和数据库。
/// 仅在显式设置环境变量时执行，避免把一万连接的负载施加到普通 CI。
@Suite("Gateway slow fanout benchmark", .serialized, .timeLimit(.minutes(15)))
struct V2GatewaySlowFanoutBenchmarkTests {
    @Test("10,000 TLS connections with optional paused readers",
        .enabled(if: ProcessInfo.processInfo.environment["IMV2_RUN_SLOW_FANOUT_BENCHMARK"] == "1"))
    func tenThousandConnections() async throws {
        let connectionCount = 10_000
        let pausedCount = Int(ProcessInfo.processInfo.environment["IMV2_SLOW_FANOUT_PAUSED"] ?? "1000") ?? 1_000
        try #require((0...connectionCount).contains(pausedCount))
        let preloadSlowReaders = ProcessInfo.processInfo.environment["IMV2_SLOW_FANOUT_PRELOAD"] == "1"
        let rounds = 120
        let frameBytes = 1_024
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "imv2-slow-fanout-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cert = directory.appending(path: "cert.pem")
        let key = directory.appending(path: "key.pem")
        let openssl = Process()
        openssl.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        openssl.arguments = ["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1",
            "-subj", "/CN=localhost", "-addext", "subjectAltName=DNS:localhost",
            "-keyout", key.path, "-out", cert.path]
        openssl.standardOutput = FileHandle.nullDevice
        openssl.standardError = FileHandle.nullDevice
        try openssl.run()
        openssl.waitUntilExit()
        try #require(openssl.terminationStatus == 0)
        let certificates = try NIOSSLCertificate.fromPEMFile(cert.path)
        var serverTLS = TLSConfiguration.makeServerConfiguration(
            certificateChain: certificates.map { .certificate($0) },
            privateKey: .privateKey(try NIOSSLPrivateKey(file: key.path, format: .pem)))
        serverTLS.minimumTLSVersion = .tlsv13
        let serverContext = try NIOSSLContext(configuration: serverTLS)
        var clientTLS = TLSConfiguration.makeClientConfiguration()
        clientTLS.minimumTLSVersion = .tlsv13
        clientTLS.trustRoots = .certificates(certificates)
        let clientContext = try NIOSSLContext(configuration: clientTLS)

        let group = MultiThreadedEventLoopGroup(numberOfThreads: 8)
        let scheduler = V2NIOForegroundWriteScheduler()
        let metrics = V2GatewayTransportMetrics()
        let state = SlowFanoutState()
        let writers = SlowFanoutWriterRegistry()
        var listener: (any Channel)?
        var clients: [any Channel] = []
        clients.reserveCapacity(connectionCount)
        do {
            listener = try await ServerBootstrap(group: group)
                .childChannelOption(ChannelOptions.socketOption(.so_sndbuf), value: 4096)
                .childChannelInitializer { channel in
                    channel.eventLoop.makeCompletedFuture {
                        try channel.pipeline.syncOperations.addHandler(
                            NIOSSLServerHandler(context: serverContext))
                        try channel.pipeline.syncOperations.addHandler(
                            SlowFanoutServerHandler(channel: channel, scheduler: scheduler,
                                metrics: metrics, writers: writers))
                    }
                }.bind(host: "127.0.0.1", port: 0).get()
            let port = try #require(listener?.localAddress?.port)
            let started = DispatchTime.now().uptimeNanoseconds
            for index in 0..<connectionCount {
                let paused = index < pausedCount
                let channel = try await ClientBootstrap(group: group)
                    .channelOption(ChannelOptions.socketOption(.so_rcvbuf), value: 4096)
                    .channelInitializer { channel in
                        channel.eventLoop.makeCompletedFuture {
                            try channel.pipeline.syncOperations.addHandler(
                                NIOSSLClientHandler(context: clientContext, serverHostname: "localhost"))
                            try channel.pipeline.syncOperations.addHandler(
                                SlowFanoutClientHandler(paused: paused, state: state))
                        }
                    }.connect(host: "127.0.0.1", port: port).get()
                clients.append(channel)
                if index % 1_000 == 999 {
                    print("IMV2_SLOW_FANOUT_CONNECT attempted=\(index + 1) ready=\(state.snapshot().ready)")
                }
            }
            let readyDeadline = ContinuousClock.now.advanced(by: .seconds(120))
            while state.snapshot().ready < connectionCount || writers.snapshot().all.count < connectionCount {
                try #require(ContinuousClock.now < readyDeadline)
                try await Task.sleep(for: .milliseconds(100))
            }
            let connectedAt = DispatchTime.now().uptimeNanoseconds
            let targets = writers.snapshot()
            try #require(targets.all.count == connectionCount)
            try #require(targets.slow.count == pausedCount)
            if preloadSlowReaders {
                let preloadFrame = ByteBuffer(bytes: Data(repeating: 0x41, count: 64 * 1_024))
                for _ in 0..<40 {
                    V2NIOGatewayForegroundWriter.submitBatch(targets.slow.map {
                        .init(writer: $0, bytes: preloadFrame)
                    })
                }
                try await Task.sleep(for: .milliseconds(500))
            }
            let frame = ByteBuffer(bytes: Data(repeating: 0x42, count: frameBytes))
            for _ in 0..<rounds {
                V2NIOGatewayForegroundWriter.submitBatch(targets.all.map {
                    .init(writer: $0, bytes: frame)
                })
                try await Task.sleep(for: .milliseconds(100))
            }
            state.markProbeSent()
            let probe = ByteBuffer(bytes: Data(repeating: 0x43, count: frameBytes))
            V2NIOGatewayForegroundWriter.submitBatch(targets.all.map {
                .init(writer: $0, bytes: probe)
            })
            let submittedAt = DispatchTime.now().uptimeNanoseconds
            let completeDeadline = ContinuousClock.now.advanced(by: .seconds(30))
            while state.snapshot().completedFast < connectionCount - pausedCount,
                  ContinuousClock.now < completeDeadline {
                try await Task.sleep(for: .milliseconds(100))
            }
            let result = state.snapshot()
            let transport = metrics.gatewayTransportMetricsSnapshot()
            let percentiles = result.latencies.sorted()
            func percentile(_ fraction: Double) -> Double {
                guard !percentiles.isEmpty else { return 0 }
                let index = min(percentiles.count - 1, Int(Double(percentiles.count - 1) * fraction))
                return Double(percentiles[index]) / 1_000_000
            }
            let fastBytes = result.fastBytesAtProbe.sorted()
            let medianFastBytes = fastBytes.isEmpty ? 0 : fastBytes[fastBytes.count / 2]
            print("IMV2_SLOW_FANOUT_RESULT connected=\(result.ready) paused=\(pausedCount) preload=\(preloadSlowReaders) fast_probe_received=\(result.completedFast) connect_seconds=\(Double(connectedAt - started) / 1e9) load_seconds=\(Double(submittedAt - connectedAt) / 1e9) probe_p50_ms=\(percentile(0.50)) probe_p95_ms=\(percentile(0.95)) probe_p99_ms=\(percentile(0.99)) min_fast_bytes_at_probe=\(fastBytes.first ?? 0) median_fast_bytes_at_probe=\(medianFastBytes) deferred=\(transport.foregroundNonWritableDeferrals) recovery_queued=\(transport.foregroundRecoveryFramesQueued) recovery_replaced=\(transport.foregroundRecoveryFramesReplaced) peak_queue_bytes=\(transport.peakQueuedForegroundBytes) process_rss_mib=\(slowFanoutResidentBytes() / 1_048_576)")
            #expect(result.ready == connectionCount)
            #expect(result.completedFast == connectionCount - pausedCount)
            #expect(fastBytes.first == (rounds + 1) * frameBytes)
        } catch {
            let futures = clients.map(\.closeFuture) + (listener.map { [$0.closeFuture] } ?? [])
            for client in clients { client.close(promise: nil) }
            listener?.close(promise: nil)
            try? await EventLoopFuture.andAllSucceed(futures, on: group.next()).get()
            try? await group.shutdownGracefully()
            throw error
        }
        let futures = clients.map(\.closeFuture) + (listener.map { [$0.closeFuture] } ?? [])
        for client in clients { client.close(promise: nil) }
        listener?.close(promise: nil)
        try await EventLoopFuture.andAllSucceed(futures, on: group.next()).get()
        try await group.shutdownGracefully()
    }
}

private func slowFanoutResidentBytes() -> UInt64 {
    #if canImport(Darwin)
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
    let result = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
        }
    }
    return result == KERN_SUCCESS ? UInt64(info.resident_size) : 0
    #else
    return 0
    #endif
}

private final class SlowFanoutState: Sendable {
    private struct Storage: Sendable {
        var ready = 0
        var completedFast = 0
        var probeSentAt: UInt64 = 0
        var latencies: [UInt64] = []
        var fastBytesAtProbe: [Int] = []
    }
    private let storage = Mutex(Storage())
    func ready() { storage.withLock { $0.ready += 1 } }
    func markProbeSent() { storage.withLock { $0.probeSentAt = DispatchTime.now().uptimeNanoseconds } }
    func completed(bytes: Int) {
        storage.withLock {
            $0.completedFast += 1
            $0.latencies.append(DispatchTime.now().uptimeNanoseconds - $0.probeSentAt)
            $0.fastBytesAtProbe.append(bytes)
        }
    }
    func snapshot() -> (ready: Int, completedFast: Int, latencies: [UInt64], fastBytesAtProbe: [Int]) {
        storage.withLock { ($0.ready, $0.completedFast, $0.latencies, $0.fastBytesAtProbe) }
    }
}

private final class SlowFanoutWriterRegistry: Sendable {
    private struct Storage: Sendable {
        var all: [V2NIOGatewayForegroundWriter] = []
        var slow: [V2NIOGatewayForegroundWriter] = []
    }
    private let writers = Mutex(Storage())
    func append(_ writer: V2NIOGatewayForegroundWriter, slow: Bool) {
        writers.withLock {
            $0.all.append(writer)
            if slow { $0.slow.append(writer) }
        }
    }
    func snapshot() -> (all: [V2NIOGatewayForegroundWriter], slow: [V2NIOGatewayForegroundWriter]) {
        writers.withLock { ($0.all, $0.slow) }
    }
}

private final class SlowFanoutServerHandler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    private let channel: any Channel
    private let scheduler: V2NIOForegroundWriteScheduler
    private let metrics: V2GatewayTransportMetrics
    private let writers: SlowFanoutWriterRegistry
    private var writer: V2NIOGatewayForegroundWriter?
    private var registered = false
    init(channel: any Channel, scheduler: V2NIOForegroundWriteScheduler,
         metrics: V2GatewayTransportMetrics, writers: SlowFanoutWriterRegistry) {
        self.channel = channel; self.scheduler = scheduler; self.metrics = metrics; self.writers = writers
    }
    func handlerAdded(context: ChannelHandlerContext) {
        writer = V2NIOGatewayForegroundWriter(channel: channel, scheduler: scheduler, metrics: metrics)
    }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let buffer = unwrapInboundIn(data)
        if !registered, let writer,
           let marker: UInt8 = buffer.getInteger(at: buffer.readerIndex) {
            registered = true
            writers.append(writer, slow: marker == 1)
        }
    }
}

private final class SlowFanoutClientHandler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer
    private let paused: Bool
    private let state: SlowFanoutState
    private var receivedBytes = 0
    private var completed = false
    private var ready = false
    init(paused: Bool, state: SlowFanoutState) {
        self.paused = paused; self.state = state
    }
    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if !ready, let event = event as? TLSUserEvent, case .handshakeCompleted = event {
            ready = true
            var marker = context.channel.allocator.buffer(capacity: 1)
            marker.writeInteger(UInt8(paused ? 1 : 0))
            context.writeAndFlush(wrapOutboundOut(marker), promise: nil)
            if paused {
                let state = state
                context.channel.setOption(ChannelOptions.autoRead, value: false).whenSuccess {
                    state.ready()
                }
            } else { state.ready() }
        }
        context.fireUserInboundEventTriggered(event)
    }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let buffer = unwrapInboundIn(data)
        receivedBytes += buffer.readableBytes
        if !paused, !completed, buffer.readableBytesView.contains(0x43) {
            completed = true
            state.completed(bytes: receivedBytes)
        }
        context.fireChannelRead(data)
    }
}
