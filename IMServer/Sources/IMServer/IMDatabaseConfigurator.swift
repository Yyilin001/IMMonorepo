import Foundation
import Fluent
import FluentPostgresDriver
import FluentSQLiteDriver
import SQLKit
import Vapor

enum IMDatabaseConfigurator {
    static func configureDatabases(_ app: Application) {
        // 测试环境使用内存 SQLite，保证测试隔离和速度；开发/生产统一使用 PostgreSQL。
        if app.environment == .testing {
            app.databases.use(.sqlite(.memory), as: .sqlite)
            app.imReplicaDatabaseEnabled = false
            app.imSummaryDatabaseEnabled = false
            app.conversationShardDatabaseIDs = [:]
            app.conversationShardReplicaDatabaseIDs = [:]
            app.summaryShardDatabaseIDs = [:]
        } else {
            let databasePair = databaseConfigurationPair(for: app.environment)
            app.databases.use(.postgres(configuration: databasePair.primary), as: .psql)
            if let replica = databasePair.replica {
                app.databases.use(.postgres(configuration: replica), as: .imReplica)
                app.imReplicaDatabaseEnabled = true
            } else {
                app.imReplicaDatabaseEnabled = false
            }
            if let summary = databasePair.summary {
                app.databases.use(.postgres(configuration: summary), as: .imSummary)
                app.imSummaryDatabaseEnabled = true
            } else {
                app.imSummaryDatabaseEnabled = false
            }
            app.conversationShardDatabaseIDs = [:]
            app.conversationShardReplicaDatabaseIDs = [:]
            for (shardID, configuration) in databasePair.conversationShards {
                let databaseID = DatabaseID(string: "im-conversation-\(shardID)")
                app.databases.use(.postgres(configuration: configuration), as: databaseID)
                app.conversationShardDatabaseIDs[shardID] = databaseID
            }
            for (shardID, configuration) in databasePair.conversationShardReplicas {
                let databaseID = DatabaseID(string: "im-conversation-\(shardID)-replica")
                app.databases.use(.postgres(configuration: configuration), as: databaseID)
                app.conversationShardReplicaDatabaseIDs[shardID] = databaseID
            }
            app.summaryShardDatabaseIDs = [:]
            for (shardID, configuration) in databasePair.summaryShards {
                let databaseID = DatabaseID(string: "im-summary-\(shardID)")
                app.databases.use(.postgres(configuration: configuration), as: databaseID)
                app.summaryShardDatabaseIDs[shardID] = databaseID
            }
        }
    }

    private static func databaseConfigurationPair(for environment: Environment) -> IMPostgresDatabasePairConfiguration {
        let isProduction = environment == .production
        let defaultUsername = isProduction ? "vapor" : NSUserName()
        let defaultPassword = isProduction ? "vapor_password" : ""
        let base = PostgresConnectionParameters(
            host: Environment.get("DATABASE_HOST") ?? (isProduction ? "db" : "127.0.0.1"),
            port: Environment.get("DATABASE_PORT").flatMap(Int.init(_:)) ?? 5432,
            username: Environment.get("DATABASE_USERNAME") ?? defaultUsername,
            password: Environment.get("DATABASE_PASSWORD") ?? defaultPassword,
            database: Environment.get("DATABASE_NAME") ?? "vapor_auth"
        )

        let primaryParameters = PostgresConnectionParameters(
            host: Environment.get("DATABASE_PRIMARY_HOST") ?? base.host,
            port: Environment.get("DATABASE_PRIMARY_PORT").flatMap(Int.init(_:)) ?? base.port,
            username: Environment.get("DATABASE_PRIMARY_USERNAME") ?? base.username,
            password: Environment.get("DATABASE_PRIMARY_PASSWORD") ?? base.password,
            database: Environment.get("DATABASE_PRIMARY_NAME") ?? base.database
        )

        let replica = Environment.get("DATABASE_REPLICA_HOST").map { host in
            PostgresConnectionParameters(
                host: host,
                port: Environment.get("DATABASE_REPLICA_PORT").flatMap(Int.init(_:)) ?? primaryParameters.port,
                username: Environment.get("DATABASE_REPLICA_USERNAME") ?? primaryParameters.username,
                password: Environment.get("DATABASE_REPLICA_PASSWORD") ?? primaryParameters.password,
                database: Environment.get("DATABASE_REPLICA_NAME") ?? primaryParameters.database
            )
        }

        let summary = Environment.get("DATABASE_SUMMARY_HOST").map { host in
            PostgresConnectionParameters(
                host: host,
                port: Environment.get("DATABASE_SUMMARY_PORT").flatMap(Int.init(_:)) ?? primaryParameters.port,
                username: Environment.get("DATABASE_SUMMARY_USERNAME") ?? primaryParameters.username,
                password: Environment.get("DATABASE_SUMMARY_PASSWORD") ?? primaryParameters.password,
                database: Environment.get("DATABASE_SUMMARY_NAME") ?? primaryParameters.database
            )
        }

        let conversationShardPairs: [(String, SQLPostgresConfiguration)] = IMShardTopologyConfiguration.load(from: environment).shardIDs.compactMap { shardID in
            guard let parameters = conversationShardParameters(
                shardID: shardID,
                primaryParameters: primaryParameters
            ) else {
                return nil
            }
            return (shardID, parameters.configuration)
        }
        let conversationShardReplicaPairs: [(String, SQLPostgresConfiguration)] = IMShardTopologyConfiguration.load(from: environment).shardIDs.compactMap { shardID in
            guard let parameters = conversationShardReplicaParameters(
                shardID: shardID,
                primaryParameters: primaryParameters,
                replicaParameters: replica
            ) else {
                return nil
            }
            return (shardID, parameters.configuration)
        }

        let summaryShardPairs: [(String, SQLPostgresConfiguration)] = IMSummaryStoreConfiguration.load(from: environment).shardIDs.compactMap { shardID in
            guard let parameters = summaryShardParameters(
                shardID: shardID,
                primaryParameters: primaryParameters,
                legacySummary: summary
            ) else {
                return nil
            }
            return (shardID, parameters.configuration)
        }
        let summaryShardConfigurations = Dictionary(uniqueKeysWithValues: summaryShardPairs)

        return IMPostgresDatabasePairConfiguration(
            primary: primaryParameters.configuration,
            replica: replica?.configuration,
            conversationShards: Dictionary(uniqueKeysWithValues: conversationShardPairs),
            conversationShardReplicas: Dictionary(uniqueKeysWithValues: conversationShardReplicaPairs),
            summary: summary?.configuration,
            summaryShards: summaryShardConfigurations
        )
    }

    private static func conversationShardParameters(
        shardID: String,
        primaryParameters: PostgresConnectionParameters
    ) -> PostgresConnectionParameters? {
        let envComponent = normalizedEnvironmentComponent(shardID)
        let hostKey = "DATABASE_CONVERSATION_\(envComponent)_HOST"
        if let host = Environment.get(hostKey) {
            return PostgresConnectionParameters(
                host: host,
                port: Environment.get("DATABASE_CONVERSATION_\(envComponent)_PORT").flatMap(Int.init(_:)) ?? primaryParameters.port,
                username: Environment.get("DATABASE_CONVERSATION_\(envComponent)_USERNAME") ?? primaryParameters.username,
                password: Environment.get("DATABASE_CONVERSATION_\(envComponent)_PASSWORD") ?? primaryParameters.password,
                database: Environment.get("DATABASE_CONVERSATION_\(envComponent)_NAME") ?? primaryParameters.database
            )
        }

        if shardID == SingleShardConversationShardRouter.defaultShardID {
            return primaryParameters
        }

        return nil
    }

    private static func conversationShardReplicaParameters(
        shardID: String,
        primaryParameters: PostgresConnectionParameters,
        replicaParameters: PostgresConnectionParameters?
    ) -> PostgresConnectionParameters? {
        let envComponent = normalizedEnvironmentComponent(shardID)
        let hostKey = "DATABASE_CONVERSATION_\(envComponent)_REPLICA_HOST"
        if let host = Environment.get(hostKey) {
            return PostgresConnectionParameters(
                host: host,
                port: Environment.get("DATABASE_CONVERSATION_\(envComponent)_REPLICA_PORT").flatMap(Int.init(_:)) ?? replicaParameters?.port ?? primaryParameters.port,
                username: Environment.get("DATABASE_CONVERSATION_\(envComponent)_REPLICA_USERNAME") ?? replicaParameters?.username ?? primaryParameters.username,
                password: Environment.get("DATABASE_CONVERSATION_\(envComponent)_REPLICA_PASSWORD") ?? replicaParameters?.password ?? primaryParameters.password,
                database: Environment.get("DATABASE_CONVERSATION_\(envComponent)_REPLICA_NAME") ?? replicaParameters?.database ?? primaryParameters.database
            )
        }

        if shardID == SingleShardConversationShardRouter.defaultShardID {
            return replicaParameters
        }

        return nil
    }

    private static func summaryShardParameters(
        shardID: String,
        primaryParameters: PostgresConnectionParameters,
        legacySummary: PostgresConnectionParameters?
    ) -> PostgresConnectionParameters? {
        let envComponent = normalizedEnvironmentComponent(shardID)
        let hostKey = "DATABASE_SUMMARY_\(envComponent)_HOST"
        if let host = Environment.get(hostKey) {
            return PostgresConnectionParameters(
                host: host,
                port: Environment.get("DATABASE_SUMMARY_\(envComponent)_PORT").flatMap(Int.init(_:)) ?? legacySummary?.port ?? primaryParameters.port,
                username: Environment.get("DATABASE_SUMMARY_\(envComponent)_USERNAME") ?? legacySummary?.username ?? primaryParameters.username,
                password: Environment.get("DATABASE_SUMMARY_\(envComponent)_PASSWORD") ?? legacySummary?.password ?? primaryParameters.password,
                database: Environment.get("DATABASE_SUMMARY_\(envComponent)_NAME") ?? legacySummary?.database ?? primaryParameters.database
            )
        }

        if shardID == IMSummaryStoreConfiguration.defaultShardID {
            return legacySummary
        }

        return nil
    }

    private static func normalizedEnvironmentComponent(_ rawValue: String) -> String {
        let scalars = rawValue.unicodeScalars.map { scalar -> Character in
            if CharacterSet.alphanumerics.contains(scalar) {
                return Character(String(scalar).uppercased())
            }
            return "_"
        }
        return String(scalars)
    }
}

private struct PostgresConnectionParameters {
    let host: String
    let port: Int
    let username: String
    let password: String
    let database: String

    var configuration: SQLPostgresConfiguration {
        SQLPostgresConfiguration(
            hostname: host,
            port: port,
            username: username,
            password: password,
            database: database,
            tls: .disable
        )
    }
}
