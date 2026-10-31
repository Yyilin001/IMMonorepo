import Foundation
import IMV2Core

extension IMV2AuthorPresentationReceipt {
    func domain() throws -> V2AuthorPresentationReceipt {
        guard hasMinimumRemainingMilliseconds, let stream = UUID(uuidString: streamID), let view = UUID(uuidString: viewID),
              (1...V2AuthorPresentationDelta.maximumEntries).contains(keys.count) else {
            throw V2GatewaySessionError.unsupportedCommand
        }
        return try .init(streamID: stream, viewID: view,
                         sequence: sequence, keys: keys.map { try $0.domain() },
                         minimumRemainingMilliseconds: Int64(minimumRemainingMilliseconds))
    }
}
