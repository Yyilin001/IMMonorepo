import SwiftUI
import UIKit

/// One bridge per scene, including sheets presented in that scene's window.
struct V2KeyboardDismissal: UIViewRepresentable {
    /// SwiftUI buttons may deliver touches through their hosting view rather
    /// than UIControl. Mark a composer explicitly as an editing interaction.
    struct PreservedRegion: UIViewRepresentable {
        func makeUIView(context: Context) -> PreservedRegionView {
            let view = PreservedRegionView()
            view.isUserInteractionEnabled = false
            return view
        }

        func updateUIView(_ uiView: PreservedRegionView, context: Context) {}
    }

    final class PreservedRegionView: UIView {
        override func didMoveToWindow() {
            super.didMoveToWindow()
            for gesture in window?.gestureRecognizers ?? [] {
                (gesture.delegate as? Coordinator)?.preserve(self)
            }
        }

        func containsInteraction(in view: UIView, at location: CGPoint) -> Bool {
            guard window != nil, window === view.window,
                  bounds.contains(convert(location, from: view)) else { return false }
            var ancestor: UIResponder? = self
            while let current = ancestor {
                if let container = current as? UIView, container.isHidden || container.alpha == 0 { return false }
                if let controller = current as? UIViewController {
                    // A sheet over the composer owns its own keyboard behavior.
                    return view.isDescendant(of: controller.view)
                }
                ancestor = current.next
            }
            return false
        }
    }

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
        private let preservedRegions = NSHashTable<PreservedRegionView>.weakObjects()
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
            preservedRegions.removeAllObjects()
            window = newWindow
            newWindow?.addGestureRecognizer(tap)
            if let newWindow { registerRegions(in: newWindow) }
        }

        func preserve(_ region: PreservedRegionView) { preservedRegions.add(region) }

        private func registerRegions(in view: UIView) {
            if let region = view as? PreservedRegionView { preserve(region) }
            for child in view.subviews { registerRegions(in: child) }
        }

        @objc private func dismissKeyboard() { window?.endEditing(false) }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            shouldDismiss(touching: touch.view, at: touch.location(in: touch.view))
        }

        func shouldDismiss(touching view: UIView?, at location: CGPoint) -> Bool {
            guard let view, Self.shouldDismiss(touching: view) else { return false }
            return !preservedRegions.allObjects.contains { $0.containsInteraction(in: view, at: location) }
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
