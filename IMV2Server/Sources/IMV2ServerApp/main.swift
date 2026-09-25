import Logging
import IMV2Server
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
            fputs("Invalid IM_V2_LOG_LEVEL; expected a swift-log level.\n", stderr)
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
