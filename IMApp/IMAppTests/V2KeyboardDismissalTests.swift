import Testing
import UIKit
@testable import IMApp

@MainActor
struct V2KeyboardDismissalTests {
    @Test func blankAreasDismissButInputsAndControlsKeepTheirTouches() {
        let blank = UIView()
        #expect(V2KeyboardDismissal.Coordinator.shouldDismiss(touching: blank))
        for control in [UITextField(), UITextView(), UIButton()] as [UIView] {
            let child = UIView()
            control.addSubview(child)
            #expect(!V2KeyboardDismissal.Coordinator.shouldDismiss(touching: child))
        }
        #expect(!V2KeyboardDismissal.Coordinator.shouldDismiss(touching: nil))
    }

    @Test func attachmentIsIdempotentAndMovesBetweenWindows() {
        let coordinator = V2KeyboardDismissal.Coordinator()
        let first = UIWindow(), second = UIWindow()
        let initialCount = first.gestureRecognizers?.count ?? 0
        coordinator.attach(to: first)
        coordinator.attach(to: first)
        #expect(first.gestureRecognizers?.count == initialCount + 1)
        let gesture = first.gestureRecognizers!.last!
        #expect(!gesture.cancelsTouchesInView)
        coordinator.attach(to: second)
        #expect(!(first.gestureRecognizers ?? []).contains(gesture))
        #expect((second.gestureRecognizers ?? []).contains(gesture))
        coordinator.attach(to: nil)
        #expect(!(second.gestureRecognizers ?? []).contains(gesture))
    }

    @Test(arguments: [true, false])
    func composerRegionPreservesOnlyItsVisiblePage(attachFirst: Bool) {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 800))
        let page = UIViewController()
        page.view.frame = window.bounds
        window.addSubview(page.view)
        let coordinator = V2KeyboardDismissal.Coordinator()
        if attachFirst { coordinator.attach(to: window) }
        let region = V2KeyboardDismissal.PreservedRegionView(frame: CGRect(x: 0, y: 700, width: 400, height: 100))
        page.view.addSubview(region)
        if !attachFirst { coordinator.attach(to: window) }
        let inside = CGPoint(x: 200, y: 750)
        #expect(!coordinator.shouldDismiss(touching: page.view, at: inside))
        #expect(coordinator.shouldDismiss(touching: page.view, at: CGPoint(x: 200, y: 600)))

        let sheet = UIViewController()
        sheet.view.frame = window.bounds
        window.addSubview(sheet.view)
        #expect(coordinator.shouldDismiss(touching: sheet.view, at: inside))
        sheet.view.removeFromSuperview()

        region.isHidden = true
        #expect(coordinator.shouldDismiss(touching: page.view, at: inside))
        region.isHidden = false
        region.removeFromSuperview()
        #expect(coordinator.shouldDismiss(touching: page.view, at: inside))
        coordinator.attach(to: nil)
    }
}
