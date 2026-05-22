import Foundation
import Observation

@MainActor
@Observable
final class IMAsyncSubmitter {
    var isSubmitting = false
    var message: String?
    var didSucceed = false

    func run(
        messageOnFailure: String,
        action: @escaping () async -> Bool
    ) async {
        guard !isSubmitting else {
            return
        }

        isSubmitting = true
        didSucceed = false
        message = nil
        let succeeded = await action()
        isSubmitting = false
        didSucceed = succeeded
        if !succeeded {
            message = messageOnFailure
        }
    }
}
