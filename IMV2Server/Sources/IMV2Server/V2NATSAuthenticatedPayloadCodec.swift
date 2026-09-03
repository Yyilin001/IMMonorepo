import Crypto
import Foundation

/// Compact application-level integrity envelope for every NATS payload that
/// can affect a connected client. Core NATS authentication protects broker
/// access; this independent MAC prevents a leaked broker credential from
/// turning arbitrary bytes into a trusted Gateway event.
enum V2NATSAuthenticatedPayloadCodec {
    static let overheadBytes = magic.count + authenticationCodeBytes

    private static let magic = Data([0x49, 0x4D, 0x4E, 0x41, 0x01]) // IMNA v1
    private static let authenticationCodeBytes = 32
    private static let keyDerivationContext = Data(
        "im-v2/nats-payload-authentication/v1".utf8
    )

    static func seal(_ payload: Data, subject: String, routingKey: Data) -> Data {
        var authenticated = magic
        authenticated.append(payload)
        authenticated.append(contentsOf: HMAC<SHA256>.authenticationCode(
            for: authenticationInput(subject: subject, authenticated: authenticated),
            using: authenticationKey(from: routingKey)
        ))
        return authenticated
    }

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

    private static func authenticationKey(from routingKey: Data) -> SymmetricKey {
        let derived = HMAC<SHA256>.authenticationCode(
            for: keyDerivationContext,
            using: SymmetricKey(data: routingKey)
        )
        return SymmetricKey(data: Data(derived))
    }

    private static func authenticationInput(
        subject: String,
        authenticated: Data
    ) -> Data {
        // NATS subjects cannot contain NUL, so this binds the MAC to the
        // transport subject without adding another field to the envelope.
        var input = Data(subject.utf8)
        input.append(0)
        input.append(authenticated)
        return input
    }
}

final class V2NATSAuthenticatedPayloadDispatcher: V2NATSPayloadSubmitting, Sendable {
    private let routingKey: Data
    private let invalidPayload: @Sendable () -> Void
    private let downstream: any V2NATSPayloadSubmitting

    init(
        routingKey: Data,
        invalidPayload: @escaping @Sendable () -> Void = {},
        downstream: any V2NATSPayloadSubmitting
    ) {
        self.routingKey = routingKey
        self.invalidPayload = invalidPayload
        self.downstream = downstream
    }

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
