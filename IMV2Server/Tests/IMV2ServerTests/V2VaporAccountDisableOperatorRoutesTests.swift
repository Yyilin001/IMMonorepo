import HTTPTypes
import Foundation
import IMV2Core
import IMV2Server
import IMV2ServerHTTP
import Testing
import Vapor
import VaporTesting

@Suite("V2 Vapor account-disable operator routes")
struct V2VaporAccountDisableOperatorRoutesTests {
    @Test("account-disable responses reject unrepresentable timestamps and preserve floor rounding", arguments: ["disabled", "idempotent", "already_disabled"])
    func responseClockBounds(kind: String) async throws {
        let app = try await Application(.testing)
        do {
            let token = Data(repeating: 14, count: 32).base64EncodedString()
            let service = AccountDisableRouteService()
            V2VaporAccountDisableOperatorRoutes(authenticator: try .init(base64EncodedBearerToken: token), service: service).register(on: app)
            let input = V2AccountDisableHTTPRequest(operationID: UUID(), userID: UUID().uuidString, reason: .userRequested)
            func outcome(_ date: Date) -> V2AccountDisableOutcome {
                switch kind {
                case "idempotent": .idempotent(disabledAt: date)
                case "already_disabled": .alreadyDisabled(disabledAt: date)
                default: .disabled(disabledAt: date)
                }
            }
            let badDates = [Double.nan, .infinity, -.infinity, .greatestFiniteMagnitude, -.greatestFiniteMagnitude, Double(Int64.max) / 1_000, Double(Int64.min) / 1_000 - 2].map { Date(timeIntervalSince1970: $0) }
            for bad in badDates {
                await service.setOutcome(outcome(bad))
                try await app.testing { client in
                    let response = try await client.send(.post, headers: [.authorization: "Bearer \(token)"], to: "internal/v2/accounts/disable", beforeSend: { request in
                    try request.content.encode(input)
                })
                    #expect(response.status == .serviceUnavailable)
                    #expect(response.headers[.cacheControl] == "no-store")
                    #expect(response.headers[.pragma] == "no-cache")
                    #expect((try await response.body.data() ?? Data()).isEmpty)
                }
            }
            await service.setFailure(.unavailable)
            try await app.testing { client in
                let response = try await client.send(.post, headers: [.authorization: "Bearer \(token)"], to: "internal/v2/accounts/disable", beforeSend: { request in
                try request.content.encode(input)
            })
                #expect(response.status == .serviceUnavailable)
                #expect(response.headers[.cacheControl] == "no-store")
                #expect(response.headers[.pragma] == "no-cache")
                #expect((try await response.body.data() ?? Data()).isEmpty)
            }
            for (error, status) in [(V2AccountDisableError.operationConflict, HTTPResponse.Status.conflict), (.invalidUserID, .badRequest)] {
                await service.setFailure(error)
                try await app.testing { client in
                    let response = try await client.send(.post, headers: [.authorization: "Bearer \(token)"], to: "internal/v2/accounts/disable", beforeSend: { request in
                    try request.content.encode(input)
                })
                    #expect(response.status == status)
                }
            }
            let validDates: [(Double, Int64)] = [
                (0, 0), (1.25, 1_250), (-1.00025, -1_001),
                (1_750_000_000.125, 1_750_000_000_125),
                (946_684_800 - 211_813_488_000, -210_866_803_200_000),
                (946_684_800 + 9_223_371_331_200 - 10, 9_224_318_015_990_000)
            ]
            for (seconds, expected) in validDates {
                await service.setOutcome(outcome(Date(timeIntervalSince1970: seconds)))
                try await app.testing { client in
                    let response = try await client.send(.post, headers: [.authorization: "Bearer \(token)"], to: "internal/v2/accounts/disable", beforeSend: { request in
                    try request.content.encode(input)
                })
                    #expect(response.status == .ok)
                    #expect(response.headers[.cacheControl] == "no-store")
                    #expect(response.headers[.pragma] == "no-cache")
                    var decoded: V2AccountDisableHTTPResponse?
                    decoded = try await response.content.decode(V2AccountDisableHTTPResponse.self)
                    #expect(decoded?.operationID == input.operationID)
                    #expect(decoded?.outcome == kind)
                    #expect(decoded?.disabledAtMilliseconds == expected)
                }
            }
            #expect(await service.receivedCommand()?.operationID == input.operationID)
            try await app.shutdown()
        } catch {
            try? await app.shutdown()
            throw error
        }
    }

    @Test("account disable requires its dedicated credential and returns an audited no-store result")
    func authorizedDisable() async throws {
        let app = try await Application(.testing)
        defer { Task { try? await app.shutdown() } }
        let token = Data(repeating: 14, count: 32).base64EncodedString()
        let service = AccountDisableRouteService()
        V2VaporAccountDisableOperatorRoutes(
            authenticator: try .init(base64EncodedBearerToken: token), service: service
        ).register(on: app)
        let input = V2AccountDisableHTTPRequest(
            operationID: UUID(uuidString: "00000000-0000-0000-0000-000000000981")!,
            userID: "00000000-0000-0000-0000-000000000982", reason: .credentialCompromise
        )

        try await app.testing { client in
            let response = try await client.send(.post, headers: [.authorization: "Bearer \(token)"], to: "internal/v2/accounts/disable", beforeSend: { request in
            try request.content.encode(input)
        })
            #expect(response.status == .ok)
            #expect(response.headers[.cacheControl] == "no-store")
            #expect(response.headers[.pragma] == "no-cache")
            var decoded: V2AccountDisableHTTPResponse?
            decoded = try await response.content.decode(V2AccountDisableHTTPResponse.self)
            #expect(decoded?.operationID == input.operationID)
            #expect(decoded?.outcome == "disabled")
            #expect(decoded?.disabledAtMilliseconds == 1_750_000_000_000)
        }
        let command = try #require(await service.receivedCommand())
        #expect(command.userID.rawValue == input.userID)
        #expect(command.operationID == input.operationID)
        #expect(command.reason == .credentialCompromise)
    }

    @Test("account disable refuses unauthenticated and malformed requests before calling the service")
    func rejectsUnauthenticatedOrMalformedRequest() async throws {
        let app = try await Application(.testing)
        defer { Task { try? await app.shutdown() } }
        let token = Data(repeating: 15, count: 32).base64EncodedString()
        let service = AccountDisableRouteService()
        V2VaporAccountDisableOperatorRoutes(
            authenticator: try .init(base64EncodedBearerToken: token), service: service
        ).register(on: app)
        let valid = V2AccountDisableHTTPRequest(operationID: UUID(), userID: "00000000-0000-0000-0000-000000000983", reason: .userRequested)
        try await app.testing { client in
            let response = try await client.send(.post, to: "internal/v2/accounts/disable", beforeSend: { request in
            try request.content.encode(valid)
        })
            #expect(response.status == .unauthorized)
        }
        let malformed = V2AccountDisableHTTPRequest(operationID: UUID(), userID: "not-a-uuid", reason: .userRequested)
        try await app.testing { client in
            let response = try await client.send(.post, headers: [.authorization: "Bearer \(token)"], to: "internal/v2/accounts/disable", beforeSend: { request in
            try request.content.encode(malformed)
        })
            #expect(response.status == .badRequest)
        }
        #expect(await service.receivedCommand() == nil)
    }
}

private actor AccountDisableRouteService: V2AccountDisabling {
    private var command: V2AccountDisableCommand?
    private var outcome: V2AccountDisableOutcome = .disabled(disabledAt: Date(timeIntervalSince1970: 1_750_000_000))

    private var failure: V2AccountDisableError?

    func setOutcome(_ outcome: V2AccountDisableOutcome) { self.outcome = outcome; failure = nil }
    func setFailure(_ error: V2AccountDisableError) { failure = error }

    func disable(_ command: V2AccountDisableCommand) throws -> V2AccountDisableOutcome {
        self.command = command
        if let failure { throw failure }
        return outcome
    }

    func receivedCommand() -> V2AccountDisableCommand? { command }
}
