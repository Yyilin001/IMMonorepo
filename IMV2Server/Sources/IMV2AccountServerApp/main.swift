import Dispatch
import FluentPostgresDriver
import Foundation
import IMV2Core
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
        let localMediaConfiguration = try V2LocalFilesystemMediaRuntimeConfiguration(environment: ProcessRuntimeEnvironment())
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
            let edgeClientRateLimiter = V2PostgresAccountEdgeClientRateLimiter(
                database: database,
                policy: configuration.edgeClientRateLimit,
                key: configuration.edgeClientRateLimitKey
            )
            app.middleware.use(V2AccountEdgeClientRateLimitMiddleware(
                limiter: edgeClientRateLimiter,
                limitedPaths: [
                    "/v2/account-auth/password/register",
                    "/v2/account-auth/password/assertion",
                    "/v2/account-auth/passkeys/assertion-options",
                    "/v2/account-auth/passkeys/assertion",
                    "/v2/device-credentials"
                ]
            ))

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
            var localMediaScanTask: Task<Void, Never>?
            let edgeRateLimitRetentionTask = Task {
                while !Task.isCancelled {
                    do {
                        _ = try await edgeClientRateLimiter.purgeExpired(limit: 1_000)
                    } catch is CancellationError {
                        break
                    } catch {
                        app.logger.error("IM V2 account-edge rate-limit retention failed; retrying")
                    }
                    do {
                        try await Task.sleep(for: .seconds(60))
                    } catch {
                        break
                    }
                }
            }
            if let localMediaConfiguration {
                let provider = try V2LocalFilesystemMediaProvider(
                    rootDirectory: localMediaConfiguration.rootDirectory,
                    targetBaseURL: localMediaConfiguration.publicBaseURL,
                    signingKey: localMediaConfiguration.signingKey
                )
                try await provider.prepare()
                let media = V2MediaService(
                    store: PostgresV2MediaStore(database: database),
                    limits: try V2MediaUploadLimits(maximumBytes: localMediaConfiguration.maximumBytes)
                )
                let uploadProviderSessions = try V2MediaUploadProviderSessionService(
                    store: PostgresV2MediaUploadSessionStore(database: database),
                    provider: provider
                )
                let downloadProviderSessions = try V2MediaProviderSessionService(
                    store: PostgresV2MediaDownloadSessionStore(database: database),
                    provider: provider
                )
                V2VaporMediaUploadRoutes(
                    authenticator: authenticator,
                    handler: .init(edge: .init(media: media, providerSessions: uploadProviderSessions))
                ).register(on: app)
                V2VaporMediaEdgeRoutes(
                    authenticator: authenticator,
                    handler: .init(edge: .init(media: media, providerSessions: downloadProviderSessions))
                ).register(on: app)
                try V2VaporLocalFilesystemMediaRoutes(
                    provider: provider,
                    publicBaseURL: localMediaConfiguration.publicBaseURL,
                    maximumUploadBytes: localMediaConfiguration.maximumBytes
                ).register(on: app)

                let scanner = try V2MediaScanWorker(
                    store: PostgresV2MediaScanStore(database: database),
                    provider: V2LocalEICARMediaScanner(provider: provider)
                )
                let purger = try V2MediaPurgeWorker(
                    store: PostgresV2MediaPurgeStore(database: database),
                    provider: provider
                )
                let logger = app.logger
                localMediaScanTask = Task {
                    while !Task.isCancelled {
                        do {
                            async let scanReport = scanner.runOnce(limit: 16)
                            async let purgeReport = purger.runOnce(limit: 16)
                            _ = try await (scanReport, purgeReport)
                        } catch is CancellationError {
                            break
                        } catch {
                            // This local scanner is deliberately diagnostic
                            // only; never include IDs, paths, or bytes here.
                            logger.error("IM V2 local media maintenance worker failed; retrying")
                        }
                        do {
                            try await Task.sleep(for: .milliseconds(200))
                        } catch is CancellationError {
                            break
                        } catch {
                            break
                        }
                    }
                }
                app.logger.notice("IM V2 local filesystem media edge enabled")
            }
            V2VaporDeviceCredentialRoutes(assertionVerifier: assertionIssuer, issuer: credentials).register(on: app)
            V2VaporPushEndpointRoutes(
                authenticator: authenticator,
                store: PostgresV2PushDeviceEndpointStore(
                    database: database,
                    envelopeKey: configuration.pushEndpointEnvelopeKey
                )
            ).register(on: app)
            V2VaporDeviceSessionRoutes(
                authenticator: authenticator,
                sessions: V2PostgresDeviceSessionService(database: database)
            ).register(on: app)
            V2VaporPublicIdentityRoutes(
                authenticator: authenticator,
                directory: V2PostgresPublicIdentityDirectory(
                    database: database,
                    policy: configuration.publicIdentityLookupRateLimit
                )
            ).register(on: app)
            V2VaporProfileViewRoutes(
                authenticator: authenticator,
                profiles: .init(store: PostgresV2ProfileViewStore(database: database))
            ).register(on: app)
            let profileUpdateStore = PostgresV2ProfileUpdateStore(database: database)
            V2VaporProfileUpdateRoutes(
                authenticator: authenticator,
                profiles: .init(store: profileUpdateStore, reader: profileUpdateStore)
            ).register(on: app)
            V2VaporProfilePresentationRoutes(
                authenticator: authenticator,
                presentations: PostgresV2ProfilePresentationStore(database: database)
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
            localMediaScanTask?.cancel()
            edgeRateLimitRetentionTask.cancel()
            if let localMediaScanTask {
                await localMediaScanTask.value
            }
            await edgeRateLimitRetentionTask.value
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
