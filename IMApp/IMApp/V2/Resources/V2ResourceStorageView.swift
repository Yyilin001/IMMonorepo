import IMV2ClientKit
import IMV2Core
import SwiftUI

struct V2ResourceStorageView: View {
    private struct PlanPresentation: Identifiable { let plan: V2ResourceCleanupPlan; var id: UUID { plan.id } }
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.v2ResourceNavigation) private var navigation
    @State private var store: V2ResourceStorageStore
    @State private var showsUsageExplanation = false
    init(service: V2ResourceManagementService) { _store = State(initialValue: .init(service: service)) }
    var body: some View {
        V2ResourceSettingsPage {
            if let snapshot = store.content.snapshot {
                Section {
                    usage("聊天及其他缓存", bytes: snapshot.otherCacheBytes, symbol: "arrow.clockwise", color: colorScheme == .dark ? .blue : Color(red: 0, green: 0.30, blue: 0.65))
                    usage("头像缓存", bytes: snapshot.avatarCacheBytes, symbol: "person.crop.circle", color: colorScheme == .dark ? .teal : Color(red: 0, green: 0.38, blue: 0.38))
                    usage("保留本机", bytes: snapshot.bytes(for: .retained), symbol: "pin", color: colorScheme == .dark ? .orange : Color(red: 0.58, green: 0.27, blue: 0))
                    usage("待发送原件", bytes: snapshot.bytes(for: .original), symbol: "paperplane", color: colorScheme == .dark ? .green : Color(red: 0, green: 0.38, blue: 0.16))
                    usage("临时传输", bytes: snapshot.transferAllocatedBytes + snapshot.backgroundAllocatedBytes,
                          symbol: "arrow.up.arrow.down", color: colorScheme == .dark ? .purple : Color(red: 0.48, green: 0, blue: 0.62))
                    V2ResourceMetadataRow(title: "合计", value: V2ResourceFormatting.bytes(snapshot.totalBytes))
                } header: { Text("资源文件占用").font(.headline).foregroundStyle(Color.primary) }
                Section {
                    V2ResourceByteLimitPicker(title: "缓存额度", value: snapshot.quota.policy.maximumCacheBytes,
                        options: cacheLimits(snapshot), optionPrefix: "v2.resources.cache-option.", select: store.changeCacheLimit)
                        .disabled(store.isUpdatingPolicy || store.isUpdatingNetwork || store.cleanup.isCommitting || store.isManagingRetention)
                        .accessibilityIdentifier("v2.resources.cache-limit")
                    if store.isUpdatingPolicy { ProgressView("正在更新缓存额度") }
                    if let message = store.policyMessage { Text(message).font(.footnote).foregroundStyle(Color.primary) }
                    if snapshot.quota.retainedWarning { Label("保留文件占用较多，可在资源详情中解除保留。", systemImage: "info.circle").font(.footnote).foregroundStyle(Color.primary) }
                } header: { Text("缓存策略").font(.headline).foregroundStyle(Color.primary) } footer: {
                    Text("降低额度会回收可重建缓存。保留文件、待发送原件和使用中的文件不会因此被删除。").foregroundStyle(Color.primary)
                }
                Section {
                    Button { navigation?.showResourceDownloadSettings() } label: {
                        HStack {
                            V2ResourceNavigationLabel(title: "下载设置", symbol: "arrow.down.circle")
                            Image(systemName: "chevron.right").accessibilityHidden(true)
                        }.foregroundStyle(Color.primary).frame(minHeight: 44)
                    }.buttonStyle(.plain).disabled(navigation == nil)
                        .accessibilityIdentifier("v2.resources.download-settings.open")
                } header: { Text("下载偏好").font(.headline).foregroundStyle(Color.primary) } footer: {
                    Text("管理下载网络、自动下载类型和单个文件上限。").foregroundStyle(Color.primary)
                }
                Section {
                    Button { store.previewUnavailableRetention() } label: {
                        storageActionLabel("管理失效资源保留", symbol: "pin.slash")
                    }.buttonStyle(.plain)
                        .disabled(store.isManagingRetention || store.isUpdatingNetwork || store.isUpdatingPolicy || store.cleanup.isCommitting)
                        .accessibilityIdentifier("v2.resources.retention.unavailable.preview")
                    if store.isManagingRetention { ProgressView("正在处理保留设置") }
                    if let message = store.retentionMessage {
                        Text(message).foregroundStyle(Color.primary)
                            .accessibilityIdentifier("v2.resources.retention.unavailable.feedback")
                    }
                    Button { store.previewCleanup() } label: {
                        storageActionLabel("预览可清理内容", symbol: "trash")
                    }.buttonStyle(.plain)
                        .disabled(isPlanning || store.cleanup.isCommitting || store.isManagingRetention)
                        .accessibilityIdentifier("v2.resources.cleanup.preview")
                    cleanupFeedback
                } header: { Text("释放空间").font(.headline).foregroundStyle(Color.primary) } footer: {
                    Text("只清理本机可重建缓存，不删除消息或云端资源。").foregroundStyle(Color.primary)
                }
            } else if case .initial = store.content { ProgressView("正在读取资源占用") }
            if case .failed(_, let message) = store.content {
                Section { Label(message, systemImage: "exclamationmark.circle").foregroundStyle(Color.primary) }
            }
        }
        .navigationTitle("存储管理").navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Color(uiColor: .systemGroupedBackground), for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarColorScheme(colorScheme, for: .navigationBar)
        .toolbar(.hidden, for: .tabBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("统计说明", systemImage: "info.circle") { showsUsageExplanation = true }
                    .accessibilityIdentifier("v2.resources.storage.explanation")
            }
        }
        .alert("存储统计说明", isPresented: $showsUsageExplanation) {
            Button("好", role: .cancel) { }
        } message: {
            Text("头像缓存单独统计。与聊天共用的头像文件计入聊天及其他缓存，合计不会重复计算。保留本机和待发送原件按各自用途计入，不重复列为缓存。\n\n系统显示的占用可能不同。下载设置影响新下载和重试，已经开始的系统任务不会立即停止。自动预取本机已同步资源，不使用蜂窝、昂贵网络或低数据模式；关闭类型或降低上限不删除已有文件，主动下载不受类型和大小限制。清理只释放本机空间，不删除消息、收藏或云端资源。")
        }
        .sheet(item: Binding(get: { store.retentionPlan }, set: { if $0 == nil { store.dismissUnavailableRetention() } })) { plan in
            NavigationStack {
                List {
                    Section {
                        LabeledContent("本次处理资源版本", value: plan.count.formatted())
                        Text("本次最多处理 \(plan.count) 项当前不可访问的资源版本。不展示失效内容；执行时恢复访问的资源会跳过。")
                            .foregroundStyle(Color.primary)
                        if plan.hasMore { Text("仍有更多，可完成后再次处理。").foregroundStyle(Color.primary) }
                        Text("解除保留不会删除消息或云端文件，也不会立即清理本机字节。")
                            .foregroundStyle(Color.primary)
                    }
                    Section {
                        Button(role: .destructive) { store.releaseUnavailableRetention() } label: {
                            Text("解除本次保留").foregroundStyle(Color.primary).frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        }.accessibilityIdentifier("v2.resources.retention.unavailable.confirm")
                    }
                }
                .accessibilityIdentifier("v2.resources.retention.unavailable.sheet")
                .v2GroupedPageSurface().listRowSpacing(0)
                .navigationTitle("失效资源保留").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("取消", systemImage: "xmark") { store.dismissUnavailableRetention() }
                            .frame(minWidth: 44, minHeight: 44)
                            .accessibilityIdentifier("v2.resources.retention.unavailable.cancel")
                    }
                }
            }
        }
        .accessibilityIdentifier("v2.resources.storage")
        .task { await store.observe() }
        .task(id: store.command) { if let command = store.command { await store.execute(command) } }
        .refreshable { await store.reload(reconcile: true) }
        .sheet(item: Binding(get: { store.cleanup.plan.map { PlanPresentation(plan: $0) } }, set: { if $0 == nil { store.dismissCleanup() } })) { item in
            NavigationStack {
                List {
                    Section {
                        LabeledContent("预计释放", value: V2ResourceFormatting.bytes(item.plan.estimatedBytes))
                        LabeledContent("可清理文件", value: item.plan.fileIDs.count.formatted())
                        LabeledContent("暂存记录", value: item.plan.transferStagingIDs.count.formatted())
                        LabeledContent("本次跳过", value: item.plan.skippedCount.formatted())
                    } footer: { Text("执行前会再次核对使用状态；最终释放量以实际结果为准。") }
                    Section {
                        Button(role: .destructive) { store.commitCleanup() } label: {
                            if store.cleanup.isCommitting { ProgressView("正在清理") }
                            else { Text("清理可回收内容") }
                        }.disabled(store.cleanup.isCommitting || item.plan.fileIDs.isEmpty && item.plan.transferStagingIDs.isEmpty)
                            .accessibilityIdentifier("v2.resources.cleanup.confirm")
                    }
                }
                .v2GroupedPageSurface().navigationTitle("清理预览").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("完成") { store.dismissCleanup() }.disabled(store.cleanup.isCommitting)
                    }
                }
                .interactiveDismissDisabled(store.cleanup.isCommitting)
            }
        }
    }
    private var isPlanning: Bool { if case .planning = store.cleanup { true } else { false } }
    @ViewBuilder private var cleanupFeedback: some View {
        switch store.cleanup {
        case .planning: ProgressView("正在核对可清理内容")
        case .finished(let result):
            Label("已释放 \(V2ResourceFormatting.bytes(result.releasedBytes))", systemImage: "checkmark.circle").foregroundStyle(.green)
            if result.skippedCount > 0 { Text("跳过 \(result.skippedCount) 项受保护或状态已变化的内容。") .font(.footnote).foregroundStyle(Color.primary) }
            if result.failedCount > 0 { Label("\(result.failedCount) 项暂未清理，可稍后重试。", systemImage: "exclamationmark.circle").foregroundStyle(.orange) }
        case .failed(let message): Label(message, systemImage: "exclamationmark.circle").foregroundStyle(Color.primary)
        default: EmptyView()
        }
    }
    private func cacheLimits(_ snapshot: V2ResourceStorageSnapshot) -> [Int64] {
        Array(Set([128,256,512,1024].map { Int64($0) * 1024 * 1024 } + [snapshot.quota.policy.maximumCacheBytes])).sorted()
    }
    private func storageActionLabel(_ title: String, symbol: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: symbol).foregroundStyle(Color.primary).accessibilityHidden(true)
            Text(title).foregroundStyle(Color.primary).fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(.rect)
    }
    private func usage(_ title: String, bytes: Int64, symbol: String, color: Color) -> some View {
        V2ResourceMetadataRow(title: title, value: V2ResourceFormatting.bytes(bytes), symbol: symbol, symbolColor: color)
    }
}


/// A focused destination owns its observation and commands while visible.
/// Returning to storage keeps its existing snapshot; no nested navigation root.
struct V2ResourceDownloadSettingsView: View {
    @Environment(\.colorScheme) private var colorScheme
    @State private var store: V2ResourceStorageStore
    init(service: V2ResourceManagementService) { _store = State(initialValue: .init(service: service)) }
    var body: some View {
        V2ResourceSettingsPage {
            if let network = store.downloadNetworkPreferences {
                Section {
                    Toggle("允许蜂窝网络下载", isOn: Binding(get: { network.allowsCellular }, set: {
                        store.changeDownloadNetwork(.init(allowsCellular: $0, allowsConstrained: network.allowsConstrained, automaticDownloads: network.automaticDownloads))
                    })).accessibilityIdentifier("v2.resources.network.cellular")
                    Toggle("允许低数据模式下载", isOn: Binding(get: { network.allowsConstrained }, set: {
                        store.changeDownloadNetwork(.init(allowsCellular: network.allowsCellular, allowsConstrained: $0, automaticDownloads: network.automaticDownloads))
                    })).accessibilityIdentifier("v2.resources.network.constrained")
                    if store.isUpdatingNetwork { ProgressView("正在保存网络设置") }
                    if let message = store.networkMessage { Text(message).font(.footnote).foregroundStyle(Color.primary) }
                } header: { Text("下载网络").font(.headline).foregroundStyle(Color.primary) } footer: {
                    Text("设置影响新下载和重试，本机已有文件仍可查看。").foregroundStyle(Color.primary)
                }
                .disabled(store.isUpdatingNetwork || store.isUpdatingPolicy || store.cleanup.isCommitting)
            }
            if let network = store.downloadNetworkPreferences {
                Section {
                    automaticToggle("图片", category: .image, policy: network.automaticDownloads)
                    automaticToggle("视频", category: .video, policy: network.automaticDownloads)
                    automaticToggle("音频", category: .audio, policy: network.automaticDownloads)
                    automaticToggle("文件", category: .file, policy: network.automaticDownloads)
                    V2ResourceByteLimitPicker(title: "单个文件上限", value: network.automaticDownloads.maximumByteCount,
                        options: Array(Set([1,5,10,25,50].map { Int64($0) * 1024 * 1024 } + [network.automaticDownloads.maximumByteCount])).sorted(),
                        optionPrefix: "v2.resources.automatic.option.", select: store.changeAutomaticLimit)
                        .accessibilityIdentifier("v2.resources.automatic.limit")
                } header: { Text("自动下载").font(.headline).foregroundStyle(Color.primary) } footer: {
                    Text("聊天默认仅加载缩略图。此处控制原件的自动下载，仅使用非昂贵、非受限的 Wi-Fi。").foregroundStyle(Color.primary)
                }.disabled(store.isUpdatingNetwork || store.isUpdatingPolicy || store.cleanup.isCommitting)
            }
            if store.downloadNetworkPreferences == nil, case .initial = store.content {
                ProgressView("正在读取下载设置")
            }
            if case .failed(_, let message) = store.content {
                Section { Label(message, systemImage: "exclamationmark.circle").foregroundStyle(Color.primary) }
            }
        }
        .navigationTitle("下载设置").navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Color(uiColor: .systemGroupedBackground), for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarColorScheme(colorScheme, for: .navigationBar)
        .toolbar(.hidden, for: .tabBar)
        .accessibilityIdentifier("v2.resources.download-settings")
        .task { await store.observe(reconcile: false) }
        .task(id: store.command) { if let command = store.command { await store.execute(command) } }
        .refreshable { await store.reload() }
    }
    private func automaticToggle(_ title: String, category: V2ResourceCategory, policy: V2ResourceAutomaticDownloadPolicy) -> some View {
        Toggle(title, isOn: Binding(get: { policy.categories.contains(category) }, set: { store.changeAutomaticCategory(category, enabled: $0) }))
            .accessibilityIdentifier("v2.resources.automatic." + category.rawValue)
    }
}


/// Settings have a bounded number of rows. Keep their native controls mounted
/// while system text sizes change instead of recycling off-screen list cells.
/// The resource directory and transfer history remain virtualized lists.
private struct V2ResourceSettingsPage<Content: View>: View {
    let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                ForEach(sections: content) { section in
                    VStack(alignment: .leading, spacing: 10) {
                        if !section.header.isEmpty {
                            VStack(alignment: .leading, spacing: 4) {
                                ForEach(section.header) { $0 }
                            }.padding(.horizontal, 16).accessibilityAddTraits(.isHeader)
                        }
                        if !section.content.isEmpty {
                            VStack(alignment: .leading, spacing: 0) {
                                ForEach(section.content) { row in
                                    if row.id != section.content.first?.id {
                                        Divider().padding(.horizontal, 16)
                                    }
                                    row.frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(.horizontal, 16).padding(.vertical, 12)
                                }
                            }
                            .background(Color(uiColor: .secondarySystemGroupedBackground),
                                in: RoundedRectangle(cornerRadius: 20))
                        }
                        if !section.footer.isEmpty {
                            VStack(alignment: .leading, spacing: 4) {
                                ForEach(section.footer) { $0 }
                            }.font(.footnote).padding(.horizontal, 16)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            }.padding(.horizontal, 16).padding(.vertical, 20)
        }
        .background(Color(uiColor: .systemGroupedBackground))
    }
}
