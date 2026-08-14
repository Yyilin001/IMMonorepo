import IMV2ClientKit
import IMV2Core
import Observation
import SwiftUI

@MainActor
@Observable
final class V2DeviceSessionsStore {
    enum State: Equatable { case loading, loaded, failed }

    private let manager: any V2ClientDeviceSessionManaging
    private let makeUUID: @Sendable () -> UUID
    private(set) var state: State = .loading
    private(set) var sessions: [V2ClientDeviceSession] = []
    private(set) var feedback: String?
    private(set) var isMutating = false
    private(set) var isLoadingMore = false
    private(set) var nextCursor: String?
    private var refreshGeneration = 0
    private let pageSize = 50

    init(manager: any V2ClientDeviceSessionManaging, makeUUID: @escaping @Sendable () -> UUID = { UUID() }) {
        self.manager = manager
        self.makeUUID = makeUUID
    }

    func refresh() async {
        refreshGeneration &+= 1
        let generation = refreshGeneration
        state = .loading
        do {
            let page = try await manager.list(cursor: nil, pageSize: pageSize)
            try Task.checkCancellation()
            guard generation == refreshGeneration else { return }
            sessions = page.sessions
            nextCursor = page.nextCursor
            state = .loaded
            feedback = nil
        } catch is CancellationError {
        } catch {
            guard generation == refreshGeneration else { return }
            state = .failed
            feedback = "无法读取登录设备，请稍后重试。"
        }
    }

    func loadMore() async {
        guard let cursor = nextCursor, !isLoadingMore, state == .loaded else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        do {
            let page = try await manager.list(cursor: cursor, pageSize: pageSize)
            try Task.checkCancellation()
            let existing = Set(sessions.map(\.deviceID))
            sessions.append(contentsOf: page.sessions.filter { !existing.contains($0.deviceID) })
            nextCursor = page.nextCursor
        } catch is CancellationError {
        } catch {
            feedback = "无法继续读取登录设备，请稍后重试。"
        }
    }

    func revoke(_ session: V2ClientDeviceSession) async {
        guard !session.isCurrentDevice, !isMutating else { return }
        isMutating = true
        defer { isMutating = false }
        do {
            try await manager.revoke(deviceID: session.deviceID, operationID: makeUUID())
            try Task.checkCancellation()
            sessions.removeAll { $0.deviceID == session.deviceID }
            feedback = "已退出该设备。"
        } catch is CancellationError {
        } catch V2ClientDeviceSessionError.sessionUnavailable {
            sessions.removeAll { $0.deviceID == session.deviceID }
            feedback = "该设备已退出。"
        } catch {
            feedback = "无法退出该设备，请检查网络后重试。"
        }
    }

    func revokeOtherDevices() async {
        guard !isMutating else { return }
        isMutating = true
        defer { isMutating = false }
        do {
            try await manager.revokeOtherDevices(operationID: makeUUID())
            try Task.checkCancellation()
            sessions.removeAll { !$0.isCurrentDevice }
            feedback = "已退出其他所有设备。"
        } catch is CancellationError {
        } catch {
            feedback = "无法退出其他设备，请检查网络后重试。"
        }
    }
}

struct V2DeviceSessionsView: View {
    @Bindable var store: V2DeviceSessionsStore
    @State private var sessionPendingRevocation: V2ClientDeviceSession?
    @State private var confirmsOtherDevices = false
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
        .confirmationDialog("退出此设备？", isPresented: Binding(get: { sessionPendingRevocation != nil }, set: { if !$0 { sessionPendingRevocation = nil } }), titleVisibility: .visible, presenting: sessionPendingRevocation) { session in
            Button("退出设备", role: .destructive) {
                actionTask?.cancel()
                actionTask = Task { await store.revoke(session) }
            }
        } message: { session in
            Text("\(session.deviceName) 将需要重新登录。")
        }
        .confirmationDialog("退出其他所有设备？", isPresented: $confirmsOtherDevices, titleVisibility: .visible) {
            Button("退出其他设备", role: .destructive) {
                actionTask?.cancel()
                actionTask = Task { await store.revokeOtherDevices() }
            }
        } message: {
            Text("其他设备会立即失去会话，需要重新登录。")
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
                    Button("退出此设备", role: .destructive) { sessionPendingRevocation = session }
                        .disabled(store.isMutating)
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
                Button("退出其他所有设备", role: .destructive) { confirmsOtherDevices = true }
                    .disabled(store.isMutating)
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
