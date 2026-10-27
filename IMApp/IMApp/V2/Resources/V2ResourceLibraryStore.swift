import Foundation
import IMV2ClientKit
import IMV2Core
import Observation

@MainActor @Observable
final class V2ResourceLibraryStore {
    struct Query: Equatable {
        let category: V2ResourceCategory
        let search: String
        let retainedOnly: Bool
        let before: V2ResourceDirectoryCursor?
    }
    enum Content {
        case initial
        case available(V2ResourceDirectoryPage)
        case unavailable(previous: V2ResourceDirectoryPage?, message: String)
        var page: V2ResourceDirectoryPage? {
            switch self { case .initial: nil; case .available(let page): page; case .unavailable(let previous, _): previous }
        }
    }
    enum CloudState { case idle, loading, available(hasMore: Bool), failed(String) }
    private enum CloudActivity: Equatable { case idle, pending(UUID), running(UUID), finished(UUID) }
    private var cloudActivity: CloudActivity = .idle
    private var loadedQuery: Query?
    struct CloudRequest: Equatable { let id = UUID(); let category: V2ResourceCategory; let restart: Bool }
    let room: RoomID?
    let service: V2ResourceManagementService
    var category: V2ResourceCategory = .all { didSet { if category != oldValue { resetPaging(); cloud = .idle; cloudRequest = nil; cloudActivity = .idle } } }
    var search = "" { didSet { if search != oldValue { resetPaging() } } }
    var retainedOnly = false { didSet { if retainedOnly != oldValue { resetPaging() } } }
    private(set) var content: Content = .initial
    private(set) var cloud: CloudState = .idle
    private(set) var before: V2ResourceDirectoryCursor?
    private(set) var pageNumber = 1
    @ObservationIgnored private var previousCursors: [V2ResourceDirectoryCursor?] = []
    private(set) var cloudRequest: CloudRequest?
    var query: Query { .init(category: category, search: search, retainedOnly: retainedOnly, before: before) }
    var hasCurrentPage: Bool { loadedQuery == query && content.page != nil }
    var canGoNextPage: Bool { hasCurrentPage && content.page?.nextCursor != nil }
    func isCurrentPageResource(_ key: V2ResourceKey) -> Bool {
        hasCurrentPage && content.page?.entries.contains(where: { $0.descriptor.key == key }) == true
    }
    var usesMediaGrid: Bool { category == .image || category == .video }

    init(room: RoomID?, service: V2ResourceManagementService) { self.room = room; self.service = service }

    func observe() async {
        let expected = query
        do {
            if !expected.search.isEmpty { try await Task.sleep(for: .milliseconds(250)) }
            let request = try V2ResourceDirectoryQuery(roomID: room, category: expected.category, search: expected.search,
                retainedOnly: expected.retainedOnly, before: expected.before)
            let stream = try await service.center.snapshots(for: request)
            for await snapshot in stream {
                guard !Task.isCancelled, expected == query else { return }
                switch snapshot {
                case .available(let page): content = .available(page); loadedQuery = expected
                case .unavailable(let previous): content = .unavailable(previous: previous, message: "本机目录暂不可用，请稍后重试。")
                }
                if room != nil, case .idle = cloud { requestCloud(restart: true) }
            }
        } catch is CancellationError { }
        catch {
            guard !Task.isCancelled, expected == query else { return }
            content = .unavailable(previous: content.page, message: V2ResourceFailure.message(error))
        }
    }

    func nextPage() {
        guard canGoNextPage, let cursor = content.page?.nextCursor else { return }
        previousCursors.append(before); before = cursor; pageNumber += 1
    }
    func previousPage() {
        guard !previousCursors.isEmpty else { return }
        before = previousCursors.removeLast(); pageNumber -= 1
    }
    func requestCloud(restart: Bool) {
        guard room != nil else { return }
        switch cloudActivity { case .pending, .running: return; default: break }
        let next = CloudRequest(category: category, restart: restart)
        cloudRequest = next
        cloudActivity = .pending(next.id)
        cloud = .loading
    }
    func synchronize(_ request: CloudRequest) async {
        guard let room, request == cloudRequest, cloudActivity == .pending(request.id) else { return }
        cloudActivity = .running(request.id)
        defer {
            if cloudActivity == .running(request.id) { cloudActivity = .finished(request.id) }
        }
        do {
            let more = try await service.synchronize(room: room, category: request.category, restart: request.restart)
            try Task.checkCancellation()
            guard request == cloudRequest else { return }
            cloud = .available(hasMore: more)
        } catch is CancellationError {
            if request == cloudRequest { cloud = .idle }
        } catch {
            guard !Task.isCancelled, request == cloudRequest else { return }
            cloud = .failed(V2ResourceFailure.message(error))
        }
    }
    private func resetPaging() {
        previousCursors.removeAll(); before = nil; pageNumber = 1
    }
}
