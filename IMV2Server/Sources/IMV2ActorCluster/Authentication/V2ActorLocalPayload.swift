import IMV2ActorContracts

/// Exact local authority passes models; no wire encoder runs for budgeting.
struct V2ActorLocalPayload<Body: Sendable>: Sendable {
    let body: Body
    let byteCount: Int
    init(_ body: Body) throws {
        self.body = body
        self.byteCount = V2ActorPayloadBudget.retainedBytes(of: body)
    }
}
