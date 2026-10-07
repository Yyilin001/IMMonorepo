@testable import IMV2ServerApplication
@testable import IMV2ServerContracts
import Logging
@testable import IMV2Server
@testable import IMV2ServerInfrastructure
import Testing

@Suite("服务端日志边界")
struct V2ServiceLoggingTests {
    @Test("默认日志级别为 info，显式级别必须有效")
    func validatesLogLevel() throws {
        #expect(try V2ServiceLogging.applicationLevel(environment: [:]) == .info)
        #expect(try V2ServiceLogging.applicationLevel(environment: ["IM_V2_LOG_LEVEL": " DEBUG "]) == .debug)
        #expect(throws: V2ServiceLogging.ConfigurationError.invalidLevel) {
            try V2ServiceLogging.applicationLevel(environment: ["IM_V2_LOG_LEVEL": "verbose"])
        }
        #expect(V2ServiceLogging.handler(label: "imv2.gateway", applicationLevel: .debug).logLevel == .debug)
        #expect(V2ServiceLogging.handler(label: "vapor", applicationLevel: .debug).logLevel == .info)
    }

    @Test("故障 metadata 保留类型和固定分类，但不调用异常描述")
    func omitsErrorDescription() {
        let secret = "postgres://operator:password@private-host/database"
        let metadata = V2SafeLogMetadata.workerFailure(
            SecretBearingError(secret: secret), worker: "projection"
        )
        let rendered = String(describing: metadata)
        #expect(metadata["stage"] == "background_worker")
        #expect(metadata["worker"] == "projection")
        #expect(metadata["error_code"] == "operation_failed")
        #expect(rendered.contains("SecretBearingError"))
        #expect(!rendered.contains(secret))

        let staged = V2StagedOperationalError(
            stage: "gateway_configuration", error: SecretBearingError(secret: secret)
        )
        let stagedMetadata = V2SafeLogMetadata.failure(staged, stage: "gateway_lifecycle")
        #expect(stagedMetadata["stage"] == "gateway_configuration")
        #expect(!String(describing: stagedMetadata).contains(secret))

        let configurationFailure = V2SafeLogMetadata.failure(
            V2GatewayRuntimeConfigurationError.invalid(secret), stage: "account_configuration"
        )
        #expect(configurationFailure["error_code"] == "invalid_configuration")
        #expect(!String(describing: configurationFailure).contains(secret))
        let missingConfiguration = V2SafeLogMetadata.failure(
            V2GatewayRuntimeConfigurationError.missing(secret), stage: "gateway_configuration"
        )
        #expect(missingConfiguration["error_code"] == "missing_configuration")
        #expect(!String(describing: missingConfiguration).contains(secret))
        #expect(V2SafeLogMetadata.drainTimeout(stage: "gateway_worker_shutdown")["error_code"] == "drain_timeout")

        // These concrete Infrastructure failures cross the existing dependency
        // boundary without importing Infrastructure into Application.
        let queueFull = V2SafeLogMetadata.failure(V2PhysicalDatabaseLoanFailure.queueFull, stage: "gateway_transport")
        let timedOut = V2SafeLogMetadata.failure(V2PhysicalDatabaseLoanFailure.timedOut, stage: "gateway_transport")
        #expect(queueFull["error_code"] == "database_loan_queue_full")
        #expect(timedOut["error_code"] == "database_loan_timed_out")
        let stagedLoan = V2StagedOperationalError(stage: "gateway_transport", error: V2PhysicalDatabaseLoanFailure.cancelled)
        #expect(V2SafeLogMetadata.failure(stagedLoan, stage: "cleanup")["error_code"] == "database_loan_cancelled")
        let classified = V2SafeLogMetadata.failure(SecretBearingClassifiedError(secret: secret), stage: "gateway_transport")
        #expect(classified["error_code"] == "database_loan_closed")
        #expect(!String(describing: classified).contains(secret))
    }
}

private struct SecretBearingError: Error, CustomStringConvertible {
    let secret: String
    var description: String { secret }
}

private struct SecretBearingClassifiedError: V2SafeOperationalErrorCodeProviding, CustomStringConvertible {
    let secret: String
    var safeOperationalErrorCode: V2SafeOperationalErrorCode { .databaseLoanClosed }
    var description: String { secret }
}
