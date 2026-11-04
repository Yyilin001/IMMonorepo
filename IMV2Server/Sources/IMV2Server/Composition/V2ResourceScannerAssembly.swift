import IMV2ServerApplication
import IMV2ServerInfrastructure

/// Both ordinary uploads and forwarded copies use this checked composition.
public enum V2ResourceScannerAssembly {
    public static func build(configuration: V2ResourceRuntimeConfiguration) async throws -> any V2ResourceScanner {
        switch configuration.scanner {
        case .integrityOnly:
            return V2IntegrityOnlyResourceScanner(maximumBytes: configuration.maximumBytes)
        case .unsafeLocalFixture:
            return V2LocalResourceScanner()
        case .clamAV(let executable, let databaseDirectory):
            let scanner = try V2ClamAVResourceScanner(executable: executable, databaseDirectory: databaseDirectory,
                maximumBytes: configuration.maximumBytes)
            try await scanner.verifyReadiness()
            return scanner
        }
    }
}
