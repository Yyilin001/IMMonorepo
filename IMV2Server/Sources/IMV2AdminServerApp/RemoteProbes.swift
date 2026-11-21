import AsyncHTTPClient
import Foundation
import IMV2ActorApplication
import IMV2Core
import IMV2Server
import IMV2ServerApplication
import IMV2ServerContracts
import IMV2ServerGateway
import NIOCore
import NIOPosix
import NIOSSL

/// Probes use fixed deployment targets. Browser requests cannot supply an address or credentials.
struct AdminRemoteProbes {
    static func make(configuration: V2AdminRuntimeConfiguration, caller: V2RoomActorApplication,
                     http: HTTPClient, group: EventLoopGroup) throws -> [V2AdminProbeTarget: V2AdminProbe] {
        let accountURL = configuration.accountProbeOrigin + "/v2/public-identities/me"
        let gateway = try GatewayHelloProbe(host: configuration.gatewayProbeHost, port: configuration.gatewayProbePort)
        return [
            .account: {
                let response = try await http.execute(.init(url: accountURL), timeout: .seconds(3))
                // Check the Account route's actual response through the same TLS edge as the clients.
                guard response.status == .unauthorized else {
                    return .init(healthy: false, detail: "账户身份接口返回非预期的 HTTP 状态")
                }
                struct Denial: Decodable { let error: Bool; let reason: String }
                let body = try await response.body.collect(upTo: 1024)
                let denial = try JSONDecoder().decode(Denial.self, from: Data(body.readableBytesView))
                let ok = denial.error && denial.reason == "Unauthorized"
                return .init(healthy: ok, detail: ok ? "HTTPS 身份接口正确拒绝了未登录请求" : "账户身份接口响应不符合协议")
            },
            .gateway: { try await gateway.check(on: group) },
            .policy: {
                let value = try await caller.probePolicyOwners(deadline: .now + .seconds(3))
                return .init(healthy: !value.closed, detail: value.closed ? "有策略目录已关闭" : "已从全部配置的 Policy Owner 读取策略目录状态",
                    owners: value.owners, inFlight: value.inFlight)
            },
            .actors: {
                let state = try await caller.probePlacement(deadline: .now + .seconds(3))
                let ok = state.shards > 0 && state.expected > 0 && state.healthy == state.expected
                return .init(healthy: ok, detail: "已取得 \(state.shards) 个分片的多数派确认，Room Host 就绪 \(state.healthy)/\(state.expected)")
            },
        ]
    }
}

private struct GatewayHelloProbe: Sendable {
    let host: String
    let port: Int
    let tls: NIOSSLContext
    let limits: V2FrameLimits
    let hello: ByteBuffer

    init(host: String, port: Int) throws {
        self.host = host; self.port = port
        var configuration = TLSConfiguration.makeClientConfiguration()
        configuration.minimumTLSVersion = .tlsv13
        self.tls = try NIOSSLContext(configuration: configuration)
        limits = try V2FrameLimits(maximumPayloadBytes: 8192, maximumMessageSendPayloadBytes: 8192,
            acceptedVersions: [0, UInt8(IMV2ProtocolVersion.current)])
        var message = IMV2Envelope()
        message.requestID = 1
        message.clientHello.supportedProtocolVersions = [IMV2ProtocolVersion.current]
        message.clientHello.supportedCapabilityProfiles = ["base"]
        message.clientHello.supportsMessageSendOperations = true
        message.clientHello.deviceID = UUID().uuidString
        let frame = try V2ServerProtobufFrameCodec.encode(message, frameVersion: 0)
        hello = .init(bytes: try V2FrameCodec.encode(frame, limits: limits))
    }

    func check(on group: EventLoopGroup) async throws -> V2AdminProbeReading {
        // For IP literals NIOSSL verifies the peer IP SAN and must not send an IP as SNI.
        let serverName = (try? SocketAddress(ipAddress: host, port: port)) == nil ? host : nil
        let deadline = NIODeadline.now() + .seconds(3)
        let channel = try await ClientBootstrap(group: group).connectTimeout(.seconds(2))
            .connect(host: host, port: port) { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(NIOSSLClientHandler(context: tls, serverHostname: serverName))
                    return try NIOAsyncChannel<ByteBuffer, ByteBuffer>(wrappingChannelSynchronously: channel)
                }
            }
        let timeout = channel.channel.eventLoop.scheduleTask(deadline: deadline) { channel.channel.close(promise: nil) }
        defer { timeout.cancel() }
        return try await channel.executeThenClose { inbound, outbound in
            try await outbound.write(hello)
            var decoder = V2FrameDecoder(limits: limits)
            for try await bytes in inbound {
                guard let frame = try decoder.append(Data(bytes.readableBytesView)).first else { continue }
                let reply = try V2ServerProtobufFrameCodec.decode(frame)
                guard frame.requestID == 1, case .serverHello(let negotiated)? = reply.body,
                      negotiated.selectedProtocolVersion == IMV2ProtocolVersion.current,
                      negotiated.selectedCapabilityProfile == "base" else {
                    return .init(healthy: false, detail: "网关已响应，但协议协商不匹配")
                }
                return .init(healthy: true, detail: "已验证 TLS 证书并完成 IM 协议 v\(negotiated.selectedProtocolVersion) 握手")
            }
            throw V2AdminError.unavailable
        }
    }
}
