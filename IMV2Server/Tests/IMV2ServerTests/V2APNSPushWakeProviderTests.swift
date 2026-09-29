@testable import IMV2ServerApplication
@testable import IMV2ServerContracts
import Foundation
import IMV2Core
@testable import IMV2Server
@testable import IMV2ServerInfrastructure
import Testing

@Suite("V2 APNs Push wake provider")
struct V2APNSPushWakeProviderTests {
    @Test("JWT timestamps reject overflow and nonfinite clocks", arguments: [
        Double(Int64.max), Double.infinity, -Double.infinity, Double.nan, -1.0
    ])
    func rejectsUnrepresentableTimestamp(seconds: Double) throws {
        let authorizer = try V2APNSJWTAuthorizer(teamID: "TEST", keyID: "TEST", privateKeyRawBase64: Data(repeating: 1, count: 32).base64EncodedString())
        #expect(throws: V2APNSPushProviderError.invalidConfiguration) {
            try authorizer.authorizationValue(now: Date(timeIntervalSince1970: seconds))
        }
    }

    @Test("JWT issuance retains integral seconds", arguments: [0.0, 42.75, 1_750_000_000.999])
    func preservesTimestamp(seconds: Double) throws {
        let authorizer = try V2APNSJWTAuthorizer(teamID: "TEST", keyID: "TEST", privateKeyRawBase64: Data(repeating: 1, count: 32).base64EncodedString())
        let token = try authorizer.authorizationValue(now: Date(timeIntervalSince1970: seconds))
        let components = token.split(separator: ".")
        #expect(components.count == 3)
        var payload = String(components[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        let data = try #require(Data(base64Encoded: payload))
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect((json["iat"] as? NSNumber)?.int64Value == Int64(seconds))
    }

    @Test("missing endpoint terminally suppresses a generic wake without an HTTP request")
    func missingEndpointSuppresses() async throws {
        let endpoints = RecordingEndpointStore(endpoint: nil)
        let http = RecordingPushHTTPClient(response: .init(statusCode: 200))
        let provider = try V2APNSPushWakeProvider(
            endpointStore: endpoints,
            httpClient: http,
            authorizer: StaticAPNSAuthorizer(),
            topic: "com.example.im"
        )

        let outcome = try await provider.send(try wake())

        #expect(outcome == .suppressed(.endpointUnavailable))
        #expect(await http.requests().isEmpty)
        #expect(await endpoints.disabled().isEmpty)
    }

    @Test("unregistered endpoint is disabled and the wake becomes terminal")
    func unregisteredEndpointIsDisabled() async throws {
        let endpoint = try endpoint()
        let endpoints = RecordingEndpointStore(endpoint: endpoint)
        let http = RecordingPushHTTPClient(
            response: .init(statusCode: 410, body: Data(#"{"reason":"Unregistered"}"#.utf8))
        )
        let provider = try V2APNSPushWakeProvider(
            endpointStore: endpoints,
            httpClient: http,
            authorizer: StaticAPNSAuthorizer(),
            topic: "com.example.im",
            now: { Date(timeIntervalSince1970: 100) }
        )

        let outcome = try await provider.send(try wake())

        #expect(outcome == .suppressed(.endpointRejected))
        #expect(await endpoints.disabled() == [endpoint])
        let request = try #require(await http.requests().first)
        #expect(request.body == Data(#"{"aps":{"content-available":1}}"#.utf8))
        #expect(request.headers["apns-push-type"] == "background")
        #expect(request.headers["apns-priority"] == "5")
        #expect(request.headers["authorization"] == "bearer test")
        #expect(!String(decoding: request.body, as: UTF8.self).contains("room"))
        #expect(!String(decoding: request.body, as: UTF8.self).contains("message"))
    }

    @Test("transient provider rejection remains retryable and preserves endpoint")
    func transientProviderFailurePreservesEndpoint() async throws {
        let endpoint = try endpoint()
        let endpoints = RecordingEndpointStore(endpoint: endpoint)
        let http = RecordingPushHTTPClient(response: .init(statusCode: 503))
        let provider = try V2APNSPushWakeProvider(
            endpointStore: endpoints,
            httpClient: http,
            authorizer: StaticAPNSAuthorizer(),
            topic: "com.example.im"
        )

        await #expect(throws: V2APNSPushProviderError.providerRejected) {
            try await provider.send(try wake())
        }
        #expect(await endpoints.disabled().isEmpty)
    }

    private func wake() throws -> V2GenericPushWake {
        .init(
            dispatchID: UUID(uuidString: "00000000-0000-0000-0000-000000000401")!,
            deviceID: try DeviceID("00000000-0000-0000-0000-000000000402"),
            campaignID: try .init(rawValue: "sync-wake")
        )
    }

    private func endpoint() throws -> V2PushDeviceEndpoint {
        .init(
            deviceID: try DeviceID("00000000-0000-0000-0000-000000000402"),
            provider: .apns,
            environment: .development,
            token: String(repeating: "a", count: 64),
            generation: UUID(uuidString: "00000000-0000-0000-0000-000000000403")!
        )
    }
}

private actor RecordingEndpointStore: V2PushDeviceEndpointStore {
    private let activeEndpoint: V2PushDeviceEndpoint?
    private var disabledEndpoints: [V2PushDeviceEndpoint] = []

    init(endpoint: V2PushDeviceEndpoint?) {
        activeEndpoint = endpoint
    }

    func register(
        actorUserID _: UserID,
        deviceID _: DeviceID,
        endpoint _: V2PushDeviceEndpointRegistration,
        now _: Date
    ) {}

    func endpoint(for _: DeviceID) -> V2PushDeviceEndpoint? {
        activeEndpoint
    }

    func disable(_ endpoint: V2PushDeviceEndpoint, now _: Date) {
        disabledEndpoints.append(endpoint)
    }

    func disabled() -> [V2PushDeviceEndpoint] {
        disabledEndpoints
    }
}

private actor RecordingPushHTTPClient: V2PushHTTPClient {
    private let response: V2PushHTTPResponse
    private var sentRequests: [V2PushHTTPRequest] = []

    init(response: V2PushHTTPResponse) {
        self.response = response
    }

    func execute(_ request: V2PushHTTPRequest) -> V2PushHTTPResponse {
        sentRequests.append(request)
        return response
    }

    func requests() -> [V2PushHTTPRequest] {
        sentRequests
    }
}

private struct StaticAPNSAuthorizer: V2APNSAuthorizer {
    func authorizationValue(now _: Date) -> String { "bearer test" }
}
