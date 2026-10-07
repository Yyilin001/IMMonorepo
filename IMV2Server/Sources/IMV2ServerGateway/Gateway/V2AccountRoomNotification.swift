import Foundation

/// Account coverage owns only the recovery boundary; room progress is Owner delivery.
enum V2AccountRoomNotification: Equatable, Sendable {
    case resyncRequired(epoch: UUID)

    func envelope() -> IMV2Envelope {
        var envelope = IMV2Envelope()
        switch self {
        case .resyncRequired(let epoch):
            envelope.accountRoomResyncRequired.connectionEpoch = epoch.uuidString.lowercased()
        }
        return envelope
    }
}
