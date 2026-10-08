import Foundation
import Logging
import IMV2ActorContracts

public enum V2SendPathTraceLogging {
    /// Detailed message diagnostics default to a stable 1/64 sample across
    /// nodes/segments. Log only diagnostic spans, never message content.
    public static func install(logger: Logger = Logger(label: "im.v2.send.path"),
                               collection: V2SendPathTrace.Collection = .sampledOperations) {
        V2SendPathTrace.installSink({ snapshot in
            let slow = snapshot.durationMilliseconds >= 100
            let sampled = snapshot.operations.contains { UUID(uuidString: $0)?.uuid.0 ?? 1 < 4 }
            let maintenance = snapshot.segment == "host_maintenance" && snapshot.durationMilliseconds >= 10
            guard slow || sampled || maintenance, let data = try? JSONEncoder().encode(snapshot),
                  let spans = String(data: data, encoding: .utf8) else { return }
            logger.log(level: slow ? .warning : .notice, "Send path trace",
                       metadata: ["send_path": .string(spans)])
        }, collection: collection)
    }
}
