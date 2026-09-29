import IMV2ServerApplication
import IMV2ServerContracts
import Foundation
import Logging
import IMV2Server
import IMV2ServerInfrastructure
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

@main
enum IMV2ServerApp {
    static func main() async {
        do { try V2ServiceLogging.bootstrap() }
        catch {
            FileHandle.standardError.write(Data("Invalid IM_V2_LOG_LEVEL; expected a swift-log level.\n".utf8))
            exit(EXIT_FAILURE)
        }
        let logger = Logger(label: "imv2.gateway")
        do {
            try await withLogger(logger) { scopedLogger in
                try await GatewayRuntime.run(logger: scopedLogger)
            }
        } catch {
            logger.error("IM V2 gateway startup or shutdown failed", metadata:
                V2SafeLogMetadata.failure(error, stage: "gateway_lifecycle"))
            exit(EXIT_FAILURE)
        }
    }
}
