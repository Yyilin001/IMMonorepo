import Foundation
import IMV2Core
@preconcurrency import NIOCore
@preconcurrency import NIOPosix
@preconcurrency import NIOSSL
import NIOTLS
import Synchronization
import Testing
@testable import IMV2ServerApplication
@testable import IMV2ServerContracts
@testable import IMV2ServerGateway
@testable import IMV2ServerInfrastructure

/// Explicit local capacity experiment. TLS, wire negotiation, Gateway, dispatcher,
/// immutable cache and application ACKs are real. Identity, authority facts and
/// change publication are deterministic fixtures; this does not measure SQL or
/// avatar byte delivery and must not be reported as a production database test.
@Suite("Author presentation real TLS capacity", .serialized, .timeLimit(.minutes(10)))
struct V2AuthorPresentationNetworkBenchmarkTests {
    @Test("bounded supplements, warm history and idle profile changes over real TLS connections",
          .enabled(if: ProcessInfo.processInfo.environment["IMV2_RUN_AUTHOR_NETWORK_BENCHMARK"] == "1"))
    func networkCapacity() async throws {
        let count = Int(ProcessInfo.processInfo.environment["IMV2_AUTHOR_NETWORK_CONNECTIONS"] ?? "10000") ?? 10_000
        let renewals = Int(ProcessInfo.processInfo.environment["IMV2_AUTHOR_NETWORK_RENEWALS"] ?? "0") ?? 0
        let authorCount = Int(ProcessInfo.processInfo.environment["IMV2_AUTHOR_NETWORK_AUTHORS"] ?? "1") ?? 1
        try #require((1...10_000).contains(count) && (0...4).contains(renewals) && (1...8).contains(authorCount))
        let room = RoomID(uuid: UUID()), authors = (0..<authorCount).map { _ in AuthorNetworkAuthor() }
        let richMetadata = ProcessInfo.processInfo.environment["IMV2_AUTHOR_NETWORK_RICH_METADATA"] == "1"
        let feed = AuthorNetworkFeed(authors: authors, room: room, richMetadata: richMetadata)
        let configuration = try V2AuthorPresentationDispatcher.Configuration()
        let runtime = V2AuthorPresentationRuntime(configuration: configuration, ingressConfiguration: try .init(),
            readBatch: feed.read, closeReader: { await feed.close() })
        let limits = try V2FrameLimits(maximumPayloadBytes: 65_536, acceptedVersions: [0, UInt8(IMV2ProtocolVersion.current)])
        let registry = V2DeviceConnectionRegistry(foregroundFrameLimits: limits, authorPresentationIngress: runtime.ingress)
        let tls = try makeGatewayTestTLSContexts(), group = MultiThreadedEventLoopGroup(numberOfThreads: 8)
        let metrics = V2GatewayTransportMetrics(), scheduler = V2NIOForegroundWriteScheduler()
        let observations = AuthorNetworkObservations(), commands = try AuthorNetworkCommands(room: room, authors: authors)
        let peaks = AuthorNetworkPeaks()
        let monitor = Task {
            while !Task.isCancelled {
                peaks.record(await runtime.dispatcher.statistics())
                do { try await Task.sleep(for: .milliseconds(200)) } catch { break }
            }
        }
        var listener: (any Channel)?, peers: [(any Channel, AuthorNetworkPeer)] = []
        do {
            try await runtime.startProfileChanges(feed)
            listener = try await ServerBootstrap(group: group)
                .childChannelInitializer { channel in
                    do {
                        let session = V2GatewaySession(limits: try .init(maximumInFlightRequests: 4),
                            authenticator: AuthorNetworkAuthenticator(), capabilityProfile: "base",
                            supportsAuthorPresentationDelta: true, commandAdmission: V2AllowingGatewayCommandAdmission())
                        let stream = V2GatewayByteStream(frameLimits: limits, session: session, handler: commands,
                            registry: registry, authorPresentationDispatcher: runtime.dispatcher,
                            authorPresentationIngress: runtime.ingress)
                        return channel.eventLoop.makeCompletedFuture {
                            try channel.pipeline.syncOperations.addHandler(NIOSSLServerHandler(context: tls.server))
                            try channel.pipeline.syncOperations.addHandler(
                            V2NIOGatewayChannelHandler(stream: stream, maximumQueuedInboundBytes: 262_144,
                                maximumQueuedInboundChunks: 64, authenticationTimeoutMilliseconds: 180_000,
                                idleTimeoutMilliseconds: 180_000, transportMetrics: metrics,
                                foregroundWriteScheduler: scheduler))
                        }
                    } catch { return channel.eventLoop.makeFailedFuture(error) }
                }.bind(host: "127.0.0.1", port: 0).get()
            let port = try #require(listener?.localAddress?.port), connectStarted = ContinuousClock.now
            for index in 0..<count {
                let peer = AuthorNetworkPeer(limits: limits, room: room, authors: authors,
                    richMetadata: richMetadata, observations: observations)
                let channel = try await ClientBootstrap(group: group).channelInitializer { channel in
                    channel.eventLoop.makeCompletedFuture {
                        try channel.pipeline.syncOperations.addHandler(NIOSSLClientHandler(context: tls.client, serverHostname: "localhost"))
                        try channel.pipeline.syncOperations.addHandler(peer)
                    }
                }.connect(host: "127.0.0.1", port: port).get()
                peers.append((channel, peer))
                if index % 1_000 == 999 { print("IMV2_AUTHOR_NETWORK_CONNECT attempted=\(index + 1) authenticated=\(observations.authenticatedCount)") }
            }
            try await wait(observations, seconds: 120) { observations.authenticatedCount == count }
            let connectedSeconds = seconds(connectStarted.duration(to: .now)), started = ContinuousClock.now
            for (channel, peer) in peers { try await channel.eventLoop.submit { try peer.begin(on: channel) }.get() }
            print("IMV2_AUTHOR_NETWORK_STARTED seconds=\(seconds(started.duration(to: .now)))")
            try await wait(observations, seconds: 25) { observations.acknowledged(1) == count }
            let firstSeconds = seconds(started.duration(to: .now)), firstReads = await feed.recipientReads
            print("IMV2_AUTHOR_NETWORK_INITIAL applied=\(observations.acknowledged(1)) seconds=\(firstSeconds) recipientReads=\(firstReads) statistics=\(await runtime.dispatcher.statistics())")
            try #require(await runtime.dispatcher.statistics().visibleInterests == count * authorCount)
            try #require(feed.origins.loads == authorCount)
            for (channel, peer) in peers { try await channel.eventLoop.submit { try peer.pull(on: channel) }.get() }
            try await wait(observations, seconds: 10) { observations.historyCount == count }
            try await Task.sleep(for: .milliseconds(200))
            let warmReads = await feed.recipientReads - firstReads
            // Warm message/history delivery must not repeat one profile read per
            // recipient while its applied grant and source freshness remain live.
            #expect(warmReads == 0)
            let changed = ContinuousClock.now
            await feed.advance()
            try await wait(observations, seconds: 20) { observations.acknowledged(2) == count }
            #expect(feed.origins.loads == authorCount + 1)
            let changeSeconds = seconds(changed.duration(to: .now))
            var previousViewStarted = started
            if renewals > 0 {
                for generation in 1...renewals {
                    // Replace the 30-second view before expiry, retaining the
                    // applied display lease while the new view is populated.
                    try await ContinuousClock().sleep(until: previousViewStarted + .seconds(24))
                    let renewedAt = ContinuousClock.now
                    for (channel, peer) in peers {
                        try await channel.eventLoop.submit { try peer.renew(on: channel) }.get()
                    }
                    try await wait(observations, seconds: 20) { observations.acknowledgedView(generation) == count }
                    let readsBeforeHistory = await feed.recipientReads
                    for (channel, peer) in peers { try await channel.eventLoop.submit { try peer.pull(on: channel) }.get() }
                    try await wait(observations, seconds: 10) { observations.historyCount(generation) == count }
                    try await Task.sleep(for: .milliseconds(200))
                    let renewedWarmReads = await feed.recipientReads - readsBeforeHistory
                    #expect(renewedWarmReads == 0)
                    #expect(feed.origins.loads == authorCount + 1)
                    print("IMV2_AUTHOR_NETWORK_RENEWAL generation=\(generation) applied=\(observations.acknowledgedView(generation)) history=\(observations.historyCount(generation)) seconds=\(seconds(renewedAt.duration(to: .now))) warmRecipientReads=\(renewedWarmReads)")
                    previousViewStarted = renewedAt
                }
            }
            let stats = await runtime.dispatcher.statistics()
            peaks.record(stats); monitor.cancel(); await monitor.value
            let peak = peaks.snapshot
            #expect(peak.pendingKeys <= 128 && peak.pendingBytes <= 262_144 && peak.outputBytes <= 262_144)
            #expect(peak.hintBytes <= configuration.maximumHintBytes && peak.reading <= 4 && peak.writing <= 4)
            #expect(stats.pendingKeys <= 1_024 && stats.pendingBytes <= 262_144 && stats.outputBytes <= 262_144)
            #expect(stats.hintBytes <= configuration.maximumHintBytes)
            #expect(stats.reading <= 4 && stats.writing <= 4)
            print("IMV2_AUTHOR_NETWORK_RESULT connections=\(count) authors=\(authorCount) richMetadata=\(richMetadata) renewals=\(renewals) authenticated=\(observations.authenticatedCount) appliedV1=\(observations.acknowledged(1)) appliedV2=\(observations.acknowledged(2)) history=\(observations.historyCount) connectSeconds=\(connectedSeconds) initialSeconds=\(firstSeconds) changeSeconds=\(changeSeconds) recipientReads=\(await feed.recipientReads) keyReads=\(await feed.keyReads) readBatches=\(await feed.readBatches) originBatches=\(await feed.originBatches) originLoads=\(feed.origins.loads) warmRecipientReads=\(warmReads) rejectedOffers=\(stats.rejectedOffers) expiredJobs=\(stats.expiredJobs) sampledPeaks=\(peak)")
            for (channel, _) in peers { try? await channel.close().get() }
            peers.removeAll()
            try await listener?.close().get(); listener = nil
            try await wait(observations, seconds: 10) { await runtime.dispatcher.statistics().connections == 0 }
            await runtime.close()
            try await group.shutdownGracefully()
        } catch {
            monitor.cancel(); await monitor.value
            let stats = await runtime.dispatcher.statistics()
            print("IMV2_AUTHOR_NETWORK_FAILURE authors=\(authorCount) authenticated=\(observations.authenticatedCount) appliedV1=\(observations.acknowledged(1)) appliedV2=\(observations.acknowledged(2)) recipientReads=\(await feed.recipientReads) keyReads=\(await feed.keyReads) readBatches=\(await feed.readBatches) originBatches=\(await feed.originBatches) originLoads=\(feed.origins.loads) statistics=\(stats)")
            for (channel, _) in peers { try? await channel.close().get() }
            try? await listener?.close().get()
            await runtime.close()
            try? await group.shutdownGracefully()
            throw error
        }
    }

    @Test("independent gateways update healthy peers while real TLS readers stall and recover",
          .enabled(if: ProcessInfo.processInfo.environment["IMV2_RUN_AUTHOR_MULTI_GATEWAY_BENCHMARK"] == "1"))
    func multiGatewaySlowConnections() async throws {
        let environment = ProcessInfo.processInfo.environment
        let count = Int(environment["IMV2_AUTHOR_NETWORK_CONNECTIONS"] ?? "10000") ?? 10_000
        let gatewayCount = Int(environment["IMV2_AUTHOR_NETWORK_GATEWAYS"] ?? "2") ?? 2
        let slowPerGateway = Int(environment["IMV2_AUTHOR_NETWORK_SLOW_PER_GATEWAY"] ?? "8") ?? 8
        let authorCount = Int(environment["IMV2_AUTHOR_NETWORK_AUTHORS"] ?? "1") ?? 1
        try #require((2...4).contains(gatewayCount) && (1...100).contains(slowPerGateway)
            && (gatewayCount * (slowPerGateway + 1)...10_000).contains(count) && (1...8).contains(authorCount))
        let room = RoomID(uuid: UUID()), authors = (0..<authorCount).map { _ in AuthorNetworkAuthor() }
        let source = AuthorNetworkSource(author: authors[0].userID)
        let limits = try V2FrameLimits(maximumPayloadBytes: 65_536, acceptedVersions: [0, UInt8(IMV2ProtocolVersion.current)])
        let tls = try makeGatewayTestTLSContexts(), group = MultiThreadedEventLoopGroup(numberOfThreads: 8)
        let observations = AuthorNetworkObservations()
        var gateways: [AuthorNetworkGateway] = []
        var peers: [(channel: any Channel, peer: AuthorNetworkPeer, gateway: Int, slow: Bool)] = []
        var phase = "connecting"
        do {
            for _ in 0..<gatewayCount {
                gateways.append(try await .start(authors: authors, room: room, source: source, limits: limits, tls: tls.server))
            }
            let connecting = ContinuousClock.now
            for index in 0..<count {
                let gateway = index % gatewayCount, slow = index / gatewayCount < slowPerGateway
                let peer = AuthorNetworkPeer(limits: limits, room: room, authors: authors,
                    richMetadata: true, observations: observations)
                var bootstrap = ClientBootstrap(group: group)
                if slow { bootstrap = bootstrap.channelOption(ChannelOptions.socketOption(.so_rcvbuf), value: 4096) }
                let channel = try await bootstrap.channelInitializer { channel in
                    channel.eventLoop.makeCompletedFuture {
                        try channel.pipeline.syncOperations.addHandler(NIOSSLClientHandler(context: tls.client, serverHostname: "localhost"))
                        try channel.pipeline.syncOperations.addHandler(peer)
                    }
                }.connect(host: "127.0.0.1", port: try #require(gateways[gateway].listener.localAddress?.port)).get()
                peers.append((channel, peer, gateway, slow))
                // Bound setup handshakes so this experiment measures a cold
                // presentation burst across established connections, not the
                // fixture listener's kernel accept backlog. All interests are
                // still published together after every connection is ready.
                if index % 128 == 127 {
                    try await wait(observations, seconds: 20) { observations.authenticatedCount == index + 1 }
                }
                if index % 1_000 == 999 { print("IMV2_AUTHOR_MULTI_CONNECT attempted=\(index + 1) authenticated=\(observations.authenticatedCount)") }
            }
            try await wait(observations, seconds: 120) { observations.authenticatedCount == count }
            let connectedSeconds = seconds(connecting.duration(to: .now)), started = ContinuousClock.now
            phase = "initial presentations"
            for entry in peers { try await entry.channel.eventLoop.submit { try entry.peer.begin(on: entry.channel) }.get() }
            try await wait(observations, seconds: 25) { observations.acknowledged(1) == count }
            let initialSeconds = seconds(started.duration(to: .now))
            phase = "warm history"
            var readsBeforeHistory: [Int] = []
            for gateway in gateways { readsBeforeHistory.append(await gateway.feed.recipientReads) }
            for entry in peers { try await entry.channel.eventLoop.submit { try entry.peer.pull(on: entry.channel) }.get() }
            try await wait(observations, seconds: 10) { observations.historyCount == count }
            try await Task.sleep(for: .milliseconds(200))
            for (index, gateway) in gateways.enumerated() {
                #expect(await gateway.feed.recipientReads == readsBeforeHistory[index])
                #expect(gateway.feed.origins.loads == authorCount)
                #expect(await gateway.runtime.dispatcher.statistics().visibleInterests
                    == peers.filter { $0.gateway == index }.count * authorCount)
            }

            let slowPeers = peers.filter(\.slow), slowIDs = Set(slowPeers.map(\.peer.id))
            var blockedChannels: [any Channel] = []
            phase = "socket backpressure"
            for entry in slowPeers {
                try await entry.channel.setOption(ChannelOptions.autoRead, value: false).get()
                let port = try #require(entry.channel.localAddress?.port)
                blockedChannels.append(try #require(gateways[entry.gateway].channels.peer(port: port)))
                try await entry.channel.eventLoop.submit { try entry.peer.pullWhileReadStalled(on: entry.channel) }.get()
            }
            // Observe actual socket non-writability. Merely disabling autoRead,
            // delaying an ACK or injecting a false send result is insufficient.
            try await wait(observations, seconds: 5) {
                for channel in blockedChannels where channel.isWritable { return false }
                return true
            }
            let blockedAtChange = blockedChannels.filter { !$0.isWritable }.count
            let changed = ContinuousClock.now
            phase = "healthy change delivery"
            await source.advance()
            for entry in peers where !entry.slow {
                try await entry.channel.eventLoop.submit { try entry.peer.pull(on: entry.channel, probe: true) }.get()
            }
            try await wait(observations, seconds: 20) {
                observations.acknowledged(2) == count - slowPeers.count
                    && observations.historyProbeCount == count - slowPeers.count
            }
            let fastChangeSeconds = seconds(changed.duration(to: .now))
            #expect(observations.acknowledged(2, among: slowIDs) == 0)
            #expect(blockedChannels.allSatisfy { $0.isActive && !$0.isWritable })
            for (index, gateway) in gateways.enumerated() {
                let healthy = Set(peers.filter { $0.gateway == index && !$0.slow }.map(\.peer.id))
                #expect(observations.acknowledged(2, among: healthy) == healthy.count)
                #expect(await gateway.runtime.profileChangeFailures() == 0)
            }
            print("IMV2_AUTHOR_MULTI_STALLED gateways=\(gatewayCount) connections=\(count) authors=\(authorCount) blockedSockets=\(blockedAtChange) healthyApplied=\(observations.acknowledged(2)) healthyHistory=\(observations.historyProbeCount) fastChangeAndHistorySeconds=\(fastChangeSeconds)")

            let resumed = ContinuousClock.now
            phase = "slow recovery"
            for entry in slowPeers {
                try await entry.channel.setOption(ChannelOptions.autoRead, value: true).get()
                entry.channel.read()
            }
            try await wait(observations, seconds: 20) { observations.acknowledged(2) == count }
            let recoverySeconds = seconds(resumed.duration(to: .now))
            phase = "subsequent change"
            // A further revision proves that recovery did not consume or lose
            // either gateway's independent change stream.
            await source.advance()
            try await wait(observations, seconds: 20) { observations.acknowledged(3) == count }
            for (index, gateway) in gateways.enumerated() {
                gateway.peaks.record(await gateway.runtime.dispatcher.statistics())
                let stats = await gateway.runtime.dispatcher.statistics(), peak = gateway.peaks.snapshot
                #expect(gateway.feed.origins.loads == authorCount + 2)
                #expect(peak.pendingKeys <= 128 && peak.pendingBytes <= 262_144 && peak.outputBytes <= 262_144)
                #expect(peak.hintBytes <= gateway.configuration.maximumHintBytes && peak.reading <= 4 && peak.writing <= 4)
                print("IMV2_AUTHOR_MULTI_GATEWAY index=\(index) connections=\(stats.connections) recipientReads=\(await gateway.feed.recipientReads) keyReads=\(await gateway.feed.keyReads) originLoads=\(gateway.feed.origins.loads) rejected=\(stats.rejectedOffers) expired=\(stats.expiredJobs) sampledPeaks=\(peak)")
            }
            print("IMV2_AUTHOR_MULTI_RESULT gateways=\(gatewayCount) connections=\(count) authors=\(authorCount) slowConnections=\(slowPeers.count) appliedV1=\(observations.acknowledged(1)) appliedV2=\(observations.acknowledged(2)) appliedV3=\(observations.acknowledged(3)) connectSeconds=\(connectedSeconds) initialSeconds=\(initialSeconds) fastChangeSeconds=\(fastChangeSeconds) recoverySeconds=\(recoverySeconds)")
            for entry in peers { try? await entry.channel.close().get() }
            peers.removeAll()
            for gateway in gateways {
                try await wait(observations, seconds: 10) { await gateway.runtime.dispatcher.statistics().connections == 0 }
                await gateway.close()
            }
            gateways.removeAll()
            try await group.shutdownGracefully()
        } catch {
            print("IMV2_AUTHOR_MULTI_FAILURE phase=\(phase) authenticated=\(observations.authenticatedCount) history=\(observations.historyCount) appliedV1=\(observations.acknowledged(1)) appliedV2=\(observations.acknowledged(2)) appliedV3=\(observations.acknowledged(3)) error=\(error)")
            for entry in peers { try? await entry.channel.close().get() }
            for gateway in gateways { await gateway.close() }
            try? await group.shutdownGracefully()
            throw error
        }
    }

    private func wait(_ observations: AuthorNetworkObservations, seconds: Int,
                      _ predicate: () async -> Bool) async throws {
        let end = ContinuousClock.now + .seconds(seconds)
        while !(await predicate()) {
            if let error = observations.failure { throw AuthorNetworkError.failed(error) }
            guard .now < end else {
                throw AuthorNetworkError.failed("timeout authenticated=\(observations.authenticatedCount) applied1=\(observations.acknowledged(1)) applied2=\(observations.acknowledged(2))")
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
    private func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }
}

/// Independent runtime, cache, registry, listener and event loops. Several such
/// nodes share the test process, not a dispatcher or cache. Process failure and
/// database publication are intentionally separate acceptance scenarios.
private struct AuthorNetworkGateway: Sendable {
    let configuration: V2AuthorPresentationDispatcher.Configuration
    let feed: AuthorNetworkFeed
    let runtime: V2AuthorPresentationRuntime
    let channels: AuthorNetworkServerChannels
    let peaks: AuthorNetworkPeaks
    let listener: any Channel
    let group: MultiThreadedEventLoopGroup
    let monitor: Task<Void, Never>

    static func start(authors: [AuthorNetworkAuthor], room: RoomID, source: AuthorNetworkSource,
                      limits: V2FrameLimits, tls: NIOSSLContext) async throws -> Self {
        let configuration = try V2AuthorPresentationDispatcher.Configuration()
        let feed = AuthorNetworkFeed(authors: authors, room: room, richMetadata: true, source: source)
        let runtime = V2AuthorPresentationRuntime(configuration: configuration, ingressConfiguration: try .init(),
            readBatch: feed.read, closeReader: { await feed.close() })
        let registry = V2DeviceConnectionRegistry(foregroundFrameLimits: limits, authorPresentationIngress: runtime.ingress)
        let channels = AuthorNetworkServerChannels(), group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
        let scheduler = V2NIOForegroundWriteScheduler(), metrics = V2GatewayTransportMetrics()
        let commands = try AuthorNetworkCommands(room: room, authors: authors)
        do {
            try await runtime.startProfileChanges(feed)
            let listener = try await ServerBootstrap(group: group)
                .childChannelOption(ChannelOptions.socketOption(.so_sndbuf), value: 4096)
                .childChannelOption(ChannelOptions.writeBufferWaterMark, value: .init(low: 1024, high: 4096))
                .childChannelInitializer { channel in
                    channels.add(channel)
                    do {
                        let session = V2GatewaySession(limits: try .init(maximumInFlightRequests: 4),
                            authenticator: AuthorNetworkAuthenticator(), capabilityProfile: "base",
                            supportsAuthorPresentationDelta: true, commandAdmission: V2AllowingGatewayCommandAdmission())
                        let stream = V2GatewayByteStream(frameLimits: limits, session: session, handler: commands,
                            registry: registry, authorPresentationDispatcher: runtime.dispatcher,
                            authorPresentationIngress: runtime.ingress)
                        return channel.eventLoop.makeCompletedFuture {
                            try channel.pipeline.syncOperations.addHandler(NIOSSLServerHandler(context: tls))
                            try channel.pipeline.syncOperations.addHandler(V2NIOGatewayChannelHandler(stream: stream,
                                maximumQueuedInboundBytes: 262_144, maximumQueuedInboundChunks: 64,
                                authenticationTimeoutMilliseconds: 180_000, idleTimeoutMilliseconds: 180_000,
                                transportMetrics: metrics, foregroundWriteScheduler: scheduler))
                        }
                    } catch { return channel.eventLoop.makeFailedFuture(error) }
                }.bind(host: "127.0.0.1", port: 0).get()
            let peaks = AuthorNetworkPeaks()
            let monitor = Task {
                while !Task.isCancelled {
                    peaks.record(await runtime.dispatcher.statistics())
                    do { try await Task.sleep(for: .milliseconds(100)) } catch { break }
                }
            }
            return .init(configuration: configuration, feed: feed, runtime: runtime, channels: channels,
                         peaks: peaks, listener: listener, group: group, monitor: monitor)
        } catch {
            await runtime.close()
            try? await group.shutdownGracefully()
            throw error
        }
    }

    func close() async {
        monitor.cancel(); await monitor.value
        try? await listener.close().get()
        for channel in channels.snapshot { try? await channel.close().get() }
        await runtime.close()
        try? await group.shutdownGracefully()
    }
}

private final class AuthorNetworkServerChannels: Sendable {
    private let state = Mutex<[Int: any Channel]>([:])
    func add(_ channel: any Channel) {
        guard let port = channel.remoteAddress?.port else { return }
        state.withLock { $0[port] = channel }
    }
    func peer(port: Int) -> (any Channel)? { state.withLock { $0[port] } }
    var snapshot: [any Channel] { state.withLock { Array($0.values) } }
}

private enum AuthorNetworkError: Error { case failed(String) }
private struct AuthorNetworkAuthor: Sendable {
    let userID = UserID(uuid: UUID())
    let mediaID = MediaID(uuid: UUID())
    let variantID = ResourceVariantID(uuid: UUID())
}
private final class AuthorNetworkOrigins: Sendable {
    private let state = Mutex(0)
    var loads: Int { state.withLock { $0 } }
    func loaded(_ count: Int) { state.withLock { $0 += count } }
}
private struct AuthorNetworkAuthenticator: V2GatewayAuthenticator {
    func authenticateSession(accessToken: String, deviceID: DeviceID) async throws -> V2GatewayAuthentication {
        .init(userID: try UserID(accessToken), expiresAt: nil)
    }
}

private struct AuthorNetworkCommands: V2GatewayCommandHandler {
    let page: IMV2GroupEventPage
    let stalledPage: IMV2GroupEventPage
    init(room: RoomID, authors: [AuthorNetworkAuthor]) throws {
        var page = IMV2GroupEventPage(); page.roomID = room.rawValue
        page.events = try authors.enumerated().map { index, author in
            var event = IMV2GroupEvent(); event.sourceEventID = UUID().uuidString
            event.roomSequence = UInt64(index + 1); event.projectionKind = "message"
            event.payload = try JSONSerialization.data(withJSONObject: ["event_type": "message.accepted",
                "room_id": room.rawValue, "room_sequence": index + 1, "sender_user_id": author.userID.rawValue])
            return event
        }
        page.nextRoomSequence = UInt64(authors.count)
        self.page = page
        // A normal framed history response larger than the test socket buffers
        // makes a paused reader exert real TCP backpressure. It is sent only to
        // the explicitly selected slow peers, never injected into the server's
        // write callback or used as a fake dispatcher failure.
        var stalled = page
        var payload = try #require(JSONSerialization.jsonObject(with: stalled.events[0].payload) as? [String: Any])
        payload["body"] = String(repeating: "x", count: 48_000)
        stalled.events[0].payload = try JSONSerialization.data(withJSONObject: payload)
        stalledPage = stalled
    }
    func handle(envelope: IMV2Envelope, identity: V2AuthenticatedConnection) async throws -> IMV2Envelope {
        var result = IMV2Envelope()
        guard case .groupEventPull(let pull) = envelope.body, pull.roomID == page.roomID else {
            throw AuthorNetworkError.failed("unexpected benchmark command")
        }
        result.groupEventPage = pull.pageSize == 100 ? stalledPage : page
        return result
    }
}

/// Shared committed facts, with an independent cursor in every runtime. Caches
/// and recipient reads remain gateway-local. This fixture is not a SQL reader.
private actor AuthorNetworkSource: V2AuthorProfileChangeReading {
    let author: UserID
    private(set) var revision: UInt64 = 1
    init(author: UserID) { self.author = author }
    func advance() { revision += 1 }
    func readChanges(after sequence: UInt64?) async throws -> V2AuthorProfileChangeBatch {
        let head = revision - 1
        return try .init(head: head, resetRequired: sequence == nil, changes: sequence.map { cursor in
            guard cursor < head else { return [] }
            return try ((cursor + 1)...head).map { try .init(sequence: $0, userID: author, revision: $0 + 1) }
        } ?? [])
    }
}

private actor AuthorNetworkFeed: V2AuthorProfileChangeReading {
    let authors: [AuthorNetworkAuthor], room: RoomID
    nonisolated let origins: AuthorNetworkOrigins
    private let source: AuthorNetworkSource
    private let cache: V2PublicProfileSnapshotCache
    private let richMetadata: Bool
    private(set) var recipientReads = 0, keyReads = 0, readBatches = 0
    var originBatches: Int { get async { await cache.originBatches } }
    init(authors: [AuthorNetworkAuthor], room: RoomID, richMetadata: Bool, source: AuthorNetworkSource? = nil) {
        self.authors = authors; self.room = room; self.richMetadata = richMetadata
        self.source = source ?? AuthorNetworkSource(author: authors[0].userID)
        let origins = AuthorNetworkOrigins(); self.origins = origins
        cache = V2PublicProfileSnapshotCache { keys, _ in
            origins.loaded(keys.count)
            return try Dictionary(uniqueKeysWithValues: keys.map { key in
                let name = richMetadata ? String(repeating: "名", count: 26) + String(key.revision) : "Author \(key.revision)"
                return (key, try V2PublicIdentity(userID: .init(uuid: key.userID),
                    handle: .init("author"), displayName: name, accountKind: .regular))
            })
        }
    }
    func advance() async { await source.advance() }
    func readChanges(after sequence: UInt64?) async throws -> V2AuthorProfileChangeBatch {
        try await source.readChanges(after: sequence)
    }
    func read(_ inputs: [V2ProfilePresentationReadRequest]) async throws -> [Result<V2ProfilePresentationBatchResponse, any Error>] {
        recipientReads += inputs.count; keyReads += inputs.reduce(0) { $0 + $1.request.keys.count }; readBatches += 1
        let revision = await source.revision
        let selected = Dictionary(uniqueKeysWithValues: authors.map { ($0.userID, $0) })
        let keys = try Set(inputs.flatMap(\.request.keys)).map { lookup -> V2PublicProfileSnapshotKey in
            guard selected[lookup.userID] != nil, lookup.context == .room(room), let id = lookup.userID.uuidValue else {
                throw AuthorNetworkError.failed("wrong context")
            }
            return .init(userID: id, revision: lookup.userID == authors[0].userID ? Int64(revision) : 1)
        }
        let values = try await cache.read(keys, deadline: .now + .seconds(1))
        let versions = Dictionary(uniqueKeysWithValues: keys.map { (UserID(uuid: $0.userID), $0) })
        let now = Date(), nowMilliseconds = Int64(now.timeIntervalSince1970 * 1_000)
        var avatars: [UserID: V2ResourceAvatarAccess] = [:]
        for key in keys where richMetadata {
            let author = try #require(selected[UserID(uuid: key.userID)])
            let checksum = try V2ResourceChecksum(value: String(repeating: key.revision == 1 ? "a" : "b", count: 64))
            let url = try #require(URL(string: "https://objects.invalid/avatar?token=" + String(repeating: "x", count: 256)))
            avatars[author.userID] = try .init(mediaID: author.mediaID, variantID: author.variantID,
                version: key.revision, checksum: checksum, byteCount: 20_480,
                plan: .init(mode: .httpGet, url: url, expiresAt: now.addingTimeInterval(45),
                    expectedByteCount: 20_480, checksum: checksum))
        }
        return try inputs.map { input in
            let entries = try input.request.keys.map { lookup -> V2ProfilePresentationBatchEntry in
                guard let key = versions[lookup.userID], let identity = values[key],
                      let version = V2ProfileRevision(rawValue: UInt64(key.revision)) else {
                    throw AuthorNetworkError.failed("missing immutable content")
                }
                let avatar = avatars[lookup.userID]
                let lease = try V2PresentationAccessLease(actorUserID: input.actorUserID, deviceID: input.deviceID,
                    key: lookup, profileRevision: version, visibilityRevision: version, contextRevision: 1,
                    authorityVersion: .init(controlSequence: 0, roomID: room, membershipRevision: 1, permissionRevision: 1),
                    observedAt: now, validUntil: now.addingTimeInterval(60))
                return try .presentation(.init(view: .init(userID: lookup.userID, publicIdentity: identity,
                    avatar: avatar.map { .init(mediaID: $0.mediaID) }, state: .active, revision: version,
                    visibilityRevision: version), lease: lease), avatar: avatar)
            }
            return .success(try .init(serverNowUnixMilliseconds: nowMilliseconds, results: entries))
        }
    }
    func close() async { await cache.close() }
}

private final class AuthorNetworkObservations: Sendable {
    private struct State {
        var authenticated = 0
        var history: [Int: Set<UUID>] = [:]
        var historyProbes: Set<UUID> = []
        var appliedViews: [Int: Set<UUID>] = [:]
        var applied: [UInt64: Set<UUID>] = [:]
        var failure: String?
    }
    private let state = Mutex(State())
    var authenticatedCount: Int { state.withLock { $0.authenticated } }
    var historyCount: Int { historyCount(0) }
    var historyProbeCount: Int { state.withLock { $0.historyProbes.count } }
    func historyCount(_ generation: Int) -> Int { state.withLock { $0.history[generation]?.count ?? 0 } }
    var failure: String? { state.withLock { $0.failure } }
    func authenticated() { state.withLock { $0.authenticated += 1 } }
    func history(_ id: UUID, generation: Int) { state.withLock { _ = $0.history[generation, default: []].insert(id) } }
    func historyProbe(_ id: UUID) { state.withLock { _ = $0.historyProbes.insert(id) } }
    func acknowledge(_ id: UUID, revision: UInt64, generation: Int) {
        state.withLock { $0.applied[revision, default: []].insert(id); $0.appliedViews[generation, default: []].insert(id) }
    }
    func acknowledgedView(_ generation: Int) -> Int { state.withLock { $0.appliedViews[generation]?.count ?? 0 } }
    func acknowledged(_ revision: UInt64) -> Int { state.withLock { $0.applied[revision]?.count ?? 0 } }
    func acknowledged(_ revision: UInt64, among ids: Set<UUID>) -> Int {
        state.withLock { $0.applied[revision]?.intersection(ids).count ?? 0 }
    }
    func fail(_ error: any Error) { state.withLock { if $0.failure == nil { $0.failure = String(describing: error) } } }
}

/// All mutable peer state belongs to this channel's EventLoop. The shared
/// observations use a lock; decoded metadata is installed before an ACK is sent.
private final class AuthorNetworkPeer: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    let id = UUID(), user = UserID(uuid: UUID()), device = DeviceID(uuid: UUID())
    let room: RoomID, authors: [AuthorNetworkAuthor], limits: V2FrameLimits, observations: AuthorNetworkObservations
    private let richMetadata: Bool
    private var decoder: V2FrameDecoder
    private var stream: UUID?, view = UUID(), started = ContinuousClock.now
    private var generation = 0
    private var nextAcknowledgementID: UInt64 = 100
    private struct Applied {
        let value: V2AuthorizedProfilePresentation
        let avatar: V2ResourceAvatarAccess?
        let deadline: ContinuousClock.Instant
    }
    private struct PendingACK {
        let versions: [UserID: UInt64]
        let generation: Int, view: UUID, sequence: UInt64
    }
    private var applied: [UserID: Applied] = [:]
    private var confirmed: [UserID: UInt64] = [:]
    private var pendingACKs: [UInt64: PendingACK] = [:]
    init(limits: V2FrameLimits, room: RoomID, authors: [AuthorNetworkAuthor], richMetadata: Bool, observations: AuthorNetworkObservations) {
        self.limits = limits; self.decoder = .init(limits: limits); self.room = room; self.authors = authors; self.observations = observations
        self.richMetadata = richMetadata
    }
    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if case TLSUserEvent.handshakeCompleted = event {
            var hello = IMV2Envelope(); hello.requestID = 1
            hello.clientHello.supportedProtocolVersions = [IMV2ProtocolVersion.current]
            hello.clientHello.supportedCapabilityProfiles = ["base"]; hello.clientHello.deviceID = device.rawValue
            hello.clientHello.supportsAuthorPresentationDelta = true
            do { try send(hello, on: context.channel, version: 0) } catch { observations.fail(error); context.close(promise: nil) }
        }
        context.fireUserInboundEventTriggered(event)
    }
    func begin(on channel: any Channel) throws {
        guard let stream else { throw AuthorNetworkError.failed("not authenticated") }
        started = .now
        var request = IMV2Envelope(); request.requestID = 3
        request.authorPresentationStart.streamID = stream.uuidString; request.authorPresentationStart.viewID = view.uuidString
        request.authorPresentationStart.messageRoomIds = [room.rawValue]
        try send(request, on: channel)
    }
    func renew(on channel: any Channel) throws {
        guard applied.count == authors.count, applied.values.allSatisfy({ $0.deadline > .now }) else {
            throw AuthorNetworkError.failed("display expired before renewal")
        }
        generation += 1; view = UUID(); confirmed.removeAll()
        try begin(on: channel)
    }
    func pull(on channel: any Channel, probe: Bool = false) throws {
        var request = IMV2Envelope(); request.requestID = probe ? 7 : 6
        request.groupEventPull.roomID = room.rawValue; request.groupEventPull.pageSize = UInt32(authors.count)
        try send(request, on: channel)
    }
    func pullWhileReadStalled(on channel: any Channel) throws {
        // Socket buffers can absorb one response even after application reads
        // stop. A bounded burst fills that kernel slack; the normal server
        // response writer then waits for writability without an unbounded queue.
        for _ in 0..<8 {
            var request = IMV2Envelope(); request.requestID = nextAcknowledgementID
            nextAcknowledgementID += 1
            request.groupEventPull.roomID = room.rawValue; request.groupEventPull.pageSize = 100
            try send(request, on: channel)
        }
    }
    private func wireKey(_ userID: UserID) -> IMV2ProfilePresentationKey {
        var key = IMV2ProfilePresentationKey(); key.userID = userID.rawValue; key.roomID = room.rawValue
        return key
    }
    private func send(_ envelope: IMV2Envelope, on channel: any Channel, version: UInt8 = UInt8(IMV2ProtocolVersion.current)) throws {
        var envelope = envelope; if version != 0 { envelope.protocolVersion = IMV2ProtocolVersion.current }
        let bytes = try V2FrameCodec.encode(V2ServerProtobufFrameCodec.encode(envelope, frameVersion: version), limits: limits)
        channel.writeAndFlush(ByteBuffer(bytes: bytes)).whenFailure { [observations] in observations.fail($0) }
    }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        do {
            for frame in try decoder.append(Data(unwrapInboundIn(data).readableBytesView)) {
                let response = try V2ServerProtobufFrameCodec.decode(frame)
                switch response.body {
                case .serverHello(let hello):
                    guard let selected = UUID(uuidString: hello.authorPresentationStreamID) else { throw AuthorNetworkError.failed("feature absent") }
                    stream = selected
                    var auth = IMV2Envelope(); auth.requestID = 2; auth.authenticate.accessToken = user.rawValue
                    auth.authenticate.deviceID = device.rawValue; try send(auth, on: context.channel)
                case .authenticated(let auth):
                    guard auth.userID == user.rawValue, auth.deviceID == device.rawValue,
                          UUID(uuidString: auth.authorPresentationStreamID) == stream else { throw AuthorNetworkError.failed("wrong authenticated identity") }
                    observations.authenticated()
                case .authorPresentationStarted(let echo):
                    guard UUID(uuidString: echo.streamID) == stream else { throw AuthorNetworkError.failed("wrong start stream") }
                    guard UUID(uuidString: echo.viewID) == view else { continue }
                    guard echo.messageRoomIds == [room.rawValue] else { throw AuthorNetworkError.failed("wrong start rooms") }
                    var request = IMV2Envelope(); request.requestID = 4
                    request.authorPresentationInterests.streamID = echo.streamID; request.authorPresentationInterests.viewID = echo.viewID
                    request.authorPresentationInterests.sequence = 1
                    request.authorPresentationInterests.keys = authors.map { wireKey($0.userID) }
                    try send(request, on: context.channel)
                case .authorPresentationDelta(let bytes):
                    let delta = try V2AuthorPresentationDelta.decode(bytes.payload)
                    guard delta.streamID == stream, delta.actorUserID == user, delta.deviceID == device,
                          delta.batch.results.count <= authors.count else { throw AuthorNetworkError.failed("wrong recipient or view") }
                    guard delta.viewID == view else { continue }
                    let elapsed = started.duration(to: .now).components
                    let age = elapsed.seconds * 1_000 + elapsed.attoseconds / 1_000_000_000_000_000
                    if generation > 0, applied.values.contains(where: { $0.deadline <= .now }) {
                        throw AuthorNetworkError.failed("display expired while renewing")
                    }
                    var versions: [UserID: UInt64] = [:], remaining = Int64.max
                    for result in delta.batch.results {
                        guard let author = authors.first(where: { $0.userID == result.key.userID }),
                              result.key.context == .room(room) else { throw AuthorNetworkError.failed("wrong granted key") }
                        switch result {
                        case .retryable: continue
                        case .unavailable: throw AuthorNetworkError.failed("unexpected denial")
                        case .presentation(let value, let avatar):
                            guard value.view.userID == author.userID else { throw AuthorNetworkError.failed("wrong profile identity") }
                            if richMetadata {
                                guard value.view.publicIdentity?.displayName.utf8.count == 79,
                                      avatar?.version == Int64(value.view.revision.rawValue), avatar?.byteCount == 20_480,
                                      avatar?.mediaID == author.mediaID, avatar?.variantID == author.variantID,
                                      avatar?.plan != nil else { throw AuthorNetworkError.failed("missing rich metadata") }
                            } else if avatar != nil { throw AuthorNetworkError.failed("unexpected avatar") }
                            let lifetime = value.lease.validUntilUnixMilliseconds - delta.batch.serverNowUnixMilliseconds
                                - max(0, age - delta.serverViewAgeMilliseconds)
                            guard lifetime > 0 else { throw AuthorNetworkError.failed("expired grant") }
                            if let old = applied[author.userID], old.value.view.revision.rawValue > value.view.revision.rawValue { continue }
                            applied[author.userID] = .init(value: value, avatar: avatar, deadline: .now + .milliseconds(lifetime))
                            versions[author.userID] = value.view.revision.rawValue; remaining = min(remaining, lifetime)
                        }
                    }
                    guard !versions.isEmpty else { continue }
                    let requestID = nextAcknowledgementID; nextAcknowledgementID += 1
                    pendingACKs[requestID] = .init(versions: versions, generation: generation, view: view, sequence: delta.sequence)
                    var ack = IMV2Envelope(); ack.requestID = requestID
                    ack.authorPresentationReceipt.streamID = delta.streamID.uuidString; ack.authorPresentationReceipt.viewID = delta.viewID.uuidString
                    ack.authorPresentationReceipt.sequence = delta.sequence
                    ack.authorPresentationReceipt.keys = authors.compactMap { versions[$0.userID] == nil ? nil : wireKey($0.userID) }
                    ack.authorPresentationReceipt.minimumRemainingMilliseconds = UInt32(min(300_000, remaining))
                    try send(ack, on: context.channel)
                case .authorPresentationReceipted(let echo):
                    guard let receipt = pendingACKs.removeValue(forKey: response.requestID),
                          UUID(uuidString: echo.streamID) == stream, UUID(uuidString: echo.viewID) == receipt.view,
                          echo.sequence == receipt.sequence,
                          Set(echo.keys.map(\.userID)) == Set(receipt.versions.keys.map(\.rawValue)) else {
                        throw AuthorNetworkError.failed("unsolicited or mismatched ACK echo")
                    }
                    guard receipt.generation == generation else { continue }
                    for (author, version) in receipt.versions { confirmed[author] = max(confirmed[author, default: 0], version) }
                    if authors.allSatisfy({ confirmed[$0.userID, default: 0] >= 1 }) {
                        let phase = confirmed[authors[0].userID, default: 0]
                        if generation == 0 || phase >= 2 { observations.acknowledge(id, revision: phase, generation: generation) }
                    }
                case .groupEventPage(let page):
                    guard page.roomID == room.rawValue, page.events.count == authors.count,
                          page.nextRoomSequence == UInt64(authors.count) else { throw AuthorNetworkError.failed("wrong history page") }
                    for (index, event) in page.events.enumerated() {
                        let payload = try JSONSerialization.jsonObject(with: event.payload) as? [String: Any]
                        guard event.roomSequence == UInt64(index + 1),
                              payload?["sender_user_id"] as? String == authors[index].userID.rawValue else {
                            throw AuthorNetworkError.failed("wrong history author")
                        }
                    }
                    if response.requestID == 7 { observations.historyProbe(id) }
                    else if response.requestID == 6 { observations.history(id, generation: generation) }
                case .error(let error): throw AuthorNetworkError.failed("server: \(error.code)")
                default: break // Coverage controls and interest acceptance do not authorize a profile.
                }
            }
        } catch { observations.fail(error); context.close(promise: nil) }
    }
    func errorCaught(context: ChannelHandlerContext, error: any Error) { observations.fail(error); context.close(promise: nil) }
}

/// Fixed-size sampling, not an allocation trace or a proof of unobserved peaks.
private final class AuthorNetworkPeaks: Sendable {
    struct Values: Sendable {
        var pendingKeys = 0, pendingBytes = 0, outputBytes = 0, hintBytes = 0, reading = 0, writing = 0
    }
    private let state = Mutex(Values())
    var snapshot: Values { state.withLock { $0 } }
    func record(_ value: V2AuthorPresentationDispatcher.Statistics) {
        state.withLock {
            $0.pendingKeys = max($0.pendingKeys, value.pendingKeys); $0.pendingBytes = max($0.pendingBytes, value.pendingBytes)
            $0.outputBytes = max($0.outputBytes, value.outputBytes); $0.hintBytes = max($0.hintBytes, value.hintBytes)
            $0.reading = max($0.reading, value.reading); $0.writing = max($0.writing, value.writing)
        }
    }
}
