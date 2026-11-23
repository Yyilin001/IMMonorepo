import FluentPostgresDriver
import Foundation
import IMV2Core
import IMV2Server
import IMV2ServerApplication
import IMV2ServerContracts
import IMV2ServerHTTP
import IMV2ServerInfrastructure
import Logging
import NIOPosix
import Vapor

/// 显式本地演示入口：复用真实数据库、HTTP 用例及 Policy Owner，省去多节点部署。
/// 不提供公网入口，不允许连接任意数据库，不改变生产服务的 Actor 配置要求。
enum V2AdminLocalDemo {
    static func run() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["IMV2_ADMIN_LOCAL_DEMO"] == "1",
              let rawURL = env["IMV2_ADMIN_LOCAL_DATABASE_URL"], let url = URL(string: rawURL),
              url.scheme == "postgres", url.host == "127.0.0.1", url.path == "/im_v2_admin_local",
              let accountsPath = env["IM_V2_ADMIN_ACCOUNTS_FILE"] else {
            throw V2AdminError.invalidInput
        }
        try V2ServiceLogging.bootstrap()
        V2ProcessTerminationSignal.install()
        let logger = Logger(label: "imv2.admin.local")
        try await withLogger(logger) { logger in
            let loops = MultiThreadedEventLoopGroup(numberOfThreads: 1)
            let resources = V2DatabaseResources(eventLoopGroup: loops, logger: logger, ownsEventLoopGroup: true)
            let passwords = V2PasswordHashWorker()
            let app = try await V2HTTPService.makeApplication(host: "127.0.0.1", port: 9446)
            var owners: PostgresV2PolicyOwnerDirectory?
            do {
                var postgres = try SQLPostgresConfiguration(url: rawURL)
                postgres.coreConfiguration.options.connectTimeout = .seconds(2)
                postgres.coreConfiguration.options.additionalStartupParameters.append(("statement_timeout", "2000"))
                resources.databases.use(.postgres(configuration: postgres, maxConnectionsPerEventLoop: 4,
                    connectionPoolTimeout: .seconds(2)), as: .psql)
                let database = resources.database()
                try await V2SchemaReadiness.verify(database: database)
                let store = PostgresV2AdminStore(database: database)
                try await store.verifySchema()
                let accounts = try JSONDecoder().decode([V2AdminAccount].self, from: Data(contentsOf: URL(fileURLWithPath: accountsPath)))
                let directory = PostgresV2PolicyOwnerDirectory(journal: .init(database: database),
                    dispatcher: .init(database: database, projectionDelivery: LocalDemoProjectionDelivery()))
                owners = directory
                let service = try V2AdminService(accounts: accounts, store: store, passwords: passwords) { principal, command in
                    try await V2PostgresAccountDisableService(operatorPrincipal: principal, policyOwners: directory).disable(command)
                }
                V2RedactedHTTPMiddlewareConfiguration.install(on: app)
                let databaseMonitor = PostgresV2AdminMonitoring(database: database)
                let monitoring = V2AdminMonitoringService(local: true, database: { try await databaseMonitor.observe() }, policy: {
                    let state = await directory.pressure()
                    return .init(closed: state.closed, owners: state.owners, inFlight: state.roots)
                })
                try V2AdminRoutes(service: service, origin: "http://127.0.0.1:5173", monitoring: monitoring).register(on: app)
                try await V2HTTPService.withRunning(app, logger: logger, waitForShutdown: V2ProcessTerminationSignal.wait) { shutdown in
                    logger.notice("Local admin demo ready at http://127.0.0.1:9446")
                    await shutdown.wait()
                }
                try await app.shutdown()
                await directory.shutdown()
                try await passwords.shutdown()
                try await resources.shutdown()
            } catch {
                try? await app.shutdown()
                await owners?.shutdown()
                try? await passwords.shutdown()
                try? await resources.shutdown()
                throw error
            }
        }
    }
}

/// 该演示不启动用户分片投影消费者；账户禁用只依赖其真实控制库事务。
/// 若将来引入需要投影投递的新用例，必须明确失败，不能伪造投递成功。
private struct LocalDemoProjectionDelivery: V2UserShardProjectionDelivering {
    func deliverToCurrentShard(userID: UserID, sourceEventID: EventID, projectionKinds: Set<String>) async throws -> UInt64? {
        throw V2AdminError.unavailable
    }
}
