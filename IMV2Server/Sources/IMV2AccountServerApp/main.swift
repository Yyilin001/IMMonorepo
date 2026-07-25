import Dispatch
import FluentPostgresDriver
import Foundation
import IMV2Server
import IMV2ServerHTTP
import Vapor
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

@main
enum IMV2AccountServerApp {
    static func main() async throws {
        let configuration = try V2AccountRuntimeConfiguration(environment: ProcessRuntimeEnvironment())
        let app = try await Application.make(.production)
        do {
            // Keep the password fallback cost explicit. The dummy verifier in
            // the runtime configuration must be generated at this same cost.
            app.passwords.use(.bcrypt(cost: 12))
            app.databases.use(try .postgres(url: configuration.databaseURL), as: .psql)
            let database = app.db(.psql)
            try await V2SchemaReadiness.verify(database: database)
            app.http.server.configuration.hostname = configuration.listener.host
            app.http.server.configuration.port = configuration.listener.port
            app.middleware.use(V2AccountEdgeAuthenticationMiddleware(secret: configuration.edgeAuthorizationSecret))

            let assertionIssuer = try V2HMACAccountAssertionIssuer(rawKey: configuration.accountAssertionKey)
            let credentials = try V2PostgresDeviceCredentialService(
                database: database,
                tokenHMACKey: configuration.accessTokenKey,
                replayEnvelopeKey: configuration.replayEnvelopeKey
            )
            let authenticator = V2PostgresGatewayAuthenticator(
                database: database,
                tokenKey: configuration.accessTokenKey
            )
            V2VaporDeviceCredentialRoutes(assertionVerifier: assertionIssuer, issuer: credentials).register(on: app)
            V2VaporPushEndpointRoutes(
                authenticator: authenticator,
                store: PostgresV2PushDeviceEndpointStore(
                    database: database,
                    envelopeKey: configuration.pushEndpointEnvelopeKey
                )
            ).register(on: app)
            V2VaporPublicIdentityRoutes(
                authenticator: authenticator,
                directory: V2PostgresPublicIdentityDirectory(
                    database: database,
                    policy: configuration.publicIdentityLookupRateLimit
                )
            ).register(on: app)
            V2PasswordAccountRoutes(
                store: .init(database: database),
                assertionIssuer: assertionIssuer,
                dummyPasswordHash: configuration.dummyPasswordHash,
                loginAttemptLimiter: V2PostgresPasswordLoginAttemptLimiter(
                    database: database,
                    policy: configuration.passwordLoginRateLimit
                )
            ).register(on: app)
            try await app.startup()
            app.logger.notice("IM V2 account service bound", metadata: ["host": "\(configuration.listener.host)", "port": "\(configuration.listener.port)"])
            await TerminationSignal.wait()
            try await app.asyncShutdown()
        } catch {
            try? await app.asyncShutdown()
            throw error
        }
    }
}

private struct ProcessRuntimeEnvironment: V2RuntimeEnvironment {
    func value(for key: String) -> String? { ProcessInfo.processInfo.environment[key] }
}

private enum TerminationSignal {
    static func wait() async {
        await withCheckedContinuation { continuation in
            signal(SIGTERM, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
            source.setEventHandler {
                source.cancel()
                continuation.resume()
            }
            source.resume()
        }
    }
}
