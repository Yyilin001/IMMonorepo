/// Immutable reference around a callback crossing a generic inout lock boundary.
/// Avoids accumulating function reabstraction write-backs (Swift issue #91348).
package final class V2CallbackBox<Callback: Sendable>: Sendable {
    package let callback: Callback
    package init(_ callback: Callback) { self.callback = callback }
}
