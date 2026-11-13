import Foundation
import FoundationNetworking
import IMV2ClientRuntime
import IMV2Core
import MessageSubstringSearch

func runtimeProbe(_ input: ProbeInput) async throws -> ProbeResult {
    guard let path = input.path else { throw ProbeFailure.assertion("missing search path") }
    var configuration = SearchConfiguration(path: path, scopeID: "phase-two", sourceEpoch: "1")
    configuration.automaticallyProcess = false
    let index = try await SearchIndex.open(configuration)
    do {
        do {
            _ = try await SearchIndex.open(configuration)
            throw ProbeFailure.assertion("exclusive writer lease missing")
        } catch SearchIndexError.alreadyOpen {}
        let document = SearchDocument(id: "message", groupID: "room", version: 1, timestamp: 1,
            fields: [SearchField(text: "北京欢迎你 Cafe\u{301} 👨‍👩‍👧‍👦")])
        _ = try await index.enqueue([.init(eventID: "event", operation: .upsert(document))])
        _ = try await index.processPending()
        for query in ["京欢", "fé", "👨‍👩‍👧‍👦"] {
            let hits = try await index.search(.init(query)).hits
            try require(hits.map { $0.document.id } == ["message"], "production search: " + query)
        }
        try await index.integrityCheck()
        try await index.close()
    } catch { try? await index.close(); throw error }
    let reopened = try await SearchIndex.open(configuration)
    do {
        try require(try await reopened.search(.init("京欢")).hits.count == 1, "search reopen")
        try await reopened.close()
    } catch { try? await reopened.close(); throw error }
    try await runtimeStoreProbe(root: URL(fileURLWithPath: path + ".runtime", isDirectory: true))
    let scheduler = V2AccountWorkScheduler(configuration: .init(ordinaryLimit: 1))
    let permit = try await scheduler.acquire(.init(service: "probe"))
    _ = await scheduler.release(permit)
    try require(await scheduler.snapshot().active == 0, "shared runtime scheduler")
    await scheduler.closeAndDrain()
    return .init(outcome: "ok", values: ["runtime": "IMV2ClientRuntime", "search": "MessageSubstringSearch",
        "unicode": "true", "exclusiveWriter": "true", "reopen": "true", "schedulerDrained": "true", "productionStoreAndSearchActors": "true"])
}

/// Test-only URL substitution lets the real HTTPS-only executor exercise a
/// deterministic loopback server. Production URL validation remains unchanged.
private struct LoopbackTransport: V2HTTPTransport {
    let destination: URL
    func makeExecution(events: V2HTTPTransportEvents) -> any V2HTTPTransportExecution {
        Execution(destination: destination, base: V2URLSessionHTTPTransport().makeExecution(events: events))
    }
    private struct Execution: V2HTTPTransportExecution {
        let destination: URL
        let base: any V2HTTPTransportExecution
        var observation: (Int, Bool, Int, Int?) { base.observation }
        var phaseTiming: V2HTTPPhaseTiming? { base.phaseTiming }
        func cancel() { base.cancel() }
        func execute(_ request: URLRequest, maximumResponseBytes: Int, service: String,
                     onResponse: @escaping @Sendable (HTTPURLResponse) async -> Void) async throws -> (Data, HTTPURLResponse) {
            var request = request; request.url = destination
            return try await base.execute(request, maximumResponseBytes: maximumResponseBytes, service: service, onResponse: onResponse)
        }
    }
}

func runtimeHTTPProbe(_ input: ProbeInput) async throws -> ProbeResult {
    guard let raw = input.url, let url = URL(string: raw),
          url.scheme == "https" || (url.scheme == "http" && url.host == "127.0.0.1") else {
        throw ProbeFailure.assertion("only HTTPS or loopback fixtures allowed")
    }
    let scheduler = V2AccountWorkScheduler(configuration: .init(ordinaryLimit: 1))
    let diagnostics = V2NetworkDiagnostics()
    let executor: V2HTTPExecutor
    let requestURL: URL
    if url.scheme == "http" {
        executor = .init(transport: LoopbackTransport(destination: url), scheduler: scheduler, metrics: { diagnostics.record($0) })
        requestURL = URL(string: "https://probe.invalid/fixture")!
    } else {
        executor = .init(scheduler: scheduler, metrics: { diagnostics.record($0) }); requestURL = url
    }
    do {
        let (data, response) = try await executor.execute(URLRequest(url: requestURL),
            budget: .init(timeout: Double(input.deadlineMilliseconds ?? 10_000) / 1000,
                          maximumResponseBytes: input.maximumBytes ?? 65_536), service: "phaseTwo")
        try require(await scheduler.snapshot().active == 0, "request permit released")
        try require(diagnostics.snapshot().samples.count == 1, "one runtime metric")
        await scheduler.closeAndDrain()
        return .init(outcome: "ok", values: ["status": String(response.statusCode), "bytes": String(data.count),
            "body": String(decoding: data.prefix(128), as: UTF8.self), "runtime": "IMV2ClientRuntime", "permitDrained": "true"])
    } catch {
        await scheduler.closeAndDrain()
        if let failure = error as? V2HTTPFailure {
            if failure.kind == .responseTooLarge { throw ProbeFailure.oversized }
            if failure.kind == .deadlineExceeded { throw ProbeFailure.deadline }
        }
        throw error
    }
}

private actor ProbeBindingStore: V2InstallationBindingStore {
    private var value: V2LocalInstallationBinding?
    func load() -> V2LocalInstallationBinding? { value }
    func save(_ binding: V2LocalInstallationBinding) { value = binding }
    func delete() { value = nil }
}

private func runtimeStoreProbe(root: URL) async throws {
    defer { try? FileManager.default.removeItem(at: root) }
    let bootstrap = V2LocalStoreBootstrapper(bindingStore: ProbeBindingStore())
    let store = try await bootstrap.open(databaseURL: root.appendingPathComponent("state.sqlite"))
    do {
        await store.messageSearch.startIndexing()
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while try await store.messageSearch.messageSearchIndexState() != .ready {
            try require(ContinuousClock.now < deadline, "production search index became ready")
            try await Task.sleep(for: .milliseconds(10))
        }
        let result = try await store.messageSearch.searchMessages(.init(query: "中文", scope: .allMessages))
        try require(result.hits.isEmpty, "fresh production search")
        try await store.close()
    } catch { try? await store.close(); throw error }
    let reopened = try await bootstrap.open(databaseURL: root.appendingPathComponent("state.sqlite"))
    try await reopened.close()
}
