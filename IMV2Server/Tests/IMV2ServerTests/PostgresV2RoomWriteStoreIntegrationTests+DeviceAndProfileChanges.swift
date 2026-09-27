import Crypto
import FluentKit
import FluentPostgresDriver
import Foundation
import HTTPTypes
#if os(macOS)
import Darwin
#endif
import IMV2Core
import IMV2ServerHTTP
import PostgresNIO
@testable import IMV2Server
import SQLKit
import Synchronization
import Testing
import Vapor
import VaporTesting


extension PostgresV2RoomWriteStoreIntegrationTests {
    @Test("registration cancellation serializes before, after and concurrently with issuance", arguments: ["before", "after", "race"])
    func registrationCancellationOrdering(order: String) async throws {
        guard let databaseURL = Environment.get("IMV2_POSTGRES_TEST_DATABASE_URL"),
              Environment.get("IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE") == "1" else { return }
        let resources = makeV2DatabaseTestResources()
        do {
            resources.databases.use(try .postgres(url: databaseURL, maxConnectionsPerEventLoop: 2), as: .psql, isDefault: true)
            let sql = try #require(resources.database(.psql) as? any SQLDatabase)
            try await installSchema(on: sql)
            try await V2SchemaReadiness.verify(database: resources.database(.psql))
            let start = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
            let key = try V2AccessTokenHMACKey(rawBytes: Data(repeating: 0x61, count: 32))
            let issuer = try V2PostgresDeviceCredentialService(database: resources.database(.psql), tokenHMACKey: key,
                replayEnvelopeKey: .init(rawBytes: Data(repeating: 0x62, count: 32)), now: { start })
            let cancellation = try V2DeviceRegistrationCancellation(deviceID: DeviceID(UUID().uuidString), operationID: UUID(),
                proof: .generate(), issueBeforeMilliseconds: Int64(start.timeIntervalSince1970 * 1_000) + 60_000)
            let request = try V2CancellableDeviceRegistration(registration: .init(userID: UserID(UUID().uuidString),
                deviceID: cancellation.deviceID, operationID: cancellation.operationID), cancellation: cancellation)
            let canceller = V2PostgresDeviceRegistrationCancellationService(database: resources.database(.psql), now: { start })
            let result: V2DeviceRegistrationOutcome
            if order == "before" {
                #expect(try await canceller.cancel(cancellation) == .applied)
                result = try await issuer.register(request)
                #expect(result == .deviceUnavailable)
            } else if order == "after" {
                // The client need not receive or decode this committed result.
                result = try await issuer.register(request)
                #expect(try await canceller.cancel(cancellation) == .applied)
            } else {
                async let issue = issuer.register(request)
                async let cancel = canceller.cancel(cancellation)
                let (issued, cancelled) = try await (issue, cancel)
                result = issued
                #expect(cancelled == .applied)
            }
            #expect(try await canceller.cancel(cancellation) == .idempotent)
            #expect(try await issuer.register(request) == .deviceUnavailable)
            if case .issued(let credentials) = result {
                await #expect(throws: V2GatewayAuthenticationError.unauthenticated) {
                    _ = try await V2PostgresGatewayAuthenticator(database: resources.database(.psql), tokenKey: key, now: { start })
                        .authenticateSession(accessToken: credentials.accessToken, deviceID: credentials.deviceID)
                }
                #expect(try await count("im_v2.device_revocation_events", on: sql) == 1)
            } else {
                #expect(result == .deviceUnavailable)
                #expect(try await count("im_v2.auth_devices", on: sql) == 0)
            }
            #expect(try await count("im_v2.device_access_tokens WHERE revoked_at IS NULL", on: sql) == 0)
            #expect(try await count("im_v2.device_refresh_sessions WHERE revoked_at IS NULL", on: sql) == 0)
            #expect(try await count("im_v2.device_registration_cancellations WHERE cancelled_at IS NOT NULL", on: sql) == 1)
            try await sql.raw("DROP SCHEMA im_v2 CASCADE").run()
            try await resources.shutdown()
        } catch { try? await resources.shutdown(); throw error }
    }

    @Test("registration cancellation proof isolates identity, survives issue deadline, and rolls back with revocation")
    func registrationCancellationIsolationAndRollback() async throws {
        guard let databaseURL = Environment.get("IMV2_POSTGRES_TEST_DATABASE_URL"),
              Environment.get("IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE") == "1" else { return }
        let resources = makeV2DatabaseTestResources()
        do {
            resources.databases.use(try .postgres(url: databaseURL, maxConnectionsPerEventLoop: 2), as: .psql, isDefault: true)
            let sql = try #require(resources.database(.psql) as? any SQLDatabase)
            try await installSchema(on: sql)
            let start = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
            let issuer = try V2PostgresDeviceCredentialService(database: resources.database(.psql), tokenHMACKey: .init(rawBytes: Data(repeating: 0x63, count: 32)),
                replayEnvelopeKey: .init(rawBytes: Data(repeating: 0x64, count: 32)), maximumSessionLifetime: 120, now: { start })
            let cancellation = try V2DeviceRegistrationCancellation(deviceID: DeviceID(UUID().uuidString), operationID: UUID(),
                proof: .generate(), issueBeforeMilliseconds: Int64(start.timeIntervalSince1970 * 1_000) + 60_000)
            let user = try UserID(UUID().uuidString)
            let trusted = V2TrustedDeviceRegistration(userID: user, deviceID: cancellation.deviceID, operationID: cancellation.operationID)
            let request = try V2CancellableDeviceRegistration(registration: trusted, cancellation: cancellation)
            guard case .issued(let issued) = try await issuer.register(request) else { Issue.record("expected issuance"); return }
            #expect(try await issuer.register(request) == .idempotent(issued))
            let canceller = V2PostgresDeviceRegistrationCancellationService(database: resources.database(.psql), now: { start })
            let altered = try [
                V2DeviceRegistrationCancellation(deviceID: cancellation.deviceID, operationID: cancellation.operationID, proof: .generate(), issueBeforeMilliseconds: cancellation.issueBeforeMilliseconds),
                V2DeviceRegistrationCancellation(deviceID: cancellation.deviceID, operationID: UUID(), proof: cancellation.proof, issueBeforeMilliseconds: cancellation.issueBeforeMilliseconds),
                V2DeviceRegistrationCancellation(deviceID: DeviceID(UUID().uuidString), operationID: cancellation.operationID, proof: cancellation.proof, issueBeforeMilliseconds: cancellation.issueBeforeMilliseconds),
                V2DeviceRegistrationCancellation(deviceID: cancellation.deviceID, operationID: cancellation.operationID, proof: cancellation.proof, issueBeforeMilliseconds: cancellation.issueBeforeMilliseconds + 1_000)
            ]
            for changed in altered { #expect(try await canceller.cancel(changed) == .applied) }
            #expect(try await count("im_v2.auth_devices WHERE revoked_at IS NULL", on: sql) == 1)
            #expect(try await issuer.register(request) == .idempotent(issued))
            let unknownProof = try V2DeviceRegistrationCancellation(deviceID: cancellation.deviceID, operationID: cancellation.operationID,
                proof: .generate(), issueBeforeMilliseconds: cancellation.issueBeforeMilliseconds)
            #expect(try await issuer.register(V2CancellableDeviceRegistration(registration: trusted, cancellation: unknownProof)) == .idempotencyConflict)
            let stranger = V2TrustedDeviceRegistration(userID: try UserID(UUID().uuidString), deviceID: cancellation.deviceID, operationID: cancellation.operationID)
            #expect(try await issuer.register(V2CancellableDeviceRegistration(registration: stranger, cancellation: cancellation)) == .idempotencyConflict)
            let device = try #require(UUID(uuidString: cancellation.deviceID.rawValue))
            try await sql.raw("INSERT INTO im_v2.push_device_endpoints(device_id,provider,environment,endpoint_generation,encrypted_token,updated_at) VALUES (\(bind: device),'apns','development',\(bind: UUID()),'synthetic-token',\(bind: start))").run()
            try await sql.raw("CREATE FUNCTION im_v2.test_cancel_rollback() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'synthetic cancellation rollback'; END $$").run()
            try await sql.raw("CREATE TRIGGER test_cancel_rollback AFTER INSERT ON im_v2.device_revocation_events FOR EACH ROW EXECUTE FUNCTION im_v2.test_cancel_rollback()").run()
            let late = V2PostgresDeviceRegistrationCancellationService(database: resources.database(.psql), now: { start.addingTimeInterval(90) })
            await #expect(throws: (any Error).self) { try await late.cancel(cancellation) }
            #expect(try await count("im_v2.device_registration_cancellations WHERE user_id IS NOT NULL AND cancelled_at IS NOT NULL", on: sql) == 0)
            #expect(try await count("im_v2.device_access_tokens WHERE revoked_at IS NULL", on: sql) == 1)
            #expect(try await count("im_v2.device_refresh_sessions WHERE revoked_at IS NULL", on: sql) == 1)
            #expect(try await count("im_v2.push_device_endpoints WHERE disabled_at IS NULL", on: sql) == 1)
            try await sql.raw("DROP TRIGGER test_cancel_rollback ON im_v2.device_revocation_events").run()
            #expect(try await late.cancel(cancellation) == .applied)
            #expect(try await late.cancel(cancellation) == .idempotent)
            #expect(try await count("im_v2.push_device_endpoints WHERE disabled_at IS NOT NULL", on: sql) == 1)
            #expect(try await count("im_v2.device_revocation_events", on: sql) == 1)
            let expired = try V2DeviceRegistrationCancellation(deviceID: DeviceID(UUID().uuidString), operationID: UUID(), proof: .generate(), issueBeforeMilliseconds: cancellation.issueBeforeMilliseconds)
            #expect(try await late.cancel(expired) == .expired)
            let expiredRequest = try V2CancellableDeviceRegistration(registration: .init(userID: user, deviceID: expired.deviceID, operationID: expired.operationID), cancellation: expired)
            let lateIssuer = try V2PostgresDeviceCredentialService(database: resources.database(.psql), tokenHMACKey: .init(rawBytes: Data(repeating: 0x63, count: 32)),
                replayEnvelopeKey: .init(rawBytes: Data(repeating: 0x64, count: 32)), now: { start.addingTimeInterval(90) })
            #expect(try await lateIssuer.register(expiredRequest) == .deviceUnavailable)
            #expect(try await count("im_v2.device_registration_cancellations", on: sql) == 5)
            try await sql.raw("DROP SCHEMA im_v2 CASCADE").run()
            try await resources.shutdown()
        } catch { try? await resources.shutdown(); throw error }
    }

    @Test("cancellation authority and issued credentials share the same commit")
    func registrationCancellationIssuanceRollback() async throws {
        guard let databaseURL = Environment.get("IMV2_POSTGRES_TEST_DATABASE_URL"),
              Environment.get("IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE") == "1" else { return }
        let resources = makeV2DatabaseTestResources()
        do {
            resources.databases.use(try .postgres(url: databaseURL, maxConnectionsPerEventLoop: 2), as: .psql, isDefault: true)
            let sql = try #require(resources.database(.psql) as? any SQLDatabase)
            try await installSchema(on: sql)
            let start = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
            let issuer = try V2PostgresDeviceCredentialService(database: resources.database(.psql), tokenHMACKey: .init(rawBytes: Data(repeating: 0x65, count: 32)),
                replayEnvelopeKey: .init(rawBytes: Data(repeating: 0x66, count: 32)), now: { start })
            let cancellation = try V2DeviceRegistrationCancellation(deviceID: DeviceID(UUID().uuidString), operationID: UUID(),
                proof: .generate(), issueBeforeMilliseconds: Int64(start.timeIntervalSince1970 * 1_000) + 60_000)
            let request = try V2CancellableDeviceRegistration(registration: .init(userID: UserID(UUID().uuidString),
                deviceID: cancellation.deviceID, operationID: cancellation.operationID), cancellation: cancellation)
            try await sql.raw("CREATE FUNCTION im_v2.test_cancel_binding_rollback() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'synthetic binding rollback'; END $$").run()
            try await sql.raw("CREATE TRIGGER test_cancel_binding_rollback AFTER INSERT ON im_v2.device_registration_cancellations FOR EACH ROW EXECUTE FUNCTION im_v2.test_cancel_binding_rollback()").run()
            await #expect(throws: (any Error).self) { try await issuer.register(request) }
            for table in ["auth_devices", "device_access_tokens", "device_refresh_sessions", "device_credential_operations", "device_revocation_capabilities", "device_registration_cancellations", "device_registration_rate_limits"] {
                #expect(try await count("im_v2." + table, on: sql) == 0)
            }
            try await sql.raw("DROP TRIGGER test_cancel_binding_rollback ON im_v2.device_registration_cancellations").run()
            guard case .issued = try await issuer.register(request) else { Issue.record("expected safe retry"); return }
            #expect(try await count("im_v2.device_registration_cancellations WHERE user_id IS NOT NULL", on: sql) == 1)
            try await V2SchemaReadiness.verify(database: resources.database(.psql))
            try await sql.raw("DROP INDEX im_v2.registration_cancellation_issued_device_idx").run()
            await #expect(throws: V2SchemaReadinessError.unavailableTable("im_v2.device_registration_cancellations[proof-bound]")) {
                try await V2SchemaReadiness.verify(database: resources.database(.psql))
            }
            try await sql.raw("CREATE UNIQUE INDEX registration_cancellation_issued_device_idx ON im_v2.device_registration_cancellations(device_id) WHERE user_id IS NOT NULL").run()
            try await sql.raw("ALTER TABLE im_v2.device_registration_cancellations DROP CONSTRAINT registration_cancellation_binding").run()
            try await sql.raw("ALTER TABLE im_v2.device_registration_cancellations ADD CONSTRAINT registration_cancellation_binding CHECK (true)").run()
            await #expect(throws: V2SchemaReadinessError.unavailableTable("im_v2.device_registration_cancellations[proof-bound]")) {
                try await V2SchemaReadiness.verify(database: resources.database(.psql))
            }
            try await sql.raw("DROP SCHEMA im_v2 CASCADE").run()
            try await resources.shutdown()
        } catch { try? await resources.shutdown(); throw error }
    }

    @Test("revoke-only capability survives rotation, isolates sessions and commits atomically")
    func deviceRevocationCapabilityIsolation() async throws {
        guard let databaseURL = Environment.get("IMV2_POSTGRES_TEST_DATABASE_URL"),
              Environment.get("IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE") == "1" else { return }
        let resources = makeV2DatabaseTestResources()
        let app = try await Application(.testing)
        do {
            resources.databases.use(try .postgres(url: databaseURL, maxConnectionsPerEventLoop: 2), as: .psql, isDefault: true)
            let sql = try #require(resources.database(.psql) as? any SQLDatabase)
            guard (try await sql.raw("SELECT to_regnamespace('im_v2') IS NOT NULL AS exists").first(decoding: ExistsRow.self))?.exists == false else { throw TestConfigurationError.schemaAlreadyExists }
            try await installSchema(on: sql)
            try await V2SchemaReadiness.verify(database: resources.database(.psql))
            let start = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
            let key = try V2AccessTokenHMACKey(rawBytes: Data(repeating: 0x73, count: 32))
            let replayKey = try V2CredentialReplayEnvelopeKey(rawBytes: Data(repeating: 0x74, count: 32))
            let issuer = try V2PostgresDeviceCredentialService(database: resources.database(.psql), tokenHMACKey: key,
                replayEnvelopeKey: replayKey, maximumSessionLifetime: 120, now: { start })
            try await sql.raw("CREATE FUNCTION im_v2.test_abort_complete_credential_issue() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'synthetic issue rollback'; END $$").run()
            try await sql.raw("CREATE TRIGGER test_abort_complete_credential_issue AFTER INSERT ON im_v2.device_credential_operations FOR EACH ROW EXECUTE FUNCTION im_v2.test_abort_complete_credential_issue()").run()
            await #expect(throws: (any Error).self) {
                try await issuer.register(.init(userID: .init(uuid: UUID()), deviceID: .init(uuid: UUID()), operationID: UUID()))
            }
            for table in ["auth_devices", "device_revocation_capabilities", "device_refresh_sessions", "device_access_tokens", "device_credential_operations"] {
                #expect(try await count("im_v2." + table, on: sql) == 0)
            }
            try await sql.raw("DROP TRIGGER test_abort_complete_credential_issue ON im_v2.device_credential_operations").run()
            let user = UserID(uuid: UUID()), oldDevice = DeviceID(uuid: UUID()), newDevice = DeviceID(uuid: UUID())
            let registrationOperation = UUID()
            guard case .issued(let old) = try await issuer.register(.init(userID: user, deviceID: oldDevice, operationID: registrationOperation)),
                  case .issued(let new) = try await issuer.register(.init(userID: user, deviceID: newDevice, operationID: UUID()))
            else { throw V2DeviceCredentialServiceError.unavailable }
            let capability = V2IssuedDeviceRevocationCapability(credential: old.revocationCredential, expiresAt: old.revocationCredentialExpiresAt)
            let newCapability = V2IssuedDeviceRevocationCapability(credential: new.revocationCredential, expiresAt: new.revocationCredentialExpiresAt)
            #expect(capability.expiresAt == start.addingTimeInterval(720))
            #expect(capability.credential != newCapability.credential)
            guard case .idempotent(let replayed) = try await issuer.register(.init(userID: user, deviceID: oldDevice, operationID: registrationOperation)) else { throw V2DeviceCredentialServiceError.unavailable }
            let completeReplay = replayed == old
            #expect(completeReplay)
            let mismatchedProofRejected = try await issuer.refresh(.init(userID: user, deviceID: oldDevice,
                refreshCredential: old.refreshCredential, revocationCredential: new.revocationCredential, operationID: UUID())) == .terminalRejection
            #expect(mismatchedProofRejected)

            let oldUUID = try #require(UUID(uuidString: oldDevice.rawValue))
            let newUUID = try #require(UUID(uuidString: newDevice.rawValue))
            // SQL never receives the plaintext credential, including assertions.
            #expect(try await count("im_v2.device_revocation_capabilities WHERE length(credential_digest) = 64", on: sql) == 2)
            let gateway = V2PostgresGatewayAuthenticator(database: resources.database(.psql), tokenKey: key, now: { start })
            await #expect(throws: V2GatewayAuthenticationError.unauthenticated) {
                try await gateway.authenticateSession(accessToken: capability.credential.rawValue, deviceID: oldDevice)
            }
            let deniedRefresh = try await issuer.refresh(.init(userID: user, deviceID: oldDevice,
                refreshCredential: capability.credential.rawValue, revocationCredential: capability.credential, operationID: UUID())) == .terminalRejection
            #expect(deniedRefresh)
            _ = try await gateway.authenticateSession(accessToken: old.accessToken, deviceID: oldDevice)
            guard case .rotated(let rotated) = try await issuer.refresh(.init(userID: user, deviceID: oldDevice,
                refreshCredential: old.refreshCredential, revocationCredential: old.revocationCredential, operationID: UUID())) else { throw V2DeviceCredentialServiceError.unavailable }
            #expect(rotated.revocationCredential == old.revocationCredential)
            #expect(rotated.revocationCredentialExpiresAt == old.revocationCredentialExpiresAt)
            let service = V2PostgresDeviceSessionService(database: resources.database(.psql), now: { start.addingTimeInterval(1) })
            let proof = Data(repeating: 0x42, count: 32).base64EncodedString()
            app.middleware.use(V2AccountEdgeAuthenticationMiddleware(secret: try .init(base64Encoded: proof)))
            app.middleware.use(V2AccountEdgeClientRateLimitMiddleware(
                limiter: V2PostgresAccountEdgeClientRateLimiter(database: resources.database(.psql),
                    policy: try .init(maximumRequests: 4, window: 60),
                    key: try .init(base64Encoded: Data(repeating: 0x43, count: 32).base64EncodedString()), now: { start }),
                limitedPaths: [V2VaporDeviceRevocationCapabilityRoutes.path]))
            V2VaporDeviceRevocationCapabilityRoutes(service: service).register(on: app)
            func http(_ body: Data, expected: HTTPResponse.Status, edge: Bool = true) async throws {
                try await app.testing { client in
                    let response = try await client.send(.post, to: URI(string: V2VaporDeviceRevocationCapabilityRoutes.path), beforeSend: { request in
                    if edge {
                        request.headers[V2AccountEdgeAuthenticationMiddleware.headerName] = proof
                        request.headers[V2AccountEdgeAuthenticationMiddleware.clientAddressHeaderName] = "192.0.2.19"
                    }
                    request.headers.contentType = .json
                    request.body = .init(data: body)
                    })
                    #expect(response.status == expected)
                    if expected != .forbidden {
                        #expect(response.headers[.cacheControl] == "no-store")
                        #expect((try await response.body.data() ?? Data()).isEmpty)
                    }
                    if expected == .tooManyRequests { #expect(response.headers[.retryAfter] == "60") }
                }
            }
            let httpOperation = UUID()
            let httpBody = try JSONEncoder().encode(V2DeviceRevocationCapabilityHTTPRequest(credential: capability.credential, operationID: httpOperation))
            try await http(httpBody, expected: .forbidden, edge: false)
            let forgedTarget = try JSONSerialization.data(withJSONObject: ["credential": capability.credential.rawValue, "operationID": UUID().uuidString, "deviceID": newDevice.rawValue])
            try await http(forgedTarget, expected: .badRequest)
            let unknownBody = try JSONEncoder().encode(V2DeviceRevocationCapabilityHTTPRequest(credential: .generate(), operationID: UUID()))
            try await http(unknownBody, expected: .unauthorized)
            #expect(try await service.redeem(.generate(), operationID: UUID()) == .invalidCredential)
            // Reusing a device ID after changing its session incarnation cannot
            // make a retained capability target the replacement session.
            try await sql.raw("UPDATE im_v2.auth_devices SET created_at = created_at + interval '1 second' WHERE device_id = \(bind: oldUUID)").run()
            #expect(try await service.redeem(capability.credential, operationID: UUID()) == .invalidCredential)
            try await sql.raw("UPDATE im_v2.auth_devices SET created_at = created_at - interval '1 second' WHERE device_id = \(bind: oldUUID)").run()
            try await sql.raw("UPDATE im_v2.auth_devices SET session_expires_at = session_expires_at + interval '1 second' WHERE device_id = \(bind: oldUUID)").run()
            #expect(try await service.redeem(capability.credential, operationID: UUID()) == .invalidCredential)
            try await sql.raw("UPDATE im_v2.auth_devices SET session_expires_at = session_expires_at - interval '1 second' WHERE device_id = \(bind: oldUUID)").run()
            try await sql.raw("INSERT INTO im_v2.push_device_endpoints(device_id, provider, environment, endpoint_generation, encrypted_token, updated_at) VALUES (\(bind: oldUUID), 'apns', 'development', \(bind: UUID()), 'synthetic-sealed-token', \(bind: start))").run()
            try await sql.raw("CREATE FUNCTION im_v2.test_reject_capability_commit() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'synthetic rollback'; END $$").run()
            try await sql.raw("CREATE TRIGGER test_reject_capability_commit AFTER INSERT ON im_v2.device_session_operations FOR EACH ROW EXECUTE FUNCTION im_v2.test_reject_capability_commit()").run()
            try await http(httpBody, expected: .serviceUnavailable)
            #expect(try await count("im_v2.auth_devices WHERE revoked_at IS NOT NULL", on: sql) == 0)
            #expect(try await count("im_v2.device_access_tokens WHERE revoked_at IS NOT NULL", on: sql) == 0)
            #expect(try await count("im_v2.device_refresh_sessions WHERE revoked_at IS NOT NULL", on: sql) == 0)
            #expect(try await count("im_v2.push_device_endpoints WHERE disabled_at IS NOT NULL", on: sql) == 0)
            #expect(try await count("im_v2.device_revocation_events", on: sql) == 0)
            try await sql.raw("DROP TRIGGER test_reject_capability_commit ON im_v2.device_session_operations").run()
            let operation = UUID()
            let outcomes = try await withThrowingTaskGroup(of: V2DeviceRevocationCapabilityOutcome.self) { group in
                for _ in 0..<10 { group.addTask { try await service.redeem(capability.credential, operationID: operation) } }
                var values: [V2DeviceRevocationCapabilityOutcome] = []
                for try await value in group { values.append(value) }
                return values
            }
            #expect(outcomes.filter { $0 == .applied }.count == 1)
            #expect(outcomes.filter { $0 == .idempotent }.count == 9)
            let retryBody = try JSONEncoder().encode(V2DeviceRevocationCapabilityHTTPRequest(credential: capability.credential, operationID: operation))
            try await http(retryBody, expected: .noContent)
            let limitedBody = try JSONEncoder().encode(V2DeviceRevocationCapabilityHTTPRequest(credential: newCapability.credential, operationID: UUID()))
            try await http(limitedBody, expected: .tooManyRequests)

            #expect(try await service.redeem(newCapability.credential, operationID: operation) == .operationConflict)
            _ = try await gateway.authenticateSession(accessToken: new.accessToken, deviceID: newDevice)
            for token in [old.accessToken, rotated.accessToken] {
                await #expect(throws: V2GatewayAuthenticationError.unauthenticated) {
                    try await gateway.authenticateSession(accessToken: token, deviceID: oldDevice)
                }
            }
            #expect(try await count("im_v2.device_revocation_events", on: sql) == 1)
            #expect(try await count("im_v2.device_session_operations", on: sql) == 1)
            #expect(try await count("im_v2.push_device_endpoints WHERE disabled_at IS NOT NULL", on: sql) == 1)
            // Different authentication key does not enter the redemption boundary.
            let rotatedKey = try V2AccessTokenHMACKey(rawBytes: Data(repeating: 0x75, count: 32))
            let rotatedGateway = V2PostgresGatewayAuthenticator(database: resources.database(.psql), tokenKey: rotatedKey, now: { start })
            await #expect(throws: V2GatewayAuthenticationError.unauthenticated) {
                try await rotatedGateway.authenticateSession(accessToken: new.accessToken, deviceID: newDevice)
            }
            let expired = V2PostgresDeviceSessionService(database: resources.database(.psql), now: { capability.expiresAt })
            #expect(try await expired.redeem(newCapability.credential, operationID: UUID()) == .expired)
            #expect(try await expired.redeem(capability.credential, operationID: operation) == .expired)
            #expect(try await count("im_v2.auth_devices WHERE revoked_at IS NULL", on: sql) == 1)
            let purged = try await V2ControlPlaneHousekeepingWorker(
                store: PostgresV2ControlPlaneHousekeepingStore(database: resources.database(.psql)),
                now: { start.addingTimeInterval(700) }
            ).runOnce(limit: 256)
            #expect(purged.purgedExpiredCredentialReplayRows == 3)
            #expect(try await count("im_v2.device_credential_operations", on: sql) == 0)
            #expect(try await count("im_v2.device_revocation_capabilities", on: sql) == 2)
            // The grace period supports server cleanup after ordinary expiry,
            // even when ordinary account authentication has been disabled.
            let userUUID = try #require(UUID(uuidString: user.rawValue))
            try await sql.raw("INSERT INTO im_v2.account_disables(user_id, operation_id, reason, operator_principal, disabled_at) VALUES (\(bind: userUUID), \(bind: UUID()), 'user_requested', 'capability-test', \(bind: start))").run()
            try await sql.raw("UPDATE im_v2.auth_devices SET revoked_at = \(bind: start) WHERE device_id = \(bind: newUUID)").run()
            let grace = V2PostgresDeviceSessionService(database: resources.database(.psql), now: { capability.expiresAt.addingTimeInterval(-1) })
            #expect(try await grace.redeem(newCapability.credential, operationID: UUID()) == .applied)
            #expect(try await count("im_v2.device_revocation_events", on: sql) == 2)
            #expect(try await count("im_v2.device_access_tokens WHERE revoked_at IS NOT NULL", on: sql) == 3)
            #expect(try await count("im_v2.device_refresh_sessions WHERE revoked_at IS NOT NULL", on: sql) == 2)
            // Schema marker alone cannot certify a lost safety constraint.
            try await sql.raw("ALTER TABLE im_v2.device_revocation_capabilities DROP CONSTRAINT device_revocation_capability_expiry").run()
            await #expect(throws: (any Error).self) { try await V2SchemaReadiness.verify(database: resources.database(.psql)) }
            try await sql.raw("DROP SCHEMA im_v2 CASCADE").run()
            try await app.shutdown(); try await resources.shutdown()
        } catch {
            if let sql = resources.database(.psql) as? any SQLDatabase { try? await sql.raw("DROP SCHEMA IF EXISTS im_v2 CASCADE").run() }
            try? await app.shutdown(); try? await resources.shutdown()
            throw error
        }
    }

    @Test("edit and room policy changes serialize authorization at commit", arguments: [
        "freeze", "mute", "moderation-remove", "membership-remove", "permission", "demote"
    ], ["standard-edit-first", "standard-policy-first", "hybrid-edit-first", "hybrid-policy-first"])
    func editPolicyCommitOrdering(restriction: String, schedule: String) async throws {
        guard let databaseURL = Environment.get("IMV2_POSTGRES_TEST_DATABASE_URL"),
              Environment.get("IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE") == "1" else { return }
        let resources = makeV2DatabaseTestResources()
        do {
            // The blocker, both real service transactions, and the observer
            // must each have a connection while the commit order is fenced.
            resources.databases.use(try .postgres(url: databaseURL, maxConnectionsPerEventLoop: 4), as: .psql, isDefault: true)
            let sql = try #require(resources.database(.psql) as? any SQLDatabase)
            guard (try await sql.raw("SELECT to_regnamespace('im_v2') IS NOT NULL AS exists").first(decoding: ExistsRow.self))?.exists == false else { throw TestConfigurationError.schemaAlreadyExists }
            try await installSchema(on: sql)
            let mode: V2GroupCapacityClass = schedule.hasPrefix("hybrid") ? .large : .standard
            let editFirst = schedule.contains("edit-first")
            try await seedRoom(capacityClass: mode, on: sql)
            try await sql.raw("UPDATE im_v2.room_memberships SET role='owner' WHERE user_id=\(bind: memberTwoUUID)").run()
            try await sql.raw("UPDATE im_v2.group_rooms SET owner_user_id=\(bind: memberTwoUUID)").run()
            if restriction == "demote" {
                // Role commands require an initialized positive membership revision.
                try await sql.raw("UPDATE im_v2.rooms SET membership_revision=1 WHERE room_id=\(bind: roomUUID)").run()
                try await sql.raw("UPDATE im_v2.room_memberships SET role='admin' WHERE user_id=\(bind: senderUUID)").run()
                try await sql.raw("INSERT INTO im_v2.group_role_permissions (room_id, role, permission) VALUES (\(bind: roomUUID), 'member', 'invite_members')").run()
            }
            let now = Date(timeIntervalSince1970: 1_750_000_000)
            let profile = try V2CapacityProfile(id: "standard", limits: .init(maxEligibleMembers: 10, maxCommandsPerWindow: 10,    retryAfterSeconds: 3))
            let send = V2SendMessageService(store: PostgresV2RoomWriteStore(database: resources.database(.psql)), capacityProfile: profile, limits: try .init(maxUTF8Bytes: 64), now: { now })
            guard case .accepted(let message) = try await send.send(.init(roomID: roomID, actorUserID: senderID, clientMessageID: clientMessageID, text: "original")) else { throw V2RoomWriteStoreError.corruptPersistenceState }
            let edit = V2MessageEditService(store: PostgresV2MessageEditStore(database: resources.database(.psql)), capacityProfile: profile, maximumTextUTF8Bytes: 64, now: { now.addingTimeInterval(1) })
            let request = V2AuthenticatedMessageEdit(roomID: roomID, actorUserID: senderID, operationID: .init(uuid: UUID()), messageID: message.messageID, expectedMessageRevision: 1, text: "committed edit")
            let owner = UserID(uuid: memberTwoUUID)
            let mutation = UUID()
            let expectedError: V2RoomWriteStoreError = restriction == "freeze" ? .roomFrozen : restriction == "mute" ? .actorMuted : .actorNotEligible
            @Sendable func run(_ editing: Bool) async throws -> String {
                if editing {
                    do {
                        guard case .edited(let value) = try await edit.edit(request) else { throw V2MessageEditStoreError.corruptPersistenceState }
                        #expect(value.messageRevision == 2 && value.roomSequence == 2)
                        return "edited"
                    } catch let error as V2RoomWriteStoreError {
                        #expect(error == expectedError)
                        return "denied"
                    }
                }
                if restriction == "permission" || restriction == "demote" {
                    let controls = V2GroupCapabilitiesService(store: PostgresV2GroupCapabilitiesStore(database: resources.database(.psql)), capacityProfile: profile, now: { now.addingTimeInterval(1) })
                    if restriction == "permission" {
                        guard case .applied = try await controls.setRolePermissions(actorUserID: owner, command: .init(operationID: .init(uuid: mutation), roomID: roomID, role: .member, permissions: [], expectedRevision: 1)) else { throw V2GroupCapabilitiesStoreError.corruptPersistenceState }
                    } else {
                        guard case .applied = try await controls.changeMemberRole(actorUserID: owner, command: .init(operationID: .init(uuid: mutation), roomID: roomID, targetUserID: senderID, role: .member, expectedMembershipRevision: 1)) else { throw V2GroupCapabilitiesStoreError.corruptPersistenceState }
                    }
                } else if restriction == "membership-remove" {
                    let memberships = V2RoomMembershipService(store: PostgresV2RoomMembershipStore(database: resources.database(.psql)), capacityProfile: profile, now: { now.addingTimeInterval(1) })
                    guard case .changed = try await memberships.change(.init(roomID: roomID, actorUserID: owner, operationID: .init(uuid: mutation), targetUserID: senderID, action: .remove, expectedMembershipRevision: 0)) else { throw V2RoomMembershipStoreError.corruptPersistenceState }
                } else {
                    let store = PostgresV2ModerationStore(database: resources.database(.psql))
                    let result: V2ModerationOutcome
                    if restriction == "freeze" {
                        let safety = V2TrustedSafetyModerationService(store: store, safetyActorUserID: owner, capacityProfile: profile, now: { now.addingTimeInterval(1) })
                        result = try await safety.apply(V2TrustedSafetyRoomControl(roomID: roomID, operationID: .init(uuid: mutation), action: .freezeRoom, reasonCode: .init("abuse_spam")))
                    } else {
                        let moderation = V2ModerationService(store: store, capacityProfile: profile, now: { now.addingTimeInterval(1) })
                        result = try await moderation.apply(.init(roomID: roomID, actorUserID: owner, operationID: .init(uuid: mutation), action: restriction == "mute" ? .muteMember : .removeMember, targetUserID: senderID, muteUntil: restriction == "mute" ? now.addingTimeInterval(300) : nil, reasonCode: .init("abuse_spam")))
                    }
                    guard case .applied = result else { throw V2ModerationStoreError.corruptPersistenceState }
                }
                return "policy"
            }
            // Both real services have acquired the room lock before their
            // sequence update reaches this test-only trigger. The advisory
            // gate controls commit order without replacing policy writes.
            try await sql.raw("""
                CREATE FUNCTION im_v2.test_hold_policy_commit() RETURNS trigger LANGUAGE plpgsql AS $$
                BEGIN
                    IF NEW.room_sequence <> OLD.room_sequence THEN
                        PERFORM pg_advisory_xact_lock(731620499);
                    END IF;
                    RETURN NEW;
                END; $$
                """).run()
            try await sql.raw("CREATE TRIGGER test_hold_policy_commit BEFORE UPDATE ON im_v2.rooms FOR EACH ROW EXECUTE FUNCTION im_v2.test_hold_policy_commit()").run()
            let gate = PostgreSQLTransactionGate()
            let blocker = Task {
                try await resources.database(.psql).transaction { transaction in
                    let locked = try #require(transaction as? any SQLDatabase)
                    try await locked.raw("SELECT pg_advisory_xact_lock(731620499)").run()
                    await gate.holdTransaction()
                }
            }
            await gate.waitUntilHeld()
            var first: Task<String, Error>?
            var second: Task<String, Error>?
            do {
                first = Task { try await run(editFirst) }
                try await waitForAdvisoryWaiters(1, on: sql)
                let firstPID = try #require(try await sql.raw("SELECT pid::bigint AS value FROM pg_locks WHERE locktype='advisory' AND NOT granted AND classid=0 AND objid=731620499").first(decoding: CountRow.self)?.value)
                second = Task { try await run(!editFirst) }
                var blocked = false
                for _ in 0..<300 {
                    blocked = try await sql.raw("SELECT EXISTS(SELECT 1 FROM pg_stat_activity WHERE datname=current_database() AND \(bind: firstPID)::integer=ANY(pg_blocking_pids(pid))) AS exists").first(decoding: ExistsRow.self)?.exists == true
                    if blocked { break }
                    try await Task.sleep(for: .milliseconds(10))
                }
                try #require(blocked, "second service must wait for the first service transaction")
                await gate.releaseTransaction()
                try await blocker.value
                #expect(try await first?.value == (editFirst ? "edited" : "policy"))
                #expect(try await second?.value == (editFirst ? "policy" : "denied"))
            } catch {
                first?.cancel(); second?.cancel()
                await gate.releaseTransaction()
                _ = try? await blocker.value
                _ = try? await first?.value
                _ = try? await second?.value
                throw error
            }
            let before = try await directWriteArtifactCounts(sql: sql)
            if editFirst {
                guard case .idempotent(let replay) = try await edit.edit(request) else { throw V2MessageEditStoreError.corruptPersistenceState }
                #expect(replay.messageRevision == 2 && replay.roomSequence == 2)
                #expect(replay.createdAt == now.addingTimeInterval(1))
            } else {
                await #expect(throws: expectedError) { try await edit.edit(request) }
            }
            await #expect(throws: expectedError) {
                try await edit.edit(.init(roomID: roomID, actorUserID: senderID, operationID: .init(uuid: UUID()), messageID: message.messageID, expectedMessageRevision: editFirst ? 2 : 1, text: "denied after policy"))
            }
            #expect(try await directWriteArtifactCounts(sql: sql) == before)
            let persisted = try #require(try await sql.raw("SELECT text_body, content_revision FROM im_v2.messages WHERE message_id=\(bind: message.messageID.uuidValue!)").first(decoding: EditMessageStateRow.self))
            #expect(persisted.text == (editFirst ? "committed edit" : "original"))
            #expect(persisted.revision == (editFirst ? 2 : 1))
            #expect(try await count("im_v2.message_edit_operations", on: sql) == (editFirst ? 1 : 0))
            #expect(try await sql.raw("SELECT COUNT(*) AS value FROM im_v2.room_events WHERE event_type='message.edited'").first(decoding: CountRow.self)?.value == (editFirst ? 1 : 0))
            #expect(try await sql.raw("SELECT room_sequence AS value FROM im_v2.rooms WHERE room_id=\(bind: roomUUID)").first(decoding: CountRow.self)?.value == (editFirst ? 3 : 2))
            try await sql.raw("DROP SCHEMA im_v2 CASCADE").run()
            try await resources.shutdown()
        } catch {
            if let sql = resources.database(.psql) as? any SQLDatabase { try? await sql.raw("DROP SCHEMA IF EXISTS im_v2 CASCADE").run() }
            try? await resources.shutdown(); throw error
        }
    }

    private func mutateAcceptedMessage(database: any Database, room: RoomID, message: MessageID,
        operation: String, operationID: UUID, replay: Bool = false, expectedRevision: UInt64 = 1, text: String = "updated authority") async throws -> EventID {
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        let profile = try forwardImportTestProfile()
        switch operation {
        case "edit":
            let service = V2MessageEditService(store: PostgresV2MessageEditStore(database: database, contentReviewMode: .disabled), capacityProfile: profile, maximumTextUTF8Bytes: 64, now: { now })
            let result = try await service.edit(.init(roomID: room, actorUserID: senderID, operationID: .init(uuid: operationID), messageID: message, expectedMessageRevision: expectedRevision, text: text))
            switch result {
            case .edited(let value): #expect(!replay); return value.eventID
            case .idempotent(let value): #expect(replay); return value.eventID
            default: throw V2MessageEditStoreError.corruptPersistenceState
            }
        case "withdraw":
            let service = V2MessageWithdrawalService(store: PostgresV2MessageWithdrawalStore(database: database), capacityProfile: profile, now: { now })
            let result = try await service.withdraw(.init(roomID: room, actorUserID: senderID, operationID: .init(uuid: operationID), messageID: message, expectedMessageRevision: expectedRevision))
            switch result {
            case .withdrawn(let value): #expect(!replay); return value.eventID
            case .idempotent(let value): #expect(replay); return value.eventID
            default: throw V2MessageWithdrawalStoreError.corruptPersistenceState
            }
        default:
            let service = V2MessageReactionService(store: PostgresV2MessageReactionStore(database: database), capacityProfile: profile, now: { now })
            let result = try await service.change(.init(roomID: room, actorUserID: senderID, operationID: .init(uuid: operationID), messageID: message, reaction: "👍", action: .add))
            switch result {
            case .changed(let value): #expect(!replay); return value.eventID
            case .idempotent(let value): #expect(replay); return value.eventID
            default: throw V2MessageReactionStoreError.corruptPersistenceState
            }
        }
    }

    @Test("profile presentation revisions preserve maximum no-op and reject increment", arguments: ["alias", "nickname"], ["same-one", "change-one", "same-before-max", "change-before-max", "same-max", "change-max"])
    func profileMaximumRevision(_ kind: String, scenario: String) async throws {
        try await withForwardOwnerDatabases(mode: .standard) { database, _, sql, _, _ in
            let now = Date(timeIntervalSince1970: 1_750_000_000)
            let change = scenario.hasPrefix("change")
            let starting: Int64 = scenario.hasSuffix("one") ? 1 : (scenario.hasSuffix("before-max") ? Int64.max-1 : Int64.max)
            let maximum = try #require(V2ProfileRevision(rawValue: UInt64(starting)))
            let exhausted = change && starting == Int64.max
            let target = UserID(uuid: memberTwoUUID), operation = UUID()
            if kind == "alias" {
                try await sql.raw("INSERT INTO im_v2.user_relationships(lower_user_id,higher_user_id,state,requested_by_user_id,updated_at) VALUES (\(bind: senderUUID),\(bind: memberTwoUUID),'accepted',\(bind: senderUUID),\(bind: now))").run()
                try await sql.raw("INSERT INTO im_v2.user_contact_aliases(owner_user_id,target_user_id,remark_name,revision,updated_at) VALUES (\(bind: senderUUID),\(bind: memberTwoUUID),'original',\(bind: starting),\(bind: now))").run()
            } else {
                try await sql.raw("INSERT INTO im_v2.room_member_nicknames(room_id,user_id,nickname,revision,updated_at) VALUES (\(bind: roomUUID),\(bind: senderUUID),'original',\(bind: starting),\(bind: now))").run()
            }
            let store = PostgresV2ProfilePresentationStore(database: database, nicknameCapacityProfile: try forwardImportTestProfile(), now: { now })
            func update(_ name: String, operationID: UUID) async throws -> V2ProfileRevision {
                if kind == "alias" {
                    return try await store.updateContactAlias(ownerUserID: senderID, targetUserID: target, operationID: .init(uuid: operationID), expectedRevision: maximum, remarkName: name).revision
                }
                return try await store.updateOwnGroupNickname(actorUserID: senderID, roomID: roomID, operationID: .init(uuid: operationID), expectedRevision: maximum, nickname: name).revision
            }
            let name = change ? "changed" : "original"
            let resultRevision = try #require(V2ProfileRevision(rawValue: UInt64(exhausted || !change ? starting : starting+1)))
            if exhausted {
                await #expect(throws: V2ProfilePresentationError.corruptPersistenceState) { _ = try await update("changed", operationID: operation) }
            } else {
                #expect(try await update(name, operationID: operation) == resultRevision)
                // A completed no-op still has a valid immutable replay result.
                #expect(try await update(name, operationID: operation) == resultRevision)
            }
            let table = kind == "alias" ? "user_contact_aliases" : "room_member_nicknames"
            let column = kind == "alias" ? "remark_name" : "nickname"
            #expect(try await sql.raw("SELECT \(unsafeRaw: column) AS value FROM im_v2.\(unsafeRaw: table)").first(decoding: StringValueRow.self)?.value == (exhausted ? "original" : name))
            #expect(try await sql.raw("SELECT revision AS value FROM im_v2.\(unsafeRaw: table)").first(decoding: CountRow.self)?.value == resultRevision.signedValue)
            let operations = kind == "alias" ? "user_contact_alias_operations" : "room_member_nickname_operations"
            #expect(try await count("im_v2." + operations, on: sql) == (exhausted ? 0 : 1))
        }
    }

    @Test("Directory name changes preserve exhausted no-ops and reject required revision increments",
          arguments: ["revision", "visibility_revision"])
    func publicIdentityNameRevisionBoundary(column: String) async throws {
        try await withForwardOwnerDatabases(mode: .standard) { database, _, sql, _, _ in
            let now = Date(timeIntervalSince1970: 1_750_000_000)
            let clock = TestSequenceClock([now])
            let directory = V2PostgresPublicIdentityDirectory(database: database,
                policy: try .init(maximumQueries: 10, window: 60), now: { clock.now() })
            let original = try #require(try await directory.profile(for: senderID))
            try await sql.raw("UPDATE im_v2.public_user_profiles SET \(unsafeRaw: column) = \(bind: Int64.max) WHERE user_id = \(bind: senderUUID)").run()
            func snapshot() async throws -> [String] {
                var values: [String] = []
                for table in ["public_user_profiles", "public_profile_update_outbox"] {
                    guard let row = try await sql.raw("SELECT COALESCE(jsonb_agg(to_jsonb(r) ORDER BY to_jsonb(r)::text), '[]'::jsonb)::text AS value FROM im_v2.\(unsafeRaw: table) r").first(decoding: StringValueRow.self) else { throw CancellationError() }
                    values.append(row.value)
                }
                return values
            }
            let before = try await snapshot()
            for _ in 0..<2 {
                await #expect(throws: V2PublicIdentityDirectoryError.unavailable) {
                    try await directory.updateDisplayName(for: senderID, displayName: "Boundary name")
                }
                #expect(try await snapshot() == before)
                clock.set([Date(timeIntervalSince1970: .nan)])
                #expect(try await directory.updateDisplayName(for: senderID, displayName: original.displayName) == original)
                #expect(try await snapshot() == before)
                clock.set([now])
            }
            try await sql.raw("UPDATE im_v2.public_user_profiles SET \(unsafeRaw: column) = \(bind: Int64.max - 1) WHERE user_id = \(bind: senderUUID)").run()
            let updated = try await directory.updateDisplayName(for: senderID, displayName: "Boundary name")
            #expect(updated.displayName == "Boundary name")
            #expect(try await sql.raw("SELECT \(unsafeRaw: column) AS value FROM im_v2.public_user_profiles WHERE user_id = \(bind: senderUUID)").first(decoding: CountRow.self)?.value == Int64.max)
            #expect(try await count("im_v2.public_profile_update_outbox", on: sql) == 1)
            let committed = try await snapshot()
            for date in [Date(timeIntervalSince1970: .nan), now, Date(timeIntervalSince1970: .infinity)] {
                clock.set([date])
                #expect(try await directory.updateDisplayName(for: senderID, displayName: "Boundary name") == updated)
                #expect(try await snapshot() == committed)
            }
        }
    }

    @Test("Concurrent identical directory name changes return the committed identity once")
    func publicIdentityConcurrentNameUpdate() async throws {
        try await withForwardOwnerDatabases(mode: .standard) { database, _, sql, _, _ in
            let now = Date(timeIntervalSince1970: 1_750_000_000)
            let directory = V2PostgresPublicIdentityDirectory(database: database,
                policy: try .init(maximumQueries: 10, window: 60), now: { now })
            let gate = PostgreSQLTransactionGate()
            let holder = Task {
                try await database.transaction { transaction in
                    let held = try #require(transaction as? any SQLDatabase)
                    try await held.raw("SELECT user_id FROM im_v2.public_user_profiles WHERE user_id = \(bind: senderUUID) FOR UPDATE").run()
                    await gate.holdTransaction()
                }
            }
            await gate.waitUntilHeld()
            let tasks = (0..<2).map { _ in
                Task { try await directory.updateDisplayName(for: senderID, displayName: "Concurrent name") }
            }
            do {
                var blocked = false
                for _ in 0..<500 {
                    let waiting = try await sql.raw("SELECT COUNT(*) AS value FROM pg_stat_activity WHERE datname = current_database() AND wait_event_type = 'Lock' AND query LIKE '%public_user_profiles%'").first(decoding: CountRow.self)?.value ?? 0
                    if waiting == 2 { blocked = true; break }
                    try await Task.sleep(for: .milliseconds(10))
                }
                try #require(blocked, "Both real writers must wait on the held profile row")
                await gate.releaseTransaction()
                try await holder.value
                for task in tasks { #expect(try await task.value.displayName == "Concurrent name") }
            } catch {
                for task in tasks { task.cancel() }
                await gate.releaseTransaction()
                _ = await holder.result
                for task in tasks { _ = await task.result }
                throw error
            }
            #expect(try await directory.profile(for: senderID)?.displayName == "Concurrent name")
            #expect(try await count("im_v2.public_profile_update_outbox", on: sql) == 1)
            #expect(try await sql.raw("SELECT COUNT(*) AS value FROM im_v2.public_user_profiles WHERE user_id = \(bind: senderUUID) AND revision = 2 AND visibility_revision = 2").first(decoding: CountRow.self)?.value == 1)
        }
    }

    @Test("Directory profile propagation copies the exact persisted update timestamp", arguments: [0, 1, 2, 3, 4, 5, 6])
    func publicIdentityNameTimestampPrecision(clockIndex: Int) async throws {
        let dates: [Double] = [946_684_800 - 0.00000075, 946_684_800 + 0.00000125, 1_750_000_000 + 0.12345725,
                               1_750_000_000 + 0.99999975, -0.00075, -210_866_803_200, 9_224_318_015_990]
        let now = Date(timeIntervalSince1970: dates[clockIndex])
        try await withForwardOwnerDatabases(mode: .standard) { database, _, sql, _, _ in
            let operation = UUID()
            let directory = V2PostgresPublicIdentityDirectory(database: database,
                policy: try .init(maximumQueries: 10, window: 60), makeUUID: { operation }, now: { now })
            let updated = try await directory.updateDisplayName(for: senderID, displayName: "Precise name")
            #expect(try await directory.updateDisplayName(for: senderID, displayName: "Precise name") == updated)
            #expect(try await sql.raw("SELECT COUNT(*) AS value FROM im_v2.public_profile_update_outbox o JOIN im_v2.public_user_profiles p ON p.user_id = o.source_user_id WHERE o.source_event_id = \(bind: operation) AND o.profile_updated_at = p.updated_at AND o.created_at = p.updated_at AND p.updated_at = \(bind: now) AND o.revision = p.revision AND o.display_name = p.display_name").first(decoding: CountRow.self)?.value == 1)
            #expect(try await count("im_v2.public_profile_update_outbox", on: sql) == 1)
        }
    }

    @Test("Concurrent profile retries serialize ledger reads and preserve payload and revision conflicts",
          arguments: ["changed", "no-op", "changed-invalid-clock", "no-op-invalid-clock", "name-mismatch", "avatar-mismatch", "different-operation"])
    func ownProfileConcurrentReplay(scenario: String) async throws {
        try await withForwardOwnerDatabases(mode: .standard) { database, _, sql, _, _ in
            let now = Date(timeIntervalSince1970: 946_684_800 + 0.00000125)
            let clockReads = Mutex(0)
            let store = PostgresV2ProfileUpdateStore(database: database, now: {
                let index = clockReads.withLock { count in defer { count += 1 }; return count }
                return index > 0 && scenario.hasSuffix("invalid-clock") ? Date(timeIntervalSince1970: .nan) : now
            })
            let before = try await store.currentProfile(for: senderID)
            let noOp = scenario.hasPrefix("no-op")
            let name = noOp ? try #require(before.publicIdentity).displayName : "Concurrent profile"
            let operation = ProfileUpdateOperationID(uuid: UUID())
            let command = try V2ProfileUpdateCommand(actorUserID: senderID, operationID: operation,
                expectedRevision: before.revision, displayName: name, avatar: nil)
            let retry = try V2ProfileUpdateCommand(actorUserID: senderID,
                operationID: scenario == "different-operation" ? .init(uuid: UUID()) : operation,
                expectedRevision: before.revision,
                displayName: scenario == "name-mismatch" ? "Another name" : "  " + name + "  ",
                avatar: scenario == "avatar-mismatch" ? .init(mediaID: .init(uuid: UUID())) : nil)
            let gate = PostgreSQLTransactionGate()
            let holder = Task {
                try await database.transaction { transaction in
                    let held = try #require(transaction as? any SQLDatabase)
                    try await held.raw("SELECT user_id FROM im_v2.public_user_profiles WHERE user_id = \(bind: senderUUID) FOR UPDATE").run()
                    await gate.holdTransaction()
                }
            }
            await gate.waitUntilHeld()
            func waitForWriters(_ expected: Int64) async throws {
                for _ in 0..<500 {
                    let waiting = try await sql.raw("SELECT COUNT(*) AS value FROM pg_stat_activity WHERE datname = current_database() AND wait_event_type = 'Lock' AND query LIKE '%public_user_profiles%'").first(decoding: CountRow.self)?.value ?? 0
                    if waiting == expected { return }
                    try await Task.sleep(for: .milliseconds(10))
                }
                Issue.record("Expected real profile writers to wait on the held row")
                throw CancellationError()
            }
            let first = Task { try await store.update(command) }
            var second: Task<V2ProfileUpdateOutcome, Error>?
            do {
                // Establish the first writer's row-lock position before
                // allowing its concurrent retry to read an empty ledger.
                try await waitForWriters(1)
                second = Task { try await store.update(retry) }
                try await waitForWriters(2)
                await gate.releaseTransaction()
                try await holder.value
                guard case .updated(let updated) = try await first.value else {
                    throw V2ProfileUpdateError.corruptPersistenceState
                }
                let second = try #require(second)
                if scenario.hasSuffix("mismatch") {
                    await #expect(throws: V2ProfileUpdateError.operationPayloadMismatch) { try await second.value }
                } else if scenario == "different-operation" {
                    await #expect(throws: V2ProfileUpdateError.revisionConflict(current: updated.revision)) { try await second.value }
                } else {
                    #expect(try await second.value == .idempotent(updated))
                }
                #expect(clockReads.withLock { $0 } == 1)
                #expect(updated.revision.signedValue == before.revision.signedValue + (noOp ? 0 : 1))
                #expect(updated.visibilityRevision.signedValue == before.visibilityRevision.signedValue + (noOp ? 0 : 1))
                #expect(try await store.currentProfile(for: senderID) == updated)
                #expect(try await store.update(command) == .idempotent(updated))
                #expect(clockReads.withLock { $0 } == 1)
                #expect(try await count("im_v2.public_profile_update_operations", on: sql) == 1)
                #expect(try await count("im_v2.public_profile_update_outbox", on: sql) == (noOp ? 0 : 1))
                #expect(try await sql.raw("SELECT COUNT(*) AS value FROM im_v2.public_profile_update_operations WHERE actor_user_id = \(bind: senderUUID) AND created_at = \(bind: now)").first(decoding: CountRow.self)?.value == 1)
            } catch {
                first.cancel()
                second?.cancel()
                await gate.releaseTransaction()
                _ = await holder.result
                _ = await first.result
                if let second { _ = await second.result }
                throw error
            }
        }
    }

    @Test("Profile names persist canonically with exact event times and replay across clock boundaries",
          arguments: [0, 1, 2], [false, true])
    func ownProfileCanonicalNameTimestamp(clockIndex: Int, hasAvatar: Bool) async throws {
        let dates: [Double] = [946_684_800 + 0.00000125, -210_866_803_200, 9_224_318_015_990]
        let now = Date(timeIntervalSince1970: dates[clockIndex])
        try await withForwardOwnerDatabases(mode: .standard) { database, _, sql, _, _ in
            let clock = TestSequenceClock([now])
            let store = PostgresV2ProfileUpdateStore(database: database, now: { clock.now() })
            let media = UUID()
            if hasAvatar {
                try await sql.raw("INSERT INTO im_v2.media_objects(media_id,owner_user_id,content_type,byte_count,state,upload_session_id,expires_at,state_updated_at,created_at) VALUES (\(bind: media),\(bind: senderUUID),'image/png',1,'available',\(bind: UUID()),\(bind: now),\(bind: now),\(bind: now))").run()
            }
            let avatar: V2AvatarReference? = hasAvatar ? .init(mediaID: .init(uuid: media)) : nil
            let operation = ProfileUpdateOperationID(uuid: UUID())
            let before = try await store.currentProfile(for: senderID)
            func command(_ name: String) throws -> V2ProfileUpdateCommand {
                try .init(actorUserID: senderID, operationID: operation,
                    expectedRevision: before.revision, displayName: name, avatar: avatar)
            }
            guard case .updated(let updated) = try await store.update(command("\nCafe\u{301}\t")) else {
                throw V2ProfileUpdateError.corruptPersistenceState
            }
            #expect(updated.publicIdentity?.displayName == "Café")
            #expect(updated.avatar == avatar)
            #expect(updated.revision.signedValue == 2)
            #expect(try await sql.raw("""
                SELECT COUNT(*) AS value FROM im_v2.public_user_profiles p
                JOIN im_v2.public_profile_update_operations op ON op.actor_user_id = p.user_id
                JOIN im_v2.public_profile_update_outbox o ON o.source_user_id = p.user_id
                WHERE p.user_id = \(bind: senderUUID)
                  AND convert_to(p.display_name, 'UTF8') = convert_to(\(bind: "Café")::text, 'UTF8')
                  AND op.requested_display_name = p.display_name AND o.display_name = p.display_name
                  AND p.updated_at = \(bind: now) AND o.profile_updated_at = p.updated_at
                  AND o.created_at = p.updated_at AND op.created_at = p.updated_at
                """).first(decoding: CountRow.self)?.value == 1)
            for date in [Date(timeIntervalSince1970: .nan), Date(timeIntervalSince1970: .infinity), now] {
                clock.set([date])
                for name in ["Café", "\nCafe\u{301}\t", "  Café  "] {
                    guard case .idempotent(let replay) = try await store.update(command(name)) else {
                        throw V2ProfileUpdateError.corruptPersistenceState
                    }
                    #expect(replay == updated)
                }
            }
            #expect(try await store.currentProfile(for: senderID) == updated)
            #expect(try await count("im_v2.public_profile_update_operations", on: sql) == 1)
            #expect(try await count("im_v2.public_profile_update_outbox", on: sql) == 1)
        }
    }

    @Test("Equivalent profile names remain no-ops at exhausted revision boundaries",
          arguments: ["revision", "visibility_revision"])
    func ownProfileCanonicalNameNoOp(column: String) async throws {
        try await withForwardOwnerDatabases(mode: .standard) { database, _, sql, _, _ in
            let now = Date(timeIntervalSince1970: 1_750_000_000)
            let store = PostgresV2ProfileUpdateStore(database: database, now: { now })
            try await sql.raw("UPDATE im_v2.public_user_profiles SET \(unsafeRaw: column) = \(bind: Int64.max) WHERE user_id = \(bind: senderUUID)").run()
            let before = try await store.currentProfile(for: senderID)
            let name = try #require(before.publicIdentity).displayName
            let persistedBefore = try await sql.raw("SELECT to_jsonb(p)::text AS value FROM im_v2.public_user_profiles p WHERE user_id = \(bind: senderUUID)").first(decoding: StringValueRow.self)?.value
            // Padding can exceed the database's raw-name length limit; only
            // the already validated canonical name belongs in persistence.
            let command = try V2ProfileUpdateCommand(actorUserID: senderID, operationID: .init(uuid: UUID()),
                expectedRevision: before.revision, displayName: String(repeating: " ", count: 300) + name + "\n", avatar: nil)
            #expect(try await store.update(command) == .updated(before))
            #expect(try await store.update(command) == .idempotent(before))
            #expect(try await sql.raw("SELECT to_jsonb(p)::text AS value FROM im_v2.public_user_profiles p WHERE user_id = \(bind: senderUUID)").first(decoding: StringValueRow.self)?.value == persistedBefore)
            #expect(try await sql.raw("SELECT requested_display_name AS value FROM im_v2.public_profile_update_operations WHERE actor_user_id = \(bind: senderUUID)").first(decoding: StringValueRow.self)?.value == name)
            #expect(try await count("im_v2.public_profile_update_operations", on: sql) == 1)
            #expect(try await count("im_v2.public_profile_update_outbox", on: sql) == 0)
        }
    }

    @Test("Historical padded profile operation names replay without weakening payload matching", arguments: [false, true])
    func ownProfileLegacyCanonicalNameReplay(hasAvatar: Bool) async throws {
        try await withForwardOwnerDatabases(mode: .standard) { database, _, sql, _, _ in
            let now = Date(timeIntervalSince1970: 1_750_000_000)
            let operation = ProfileUpdateOperationID(uuid: UUID())
            let media = UUID()
            if hasAvatar {
                try await sql.raw("INSERT INTO im_v2.media_objects(media_id,owner_user_id,content_type,byte_count,state,upload_session_id,expires_at,state_updated_at,created_at) VALUES (\(bind: media),\(bind: senderUUID),'image/png',1,'available',\(bind: UUID()),\(bind: now),\(bind: now),\(bind: now))").run()
            }
            let avatar: V2AvatarReference? = hasAvatar ? .init(mediaID: .init(uuid: media)) : nil
            let revision = try #require(V2ProfileRevision(rawValue: 1))
            let command = try V2ProfileUpdateCommand(actorUserID: senderID, operationID: operation,
                expectedRevision: revision, displayName: "Café", avatar: avatar)
            let initial = PostgresV2ProfileUpdateStore(database: database, now: { now })
            _ = try await initial.update(command)
            // Reproduce rows written by the old implementation, which kept
            // raw input in the profile and ledger but normalized the outbox.
            try await sql.raw("UPDATE im_v2.public_user_profiles SET display_name = \(bind: "\nCafe\u{301}\t") WHERE user_id = \(bind: senderUUID)").run()
            try await sql.raw("UPDATE im_v2.public_profile_update_operations SET requested_display_name = \(bind: "\nCafe\u{301}\t") WHERE actor_user_id = \(bind: senderUUID)").run()
            func snapshot() async throws -> [String] {
                var values: [String] = []
                for table in ["public_user_profiles", "public_profile_update_operations", "public_profile_update_outbox"] {
                    guard let row = try await sql.raw("SELECT COALESCE(jsonb_agg(to_jsonb(r) ORDER BY to_jsonb(r)::text), '[]'::jsonb)::text AS value FROM im_v2.\(unsafeRaw: table) r").first(decoding: StringValueRow.self) else { throw CancellationError() }
                    values.append(row.value)
                }
                return values
            }
            let before = try await snapshot()
            let current = try await initial.currentProfile(for: senderID)
            let replayStore = PostgresV2ProfileUpdateStore(database: database, now: { Date(timeIntervalSince1970: .nan) })
            for name in ["Café", "\nCafe\u{301}\t", "  Café  "] {
                let retry = try V2ProfileUpdateCommand(actorUserID: senderID, operationID: operation,
                    expectedRevision: revision, displayName: name, avatar: avatar)
                #expect(try await replayStore.update(retry) == .idempotent(current))
                #expect(try await snapshot() == before)
            }
            let differentAvatar: V2AvatarReference? = hasAvatar ? nil : .init(mediaID: .init(uuid: UUID()))
            for changed in [
                try V2ProfileUpdateCommand(actorUserID: senderID, operationID: operation, expectedRevision: revision, displayName: "Different", avatar: avatar),
                try V2ProfileUpdateCommand(actorUserID: senderID, operationID: operation, expectedRevision: current.revision, displayName: "Café", avatar: avatar),
                try V2ProfileUpdateCommand(actorUserID: senderID, operationID: operation, expectedRevision: revision, displayName: "Café", avatar: differentAvatar)
            ] {
                await #expect(throws: V2ProfileUpdateError.operationPayloadMismatch) { try await replayStore.update(changed) }
                #expect(try await snapshot() == before)
            }
        }
    }

    @Test("own profile writes use signed revisions and reject exhausted counters", arguments: ["normal", "before-max", "revision-max", "visibility-max"], [false, true])
    func ownProfileRevisionBounds(_ scenario: String, change: Bool) async throws {
        try await withForwardOwnerDatabases(mode: .standard) { database, _, sql, _, _ in
            let now = Date(timeIntervalSince1970: 1_750_000_000)
            let revision: Int64 = scenario == "revision-max" ? Int64.max : (scenario == "before-max" ? Int64.max-1 : 1)
            let visibility: Int64 = scenario == "visibility-max" ? Int64.max : revision
            try await sql.raw("UPDATE im_v2.public_user_profiles SET revision=\(bind: revision),visibility_revision=\(bind: visibility) WHERE user_id=\(bind: senderUUID)").run()
            let store = PostgresV2ProfileUpdateStore(database: database, now: { now })
            let before = try await store.currentProfile(for: senderID)
            let name = change ? "changed name" : try #require(before.publicIdentity).displayName
            let command = try V2ProfileUpdateCommand(actorUserID: senderID, operationID: .init(uuid: UUID()), expectedRevision: before.revision, displayName: name, avatar: nil)
            let exhausted = change && (revision == Int64.max || visibility == Int64.max)
            if exhausted {
                await #expect(throws: V2ProfileUpdateError.corruptPersistenceState) { _ = try await store.update(command) }
                #expect(try await store.currentProfile(for: senderID) == before)
            } else {
                guard case .updated(let updated) = try await store.update(command) else { throw V2ProfileUpdateError.corruptPersistenceState }
                #expect(updated.revision.signedValue == revision + (change ? 1 : 0))
                #expect(updated.visibilityRevision.signedValue == visibility + (change ? 1 : 0))
                guard case .idempotent(let replay) = try await store.update(command) else { throw V2ProfileUpdateError.corruptPersistenceState }
                #expect(replay == updated)
            }
            #expect(try await count("im_v2.public_profile_update_operations", on: sql) == (exhausted ? 0 : 1))
            #expect(try await count("im_v2.public_profile_update_outbox", on: sql) == (!exhausted && change ? 1 : 0))
        }
    }

    @Test("room-log media grants revalidate historical content and provider completion", arguments: ["healthy", "issue-gap", "claim-gap", "provider-gap", "provider-device", "provider-device-expiry", "provider-account", "provider-profile", "provider-reference", "provider-lease", "provider-takeover", "provider-expiry", "avatar-gap", "issue-missing", "claim-missing", "provider-missing"])
    func roomLogMediaAuthorization(scenario: String) async throws {
        try await withForwardOwnerDatabases(mode: .standard) { database, _, sql, _, _ in
            let now = Date(timeIntervalSince1970: 1_750_000_000)
            let clock = LegacyMediaTestClock(now)
            let media = MediaID(uuid: UUID()), device = DeviceID(uuid: UUID()), actor = UserID(uuid: memberTwoUUID)
            let mediaUUID = try #require(media.uuidValue), deviceUUID = try #require(device.uuidValue)
            try await sql.raw("INSERT INTO im_v2.media_objects(media_id,owner_user_id,content_type,byte_count,state,upload_session_id,expires_at,state_updated_at,created_at) VALUES (\(bind: mediaUUID),\(bind: senderUUID),'text/plain',1,'available',\(bind: UUID()),\(bind: now.addingTimeInterval(600)),\(bind: now),\(bind: now))").run()
            try await sql.raw("INSERT INTO im_v2.auth_devices(user_id,device_id,created_at,last_active_at) VALUES (\(bind: memberTwoUUID),\(bind: deviceUUID),\(bind: now),\(bind: now))").run()
            let sender = try V2SendMessageService(store: PostgresV2RoomWriteStore(database: database), capacityProfile: forwardImportTestProfile(), limits: .init(maxUTF8Bytes: 64), now: { now })
            guard case .accepted(let message) = try await sender.send(.init(roomID: roomID, actorUserID: senderID, clientMessageID: .init(uuid: UUID()), text: "media baseline", media: [.init(mediaID: media)])) else { throw V2RoomWriteStoreError.corruptPersistenceState }
            #expect(try await count("im_v2.user_sync_log", on: sql) == 0)
            let store = PostgresV2MediaStore(database: database)
            let sessions = PostgresV2MediaDownloadSessionStore(database: database)
            @Sendable func change() async throws {
                if scenario.hasSuffix("gap") {
                    try await sql.raw("UPDATE im_v2.room_memberships SET left_revision=1 WHERE user_id=\(bind: memberTwoUUID)").run()
                    try await sql.raw("UPDATE im_v2.rooms SET membership_revision=1").run()
                    _ = try await mutateAcceptedMessage(database: database, room: roomID, message: message.messageID, operation: "edit", operationID: UUID())
                    try await sql.raw("INSERT INTO im_v2.room_memberships(room_id,user_id,joined_revision) VALUES (\(bind: roomUUID),\(bind: memberTwoUUID),2)").run()
                    try await sql.raw("UPDATE im_v2.rooms SET membership_revision=2").run()
                    if scenario == "avatar-gap" { try await sql.raw("UPDATE im_v2.public_user_profiles SET avatar_media_id=\(bind: mediaUUID) WHERE user_id=\(bind: senderUUID)").run() }
                } else if scenario.hasSuffix("missing") {
                    try await sql.raw("DELETE FROM im_v2.message_send_completions WHERE message_id=\(bind: message.messageID.uuidValue!)").run()
                } else if scenario == "provider-device-expiry" {
                    try await sql.raw("UPDATE im_v2.auth_devices SET session_expires_at=clock_timestamp()-interval '1 second' WHERE device_id=\(bind: deviceUUID)").run()
                } else if scenario == "provider-device" {
                    try await sql.raw("UPDATE im_v2.auth_devices SET revoked_at=\(bind: now) WHERE device_id=\(bind: deviceUUID)").run()
                } else if scenario == "provider-account" {
                    try await sql.raw("INSERT INTO im_v2.account_disables(user_id,operation_id,reason,operator_principal,disabled_at) VALUES (\(bind: memberTwoUUID),\(bind: UUID()),'policy_enforcement','test',\(bind: now))").run()
                } else if scenario == "provider-profile" {
                    try await sql.raw("UPDATE im_v2.public_user_profiles SET state='suspended' WHERE user_id=\(bind: memberTwoUUID)").run()
                } else if scenario == "provider-reference" {
                    try await sql.raw("UPDATE im_v2.message_media_references SET revoked_at=\(bind: now) WHERE message_id=\(bind: message.messageID.uuidValue!)").run()
                } else if scenario == "provider-lease" || scenario == "provider-takeover" {
                    clock.advance(by: 20)
                } else if scenario == "provider-expiry" { clock.advance(by: 61) }
            }
            if scenario.hasPrefix("issue") || scenario == "avatar-gap" { try await change() }
            if scenario.hasPrefix("issue") {
                await #expect(throws: V2MediaStoreError.downloadNotAuthorized) {
                    _ = try await store.requestDownload(requesterUserID: actor, deviceID: device, mediaID: media, expiresAt: now.addingTimeInterval(60), now: now)
                }
                #expect(try await count("im_v2.media_download_grants", on: sql) == 0)
                return
            }
            let grant = try await store.requestDownload(requesterUserID: actor, deviceID: device, mediaID: media, expiresAt: now.addingTimeInterval(60), now: now)
            if scenario.hasPrefix("claim") {
                try await change()
                await #expect(throws: V2MediaDownloadSessionStoreError.sessionUnavailable) {
                    _ = try await sessions.claimDownload(requesterUserID: actor, deviceID: device, downloadSessionID: grant.downloadSessionID, now: now, leaseDuration: 15)
                }
                #expect(try await sql.raw("SELECT state AS value FROM im_v2.media_download_grants").first(decoding: StringValueRow.self)?.value == "pending")
                return
            }
            let provider = LegacyMediaTransitionProvider {
                if scenario.hasPrefix("provider") { try await change() }
                if scenario == "provider-takeover" {
                    _ = try await sessions.claimDownload(requesterUserID: actor, deviceID: device, downloadSessionID: grant.downloadSessionID, now: clock.now(), leaseDuration: 15)
                }
            }
            let service = try V2MediaProviderSessionService(store: sessions, provider: provider, now: { clock.now() })
            if scenario == "healthy" || scenario == "avatar-gap" {
                let result = try await service.exchangeDownload(actorUserID: actor, deviceID: device, downloadSessionID: grant.downloadSessionID)
                #expect(result.expiresAt == grant.expiresAt)
            } else if scenario == "provider-expiry" {
                await #expect(throws: V2MediaProviderSessionError.invalidProviderTarget) {
                    _ = try await service.exchangeDownload(actorUserID: actor, deviceID: device, downloadSessionID: grant.downloadSessionID)
                }
            } else {
                await #expect(throws: V2MediaDownloadSessionStoreError.sessionUnavailable) {
                    _ = try await service.exchangeDownload(actorUserID: actor, deviceID: device, downloadSessionID: grant.downloadSessionID)
                }
            }
            let expected = scenario == "provider-takeover" ? "claimed" : (scenario == "healthy" || scenario == "avatar-gap" ? "consumed" : "pending")
            #expect(try await sql.raw("SELECT state AS value FROM im_v2.media_download_grants").first(decoding: StringValueRow.self)?.value == expected)
            #expect(await provider.calls == 1)
        }
    }

    @Test("message references require accepted and current content audiences", arguments: ["reply-standard", "reply-hybrid", "pin-standard", "pin-hybrid"], ["member", "new-member", "gap-edit", "rejoined", "missing-acceptance", "withdrawn", "accepted-storage-drift", "replay-after-leave", "visible-edit", "hidden-existing-pin", "wrong-completion"])
    func messageReferenceAudience(_ path: String, scenario: String) async throws {
        try await withForwardOwnerDatabases(mode: path.hasSuffix("hybrid") ? .large : .standard) { database, _, sql, _, _ in
            let now = Date(timeIntervalSince1970: 1_750_000_000)
            let profile = try forwardImportTestProfile()
            let limits = try V2MessageCommandLimits(maxUTF8Bytes: 64)
            let store = PostgresV2RoomWriteStore(database: database)
            let sender = V2SendMessageService(store: store, capacityProfile: profile, limits: limits, now: { now })
            try await sql.raw("UPDATE im_v2.room_memberships SET role='admin' WHERE user_id=\(bind: memberTwoUUID)").run()
            guard case .accepted(let source) = try await sender.send(.init(roomID: roomID, actorUserID: senderID, clientMessageID: .init(uuid: UUID()), text: "reference target")) else { throw V2RoomWriteStoreError.corruptPersistenceState }
            let target = try #require(source.messageID.uuidValue)
            if scenario == "hidden-existing-pin" {
                try await sql.raw("UPDATE im_v2.room_memberships SET role='owner' WHERE user_id=\(bind: senderUUID)").run()
                let result = try await PostgresV2GroupCapabilitiesStore(database: database).setPinnedMessage(actorUserID: senderID, command: .init(operationID: .init(uuid: UUID()), roomID: roomID, messageID: source.messageID, isPinned: true), capacityProfile: profile, eventID: .init(uuid: UUID()), now: now)
                guard case .applied = result else { throw V2GroupCapabilitiesStoreError.corruptPersistenceState }
            }
            if ["gap-edit", "rejoined"].contains(scenario) {
                try await sql.raw("UPDATE im_v2.room_memberships SET left_revision=1 WHERE user_id=\(bind: memberTwoUUID)").run()
                try await sql.raw("UPDATE im_v2.rooms SET membership_revision=1").run()
                if scenario == "gap-edit" { _ = try await mutateAcceptedMessage(database: database, room: roomID, message: source.messageID, operation: "edit", operationID: UUID()) }
                try await sql.raw("INSERT INTO im_v2.room_memberships(room_id,user_id,role,joined_revision) VALUES (\(bind: roomUUID),\(bind: memberTwoUUID),'admin',2)").run()
                try await sql.raw("UPDATE im_v2.rooms SET membership_revision=2").run()
            } else if ["new-member", "hidden-existing-pin"].contains(scenario) {
                try await sql.raw("UPDATE im_v2.room_memberships SET joined_revision=1 WHERE user_id=\(bind: memberTwoUUID)").run()
                try await sql.raw("UPDATE im_v2.rooms SET membership_revision=1").run()
            } else if scenario == "missing-acceptance" {
                try await sql.raw("DELETE FROM im_v2.message_send_completions WHERE message_id=\(bind: target)").run()
            } else if scenario == "accepted-storage-drift" {
                // The physical compatibility copy is not accepted authority.
                try await sql.raw("UPDATE im_v2.messages SET accepted_event_storage='message_row', accepted_membership_revision=99, accepted_event_id=\(bind: UUID()) WHERE message_id=\(bind: target)").run()
            } else if scenario == "visible-edit" {
                _ = try await mutateAcceptedMessage(database: database, room: roomID, message: source.messageID, operation: "edit", operationID: UUID())
            } else if scenario == "wrong-completion" {
                // Import-like malformed evidence: preserve its lookup key but
                // bind the immutable result to a different message identity.
                try await sql.raw("""
                    WITH old AS (DELETE FROM im_v2.message_send_completions WHERE message_id=\(bind: target) RETURNING *)
                    INSERT INTO im_v2.message_send_completions
                    SELECT changed.* FROM old CROSS JOIN LATERAL jsonb_populate_record(NULL::im_v2.message_send_completions, to_jsonb(old)||jsonb_build_object('message_id',\(bind: UUID()))) changed
                    """).run()
            } else if scenario == "withdrawn" {
                _ = try await mutateAcceptedMessage(database: database, room: roomID, message: source.messageID, operation: "withdraw", operationID: UUID())
            }
            let actor = UserID(uuid: memberTwoUUID), operation = UUID()
            let reply = try V2SendMessageCommand(roomID: roomID, senderUserID: actor, clientMessageID: .init(uuid: operation), text: "reply", replyTo: .init(messageID: source.messageID), limits: limits)
            let pin = V2PinnedMessageCommand(operationID: .init(uuid: operation), roomID: roomID, messageID: source.messageID, isPinned: true)
            func run() async throws -> String {
                if path.hasPrefix("reply") {
                    let result = try await store.accept(command: reply, capacityProfile: profile, identifiers: try V2AcceptanceIDFactory().make(at: now), now: now)
                    switch result { case .accepted: return "changed"; case .idempotent: return "replay"; default: return "other" }
                }
                let result = try await PostgresV2GroupCapabilitiesStore(database: database).setPinnedMessage(actorUserID: actor, command: pin, capacityProfile: profile, eventID: .init(uuid: UUID()), now: now)
                switch result { case .applied: return "changed"; case .idempotent: return "replay"; default: return "other" }
            }
            let allowed = ["member", "rejoined", "accepted-storage-drift", "replay-after-leave", "visible-edit"].contains(scenario)
            let before = try await sql.raw("SELECT jsonb_build_array((SELECT count(*) FROM im_v2.messages),(SELECT count(*) FROM im_v2.room_events),(SELECT count(*) FROM im_v2.room_pinned_message_operations),(SELECT jsonb_agg(to_jsonb(r)) FROM im_v2.rooms r),(SELECT jsonb_agg(to_jsonb(a)) FROM im_v2.room_admission a))::text AS value").first(decoding: StringValueRow.self)?.value
            do { #expect(try await run() == "changed"); #expect(allowed) }
            catch V2RoomWriteStoreError.replyTargetNotFound { #expect(!allowed && path.hasPrefix("reply")) }
            catch V2GroupCapabilitiesStoreError.messageNotFound { #expect(!allowed && path.hasPrefix("pin")) }
            catch V2GroupCapabilitiesStoreError.messageWithdrawn { #expect(scenario == "withdrawn" && path.hasPrefix("pin")) }
            if !allowed {
                let after = try await sql.raw("SELECT jsonb_build_array((SELECT count(*) FROM im_v2.messages),(SELECT count(*) FROM im_v2.room_events),(SELECT count(*) FROM im_v2.room_pinned_message_operations),(SELECT jsonb_agg(to_jsonb(r)) FROM im_v2.rooms r),(SELECT jsonb_agg(to_jsonb(a)) FROM im_v2.room_admission a))::text AS value").first(decoding: StringValueRow.self)?.value
                #expect(after == before)
            }
            // This predicate also serves forward export/final acceptance and
            // routed media reads. Its immutable receipt authority must agree.
            let visible = try await sql.raw("SELECT EXISTS(SELECT 1 FROM im_v2.messages message JOIN im_v2.rooms room ON room.room_id=message.room_id WHERE message.message_id=\(bind: target) AND message.withdrawn_at IS NULL AND (\(v2ForwardSourceVisibility(actorID: memberTwoUUID)))) AS value").first(decoding: GroupBoolRowForReferenceTest.self)?.value
            #expect(visible == allowed)
            if scenario == "replay-after-leave" {
                try await sql.raw("UPDATE im_v2.room_memberships SET left_revision=1 WHERE user_id=\(bind: memberTwoUUID)").run()
                try await sql.raw("UPDATE im_v2.rooms SET membership_revision=1").run()
                #expect(try await run() == "replay")
            }
        }
    }

    private struct GroupBoolRowForReferenceTest: Decodable { let value: Bool }

    @Test("room-log edit replacement bridges rejoin without exposing absent revisions")
    func roomLogEditReplacementAfterRejoin() async throws {
        try await withForwardOwnerDatabases(mode: .standard) { database, _, sql, _, _ in
            let now = Date(timeIntervalSince1970: 1_750_000_000)
            try await sql.raw("DELETE FROM im_v2.room_memberships WHERE user_id=\(bind: memberThreeUUID)").run()
            try await sql.raw("UPDATE im_v2.room_admission SET eligible_member_count=2").run()
            let sender = try V2SendMessageService(store: PostgresV2RoomWriteStore(database: database), capacityProfile: forwardImportTestProfile(), limits: .init(maxUTF8Bytes: 64), now: { now })
            guard case .accepted(let message) = try await sender.send(.init(roomID: roomID, actorUserID: senderID, clientMessageID: .init(uuid: UUID()), text: "original visible text")) else { throw V2RoomWriteStoreError.corruptPersistenceState }
            let acceptedEvent = EventID(uuid: try await v2MessageAcceptanceFact(messageID: message.messageID.uuidValue!, roomID: roomUUID, sql: sql).eventID)
            try await sql.raw("UPDATE im_v2.room_memberships SET left_revision=1 WHERE user_id=\(bind: memberTwoUUID)").run()
            try await sql.raw("UPDATE im_v2.rooms SET membership_revision=1").run()
            try await sql.raw("UPDATE im_v2.room_admission SET eligible_member_count=1").run()
            let hidden = try await mutateAcceptedMessage(database: database, room: roomID, message: message.messageID, operation: "edit", operationID: UUID(), text: "hidden while absent")
            try await sql.raw("INSERT INTO im_v2.room_memberships (room_id,user_id,joined_revision) VALUES (\(bind: roomUUID),\(bind: memberTwoUUID),2),(\(bind: roomUUID),\(bind: memberThreeUUID),2)").run()
            try await sql.raw("UPDATE im_v2.rooms SET membership_revision=2").run()
            try await sql.raw("UPDATE im_v2.room_admission SET eligible_member_count=3").run()
            let visible = try await mutateAcceptedMessage(database: database, room: roomID, message: message.messageID, operation: "edit", operationID: UUID(), expectedRevision: 2, text: "visible after rejoin")
            let payload = try #require(try await sql.raw("SELECT payload::text AS value FROM im_v2.room_events WHERE event_id=\(bind: visible.uuidValue!)").first(decoding: StringValueRow.self)).value
            let body = try #require(JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any])
            let replacement = body["replacement"] as? [String: Any]
            #expect(replacement?["schema_version"] as? Int == 1)
            #expect((replacement?["accepted_event_id"] as? String)?.lowercased() == acceptedEvent.rawValue.lowercased())
            #expect(replacement?["accepted_membership_revision"] as? Int == 0)
            let state = replacement?["state"] as? [String: Any]
            #expect(state?["message_revision"] as? Int == 3 && state?["room_sequence"] as? Int == 1)
            let log = PostgresV2GroupEventLogStore(database: database)
            let page = try await log.pull(roomID: roomID, actorUserID: .init(uuid: memberTwoUUID), afterRoomSequence: 0, pageSize: 10)
            #expect(page.events.map(\.roomSequence) == [1, 3])
            #expect(!page.events.contains { $0.sourceEventID == hidden })
            let original = try #require(page.events.first)
            let edited = try #require(page.events.last)
            #expect(original.sourceEventID == acceptedEvent && edited.sourceEventID == visible)
            let newcomer = try await log.pull(roomID: roomID, actorUserID: .init(uuid: memberThreeUUID), afterRoomSequence: 0, pageSize: 10)
            #expect(newcomer.events.isEmpty)
            #expect(try await count("im_v2.user_sync_log", on: sql) == 0)
            if let root = Environment.get("IMV2_REPLACEMENT_TEST_FIXTURE_DIRECTORY") {
                let fixture: [String: Any] = ["origin_event_id": acceptedEvent.rawValue, "event_id": visible.rawValue,
                    "accepted": try JSONSerialization.jsonObject(with: original.payload),
                    "edit": try JSONSerialization.jsonObject(with: edited.payload)]
                let directory = URL(fileURLWithPath: root)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try JSONSerialization.data(withJSONObject: fixture, options: [.sortedKeys, .prettyPrinted])
                    .write(to: directory.appending(path: "room-log.json"), options: .atomic)
            }
        }

    }

    @Test("room pulls intersect original and mutation visibility and advance hidden tails", arguments: ["personal", "roomLog", "cachedRoomLog"], ["edit", "withdraw", "reaction"])
    func roomMutationHistoricalRead(_ kind: String, operation: String) async throws {
        let mode: V2GroupCapacityClass = kind == "personal" ? .standard : .large
        try await withForwardOwnerDatabases(mode: mode) { database, _, sql, _, _ in
            let now = Date(timeIntervalSince1970: 1_750_000_000)
            try await sql.raw("DELETE FROM im_v2.room_memberships WHERE user_id=\(bind: memberThreeUUID)").run()
            try await sql.raw("UPDATE im_v2.room_admission SET eligible_member_count=2").run()
            let sender = try V2SendMessageService(store: PostgresV2RoomWriteStore(database: database), capacityProfile: forwardImportTestProfile(), limits: .init(maxUTF8Bytes: 64), now: { now })
            guard case .accepted(let message) = try await sender.send(.init(roomID: roomID, actorUserID: senderID, clientMessageID: .init(uuid: UUID()), text: "original visible text")) else { throw V2RoomWriteStoreError.corruptPersistenceState }
            let cache = V2DirectRoomLogEventCache(configuration: .init(maximumEvents: 16, maximumBytes: 65_536, maximumEventsPerRoom: 16, shardCount: 1))
            if kind == "cachedRoomLog" { await cache.recordCommittedPlainDirectMessage(message) }
            let reader = PostgresV2GroupEventLogStore(database: database, directRoomLogEventCache: kind == "cachedRoomLog" ? cache : nil)
            // User two misses an edit while absent, then rejoins. User three
            // has never had any accepted-time membership interval.
            try await sql.raw("UPDATE im_v2.room_memberships SET left_revision=1 WHERE user_id=\(bind: memberTwoUUID)").run()
            try await sql.raw("UPDATE im_v2.rooms SET membership_revision=1").run()
            try await sql.raw("UPDATE im_v2.room_admission SET eligible_member_count=1").run()
            _ = try await mutateAcceptedMessage(database: database, room: roomID, message: message.messageID, operation: "edit", operationID: UUID())
            try await sql.raw("INSERT INTO im_v2.room_memberships (room_id,user_id,joined_revision) VALUES (\(bind: roomUUID),\(bind: memberTwoUUID),2),(\(bind: roomUUID),\(bind: memberThreeUUID),2)").run()
            try await sql.raw("UPDATE im_v2.rooms SET membership_revision=2").run()
            try await sql.raw("UPDATE im_v2.room_admission SET eligible_member_count=3").run()
            let oldMember = UserID(uuid: memberTwoUUID), newMember = UserID(uuid: memberThreeUUID)
            let oldTail = try await reader.pull(roomID: roomID, actorUserID: oldMember, afterRoomSequence: 0, pageSize: 1)
            #expect(oldTail.events.map(\.roomSequence) == [message.roomSequence])
            #expect(oldTail.nextRoomSequence == message.roomSequence && oldTail.hasMore)
            let oldHiddenTail = try await reader.pull(roomID: roomID, actorUserID: oldMember, afterRoomSequence: oldTail.nextRoomSequence, pageSize: 1)
            #expect(oldHiddenTail.events.isEmpty && oldHiddenTail.nextRoomSequence == message.roomSequence + 1 && !oldHiddenTail.hasMore)
            let hiddenTail = try await reader.pull(roomID: roomID, actorUserID: newMember, afterRoomSequence: 0, pageSize: 1)
            #expect(hiddenTail.events.isEmpty && hiddenTail.nextRoomSequence == message.roomSequence && hiddenTail.hasMore)
            let hiddenEnd = try await reader.pull(roomID: roomID, actorUserID: newMember, afterRoomSequence: hiddenTail.nextRoomSequence, pageSize: 1)
            #expect(hiddenEnd.events.isEmpty && hiddenEnd.nextRoomSequence == message.roomSequence + 1 && !hiddenEnd.hasMore)
            let event = try await mutateAcceptedMessage(database: database, room: roomID, message: message.messageID,
                operation: operation, operationID: UUID(), expectedRevision: 2)
            let hiddenMutation = try await reader.pull(roomID: roomID, actorUserID: newMember, afterRoomSequence: hiddenEnd.nextRoomSequence, pageSize: 1)
            #expect(hiddenMutation.events.isEmpty && hiddenMutation.nextRoomSequence == message.roomSequence + 2 && !hiddenMutation.hasMore)
            let first = try await reader.pull(roomID: roomID, actorUserID: oldMember, afterRoomSequence: 0, pageSize: 1)
            #expect(first.events.map(\.roomSequence) == [message.roomSequence] && first.hasMore)
            let originalPayload = try #require(first.events.first?.payload)
            let original = try #require(JSONSerialization.jsonObject(with: originalPayload) as? [String: Any])
            #expect(original["text"] as? String == "original visible text")
            let second = try await reader.pull(roomID: roomID, actorUserID: oldMember, afterRoomSequence: first.nextRoomSequence, pageSize: 1)
            #expect(second.events.isEmpty && second.hasMore)
            #expect(second.nextRoomSequence == message.roomSequence + 1)
            let third = try await reader.pull(roomID: roomID, actorUserID: oldMember, afterRoomSequence: second.nextRoomSequence, pageSize: 1)
            #expect(third.events.map(\.sourceEventID) == [event])
            #expect(third.nextRoomSequence == message.roomSequence + 2 && !third.hasMore)
            // Missing authority cannot turn into silent cursor advancement.
            try await sql.raw("DELETE FROM im_v2.message_send_completions WHERE message_id=\(bind: message.messageID.uuidValue!)").run()
            await #expect(throws: V2GroupEventLogError.corruptPersistenceState) {
                try await reader.pull(roomID: roomID, actorUserID: oldMember, afterRoomSequence: message.roomSequence + 1, pageSize: 1)
            }
        }
    }

    @Test("reaction actors need accepted-time visibility before even a no-op", arguments: [V2GroupCapacityClass.standard, .large], ["newAdd", "newRemove", "rejoined"])
    func reactionRequiresAcceptedMembership(_ mode: V2GroupCapacityClass, scenario: String) async throws {
        try await withForwardOwnerDatabases(mode: mode) { database, _, sql, _, _ in
            let now = Date(timeIntervalSince1970: 1_750_000_000)
            try await sql.raw("DELETE FROM im_v2.room_memberships WHERE user_id=\(bind: memberThreeUUID)").run()
            try await sql.raw("UPDATE im_v2.room_admission SET eligible_member_count=2").run()
            let sender = try V2SendMessageService(store: PostgresV2RoomWriteStore(database: database), capacityProfile: forwardImportTestProfile(), limits: .init(maxUTF8Bytes: 64), now: { now })
            guard case .accepted(let message) = try await sender.send(.init(roomID: roomID, actorUserID: senderID, clientMessageID: .init(uuid: UUID()), text: "original")) else { throw V2RoomWriteStoreError.corruptPersistenceState }
            try await sql.raw("UPDATE im_v2.room_memberships SET left_revision=1 WHERE user_id=\(bind: memberTwoUUID)").run()
            try await sql.raw("INSERT INTO im_v2.room_memberships (room_id,user_id,joined_revision) VALUES (\(bind: roomUUID),\(bind: memberTwoUUID),2),(\(bind: roomUUID),\(bind: memberThreeUUID),2)").run()
            try await sql.raw("UPDATE im_v2.rooms SET membership_revision=2").run()
            try await sql.raw("UPDATE im_v2.room_admission SET eligible_member_count=3").run()
            let actor = UserID(uuid: scenario == "rejoined" ? memberTwoUUID : memberThreeUUID)
            let service = try V2MessageReactionService(store: PostgresV2MessageReactionStore(database: database), capacityProfile: forwardImportTestProfile(), now: { now })
            let command = V2AuthenticatedMessageReaction(roomID: roomID, actorUserID: actor, operationID: .init(uuid: UUID()), messageID: message.messageID, reaction: "👍", action: scenario == "newRemove" ? .remove : .add)
            if scenario == "rejoined" {
                guard case .changed(let result) = try await service.change(command) else { throw V2MessageReactionStoreError.corruptPersistenceState }
                try await sql.raw("UPDATE im_v2.room_memberships SET left_revision=3 WHERE user_id=\(bind: memberTwoUUID) AND left_revision IS NULL").run()
                try await sql.raw("UPDATE im_v2.rooms SET membership_revision=3").run()
                #expect(try await service.change(command) == .idempotent(result))
            } else {
                let tables = ["rooms", "room_events", "message_reactions", "message_reaction_operations", "room_admission", "shard_admission_pools"]
                var before: [String] = []
                for table in tables {
                    before.append(try #require(try await sql.raw("SELECT COALESCE(jsonb_agg(to_jsonb(t) ORDER BY to_jsonb(t)::text), '[]'::jsonb)::text AS value FROM im_v2.\(ident: table) t").first(decoding: StringValueRow.self)).value)
                }
                await #expect(throws: V2MessageReactionStoreError.actorNotMember) { try await service.change(command) }
                for (index, table) in tables.enumerated() {
                    let after = try #require(try await sql.raw("SELECT COALESCE(jsonb_agg(to_jsonb(t) ORDER BY to_jsonb(t)::text), '[]'::jsonb)::text AS value FROM im_v2.\(ident: table) t").first(decoding: StringValueRow.self)).value
                    #expect(after == before[index], "Unexpected change to \(table)")
                }
            }
        }
    }

    @Test("message mutations intersect accepted and mutation membership across rejoin", arguments: ["edit", "withdraw", "reaction"])
    func messageMutationHistoricalAudience(_ operation: String) async throws {
        try await withForwardOwnerDatabases(mode: .standard) { database, _, sql, _, _ in
            let now = Date(timeIntervalSince1970: 1_750_000_000)
            // The third user has no accepted-time interval. User two will
            // leave and rejoin, so visibility must use two independent EXISTS.
            try await sql.raw("DELETE FROM im_v2.room_memberships WHERE user_id=\(bind: memberThreeUUID)").run()
            try await sql.raw("UPDATE im_v2.room_admission SET eligible_member_count=2").run()
            let sender = try V2SendMessageService(store: PostgresV2RoomWriteStore(database: database), capacityProfile: forwardImportTestProfile(), limits: .init(maxUTF8Bytes: 64), now: { now })
            guard case .accepted(let message) = try await sender.send(.init(roomID: roomID, actorUserID: senderID,
                clientMessageID: .init(uuid: UUID()), text: "before new member")) else { throw V2RoomWriteStoreError.corruptPersistenceState }
            try await sql.raw("UPDATE im_v2.room_memberships SET left_revision=1 WHERE user_id=\(bind: memberTwoUUID)").run()
            try await sql.raw("INSERT INTO im_v2.room_memberships (room_id,user_id,joined_revision) VALUES (\(bind: roomUUID),\(bind: memberTwoUUID),2),(\(bind: roomUUID),\(bind: memberThreeUUID),2)").run()
            try await sql.raw("UPDATE im_v2.rooms SET membership_revision=2").run()
            try await sql.raw("UPDATE im_v2.room_admission SET eligible_member_count=3").run()
            let event = try await mutateAcceptedMessage(database: database, room: roomID, message: message.messageID, operation: operation, operationID: UUID())
            let log = PostgresV2GroupEventLogStore(database: database)
            let rejoined = try await log.pull(roomID: roomID, actorUserID: .init(uuid: memberTwoUUID), afterRoomSequence: message.roomSequence, pageSize: 10)
            #expect(rejoined.events.map(\.sourceEventID) == [event])
            let newcomer = try await log.pull(roomID: roomID, actorUserID: .init(uuid: memberThreeUUID), afterRoomSequence: 0, pageSize: 10)
            #expect(newcomer.events.isEmpty)
            #expect(try await count("im_v2.user_sync_log", on: sql) == 0)
        }

    }

    @Test("author can withdraw after original members leave without creating public copies")
    func withdrawAfterAllOriginalMembersLeave() async throws {
        try await withForwardOwnerDatabases(mode: .standard) { database, _, sql, _, _ in
            let now = Date(timeIntervalSince1970: 1_750_000_000)
            try await sql.raw("DELETE FROM im_v2.room_memberships WHERE user_id=\(bind: memberThreeUUID)").run()
            try await sql.raw("UPDATE im_v2.room_admission SET eligible_member_count=2").run()
            let sender = try V2SendMessageService(store: PostgresV2RoomWriteStore(database: database), capacityProfile: forwardImportTestProfile(), limits: .init(maxUTF8Bytes: 64), now: { now })
            guard case .accepted(let message) = try await sender.send(.init(roomID: roomID, actorUserID: senderID, clientMessageID: .init(uuid: UUID()), text: "original")) else { throw V2RoomWriteStoreError.corruptPersistenceState }
            try await sql.raw("UPDATE im_v2.room_memberships SET left_revision=1").run()
            try await sql.raw("INSERT INTO im_v2.room_memberships (room_id,user_id,joined_revision) VALUES (\(bind: roomUUID),\(bind: memberThreeUUID),1)").run()
            try await sql.raw("UPDATE im_v2.rooms SET membership_revision=1").run()
            try await sql.raw("UPDATE im_v2.room_admission SET eligible_member_count=1").run()
            // Existing policy permits an author to withdraw after leaving.
            let event = try await mutateAcceptedMessage(database: database, room: roomID, message: message.messageID, operation: "withdraw", operationID: UUID())
            let row = try #require(try await sql.raw("SELECT withdrawn_at IS NOT NULL AS exists FROM im_v2.messages WHERE message_id = \(bind: message.messageID.uuidValue!)").first(decoding: ExistsRow.self))
            #expect(row.exists)
            #expect(try await sql.raw("SELECT count(*) AS value FROM im_v2.room_events WHERE event_id = \(bind: event.uuidValue!)").first(decoding: CountRow.self)?.value == 1)
            let newcomer = try await PostgresV2GroupEventLogStore(database: database).pull(roomID: roomID, actorUserID: .init(uuid: memberThreeUUID), afterRoomSequence: 0, pageSize: 10)
            #expect(newcomer.events.isEmpty)
            for table in ["user_sync_log"] {
                #expect(try await count("im_v2." + table, on: sql) == 0)
            }
        }

    }

    @Test("message mutations use the original acceptance fact", arguments: ["direct", "directRich", "directReviewed", "standardGroup", "largeGroup"], ["edit", "withdraw", "reaction"])
    func messageMutationAcceptanceFact(_ kind: String, operation: String) async throws {
        let mode: V2GroupCapacityClass = kind == "largeGroup" ? .large : .standard
        try await withForwardOwnerDatabases(mode: mode) { database, _, sql, _, _ in
            let now = Date(timeIntervalSince1970: 1_750_000_000)
            let profile = try forwardImportTestProfile()
            let destination: RoomID
            if kind.hasPrefix("direct") {
                let direct = try V2DirectMessagingService(store: PostgresV2DirectMessagingStore(database: database),
                    capacityProfile: profile, roomShardID: "room-a", now: { now })
                guard case .opened(let room) = try await direct.open(actorUserID: senderID,
                    operationID: .init(uuid: UUID()), targetUserID: .init(uuid: memberTwoUUID)) else { throw V2RoomWriteStoreError.corruptPersistenceState }
                destination = room.roomID
                // A preceding message must not supply this message’s acceptance identity.
                let precedingStore = PostgresV2RoomWriteStore(database: database,
                    strangerMessagePolicy: try .init(maximumMessagesPerWindow: 10, window: 86_400), contentReviewMode: .disabled)
                let precedingSender = try V2SendMessageService(store: precedingStore, capacityProfile: profile, limits: .init(maxUTF8Bytes: 64), now: { now })
                guard case .accepted = try await precedingSender.send(.init(roomID: destination,
                    actorUserID: senderID, clientMessageID: .init(uuid: UUID()), text: "preceding message")) else { throw V2RoomWriteStoreError.corruptPersistenceState }
            } else { destination = roomID }
            let writer = PostgresV2RoomWriteStore(database: database,
                strangerMessagePolicy: try .init(maximumMessagesPerWindow: 10, window: 86_400), contentReviewMode: kind == "directReviewed" ? .enabled : .disabled)
            let sender = try V2SendMessageService(store: writer, capacityProfile: profile, limits: .init(maxUTF8Bytes: 64), now: { now })
            let entities: [V2MessageEntity] = kind.hasSuffix("Rich") ? [try .init(offsetUTF16: 0, lengthUTF16: 8, kind: .bold)] : []
            guard case .accepted(let message) = try await sender.send(.init(roomID: destination,
                actorUserID: senderID, clientMessageID: .init(uuid: UUID()), text: "accepted message", entities: entities)) else { throw V2RoomWriteStoreError.corruptPersistenceState }
            let acceptedEvent = try #require(message.sourceEventID?.uuidValue)
            #expect(try await sql.raw("""
                SELECT EXISTS (
                    SELECT 1 FROM im_v2.message_send_completions
                    WHERE message_id = \(bind: message.messageID.uuidValue!)
                      AND event_id = \(bind: acceptedEvent)
                      AND room_sequence = \(bind: Int64(message.roomSequence))
                ) AS exists
                """).first(decoding: ExistsRow.self)?.exists == true)
            if kind.hasPrefix("direct") {
                let storage = try #require(try await sql.raw("SELECT accepted_event_storage AS value FROM im_v2.messages WHERE message_id=\(bind: message.messageID.uuidValue!)").first(decoding: StringValueRow.self)).value
                #expect(storage == (kind == "directReviewed" ? "room_event" : "message_row"))
            }
            let operationID = UUID()
            let event = try await mutateAcceptedMessage(database: database, room: destination, message: message.messageID, operation: operation, operationID: operationID)
            let page = try await PostgresV2GroupEventLogStore(database: database).pull(roomID: destination,
                actorUserID: .init(uuid: memberTwoUUID), afterRoomSequence: message.roomSequence - 1, pageSize: 20)
            #expect(page.events.map(\.sourceEventID) == [try #require(message.sourceEventID), event])
            #expect(page.events.map(\.roomSequence) == [message.roomSequence, message.roomSequence + 1])
            let originalPayload = try #require(page.events.first?.payload)
            let original = try #require(JSONSerialization.jsonObject(with: originalPayload) as? [String: Any])
            #expect(original["text"] as? String == "accepted message")
            #expect(!page.hasMore)
            // Completed-operation replay remains available without the send receipt.
            // No production cleanup deletes receipts; deletion here injects loss.
            try await sql.raw("DELETE FROM im_v2.message_send_completions WHERE message_id=\(bind: message.messageID.uuidValue!)").run()
            let eventsBeforeReplay = try await count("im_v2.room_events", on: sql)
            #expect(try await mutateAcceptedMessage(database: database, room: destination, message: message.messageID,
                operation: operation, operationID: operationID, replay: true) == event)
            #expect(try await count("im_v2.room_events", on: sql) == eventsBeforeReplay)
        }
    }

    @Test("new message mutations cannot guess a missing acceptance fact", arguments: [V2GroupCapacityClass.standard, .large], ["edit", "withdraw", "reaction"])
    func messageMutationRequiresAcceptance(_ mode: V2GroupCapacityClass, operation: String) async throws {
        try await withForwardOwnerDatabases(mode: mode) { database, _, sql, _, _ in
            let now = Date(timeIntervalSince1970: 1_750_000_000)
            let sender = try V2SendMessageService(store: PostgresV2RoomWriteStore(database: database),
                capacityProfile: forwardImportTestProfile(), limits: .init(maxUTF8Bytes: 64), now: { now })
            guard case .accepted(let message) = try await sender.send(.init(roomID: roomID, actorUserID: senderID,
                clientMessageID: .init(uuid: UUID()), text: "accepted authority")) else { throw V2RoomWriteStoreError.corruptPersistenceState }
            try await sql.raw("DELETE FROM im_v2.message_send_completions WHERE message_id=\(bind: message.messageID.uuidValue!)").run()
            let tables = ["rooms", "messages", "room_events", "room_admission", "shard_admission_pools",
                "message_edit_operations", "message_withdrawal_operations", "message_reaction_operations", "message_reactions", "message_projection_state_values"]
            var before: [String] = []
            for table in tables {
                before.append(try #require(try await sql.raw("SELECT COALESCE(jsonb_agg(to_jsonb(t) ORDER BY to_jsonb(t)::text), '[]'::jsonb)::text AS value FROM im_v2.\(ident: table) t").first(decoding: StringValueRow.self)).value)
            }
            await #expect(throws: V2MessageAcceptanceFactError.self) {
                try await mutateAcceptedMessage(database: database, room: roomID, message: message.messageID,
                    operation: operation, operationID: UUID())
            }
            for (index, table) in tables.enumerated() {
                let after = try #require(try await sql.raw("SELECT COALESCE(jsonb_agg(to_jsonb(t) ORDER BY to_jsonb(t)::text), '[]'::jsonb)::text AS value FROM im_v2.\(ident: table) t").first(decoding: StringValueRow.self)).value
                #expect(after == before[index], "Unexpected mutation of \(table)")
            }
        }
    }

    @Test("Argon2id HTTP authentication persists exact inputs and fences concurrent credential replacement")
    func passwordHTTPFullInputAndLegacyIsolation() async throws {
        try await withForwardOwnerDatabases(mode: .standard) { database, _, sql, _, _ in
            let app = try await Application(.testing)
            let worker = V2PasswordHashWorker()
            let changing = PasswordCredentialTransitionWorker(worker: worker)
            let store = V2PostgresPasswordAccountStore(database: database)
            let issuer = try V2HMACAccountAssertionIssuer(rawKey: Data(repeating: 8, count: 32))
            let limiter = V2PostgresPasswordLoginAttemptLimiter(database: database,
                policy: try .init(maximumFailures: 10, window: 900, lockout: 900))
            V2PasswordAccountRoutes(store: store, assertionIssuer: issuer, passwords: changing,
                loginAttemptLimiter: limiter).register(on: app)
            do {
                let password = String(repeating: "x", count: 1023) + "a"
                let device = UUID().uuidString
                try await app.testing { client in
                    let response = try await client.send(.post, to: "v2/account-auth/password/register", beforeSend: { request in
                        try request.content.encode(V2PasswordAccountHTTPRequest(accountHandle: "argon-account", password: password,
                            deviceID: device, publicHandle: "argon_account", displayName: "Argon account"))
                    })
                    #expect(response.status == .ok)
                }
                let initial = try #require(try await store.passwordCredential(for: "argon-account"))
                #expect(V2PasswordHashPolicy.supports(initial.passwordHash))
                @Sendable func assertion(_ candidate: String, status: HTTPResponse.Status, handle: String = "argon-account") async throws {
                    try await app.testing { client in
                        let response = try await client.send(.post, to: "v2/account-auth/password/assertion", beforeSend: { request in
                            try request.content.encode(V2PasswordAccountHTTPRequest(accountHandle: handle, password: candidate, deviceID: device))
                        })
                        #expect(response.status == status)
                    }
                }
                try await assertion(String(password.dropLast()) + "b", status: .unauthorized)
                try await sql.raw("""
                    CREATE FUNCTION im_v2.password_test_audit_failure() RETURNS trigger AS $$
                    BEGIN
                        IF NEW.outcome = 'assertion_succeeded' THEN RAISE EXCEPTION 'password audit fault'; END IF;
                        RETURN NEW;
                    END;
                    $$ LANGUAGE plpgsql
                    """).run()
                try await sql.raw("CREATE TRIGGER password_test_audit_failure BEFORE INSERT ON im_v2.account_password_authentication_audit FOR EACH ROW EXECUTE FUNCTION im_v2.password_test_audit_failure()").run()
                try await assertion(password, status: .serviceUnavailable)
                #expect(try await count("im_v2.account_password_login_rate_limits", on: sql) == 1)
                #expect(try await sql.raw("SELECT COUNT(*) AS value FROM im_v2.account_password_authentication_audit WHERE outcome='assertion_succeeded'").first(decoding: CountRow.self)?.value == 0)
                try await sql.raw("DROP TRIGGER password_test_audit_failure ON im_v2.account_password_authentication_audit").run()
                try await assertion(password, status: .ok)
                #expect(try await count("im_v2.account_password_login_rate_limits", on: sql) == 0)
                let replacementPassword = "independently-reset-password"
                let replacement = try await worker.hash(replacementPassword)
                await changing.arm {
                    try await sql.raw("UPDATE im_v2.account_password_credentials SET password_hash=\(bind: replacement) WHERE account_handle='argon-account'").run()
                }
                // The old password did verify, but the credential changed
                // before successful-authentication audit/assertion publication.
                try await assertion(password, status: .unauthorized)
                #expect(try await sql.raw("SELECT COUNT(*) AS value FROM im_v2.account_password_authentication_audit WHERE outcome='assertion_succeeded'").first(decoding: CountRow.self)?.value == 1)
                #expect(try await store.passwordCredential(for: "argon-account")?.passwordHash == replacement)
                #expect(try await !store.completeAuthentication(accountHandle: "argon-account", expected: initial, deviceID: .init(device)))
                try await assertion(replacementPassword, status: .ok)
                // Existing bcrypt remains byte-for-byte intact and restricted;
                // even its matching input must not issue a password assertion.
                let legacy = "$2y$04$oIbUwndVVxRsumcBTvG/guzksLLNSB9GWHMzSydohzjWxRGFVwj3m"
                try await sql.raw("UPDATE im_v2.account_password_credentials SET password_hash=\(bind: legacy) WHERE account_handle='argon-account'").run()
                try await assertion(replacementPassword, status: .unauthorized)
                try await assertion(replacementPassword, status: .unauthorized, handle: "unknown-account")
                #expect(try await store.passwordCredential(for: "argon-account")?.passwordHash == legacy)
                #expect(try await sql.raw("SELECT COUNT(*) AS value FROM im_v2.account_password_authentication_audit WHERE outcome='assertion_succeeded'").first(decoding: CountRow.self)?.value == 2)
                await #expect(throws: V2PasswordAccountStoreError.unavailable) {
                    _ = try await store.register(accountHandle: "legacy-new", passwordHash: legacy,
                        publicHandle: "legacy_new", displayName: "Legacy", deviceID: .init(device))
                }
                #expect(try await count("im_v2.account_password_credentials", on: sql) == 1)
                try await worker.shutdown()
                try await app.shutdown()
            } catch {
                try? await worker.shutdown(); try? await app.shutdown(); throw error
            }
        }
    }

    @Test("foreground forwarding rechecks both owners at acceptance and result publication", arguments: ["source", "target"], [false, true])
    func foregroundForwardOwnerStageChange(_ changed: String, afterAcceptance: Bool) async throws {
        try await withForwardOwnerDatabases(mode: .standard) { _, owner, _, sql, sourceRoom in
            let now = Date(timeIntervalSince1970: 1_750_000_000)
            let profile = try forwardImportTestProfile(), limits = try V2MessageCommandLimits(maxUTF8Bytes: 64)
            let write = PostgresV2RoomWriteStore(database: owner)
            let sender = V2SendMessageService(store: write, capacityProfile: profile, limits: limits, now: { now })
            guard case .accepted(let source) = try await sender.send(.init(roomID: sourceRoom, actorUserID: senderID, clientMessageID: .init(uuid: UUID()), text: "stage change")) else { throw V2RoomWriteStoreError.corruptPersistenceState }
            let direct = try V2DirectMessagingService(store: PostgresV2DirectMessagingStore(database: owner), capacityProfile: profile, roomShardID: "room-b", now: { now })
            let actor = UserID(uuid: memberTwoUUID)
            guard case .opened(let target) = try await direct.open(actorUserID: actor, operationID: .init(uuid: UUID()), targetUserID: senderID) else { throw V2RoomWriteStoreError.corruptPersistenceState }
            let changing = changed == "source" ? sourceRoom : target.roomID
            let adapter = ForegroundOwnerTransitionStore(store: write, afterAcceptance: afterAcceptance) {
                try await sql.raw("UPDATE im_v2.rooms SET owner_epoch=1 WHERE room_id=\(bind: changing.uuidValue!)").run()
            }
            let service = V2ForwardMessagesService(database: owner, writeStore: adapter, capacityProfile: profile, limits: limits, now: { now })
            let command = try V2ForwardMessagesCommand(operationID: .init(uuid: UUID()), sources: [.init(roomID: sourceRoom, messageID: source.messageID, revision: .init(1))], targetRoomIDs: [target.roomID])
            let stale = try [sourceRoom: V2RoomShardRoute(shardID: "room-b", epoch: 0), target.roomID: V2RoomShardRoute(shardID: "room-b", epoch: 0)]
            let failed = try await service.forwardOwnerValidated(actorUserID: actor, command: command, ownerRoutes: stale)
            #expect(failed.count == 1 && failed[0].errorCode == "UNAVAILABLE")
            #expect(try await count("im_v2.messages", on: sql) == (afterAcceptance ? 2 : 1))
            #expect(try await count("im_v2.message_forward_operations", on: sql) == 1)
            #expect(try await sql.raw("SELECT COUNT(*) AS value FROM im_v2.message_forward_operations WHERE result_message_id IS NOT NULL").first(decoding: CountRow.self)?.value == 0)
            let stableClient = try #require(try await sql.raw("SELECT target_client_message_id::text AS value FROM im_v2.message_forward_operations").first(decoding: StringValueRow.self)).value
            await #expect(throws: V2RoomOwnerFenceError.ownerChanged) {
                _ = try await service.forwardOwnerValidated(actorUserID: actor, command: command, ownerRoutes: stale)
            }
            var current = stale
            current[changing] = try .init(shardID: "room-b", epoch: 1)
            let routes = current
            let accepted = try await service.forwardOwnerValidated(actorUserID: actor, command: command, ownerRoutes: routes)
            #expect(accepted.count == 1 && accepted[0].errorCode == nil)
            let repeats = try await withThrowingTaskGroup(of: [V2ForwardMessageResult].self) { group in
                for _ in 0..<8 {
                    group.addTask { try await service.forwardOwnerValidated(actorUserID: actor, command: command, ownerRoutes: routes) }
                }
                var results: [[V2ForwardMessageResult]] = []
                for try await result in group { results.append(result) }
                return results
            }
            #expect(repeats.count == 8 && repeats.allSatisfy { $0 == accepted })
            #expect(try await count("im_v2.messages", on: sql) == 2)
            #expect(try await count("im_v2.message_forward_operations", on: sql) == 1)
            #expect(try await sql.raw("SELECT target_client_message_id::text AS value FROM im_v2.message_forward_operations").first(decoding: StringValueRow.self)?.value == stableClient)
            #expect(try await sql.raw("SELECT COUNT(*) AS value FROM im_v2.message_forward_operations WHERE result_message_id IS NOT NULL").first(decoding: CountRow.self)?.value == 1)
            // Accepted pair evidence survives later content changes, but only
            // after its current source and target owners have been checked.
            try await sql.raw("UPDATE im_v2.messages SET content_revision=2 WHERE message_id=\(bind: source.messageID.uuidValue!)").run()
            #expect(try await service.forwardOwnerValidated(actorUserID: actor, command: command, ownerRoutes: routes) == accepted)
        }
    }

    @Test("colocated foreground forwards preserve source and target owner epochs", arguments: ["source", "target"])
    func foregroundForwardOwnerFence(_ changed: String) async throws {
        try await withForwardOwnerDatabases(mode: .standard) { control, owner, sql, ownerSQL, sourceRoom in
            let now = Date(timeIntervalSince1970: 1_750_000_000)
            let profile = try forwardImportTestProfile(), limits = try V2MessageCommandLimits(maxUTF8Bytes: 64)
            let write = PostgresV2RoomWriteStore(database: owner)
            let send = V2SendMessageService(store: write, capacityProfile: profile, limits: limits, now: { now })
            guard case .accepted(let source) = try await send.send(.init(roomID: sourceRoom, actorUserID: senderID, clientMessageID: .init(uuid: UUID()), text: "foreground owner")) else { throw V2RoomWriteStoreError.corruptPersistenceState }
            let direct = try V2DirectMessagingService(store: PostgresV2DirectMessagingStore(database: owner), capacityProfile: profile, roomShardID: "room-b", now: { now })
            guard case .opened(let target) = try await direct.open(actorUserID: .init(uuid: memberTwoUUID), operationID: .init(uuid: UUID()), targetUserID: senderID) else { throw V2RoomWriteStoreError.corruptPersistenceState }
            let changingRoom = changed == "source" ? sourceRoom : target.roomID
            try await sql.raw("INSERT INTO im_v2.room_owner_routes(room_id,room_shard_id,route_epoch,created_at,updated_at) VALUES (\(bind: sourceRoom.uuidValue!), 'room-b', 0, \(bind: now), \(bind: now)), (\(bind: target.roomID.uuidValue!), 'room-b', 0, \(bind: now), \(bind: now)) ON CONFLICT (room_id) DO UPDATE SET room_shard_id = EXCLUDED.room_shard_id, route_epoch = EXCLUDED.route_epoch, updated_at = EXCLUDED.updated_at").run()
            try await sql.raw("UPDATE im_v2.room_owner_routes SET route_epoch=1 WHERE room_id=\(bind: changingRoom.uuidValue!)").run()
            let local = V2ForwardMessagesService(database: owner, writeStore: write, capacityProfile: profile, limits: limits, now: { now })
            func routed() throws -> V2RoutedForwardMessagesService {
                try .init(router: V2CachedRoomShardRouter(source: V2PostgresRoomShardRouter(database: control)), owners: ["room-b": local, "alias": local], physicalStoreKeyByShard: ["room-b": "one", "alias": "one"])
            }
            func command() throws -> V2ForwardMessagesCommand {
                try .init(operationID: .init(uuid: UUID()), sources: [.init(roomID: sourceRoom, messageID: source.messageID, revision: .init(1))], targetRoomIDs: [target.roomID])
            }
            let original = try command()
            await #expect(throws: V2RoomOwnerFenceError.ownerChanged) { _ = try await routed().forward(actorUserID: .init(uuid: memberTwoUUID), command: original) }
            #expect(try await count("im_v2.messages", on: ownerSQL) == 1)
            #expect(try await count("im_v2.message_forward_operations", on: ownerSQL) == 0)
            guard try await count("im_v2.messages", on: ownerSQL) == 1 else { return }
            try await sql.raw("UPDATE im_v2.room_owner_routes SET route_epoch=0 WHERE room_id=\(bind: changingRoom.uuidValue!)").run()
            let cached = try routed()
            let accepted = try await cached.forward(actorUserID: .init(uuid: memberTwoUUID), command: original)
            #expect(accepted.count == 1 && accepted[0].errorCode == nil)
            try await ownerSQL.raw("UPDATE im_v2.rooms SET owner_epoch=1 WHERE room_id=\(bind: changingRoom.uuidValue!)").run()
            try await sql.raw("UPDATE im_v2.room_owner_routes SET route_epoch=1 WHERE room_id=\(bind: changingRoom.uuidValue!)").run()
            for input in [original, try command()] {
                await #expect(throws: V2RoomOwnerFenceError.ownerChanged) { _ = try await cached.forward(actorUserID: .init(uuid: memberTwoUUID), command: input) }
            }
            #expect(try await routed().forward(actorUserID: .init(uuid: memberTwoUUID), command: original) == accepted)
            #expect(try await count("im_v2.messages", on: ownerSQL) == 2)
            #expect(try await count("im_v2.message_forward_operations", on: ownerSQL) == 1)
            #expect(try await count("im_v2.message_forward_operations", on: sql) == 0)
            try await ownerSQL.raw("UPDATE im_v2.rooms SET room_shard_id='retired' WHERE room_id=\(bind: changingRoom.uuidValue!)").run()
            await #expect(throws: V2RoomOwnerFenceError.ownerChanged) { _ = try await routed().forward(actorUserID: .init(uuid: memberTwoUUID), command: original) }
            try await ownerSQL.raw("UPDATE im_v2.rooms SET room_shard_id='room-b' WHERE room_id=\(bind: changingRoom.uuidValue!)").run()
            let wrongLocal = V2ForwardMessagesService(database: control, writeStore: PostgresV2RoomWriteStore(database: control), capacityProfile: profile, limits: limits, now: { now })
            let wrong = try V2RoutedForwardMessagesService(router: V2PostgresRoomShardRouter(database: control), owners: ["room-b": wrongLocal])
            await #expect(throws: V2RoomOwnerFenceError.ownerChanged) { _ = try await wrong.forward(actorUserID: .init(uuid: memberTwoUUID), command: original) }
            let barrier = InviteImportTestBarrier()
            let holder = Task {
                try await owner.transaction { transaction in
                    let locked = try #require(transaction as? any SQLDatabase)
                    try await locked.raw("SELECT room_id FROM im_v2.rooms WHERE room_id=\(bind: changingRoom.uuidValue!) FOR NO KEY UPDATE").run()
                    await barrier.hold()
                    try await locked.raw("UPDATE im_v2.rooms SET owner_epoch=2 WHERE room_id=\(bind: changingRoom.uuidValue!)").run()
                }
            }
            await barrier.waitUntilHeld()
            let queued = Task { try await routed().forward(actorUserID: .init(uuid: memberTwoUUID), command: original) }
            do {
                var waiting = false
                for _ in 0..<1000 {
                    waiting = try await ownerSQL.raw("SELECT COUNT(*) AS value FROM pg_stat_activity WHERE datname=current_database() AND wait_event_type='Lock' AND query LIKE '%owner_epoch%' AND query LIKE '%FOR UPDATE%'").first(decoding: CountRow.self)?.value == 1
                    if waiting { break }
                    try await Task.sleep(for: .milliseconds(10))
                }
                #expect(waiting)
                await barrier.release(); try await holder.value
                await #expect(throws: V2RoomOwnerFenceError.ownerChanged) { _ = try await queued.value }
            } catch {
                await barrier.release(); _ = try? await holder.value; _ = try? await queued.value
                throw error
            }
            #expect(try await count("im_v2.messages", on: ownerSQL) == 2)
            #expect(try await count("im_v2.message_forward_operations", on: ownerSQL) == 1)
            try await sql.raw("UPDATE im_v2.room_owner_routes SET route_epoch=2 WHERE room_id=\(bind: changingRoom.uuidValue!)").run()
        }
    }

    @Test("forward inbox receiving waits for the target owner before creating durable work")
    func forwardInboxReceiveOwnerFenceWait() async throws {
        try await withForwardOwnerDatabases(mode: .standard) { sourceDB, targetDB, _, targetSQL, target in
            let now = Date(timeIntervalSince1970: 1_750_000_000)
            let profile = try forwardImportTestProfile()
            let send = try V2SendMessageService(store: PostgresV2RoomWriteStore(database: sourceDB), capacityProfile: profile, limits: .init(maxUTF8Bytes: 64), now: { now })
            guard case .accepted(let source) = try await send.send(.init(roomID: roomID, actorUserID: senderID, clientMessageID: .init(uuid: UUID()), text: "receive epoch")) else { throw V2ForwardInboxError.corruptPersistenceState }
            let export = try await PostgresV2ForwardExportStore(database: sourceDB).prepare(actorUserID: .init(uuid: memberTwoUUID), operationID: .init(uuid: UUID()), source: .init(roomID: roomID, messageID: source.messageID, revision: .init(1)), sourceRoute: .init(shardID: "room-a", epoch: 0), targetRoomID: target, targetRoute: .init(shardID: "room-b", epoch: 0), now: now)
            let inbox = PostgresV2ForwardInboxStore(database: targetDB)
            let barrier = InviteImportTestBarrier()
            let holder = Task {
                try await targetDB.transaction { transaction in
                    let sql = try #require(transaction as? any SQLDatabase)
                    try await sql.raw("SELECT room_id FROM im_v2.rooms WHERE room_id=\(bind: target.uuidValue!) FOR NO KEY UPDATE").run()
                    await barrier.hold()
                    try await sql.raw("UPDATE im_v2.rooms SET owner_epoch=1 WHERE room_id=\(bind: target.uuidValue!)").run()
                }
            }
            await barrier.waitUntilHeld()
            let receive = Task { try await inbox.receive(export, now: now) }
            do {
                var waiting = false
                for _ in 0..<1000 {
                    waiting = try await targetSQL.raw("SELECT COUNT(*) AS value FROM pg_stat_activity WHERE datname=current_database() AND wait_event_type='Lock' AND query LIKE '%owner_epoch%' AND query LIKE '%FOR SHARE%'").first(decoding: CountRow.self)?.value == 1
                    if waiting { break }
                    try await Task.sleep(for: .milliseconds(10))
                }
                #expect(waiting)
                await barrier.release(); try await holder.value
                await #expect(throws: V2ForwardInboxError.ownerChanged) { try await receive.value }
            } catch {
                await barrier.release(); _ = try? await holder.value; _ = try? await receive.value
                throw error
            }
            #expect(try await count("im_v2.message_forward_inbox", on: targetSQL) == 0)
            #expect(try await count("im_v2.messages", on: targetSQL) == 0)
        }
    }

    @Test("shared receipt batches isolate owner errors and keep scalar replay consistent", arguments: [V2GroupCapacityClass.standard, .large])
    func readReceiptOwnerMixedBatch(_ mode: V2GroupCapacityClass) async throws {
        try await withForwardOwnerDatabases(mode: mode) { control, owner, sql, ownerSQL, room in
            let now = Date(timeIntervalSince1970: 1_750_000_000)
            let service = try V2SendMessageService(store: PostgresV2RoomWriteStore(database: owner), capacityProfile: forwardImportTestProfile(), limits: .init(maxUTF8Bytes: 64), now: { now })
            var lastMessageID: MessageID?
            for _ in 0..<2 {
                guard case .accepted(let message) = try await service.send(.init(roomID: room, actorUserID: senderID, clientMessageID: .init(uuid: UUID()), text: "receipt owner")) else { throw V2ReadReceiptStoreError.corruptPersistenceState }
                lastMessageID = message.messageID
            }
            let messageID = try #require(lastMessageID)
            try await ownerSQL.raw("DELETE FROM im_v2.public_user_profiles").run()
            try await ownerSQL.raw("UPDATE im_v2.rooms SET owner_epoch=2 WHERE room_id=\(bind: room.uuidValue!)").run()
            let ownerStore = PostgresV2ReadReceiptStore(database: owner)
            let current = try V2RoomShardRoute(shardID: "room-b", epoch: 2)
            let stale = try V2RoomShardRoute(shardID: "room-b", epoch: 1)
            let missingRoom = RoomID(uuid: UUID())
            func request(_ user: UserID, _ sequence: UInt64, roomID: RoomID? = nil) throws -> V2ReadReceiptRecordRequest {
                .init(command: try .init(roomID: roomID ?? room, actorUserID: user, operationID: .init(uuid: UUID()), readThroughRoomSequence: sequence), now: now)
            }
            let first = try request(.init(uuid: memberTwoUUID), 1)
            let expired = try request(.init(uuid: memberTwoUUID), 2)
            let wrongShard = try request(.init(uuid: memberThreeUUID), 2)
            let missing = try request(.init(uuid: memberThreeUUID), 1, roomID: missingRoom)
            let overSequence = try request(.init(uuid: memberThreeUUID), 3)
            let outsider = try request(.init(uuid: UUID()), 1)
            let second = try request(.init(uuid: memberThreeUUID), 2)
            let results = try await ownerStore.recordGroupsOwnerValidated([
                .init(request: first, ownerRoute: current), .init(request: expired, ownerRoute: stale),
                .init(request: wrongShard, ownerRoute: .init(shardID: "wrong", epoch: 2)),
                .init(request: missing, ownerRoute: current), .init(request: overSequence, ownerRoute: current),
                .init(request: outsider, ownerRoute: current), .init(request: second, ownerRoute: current)
            ])
            #expect(results.count == 7)
            guard case .success(.handled(.recorded(let firstValue))) = results[0], case .success(.handled(.recorded(let secondValue))) = results[6] else { throw V2ReadReceiptStoreError.corruptPersistenceState }
            #expect(firstValue.readThroughRoomSequence == 1 && secondValue.readThroughRoomSequence == 2)
            #expect(Array(results[1...3]) == [.failure(.ownerChanged), .failure(.ownerChanged), .failure(.ownerChanged)])
            #expect(results[4] == .failure(.roomSequenceNotFound) && results[5] == .failure(.actorNotMember))
            #expect(try await ownerSQL.raw("SELECT COUNT(*) AS value FROM im_v2.read_receipt_operations").first(decoding: CountRow.self)?.value == 2)
            await #expect(throws: V2ReadReceiptStoreError.ownerChanged) { _ = try await ownerStore.recordGroupOwnerValidated(command: first.command, ownerRoute: stale, now: now) }
            let conflicting = try V2RecordReadReceiptCommand(roomID: room, actorUserID: first.command.actorUserID, operationID: first.command.operationID, readThroughRoomSequence: 2)
            #expect(try await ownerStore.recordGroupOwnerValidated(command: conflicting, ownerRoute: current, now: now) == .handled(.idempotencyConflict))
            // Production records receipts in one room-actor activation turn and
            // filters owner reader candidates with current control privacy.
            let controlStore = PostgresV2ReadReceiptStore(database: control)
            try await withRoomActivation(database: owner, roomID: room, shardID: "room-b", epoch: 2) { token in
                let replayed = try await ownerStore.recordBatchActivationValidated([first, second], scope: try .init(tokens: [token]))
                guard case .success(.idempotent) = replayed[0], case .success(.idempotent) = replayed[1] else { throw V2ReadReceiptStoreError.corruptPersistenceState }
                let raced = try request(.init(uuid: memberTwoUUID), 2)
                let races = try await withThrowingTaskGroup(of: V2ReadReceiptOutcome.self) { tasks in
                    for i in 0..<20 {
                        tasks.addTask {
                            if i.isMultiple(of: 2) { return try await ownerStore.recordActivationValidated(command: raced.command, token: token, now: now) }
                            let values = try await ownerStore.recordBatchActivationValidated([raced], scope: try .init(tokens: [token]))
                            switch try #require(values.first) { case .success(let value): return value; case .failure(let error): throw error }
                        }
                    }
                    var values: [V2ReadReceiptOutcome] = []
                    for try await value in tasks { values.append(value) }
                    return values
                }
                #expect(races.filter { if case .recorded = $0 { true } else { false } }.count == 1)
                #expect(races.filter { if case .idempotent = $0 { true } else { false } }.count == 19)
                @Sendable func visibleReaders() async throws -> [UserID] {
                    let page = try await ownerStore.readerCandidates(roomID: room, messageID: messageID, actorUserID: senderID, cursor: nil, pageSize: 10)
                    let candidates = page.candidates.map(\.userID)
                    let identities = try await controlStore.visibleReaderIdentities(actorUserID: senderID, candidateUserIDs: candidates)
                    return candidates.filter { identities[$0] != nil }
                }
                #expect(Set(try await visibleReaders()) == [UserID(uuid: memberTwoUUID), UserID(uuid: memberThreeUUID)])
                try await sql.raw("INSERT INTO im_v2.user_read_receipt_preferences(user_id, allows_group_read_receipts, updated_at) VALUES (\(bind: memberThreeUUID), false, \(bind: now)) ON CONFLICT(user_id) DO UPDATE SET allows_group_read_receipts=false").run()
                #expect(try await visibleReaders() == [UserID(uuid: memberTwoUUID)])
            }
            #expect(try await ownerSQL.raw("SELECT COUNT(*) AS value FROM im_v2.read_receipt_operations").first(decoding: CountRow.self)?.value == 3)
            #expect(try await ownerSQL.raw("SELECT COUNT(*) AS value FROM im_v2.public_user_profiles").first(decoding: CountRow.self)?.value == 0)
            #expect(try await sql.raw("SELECT COUNT(*) AS value FROM im_v2.read_receipt_operations").first(decoding: CountRow.self)?.value == 0)
            print("PASS shared receipt owner batch \(mode): per-row epoch/shard/missing/domain errors; scalar/batch twenty retries commit once; control privacy retained")
        }
    }

    @Test("moderation fences the selected owner before business and audit replay", arguments: [V2GroupCapacityClass.standard, .large], ["redact", "mute", "remove", "safety_redact", "freeze", "unfreeze"])
    func routedModerationOwnerEpochFence(_ mode: V2GroupCapacityClass, _ kind: String) async throws {
        try await withForwardOwnerDatabases(mode: mode) { control, owner, sql, ownerSQL, room in
            let now = Date(timeIntervalSince1970: 1_750_000_000)
            try await ownerSQL.raw("UPDATE im_v2.room_memberships SET role='owner' WHERE user_id=\(bind: senderUUID)").run()
            try await ownerSQL.raw("UPDATE im_v2.rooms SET membership_revision=1, group_permission_revision=1 WHERE room_id=\(bind: room.uuidValue!)").run()
            let profile = try forwardImportTestProfile()
            let send = V2SendMessageService(store: PostgresV2RoomWriteStore(database: owner), capacityProfile: profile,
                limits: try .init(maxUTF8Bytes: 64), now: { now })
            guard case .accepted(let message) = try await send.send(.init(roomID: room, actorUserID: senderID, clientMessageID: .init(uuid: UUID()), text: "original")) else {
                throw V2RoomWriteStoreError.corruptPersistenceState
            }
            try await ownerSQL.raw("DELETE FROM im_v2.public_user_profiles").run()
            try await sql.raw("INSERT INTO im_v2.room_owner_routes(room_id,room_shard_id,route_epoch,created_at,updated_at) VALUES (\(bind: room.uuidValue!), 'room-b', 1, \(bind: now), \(bind: now)) ON CONFLICT (room_id) DO UPDATE SET room_shard_id = EXCLUDED.room_shard_id, route_epoch = EXCLUDED.route_epoch, updated_at = EXCLUDED.updated_at").run()
            let router = V2PostgresRoomShardRouter(database: control)
            let operation = UUID()
            let safetyActor = UserID(uuid: UUID())
            if kind == "unfreeze" { try await ownerSQL.raw("UPDATE im_v2.rooms SET frozen_at=\(bind: now), frozen_by_user_id=\(bind: safetyActor.uuidValue!) WHERE room_id=\(bind: room.uuidValue!)").run() }
            @Sendable func run(_ route: any V2RoomShardRouting, on database: any Database, operationID: UUID, colocated: Bool = false, local: Bool = false) async throws -> String {
                let ownerStore = PostgresV2ModerationStore(database: database)
                let stores = colocated ? ["room-b": ownerStore, "colocated": ownerStore] : ["room-b": ownerStore]
                let routed = try V2RoutedModerationStore(router: route, stores: stores,
                    physicalStoreKeyByShard: colocated ? ["room-b": "physical-owner", "colocated": "physical-owner"] : nil)
                let action: V2ModerationAction = switch kind {
                case "mute": .muteMember; case "remove": .removeMember; case "freeze": .freezeRoom; case "unfreeze": .unfreezeRoom; default: .redactMessage
                }
                let result: V2ModerationOutcome
                if kind == "safety_redact" || kind == "freeze" || kind == "unfreeze" {
                    let selected: any V2TrustedSafetyModerationStore = local ? ownerStore : routed
                    let service = V2TrustedSafetyModerationService(store: selected, safetyActorUserID: safetyActor, capacityProfile: profile, now: { now })
                    result = try await service.apply(V2TrustedSafetyModeration(roomID: room, operationID: .init(uuid: operationID), action: action,
                        messageID: action == .redactMessage ? message.messageID : nil, expectedMessageRevision: action == .redactMessage ? 1 : nil,
                        reasonCode: .init("abuse_spam")))
                } else {
                    let selected: any V2ModerationStore = local ? ownerStore : routed
                    let service = V2ModerationService(store: selected, capacityProfile: profile, now: { now })
                    result = try await service.apply(.init(roomID: room, actorUserID: senderID, operationID: .init(uuid: operationID), action: action,
                        targetUserID: action == .redactMessage ? nil : .init(uuid: memberTwoUUID), messageID: action == .redactMessage ? message.messageID : nil,
                        muteUntil: action == .muteMember ? now.addingTimeInterval(300) : nil, reasonCode: .init("abuse_spam")))
                }
                switch result { case .applied: return "changed"; case .idempotent: return "replay"; default: return "other" }
            }
            let table = "moderation_operations"
            let before = try await ownerSQL.raw("SELECT to_jsonb(x)::text AS value FROM im_v2.rooms x WHERE room_id=\(bind: room.uuidValue!)").first(decoding: StringValueRow.self)?.value
            let sequenceBefore = try await ownerSQL.raw("SELECT room_sequence AS value FROM im_v2.rooms WHERE room_id=\(bind: room.uuidValue!)").first(decoding: CountRow.self)?.value
            await #expect(throws: V2RoomOwnerFenceError.ownerChanged) { _ = try await run(router, on: owner, operationID: operation) }
            #expect(try await ownerSQL.raw("SELECT COUNT(*) AS value FROM im_v2.\(unsafeRaw: table)").first(decoding: CountRow.self)?.value == 0)
            #expect(try await ownerSQL.raw("SELECT to_jsonb(x)::text AS value FROM im_v2.rooms x WHERE room_id=\(bind: room.uuidValue!)").first(decoding: StringValueRow.self)?.value == before)
            #expect(try await ownerSQL.raw("SELECT room_sequence AS value FROM im_v2.rooms WHERE room_id=\(bind: room.uuidValue!)").first(decoding: CountRow.self)?.value == sequenceBefore)
            #expect(try await ownerSQL.raw("SELECT COUNT(*) AS value FROM im_v2.moderation_audit_entries").first(decoding: CountRow.self)?.value == 0)
            try await sql.raw("UPDATE im_v2.room_owner_routes SET route_epoch=0 WHERE room_id=\(bind: room.uuidValue!)").run()
            let cached = V2CachedRoomShardRouter(source: router)
            _ = try await cached.route(for: room)
            let outcomes = try await withThrowingTaskGroup(of: String.self) { tasks in
                for _ in 0..<10 { tasks.addTask { try await run(router, on: owner, operationID: operation) } }
                var values: [String] = []
                for try await value in tasks { values.append(value) }
                return values
            }
            #expect(outcomes.filter { $0 == "changed" }.count == 1 && outcomes.filter { $0 == "replay" }.count == 9)
            try await ownerSQL.raw("UPDATE im_v2.rooms SET owner_epoch=1 WHERE room_id=\(bind: room.uuidValue!)").run()
            try await sql.raw("UPDATE im_v2.room_owner_routes SET route_epoch=1 WHERE room_id=\(bind: room.uuidValue!)").run()
            for op in [operation, UUID()] {
                await #expect(throws: V2RoomOwnerFenceError.ownerChanged) { _ = try await run(cached, on: owner, operationID: op, colocated: true) }
            }
            #expect(try await run(router, on: owner, operationID: operation) == "replay")
            try await ownerSQL.raw("UPDATE im_v2.rooms SET room_shard_id='retired-room-b' WHERE room_id=\(bind: room.uuidValue!)").run()
            await #expect(throws: V2RoomOwnerFenceError.ownerChanged) { _ = try await run(router, on: owner, operationID: operation) }
            try await ownerSQL.raw("UPDATE im_v2.rooms SET room_shard_id='room-b' WHERE room_id=\(bind: room.uuidValue!)").run()
            await #expect(throws: V2RoomOwnerFenceError.ownerChanged) { _ = try await run(router, on: control, operationID: operation) }
            try await sql.raw("UPDATE im_v2.room_owner_routes SET room_shard_id='unregistered' WHERE room_id=\(bind: room.uuidValue!)").run()
            await #expect(throws: V2RoomShardStorageRegistryError.unknownShardID) { _ = try await run(router, on: owner, operationID: operation) }
            try await sql.raw("UPDATE im_v2.room_owner_routes SET room_shard_id='room-b' WHERE room_id=\(bind: room.uuidValue!)").run()
            // This is an already committed operation. It must still wait for
            // the room fence, and observe epoch changes while acquiring it.
            let barrier = InviteImportTestBarrier()
            let holder = Task {
                try await owner.transaction { transaction in
                    let locked = try #require(transaction as? any SQLDatabase)
                    try await locked.raw("SELECT room_id FROM im_v2.rooms WHERE room_id=\(bind: room.uuidValue!) FOR UPDATE").run()
                    await barrier.hold()
                    try await locked.raw("UPDATE im_v2.rooms SET owner_epoch=2 WHERE room_id=\(bind: room.uuidValue!)").run()
                }
            }
            await barrier.waitUntilHeld()
            let replay = Task { try await run(router, on: owner, operationID: operation) }
            do {
                var waiting = false
                for _ in 0..<1000 {
                    waiting = try await ownerSQL.raw("SELECT COUNT(*) AS value FROM pg_stat_activity WHERE datname=current_database() AND wait_event_type='Lock' AND query LIKE '%SELECT room_shard_id, owner_epoch FROM im_v2.rooms%'").first(decoding: CountRow.self)?.value == 1
                    if waiting { break }
                    try await Task.sleep(for: .milliseconds(10))
                }
                #expect(waiting)
                guard waiting else { throw TestConfigurationError.schemaAlreadyExists }
                try await sql.raw("UPDATE im_v2.room_owner_routes SET route_epoch=2 WHERE room_id=\(bind: room.uuidValue!)").run()
                await barrier.release(); try await holder.value
                await #expect(throws: V2RoomOwnerFenceError.ownerChanged) { _ = try await replay.value }
            } catch {
                await barrier.release(); _ = try? await holder.value; _ = try? await replay.value
                throw error
            }
            #expect(try await run(router, on: owner, operationID: operation) == "replay")
            #expect(try await ownerSQL.raw("SELECT COUNT(*) AS value FROM im_v2.\(unsafeRaw: table)").first(decoding: CountRow.self)?.value == 1)
            #expect(try await ownerSQL.raw("SELECT room_sequence AS value FROM im_v2.rooms WHERE room_id=\(bind: room.uuidValue!)").first(decoding: CountRow.self)?.value == sequenceBefore.map { $0 + 1 })
            #expect(try await ownerSQL.raw("SELECT COUNT(*) AS value FROM im_v2.public_user_profiles").first(decoding: CountRow.self)?.value == 0)
            #expect(try await sql.raw("SELECT COUNT(*) AS value FROM im_v2.\(unsafeRaw: table)").first(decoding: CountRow.self)?.value == 0)
            #expect(try await ownerSQL.raw("SELECT COUNT(*) AS value FROM im_v2.moderation_audit_entries").first(decoding: CountRow.self)?.value == 1)
            #expect(try await sql.raw("SELECT COUNT(*) AS value FROM im_v2.moderation_audit_entries").first(decoding: CountRow.self)?.value == 0)
        }
    }

}

private actor PasswordCredentialTransitionWorker: V2PasswordHashing {
    let worker: V2PasswordHashWorker
    var transition: (@Sendable () async throws -> Void)?
    init(worker: V2PasswordHashWorker) { self.worker = worker }
    func arm(_ transition: @escaping @Sendable () async throws -> Void) { self.transition = transition }
    func hash(_ password: String) async throws -> String { try await worker.hash(password) }
    func verify(_ password: String, created digest: String) async throws -> Bool {
        let result = try await worker.verify(password, created: digest)
        if result, let transition {
            self.transition = nil
            try await transition()
        }
        return result
    }
}

private actor ForegroundOwnerTransitionStore: V2OwnerValidatedForwardMessageWriteStore {
    let store: PostgresV2RoomWriteStore
    let afterAcceptance: Bool
    var transition: (@Sendable () async throws -> Void)?

    init(store: PostgresV2RoomWriteStore, afterAcceptance: Bool, transition: @escaping @Sendable () async throws -> Void) {
        self.store = store; self.afterAcceptance = afterAcceptance; self.transition = transition
    }

    func acceptForwardOwnerValidated(request: V2RoomWriteRequest, sourceRoomID: RoomID,
        sourceOwnerRoute: V2RoomShardRoute, targetOwnerRoute: V2RoomShardRoute) async throws -> V2SendMessageOutcome {
        let action = transition; transition = nil
        if !afterAcceptance { try await action?() }
        let result = try await store.acceptForwardOwnerValidated(request: request, sourceRoomID: sourceRoomID,
            sourceOwnerRoute: sourceOwnerRoute, targetOwnerRoute: targetOwnerRoute)
        if afterAcceptance { try await action?() }
        return result
    }

    func accept(command: V2SendMessageCommand, capacityProfile: V2CapacityProfile,
        identifiers: V2AcceptanceIdentifiers, now: Date) async throws -> V2SendMessageOutcome {
        try await store.accept(command: command, capacityProfile: capacityProfile, identifiers: identifiers, now: now)
    }

}

private final class LegacyMediaTestClock: Sendable {
    private let value: Mutex<Date>
    init(_ now: Date) { value = Mutex(now) }
    func now() -> Date { value.withLock { $0 } }
    func advance(by seconds: TimeInterval) { value.withLock { $0 = $0.addingTimeInterval(seconds) } }
}
private actor LegacyMediaTransitionProvider: V2MediaObjectProvider {
    let transition: @Sendable () async throws -> Void
    private(set) var calls = 0
    init(transition: @escaping @Sendable () async throws -> Void) { self.transition = transition }
    func issueDownloadTarget(mediaID: MediaID, expiresAt: Date) async throws -> V2ResourceTransferPlan {
        calls += 1
        try await transition()
        return try resourceDownloadTestPlan(url: URL(string: "https://media.invalid/test")!, expiresAt: expiresAt)
    }
}
