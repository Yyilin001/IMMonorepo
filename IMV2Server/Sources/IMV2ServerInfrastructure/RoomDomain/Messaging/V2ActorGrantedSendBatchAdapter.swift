import IMV2ServerApplication
import IMV2ServerContracts
import Foundation
import IMV2ActorContracts
import IMV2Core

extension V2SendMessageAdmissionBatcher: V2ActorGrantedSendBatching {
    public func acceptGrantedTurn(_ sends: [V2PreparedActorSend],
                                  batchDeadline: ContinuousClock.Instant,
                                  callDeadline: ContinuousClock.Instant) async throws
        -> [Result<V2SendMessageOutcome, any Error>] {
        try await acceptGrantedTurn(sends, batchDeadline: batchDeadline,
                                    callDeadline: Optional(callDeadline))
    }
}
