import FluentPostgresDriver
import Foundation
import HTTPTypes
import IMV2Core
import IMV2Server
import IMV2ServerApplication
import IMV2ServerContracts
import IMV2ServerHTTP
import IMV2ServerInfrastructure
import Logging
import NIOPosix
import SQLKit
import Testing
import Vapor
import VaporTesting

@Suite("管理后台完整流程", .serialized)
struct V2AdminFlowTests {
    @Test("真实 PostgreSQL 与 Policy Owner：认证、查询、禁用、丢失响应恢复、审计和撤销",
          .enabled(if: ProcessInfo.processInfo.environment["IMV2_ADMIN_TEST_DATABASE_IS_DISPOSABLE"] == "1"))
    func completeFlow() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["IMV2_ADMIN_TEST_DATABASE_IS_DISPOSABLE"] == "1",
              let url = environment["IMV2_ADMIN_TEST_DATABASE_URL"] else {
            Issue.record("请使用 scripts/test_v2_admin.sh 在可丢弃数据库中运行此测试")
            return
        }
        let loops = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let resources = V2DatabaseResources(eventLoopGroup: loops, logger: Logger(label: "admin-test"), ownsEventLoopGroup: true)
        let passwords = V2PasswordHashWorker()
        resources.databases.use(try .postgres(url: url), as: .psql)
        let db = resources.database()
        let sql = try #require(db as? any SQLDatabase)
        let owners = PostgresV2PolicyOwnerDirectory(journal: .init(database: db), dispatcher: .init(database: db, projectionDelivery: TestProjectionDelivery()))
        let app = try await Application(.testing)
        do {
            let store = PostgresV2AdminStore(database: db)
            try await store.verifySchema()
            let password = "test-admin-password-only"
            let hash = try await passwords.hash(password)
            let accounts: [V2AdminAccount] = [.init(username: "operator", passwordHash: hash, role: .operatorRole), .init(username: "reader", passwordHash: hash, role: .viewer)]
            let responseLoss = ResponseLoss()
            let service = try V2AdminService(accounts: accounts, store: store, passwords: passwords) { principal, command in
                let result = try await V2PostgresAccountDisableService(operatorPrincipal: principal, policyOwners: owners).disable(command)
                if await responseLoss.consume() { throw V2AdminError.unavailable }
                return result
            }
            V2RedactedHTTPMiddlewareConfiguration.install(on: app)
            let databaseMonitor = PostgresV2AdminMonitoring(database: db)
            let monitoring = V2AdminMonitoringService(local: true, database: { try await databaseMonitor.observe() }, policy: {
                let state = await owners.pressure()
                return .init(closed: state.closed, owners: state.owners, inFlight: state.roots)
            })
            try V2AdminRoutes(service: service, origin: "https://admin.example.test", monitoring: monitoring).register(on: app)
            let firstUser = UUID(), secondUser = UUID(), device = UUID(), operation = UUID()
            for (id, handle) in [(firstUser, "admin_test_alice"), (secondUser, "admin_test_bob")] {
                try await sql.raw("INSERT INTO im_v2.public_user_profiles(user_id, public_handle, display_name, created_at, updated_at) VALUES (\(bind: id), \(bind: handle), '测试用户', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)").run()
            }
            try await sql.raw("INSERT INTO im_v2.auth_devices(user_id, device_id, created_at, last_active_at) VALUES (\(bind: firstUser), \(bind: device), CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)").run()
            try await app.testing { client in
                let anonymous = try await send(client, .get, "/users")
                #expect(anonymous.status == .unauthorized)
                #expect(try await send(client, .get, "/monitoring").status == .unauthorized)
                #expect(anonymous.headers[.cacheControl] == "no-store")
                #expect(try await send(client, .post, "/login", origin: "https://evil.example", body: LoginBody(username: "operator", password: password)).status == .forbidden)
                #expect(try await send(client, .post, "/login", body: LoginBody(username: "operator", password: "wrong-password-only")).status == .unauthorized)
                let readerLogin = try await send(client, .post, "/login", body: LoginBody(username: "reader", password: password))
                #expect(readerLogin.status == .ok)
                let readerCookie = try cookie(readerLogin)
                let monitorResponse = try await send(client, .get, "/monitoring", cookie: readerCookie)
                #expect(monitorResponse.headers[.cacheControl] == "no-store")
                let monitor = try await decode(V2AdminMonitoringSnapshot.self, monitorResponse)
                #expect(monitor.pendingDisables == "0")
                #expect(monitor.services.first { $0.id == "postgres" }?.status == .healthy)
                #expect(try await send(client, .post, "/users/\(firstUser)/disable", cookie: readerCookie, body: DisableBody(operationID: UUID(), reason: .policyEnforcement)).status == .forbidden)
                #expect(try await sql.raw("SELECT 1 FROM im_v2.account_disables WHERE user_id = \(bind: firstUser)").first() == nil)

                let login = try await send(client, .post, "/login", body: LoginBody(username: "operator", password: password))
                #expect(login.status == .ok)
                let operatorCookie = try cookie(login)
                let cookieHeader = try #require(login.headers[.setCookie])
                #expect(cookieHeader.contains("Secure") && cookieHeader.contains("HttpOnly") && cookieHeader.contains("SameSite=Strict"))
                let identity = try await decode(V2AdminIdentity.self, login)
                #expect(identity.role == .operatorRole && identity.username == "operator")
                let token = String(operatorCookie.split(separator: "=", maxSplits: 1)[1])
                // 新服务实例继续使用数据库会话；密码或权限变更立即拒绝旧会话。
                let restarted = try V2AdminService(accounts: accounts, store: PostgresV2AdminStore(database: db), passwords: passwords) { _, _ in throw V2AdminError.unavailable }
                #expect(try await restarted.identity(token: token).username == "operator")
                let rotatedHash = try await passwords.hash("different-admin-password")
                let rotated = try V2AdminService(accounts: [.init(username: "operator", passwordHash: rotatedHash, role: .operatorRole)], store: store, passwords: passwords) { _, _ in throw V2AdminError.unavailable }
                await #expect(throws: V2AdminError.self) { _ = try await rotated.identity(token: token) }
                let changedRole = try V2AdminService(accounts: [.init(username: "operator", passwordHash: hash, role: .viewer)], store: store, passwords: passwords) { _, _ in throw V2AdminError.unavailable }
                await #expect(throws: V2AdminError.self) { _ = try await changedRole.identity(token: token) }
                let expired = try V2AdminService(accounts: accounts, store: store, passwords: passwords, now: { Date().addingTimeInterval(1_801) }) { _, _ in throw V2AdminError.unavailable }
                await #expect(throws: V2AdminError.self) { _ = try await expired.identity(token: token) }
                struct SessionRow: Decodable { let digest: String }
                let saved = try #require(try await sql.raw("SELECT digest FROM im_admin.sessions WHERE username = 'operator'").first(decoding: SessionRow.self))
                #expect(saved.digest != token && saved.digest.count == 64)

                let listed = try await decode([V2AdminUser].self, send(client, .get, "/users?q=admin_test_alice", cookie: operatorCookie))
                #expect(listed.count == 1 && listed.first?.userID == firstUser && listed.first?.activeDevices == 1)
                #expect(try await send(client, .get, "/users?limit=51", cookie: operatorCookie).status == .badRequest)
                #expect(try await send(client, .get, "/users?after=invalid", cookie: operatorCookie).status == .badRequest)
                #expect(try await send(client, .get, "/users/\(UUID())", cookie: operatorCookie).status == .notFound)
                let all = try await decode([V2AdminUser].self, send(client, .get, "/users?limit=1", cookie: operatorCookie))
                let page2 = try await decode([V2AdminUser].self, send(client, .get, "/users?after=\(try #require(all.first).userID)&limit=1", cookie: operatorCookie))
                #expect(page2.count == 1 && page2.first?.userID != all.first?.userID)
                let absent = try await decode([V2AdminUser].self, send(client, .get, "/users?q=%27%20OR%201%3D1--", cookie: operatorCookie))
                #expect(absent.isEmpty)

                // 意图审计写入失败时不得调用业务停用；不能出现无审计的成功副作用。
                try await sql.raw("CREATE FUNCTION im_admin.test_reject_intent() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN IF NEW.reason IS NOT NULL THEN RAISE EXCEPTION 'test intent unavailable'; END IF; RETURN NEW; END; $$").run()
                try await sql.raw("CREATE TRIGGER test_reject_intent BEFORE INSERT ON im_admin.audit FOR EACH ROW EXECUTE FUNCTION im_admin.test_reject_intent()").run()
                #expect(try await send(client, .post, "/users/\(secondUser)/disable", cookie: operatorCookie, body: DisableBody(operationID: UUID(), reason: .policyEnforcement)).status == .serviceUnavailable)
                #expect(try await sql.raw("SELECT 1 FROM im_v2.account_disables WHERE user_id = \(bind: secondUser)").first() == nil)
                try await sql.raw("DROP TRIGGER test_reject_intent ON im_admin.audit").run()
                try await sql.raw("DROP FUNCTION im_admin.test_reject_intent()").run()

                let body = DisableBody(operationID: operation, reason: .credentialCompromise)
                let path = "/users/\(firstUser)/disable"
                let lost = try await send(client, .post, path, cookie: operatorCookie, body: body)
                #expect(lost.status == .serviceUnavailable)
                let pending = try await decode(V2AdminAudit.self, send(client, .get, "/audit/\(operation)", cookie: operatorCookie))
                #expect(pending.outcome == "pending" && pending.principal == "admin:operator")
                let backlog = try await databaseMonitor.observe()
                #expect(backlog.pendingDisables == 1 && backlog.oldestPendingAt != nil)
                // 失败响应后业务事实已经提交，重试绝不能生成第二个停用动作。
                let disabledUser = try await decode(V2AdminUser.self, send(client, .get, "/users/\(firstUser)", cookie: operatorCookie))
                #expect(disabledUser.disabledAt != nil && disabledUser.activeDevices == 0 && disabledUser.state == "suspended")
                let success = try await decode(V2AdminAudit.self, send(client, .post, path, cookie: operatorCookie, body: body))
                #expect(success.operationID == operation && success.outcome == "disabled" && success.completedAt != nil)
                let duplicate = try await decode(V2AdminAudit.self, send(client, .post, path, cookie: operatorCookie, body: body))
                #expect(duplicate == success)
                #expect(try await databaseMonitor.observe().pendingDisables == 0)
                #expect(try await send(client, .post, "/users/\(secondUser)/disable", cookie: operatorCookie, body: body).status == .conflict)
                #expect(try await send(client, .post, path, cookie: operatorCookie, body: DisableBody(operationID: operation, reason: .policyEnforcement)).status == .conflict)
                let already = try await decode(V2AdminAudit.self, send(client, .post, path, cookie: operatorCookie, body: DisableBody(operationID: UUID(), reason: .userRequested)))
                #expect(already.outcome == "already_disabled")
                let audit = try await decode([V2AdminAudit].self, send(client, .get, "/audit?userID=\(firstUser)", cookie: readerCookie))
                #expect(audit.contains { $0.operationID == operation && $0.outcome == "disabled" })
                struct Principal: Decodable { let operator_principal: String; let operation_id: UUID }
                let business = try #require(try await sql.raw("SELECT operator_principal, operation_id FROM im_v2.account_disables WHERE user_id = \(bind: firstUser)").first(decoding: Principal.self))
                #expect(business.operator_principal == "admin:operator" && business.operation_id == operation)
                await #expect(throws: (any Error).self) { try await sql.raw("UPDATE im_admin.audit SET principal = 'admin:forged' WHERE operation_id = \(bind: operation)").run() }
                await #expect(throws: (any Error).self) { try await sql.raw("DELETE FROM im_admin.audit WHERE operation_id = \(bind: operation)").run() }
                #expect(try await send(client, .post, "/logout", cookie: operatorCookie, body: EmptyBody()).status == .noContent)
                #expect(try await send(client, .get, "/session", cookie: operatorCookie).status == .unauthorized)
                #expect(try await send(client, .get, "/audit", cookie: operatorCookie).status == .unauthorized)
            }
            // 全局 + 账号预算共享数据库，未知用户名不会无限创建桶。
            for _ in 0..<5 { #expect(try await store.consumeLoginBudget(username: nil, now: Date())) }
            #expect(try await store.consumeLoginBudget(username: nil, now: Date()) == false)
            try await app.shutdown(); await owners.shutdown(); try await passwords.shutdown(); try await resources.shutdown()
        } catch {
            try? await app.shutdown(); await owners.shutdown(); try? await passwords.shutdown(); try? await resources.shutdown(); throw error
        }
    }

    @Test("管理员用户名格式校验")
    func configuration() throws {
        #expect(V2AdminService.validUsername("ops.primary-1"))
        #expect(!V2AdminService.validUsername("ADMIN"))
        #expect(!V2AdminService.validUsername("admin:forged"))
        #expect(!V2AdminService.validUsername("用户"))
    }
}

private struct LoginBody: Content { let username: String; let password: String }
private struct DisableBody: Content { let operationID: UUID; let reason: V2AccountDisableReason }
private struct EmptyBody: Content {}
private func send(_ client: any TestClient, _ method: HTTPRequest.Method, _ path: String, cookie: String? = nil,
                  origin: String = "https://admin.example.test", body: (any Content)? = nil) async throws -> ClientResponse {
    var headers: HTTPFields = [.origin: origin]
    headers[HTTPField.Name("X-IMV2-Admin")!] = "1"
    if let cookie { headers[.cookie] = cookie }
    return try await client.send(method, headers: headers, to: URI(string: "admin/api" + path), beforeSend: { request in
        if let body { try request.content.encode(body) }
    })
}
private func cookie(_ response: ClientResponse) throws -> String {
    String(try #require(response.headers[.setCookie]).split(separator: ";", maxSplits: 1)[0])
}
private func decode<T: Decodable>(_ type: T.Type, _ response: ClientResponse) async throws -> T {
    #expect(response.status == .ok)
    let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(type, from: try await response.body.data() ?? Data())
}
private actor ResponseLoss {
    private var pending = true
    func consume() -> Bool { defer { pending = false }; return pending }
}
private struct TestProjectionDelivery: V2UserShardProjectionDelivering {
    func deliverToCurrentShard(userID: UserID, sourceEventID: EventID, projectionKinds: Set<String>) async throws -> UInt64? { 1 }
}
