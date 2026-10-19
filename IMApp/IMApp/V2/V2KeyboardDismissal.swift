import SwiftUI
import UIKit

/// One bridge per scene, including sheets presented in that scene's window.
struct V2KeyboardDismissal: UIViewRepresentable {
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WindowProbe {
        let view = WindowProbe()
        view.isUserInteractionEnabled = false
        view.windowChanged = { [weak coordinator = context.coordinator] window in
            coordinator?.attach(to: window)
        }
        return view
    }

    func updateUIView(_ uiView: WindowProbe, context: Context) {}

    static func dismantleUIView(_ uiView: WindowProbe, coordinator: Coordinator) {
        uiView.windowChanged = nil
        coordinator.attach(to: nil)
    }

    final class WindowProbe: UIView {
        var windowChanged: ((UIWindow?) -> Void)?
        override func didMoveToWindow() {
            super.didMoveToWindow()
            windowChanged?(window)
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        private weak var window: UIWindow?
        private lazy var tap: UITapGestureRecognizer = {
            let gesture = UITapGestureRecognizer(target: self, action: #selector(dismissKeyboard))
            gesture.cancelsTouchesInView = false
            gesture.delaysTouchesBegan = false
            gesture.delaysTouchesEnded = false
            gesture.delegate = self
            return gesture
        }()

        func attach(to newWindow: UIWindow?) {
            guard window !== newWindow else { return }
            window?.removeGestureRecognizer(tap)
            window = newWindow
            newWindow?.addGestureRecognizer(tap)
        }

        @objc private func dismissKeyboard() { window?.endEditing(false) }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            Self.shouldDismiss(touching: touch.view)
        }

        static func shouldDismiss(touching view: UIView?) -> Bool {
            var ancestor = view
            while let current = ancestor {
                // Preserve editing, selection, field switching, and native controls.
                if current is UITextInput || current is UIControl { return false }
                ancestor = current.superview
            }
            return view != nil
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            true
        }
    }
}
