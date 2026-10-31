import Foundation
import IMV2Core

extension IMV2AuthorPresentationInterests {
    func domain() throws -> V2AuthorPresentationInterests {
        guard let stream = UUID(uuidString: streamID), let view = UUID(uuidString: viewID),
              keys.count <= V2AuthorPresentationInterests.maximumAuthors else {
            throw V2GatewaySessionError.unsupportedCommand
        }
        return try .init(streamID: stream, viewID: view,
                         sequence: sequence, keys: keys.map { try $0.domain() })
    }
}
