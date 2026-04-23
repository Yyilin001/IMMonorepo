import UIKit
import IMClientKit

final class IMAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _: UIApplication,
        didFinishLaunchingWithOptions _: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        BackgroundTransferCoordinator.shared.resumePendingSessions()
        return true
    }

    func application(
        _: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        BackgroundTransferCoordinator.shared.handleEvents(
            forSessionIdentifier: identifier,
            completionHandler: completionHandler
        )
    }
}
