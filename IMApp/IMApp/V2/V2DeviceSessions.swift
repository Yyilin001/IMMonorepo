import IMV2ClientKit
import IMV2Core
import Observation
import SwiftUI

/// 「登录设备」页面的状态容器。
///
/// 它持有设备会话分页状态、加载进度与用户反馈文案，
/// 所有网络调用都在 MainActor 上发起，并通过代次校验丢弃过期响应。
@MainActor
@Observable
final class V2DeviceSessionsStore {
    /// 页面级加载状态。
    enum State: Equatable {
        /// 正在读取第一页。
        case loading
        /// 已成功加载至少一页。
        case loaded
        /// 读取失败，且当前没有可展示的数据。
        case failed
    }

    private let manager: any V2ClientDeviceSessionManaging
    private let operations: V2RemoteDeviceRevocationService
    private var active = true
    private var appliedReceipts: Set<UUID> = []
    private var baseline: V2RemoteDeviceRevocationBaseline?
    private(set) var revocations: [V2RemoteDeviceRevocationRecord] = []
    private let makeUUID: @Sendable () -> UUID
    private(set) var state: State = .loading
    private(set) var sessions: [V2ClientDeviceSession] = []
    private(set) var feedback: String?
    private(set) var isMutating = false
    private(set) var canManageSessions = false
    private(set) var isLoadingMore = false
    private(set) var nextCursor: String?
    private var hasLoadedSnapshot = false
    private var refreshGeneration = 0
    private var loadMoreGeneration = 0
    private let pageSize = 50

    init(manager: any V2ClientDeviceSessionManaging, operations: V2RemoteDeviceRevocationService, makeUUID: @escaping @Sendable () -> UUID = { UUID() }) {
        self.manager = manager
        self.operations = operations
        self.makeUUID = makeUUID
    }

    /// 重新读取第一页设备会话。
    ///
    /// 会立即使更早的「加载更多」请求失效：即便其传输层已经在途且无法被取消，
    /// 代次校验也会阻止它写回结果。
    func refresh() async {
        guard active, !isMutating else { return }
        refreshGeneration &+= 1
        let generation = refreshGeneration
        baseline = nil
        canManageSessions = false
        // Invalidate an older page request immediately. Its cancellation may
        // not stop a transport that has already received a response.
        loadMoreGeneration &+= 1
        isLoadingMore = false
        state = hasLoadedSnapshot ? .loaded : .loading
        do {
            let page = try await manager.list(cursor: nil, pageSize: pageSize)
            try Task.checkCancellation()
            guard generation == refreshGeneration else { return }
            sessions = page.sessions
            hasLoadedSnapshot = true
            nextCursor = page.nextCursor
            state = .loaded
            feedback = nil
            do {
                let fresh = try await operations.readBaseline()
                try Task.checkCancellation()
                guard generation == refreshGeneration else { return }
                baseline = fresh; canManageSessions = true
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, generation == refreshGeneration else { return }
                if revokeAuthorityIfNeeded(error) { return }
                feedback = "设备列表可查看；请重新读取有效确认范围后再退出设备。"
            }
        } catch is CancellationError {
        } catch {
            guard generation == refreshGeneration else { return }
            if revokeAuthorityIfNeeded(error) { return }
            state = hasLoadedSnapshot ? .loaded : .failed
            feedback = "无法读取登录设备，请稍后重试。"
        }
    }

    /// 按游标继续读取下一页设备会话。
    ///
    /// 仅当状态为已加载、当前无在途加载且存在下一页游标时才会执行；
    /// 结果按设备标识去重后追加。
    func loadMore() async {
        guard active, let cursor = nextCursor, !isMutating, !isLoadingMore, state == .loaded else { return }
        let refreshGeneration = self.refreshGeneration
        loadMoreGeneration &+= 1
        let loadMoreGeneration = self.loadMoreGeneration
        isLoadingMore = true
        defer {
            if loadMoreGeneration == self.loadMoreGeneration {
                isLoadingMore = false
            }
        }
        do {
            let page = try await manager.list(cursor: cursor, pageSize: pageSize)
            try Task.checkCancellation()
            guard refreshGeneration == self.refreshGeneration,
                  loadMoreGeneration == self.loadMoreGeneration,
                  cursor == nextCursor
            else { return }
            var existing = Set(sessions.map(\.deviceID))
            sessions.append(contentsOf: page.sessions.filter {
                existing.insert($0.deviceID).inserted
            })
            nextCursor = page.nextCursor
        } catch is CancellationError {
        } catch {
            guard refreshGeneration == self.refreshGeneration,
                  loadMoreGeneration == self.loadMoreGeneration, cursor == nextCursor else { return }
            if revokeAuthorityIfNeeded(error) { return }
            feedback = "无法继续读取登录设备，请稍后重试。"
        }
    }

    func proposal(selection: V2RemoteDeviceRevocationCommand.Selection) -> V2RemoteDeviceRevocationCommand? {
        guard active, canManageSessions, !isMutating, let baseline else { return nil }
        let targets: [DeviceID]
        switch selection { case .device(let id): targets = [id]; case .allObservedOthers: targets = baseline.targetDeviceIDs }
        guard !targets.isEmpty, !revocations.contains(where: { $0.receipt == nil && !Set($0.command.targetDeviceIDs).isDisjoint(with: Set(targets)) }) else {
            feedback = "这些设备已有未确认操作，请先继续核对原操作。"; return nil
        }
        guard Date().timeIntervalSince1970 * 1_000 < Double(baseline.expiresAtMilliseconds) else {
            canManageSessions = false; feedback = "确认范围已过期，请刷新后重新确认。"; return nil
        }
        return try? V2RemoteDeviceRevocationCommand(operationID: makeUUID(), baseline: baseline, selection: selection, firstSubmissionDeadlineMilliseconds: baseline.expiresAtMilliseconds)
    }
    func confirm(_ command: V2RemoteDeviceRevocationCommand) async {
        guard active, canManageSessions, !isMutating else { return }
        isMutating = true; invalidateReadsForMutation(); defer { isMutating = false }
        do {
            try await operations.enqueue(command)
            try Task.checkCancellation()
            guard active else { return }
            baseline = nil; canManageSessions = false
            feedback = "退出请求已安全保存，正在核对结果。"
        } catch is CancellationError {
            return
        } catch V2RemoteDeviceRevocationJournalError.conflictingPending {
            guard active, !Task.isCancelled else { return }
            feedback = "已有未确认操作，请继续核对原操作。"
        } catch V2RemoteDeviceRevocationJournalError.confirmationExpired {
            guard active, !Task.isCancelled else { return }
            canManageSessions = false; feedback = "确认范围已过期，请刷新后重新确认。"
        } catch {
            guard active, !Task.isCancelled else { return }
            feedback = "无法安全保存退出请求，请解锁设备后重试。"
        }
    }
    func observeRevocations() async {
        do {
            for await records in try await operations.updates() {
                try Task.checkCancellation()
                guard active else { return }
                revocations = records
                let newlyResolved = records.filter { $0.receipt != nil && !appliedReceipts.contains($0.id) }
                if !newlyResolved.isEmpty {
                    invalidateReadsForMutation(); baseline = nil; canManageSessions = false
                    appliedReceipts.formUnion(newlyResolved.map(\.id))
                }
                let proofs = records.compactMap { record -> V2RemoteDeviceRevocationReceipt? in
                    guard let receipt = record.receipt, case .revoked = receipt.outcome else { return nil }; return receipt
                }
                // A later login using the same device identity is outside the original proof.
                sessions.removeAll { session in proofs.contains { proof in
                    proof.targetDeviceIDs.contains(session.deviceID) && session.createdAt.timeIntervalSince1970 * 1_000 <= Double(proof.resolvedAtMilliseconds)
                } }
            }
        } catch is CancellationError {} catch {
            guard active, !Task.isCancelled else { return }
            feedback = "安全记录暂不可读，请解锁后重新打开。"
        }
    }
    func resumeRevocation(_ id: UUID) async {
        guard active else { return }
        do {
            try await operations.resume(id)
            try Task.checkCancellation()
            guard active else { return }
            feedback = "正在核对原退出请求，不会扩展目标设备。"
        } catch is CancellationError {
            return
        } catch {
            guard active, !Task.isCancelled else { return }
            feedback = "无法读取安全记录，请解锁后重试。"
        }
    }
    func targetDescription(_ command: V2RemoteDeviceRevocationCommand) -> String {
        command.targetDeviceIDs.map { id in sessions.first(where: { $0.deviceID == id })?.deviceName ?? id.rawValue }.joined(separator: "\n")
    }

    func close() async {
        active = false
        feedback = nil
        isMutating = false
        invalidateReadsForMutation()
        baseline = nil
        canManageSessions = false
        sessions = []
        revocations = []
        nextCursor = nil
        hasLoadedSnapshot = false
        state = .failed
        await operations.close()
    }

    private func revokeAuthorityIfNeeded(_ error: Error) -> Bool {
        let sessionEnded = (error as? V2AuthSessionError) == .unauthenticated
            || (error as? V2AuthSessionError) == .sessionInvalidated
        guard sessionEnded || (error as? V2ClientDeviceSessionError) == .authorizationDenied
                || (error as? V2HTTPFailure)?.statusCode == 403 else { return false }
        refreshGeneration &+= 1
        loadMoreGeneration &+= 1
        canManageSessions = false
        baseline = nil
        sessions = []
        hasLoadedSnapshot = false
        nextCursor = nil
        isLoadingMore = false
        state = .failed
        feedback = "当前无法查看或管理登录设备，请重新读取后再操作。"
        return true
    }

    private func invalidateReadsForMutation() {
        refreshGeneration &+= 1
        loadMoreGeneration &+= 1
        isLoadingMore = false
        if hasLoadedSnapshot { state = .loaded }
    }


}

/// 「登录设备」页面视图。
///
/// 展示当前设备与其他登录设备，并提供单设备退出与全部退出入口。
struct V2DeviceSessionsView: View {
    @Bindable var store: V2DeviceSessionsStore
    @State private var pendingCommand: V2RemoteDeviceRevocationCommand?
    @State private var actionTask: Task<Void, Never>?

    var body: some View {
        List {
            switch store.state {
            case .loading where store.sessions.isEmpty:
                Section { HStack { Spacer(); ProgressView("正在读取设备…"); Spacer() } }
            case .failed where store.sessions.isEmpty:
                ContentUnavailableView("无法读取登录设备", systemImage: "laptopcomputer.and.iphone", description: Text("请检查网络后重试。"))
            default:
                currentDeviceSection
                otherDevicesSection
            }
            Section("退出请求") {
                ForEach(store.revocations) { record in
                    VStack(alignment: .leading) {
                        Text("目标设备：\(record.command.targetDeviceIDs.count) 台")
                        if let receipt = record.receipt {
                            switch receipt.outcome {
                            case .revoked: Text("已确认退出").foregroundStyle(.secondary)
                            case .closed: Text("已关闭，未执行").foregroundStyle(.secondary)
                            case .rejected: Text("原请求已被拒绝，请刷新后重新确认").foregroundStyle(.secondary)
                            }
                        } else {
                            Text(record.needsAttention ? "核对已暂停，结果仍未知" : "正在核对原请求").foregroundStyle(.secondary)
                            if record.needsAttention { Button("继续核对") { actionTask = Task { await store.resumeRevocation(record.id) } } }
                        }
                    }
                }
            }
            if let feedback = store.feedback {
                Section { Text(feedback).foregroundStyle(.secondary).onAppear { announceV2AccessibilityAnnouncement(feedback) } }
            }
        }
        .navigationTitle("登录设备")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { actionTask = Task { await store.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                    .disabled(store.isMutating)
                    .accessibilityLabel("刷新登录设备")
                    .accessibilityIdentifier("v2.device-sessions.refresh")
            }
        }
        .task { await store.refresh() }
        .task { await store.observeRevocations() }
        .sheet(isPresented: Binding(get: { pendingCommand != nil }, set: { if !$0 { pendingCommand = nil } })) {
            if let command = pendingCommand {
                NavigationStack {
                    List {
                        Section {
                            Text("仅退出下面已观察的 \(command.targetDeviceIDs.count) 台设备。后来登录的设备不会被加入此请求。")
                        }
                        Section("完整目标范围") {
                            ForEach(command.targetDeviceIDs, id: \.self) { id in
                                VStack(alignment: .leading) {
                                    if let session = store.sessions.first(where: { $0.deviceID == id }) { Text(session.deviceName) }
                                    Text(id.rawValue).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        Section {
                            Button("确认退出列出的设备", role: .destructive) {
                                pendingCommand = nil
                                actionTask = Task { await store.confirm(command) }
                            }
                        }
                    }
                    .navigationTitle("确认退出范围")
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { pendingCommand = nil } } }
                }
            }
        }
        .onDisappear { actionTask?.cancel() }
    }

    private var currentDeviceSection: some View {
        Section("此设备") {
            if let session = store.sessions.first(where: \.isCurrentDevice) {
                sessionRow(session)
            } else if store.state == .loaded {
                Text("当前设备信息暂不可用").foregroundStyle(.secondary)
            }
        }
    }

    private var otherDevicesSection: some View {
        Section("其他登录设备") {
            let others = store.sessions.filter { !$0.isCurrentDevice }
            if others.isEmpty {
                Text("没有其他登录设备").foregroundStyle(.secondary)
            } else {
                ForEach(others) { session in
                    sessionRow(session)
                    Button("退出此设备", role: .destructive) { pendingCommand = store.proposal(selection: .device(session.deviceID)) }
                        .disabled(store.isMutating || !store.canManageSessions)
                        .accessibilityIdentifier("v2.device-sessions.revoke.\(session.deviceID.rawValue)")
                }
                if store.nextCursor != nil {
                    Button {
                        actionTask?.cancel()
                        actionTask = Task { await store.loadMore() }
                    } label: {
                        if store.isLoadingMore { ProgressView() } else { Text("加载更多设备") }
                    }
                    .disabled(store.isLoadingMore || store.isMutating)
                    .accessibilityIdentifier("v2.device-sessions.load-more")
                }
                Button("退出其他所有设备", role: .destructive) { pendingCommand = store.proposal(selection: .allObservedOthers) }
                    .disabled(store.isMutating || !store.canManageSessions)
                    .accessibilityIdentifier("v2.device-sessions.revoke-others")
            }
        }
    }

    private func sessionRow(_ session: V2ClientDeviceSession) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(session.deviceName).fontWeight(.medium)
                Spacer()
                if session.isCurrentDevice { Text("此设备").foregroundStyle(.tint).font(.footnote) }
            }
            Text(session.platform).font(.subheadline).foregroundStyle(.secondary)
            Text("最近活跃 \(session.lastActiveAt, style: .relative)").font(.footnote).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("v2.device-sessions.row.\(session.deviceID.rawValue)")
    }
}
