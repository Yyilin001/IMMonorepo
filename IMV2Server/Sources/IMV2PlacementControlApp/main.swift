import Foundation
import IMV2ActorApplication
import IMV2Server
import IMV2ServerApplication
import IMV2ServerContracts
import Logging
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

@main
enum IMV2PlacementControlApp {
    private struct Environment: V2RuntimeEnvironment {
        func value(for key: String) -> String? { ProcessInfo.processInfo.environment[key] }
    }
    static func main() async {
        do {
            let arguments = Array(CommandLine.arguments.dropFirst())
            guard arguments.isEmpty || arguments == ["--provision"] || arguments == ["--inspect"] else {
                throw V2RoomActorApplicationConfigurationError.invalidConfiguration
            }
            let environment = Environment()
            guard let value = environment.value(for: "IMV2_PLACEMENT_SHARD_IDS") else {
                throw V2RoomActorApplicationConfigurationError.missingConfiguration
            }
            let names = value.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            guard !names.isEmpty, names.allSatisfy({ !$0.isEmpty && $0 == $0.trimmingCharacters(in: .whitespacesAndNewlines) }),
                  Set(names).count == names.count else { throw V2RoomActorApplicationConfigurationError.invalidConfiguration }
            let configuration = try V2RoomActorApplicationConfiguration(environment: environment,
                hostsRooms: false, configuredShardIDs: Set(names))
            if arguments == ["--inspect"] {
                LoggingSystem.bootstrap { label in StreamLogHandler.standardError(label: label) }
                let inspection = try await V2PlacementControlService.inspect(configuration: configuration)
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys]
                var output = try encoder.encode(inspection)
                output.append(10)
                FileHandle.standardOutput.write(output)
                return
            }
            if arguments == ["--provision"] {
                try await V2PlacementControlService.provision(configuration: configuration)
                return
            }
            V2ProcessTerminationSignal.install()
            let service = try V2PlacementControlService(configuration: configuration)
            try await service.start()
            FileHandle.standardOutput.write(Data("Placement control ready.\n".utf8))
            await V2ProcessTerminationSignal.wait()
            guard try await service.stop(deadline: .now + .seconds(30)) else {
                throw V2RoomActorApplicationError.incompleteShutdown
            }
        } catch {
            FileHandle.standardError.write(Data("Placement control startup, provisioning, inspection or shutdown failed.\n".utf8))
            exit(EXIT_FAILURE)
        }
    }
}
