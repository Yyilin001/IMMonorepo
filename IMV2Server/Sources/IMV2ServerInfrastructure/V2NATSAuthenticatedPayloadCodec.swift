import IMV2ServerApplication
import IMV2ServerContracts
import Crypto
import Foundation

/// 所有可能影响在线客户端的 NATS 载荷所使用的紧凑应用层完整性信封。
///
/// 核心 NATS 认证只保护代理访问权限；这里的独立 MAC 保证即使代理凭据泄漏，
/// 也不能把任意字节变成受信网关事件。
enum V2NATSAuthenticatedPayloadCodec {
    /// 信封相对原文的固定额外开销：魔数加认证码长度。
    static let overheadBytes = magic.count + authenticationCodeBytes

    private static let magic = Data([0x49, 0x4D, 0x4E, 0x41, 0x01]) // IMNA v1
    private static let authenticationCodeBytes = 32
    private static let keyDerivationContext = Data(
        "im-v2/nats-payload-authentication/v1".utf8
    )

    /// 以主题与路由密钥为载荷加封。
    ///
    /// 认证码同时覆盖主题，因此同一载荷被转发到其他主题时校验会失败。
    ///
    /// - Parameters:
    ///   - payload: 原始载荷。
    ///   - subject: NATS 主题。
    ///   - routingKey: 部署路由密钥。
    /// - Returns: 魔数、原文与认证码拼接而成的信封。
    static func seal(_ payload: Data, subject: String, routingKey: Data) -> Data {
        var authenticated = magic
        authenticated.append(payload)
        authenticated.append(contentsOf: HMAC<SHA256>.authenticationCode(
            for: authenticationInput(subject: subject, authenticated: authenticated),
            using: authenticationKey(from: routingKey)
        ))
        return authenticated
    }

    /// 校验并解封信封。
    ///
    /// - Parameters:
    ///   - envelope: 收到的信封。
    ///   - subject: 本次订阅的主题。
    ///   - routingKey: 部署路由密钥，长度需不少于 32 字节。
    /// - Returns: 校验通过的原始载荷；任一校验失败返回 `nil`。
    static func open(_ envelope: Data, subject: String, routingKey: Data) -> Data? {
        guard routingKey.count >= 32,
              envelope.count >= overheadBytes
        else { return nil }
        let authenticatedCount = envelope.count - authenticationCodeBytes
        let authenticated = Data(envelope.prefix(authenticatedCount))
        guard authenticated.starts(with: magic) else { return nil }
        let code = envelope.suffix(authenticationCodeBytes)
        guard HMAC<SHA256>.isValidAuthenticationCode(
            code,
            authenticating: authenticationInput(
                subject: subject,
                authenticated: authenticated
            ),
            using: authenticationKey(from: routingKey)
        ) else { return nil }
        return Data(authenticated.dropFirst(magic.count))
    }

    /// 由路由密钥派生认证密钥。
    ///
    /// - Parameter routingKey: 部署路由密钥。
    /// - Returns: 用于载荷认证的对称密钥。
    private static func authenticationKey(from routingKey: Data) -> SymmetricKey {
        let derived = HMAC<SHA256>.authenticationCode(
            for: keyDerivationContext,
            using: SymmetricKey(data: routingKey)
        )
        return SymmetricKey(data: Data(derived))
    }

    /// 构造认证输入，把主题与已封装内容绑定在一起。
    ///
    /// - Parameters:
    ///   - subject: NATS 主题。
    ///   - authenticated: 已封装内容。
    /// - Returns: 认证码输入字节。
    private static func authenticationInput(
        subject: String,
        authenticated: Data
    ) -> Data {
        // NATS 主题不能包含 NUL，因此可将 MAC 绑定到传输主题，
        // 无需在信封中增加字段。
        var input = Data(subject.utf8)
        input.append(0)
        input.append(authenticated)
        return input
    }
}

/// 对订阅载荷做解封校验后再转交下游的提交器。
final class V2NATSAuthenticatedPayloadDispatcher: V2NATSPayloadSubmitting, Sendable {
    private let routingKey: Data
    private let invalidPayload: @Sendable () -> Void
    private let downstream: any V2NATSPayloadSubmitting

    /// 组合路由密钥、非法载荷回调与下游提交器。
    ///
    /// - Parameters:
    ///   - routingKey: 部署路由密钥。
    ///   - invalidPayload: 校验失败时的回调，默认忽略。
    ///   - downstream: 校验通过后接收载荷的下游。
    init(
        routingKey: Data,
        invalidPayload: @escaping @Sendable () -> Void = {},
        downstream: any V2NATSPayloadSubmitting
    ) {
        self.routingKey = routingKey
        self.invalidPayload = invalidPayload
        self.downstream = downstream
    }

    /// 校验载荷并在通过后转交下游，失败时只触发回调而不下发任何字节。
    ///
    /// - Parameters:
    ///   - subject: NATS 主题。
    ///   - payload: 收到的原始信封。
    func submit(subject: String, payload: Data) {
        guard let verified = V2NATSAuthenticatedPayloadCodec.open(
            payload,
            subject: subject,
            routingKey: routingKey
        ) else {
            invalidPayload()
            return
        }
        downstream.submit(subject: subject, payload: verified)
    }
}
