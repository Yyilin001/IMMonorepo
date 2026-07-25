import Foundation
import IMV2Core
@testable import IMV2Server
import Testing

@Suite("V2 APNs Push wake provider")
struct V2APNSPushWakeProviderTests {
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
