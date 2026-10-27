import IMV2ClientKit
import IMV2Core
import SwiftUI

struct V2ResourceTransferView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.v2ResourceNavigation) private var navigation
    private struct Selection: Identifiable { let id: V2ManagedResourceTransferID }
    @State private var store: V2ResourceTransferStore
    @State private var selection: Selection?
    @State private var showingBatchExplanation = false
    init(service: V2ResourceManagementService) { _store = State(initialValue: .init(service: service)) }
    var body: some View {
        @Bindable var store = store
        List {
            Section {
                if dynamicTypeSize.isAccessibilitySize {
                    statusPicker.pickerStyle(.navigationLink)
                } else { statusPicker.pickerStyle(.segmented) }
            }.disabled(store.isPerforming)
            batchControls.disabled(!store.hasCurrentPage)
            Section {
                switch store.content {
                case .initial: ProgressView("正在读取传输记录")
                case .unavailable:
                    ContentUnavailableView {
                        Label("传输记录暂不可用", systemImage: "arrow.up.arrow.down")
                    } description: { Text(store.readFailure ?? "请重新读取。") } actions: {
                        Button("重新读取", systemImage: "arrow.clockwise") { store.retryRead() }
                            .disabled(store.isPerforming)
                            .accessibilityIdentifier("v2.resources.transfers.retry-read")
                    }
                case .available(let page):
                    if page.entries.isEmpty {
                        ContentUnavailableView(Self.empty(store.group), systemImage: "arrow.up.arrow.down")
                    }
                    ForEach(page.entries) { transfer in
                        VStack(alignment: .leading, spacing: 10) {
                            if let selected = store.batchSelection {
                                Button { store.toggleBatchSelection(transfer.id) } label: {
                                    HStack(alignment: .top, spacing: 12) {
                                        Image(systemName: selected.contains(transfer.id) ? "checkmark.circle.fill" : "circle")
                                            .foregroundStyle(Color.primary).accessibilityHidden(true)
                                        transferHeading(transfer)
                                    }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(.rect)
                                }.buttonStyle(.plain).disabled(store.isPerforming)
                                    .accessibilityElement(children: .ignore)
                                    .accessibilityAddTraits(.isButton)
                                    .accessibilityLabel(Text("选择任务：\((Self.name(transfer) as NSString).deletingPathExtension)"))
                                    .accessibilityValue(Self.status(transfer))
                                    .accessibilityHint(selected.contains(transfer.id) ? "取消选择此任务" : "选择此任务")
                                    .accessibilityAddTraits(selected.contains(transfer.id) ? .isSelected : [])
                                    .accessibilityIdentifier("v2.resources.transfers.selection.item." + transfer.idLabel)
                            } else { transferHeading(transfer) }
                            Button { selection = .init(id: transfer.id) } label: {
                                statusLabel(transfer).font(.subheadline)
                            }.buttonStyle(V2ResourceTransferActionStyle()).accessibilityHint("查看当前状态的详细说明")
                            if let total = transfer.totalBytes {
                                if let confirmed = transfer.confirmedBytes {
                                    Text("已确认 \(V2ResourceFormatting.bytes(confirmed)) / \(V2ResourceFormatting.bytes(total))")
                                        .font(.caption).foregroundStyle(Color.primary)
                                } else { Text(V2ResourceFormatting.bytes(total)).font(.caption).foregroundStyle(Color.primary) }
                            }
                            if let progress = transfer.attemptProgress {
                                let progressLabel = transfer.purpose == .download ? "本段下载" : "本次上传"
                                ProgressView(value: Double(progress.transferredBytes), total: Double(progress.expectedBytes))
                                    .accessibilityLabel(progressLabel + "进度")
                                    .accessibilityValue("\(V2ResourceFormatting.bytes(progress.transferredBytes))，共 \(V2ResourceFormatting.bytes(progress.expectedBytes))")
                                Text("\(progressLabel) \(V2ResourceFormatting.bytes(progress.transferredBytes)) / \(V2ResourceFormatting.bytes(progress.expectedBytes))")
                                    .font(.caption).foregroundStyle(Color.primary)
                                    .accessibilityIdentifier("v2.resources.transfers.progress." + transfer.idLabel)
                            }
                            if store.batchSelection == nil {
                            if transfer.actions.contains(.retry) {
                                Button("继续处理", systemImage: "arrow.clockwise") { store.retry(transfer.id) }
                                    .disabled(store.isPerforming).buttonStyle(V2ResourceTransferActionStyle())
                                    .accessibilityIdentifier("v2.resources.transfers.retry." + transfer.idLabel)
                            }
                            if transfer.phase == .requiresAttention(.space) || transfer.phase == .failed(.space) {
                                Button("管理本机存储", systemImage: "internaldrive") { navigation?.path.append(V2ResourceRoute.storage) }
                                    .buttonStyle(V2ResourceTransferActionStyle())
                                    .accessibilityIdentifier("v2.resources.transfers.manage-storage." + transfer.idLabel)
                            }
                            if transfer.actions.contains(.cancel) {
                                Button(transfer.cancellableMessageCount == nil ? "取消下载" : "取消发送", systemImage: "xmark.circle", role: .destructive) { store.cancel(transfer.id) }
                                    .disabled(store.isPerforming).buttonStyle(V2ResourceTransferActionStyle())
                                    .accessibilityIdentifier("v2.resources.transfers.cancel." + transfer.idLabel)
                            }
                            if transfer.actions.contains(.retryCancellation) {
                                Button("继续确认取消", systemImage: "arrow.clockwise") { store.retryCancellation(transfer.id) }
                                    .disabled(store.isPerforming).buttonStyle(V2ResourceTransferActionStyle())
                                    .accessibilityIdentifier("v2.resources.transfers.retry-cancellation." + transfer.idLabel)
                            }
                            if transfer.actions.contains(.cancelUnbound) {
                                Button("取消任务", systemImage: "xmark.circle", role: .destructive) { store.cancelUnbound(transfer.id) }
                                    .disabled(store.isPerforming).buttonStyle(V2ResourceTransferActionStyle())
                                    .accessibilityIdentifier("v2.resources.transfers.cancel-unbound." + transfer.idLabel)
                            }
                            if transfer.actions.contains(.pause) {
                                Button(Self.pauseTitle(transfer.purpose), systemImage: "pause.circle") { store.pause(transfer.id) }
                                    .disabled(store.isPerforming).buttonStyle(V2ResourceTransferActionStyle())
                                    .accessibilityIdentifier("v2.resources.transfers.pause." + transfer.idLabel)
                            }
                            if transfer.actions.contains(.resume) {
                                Button(Self.resumeTitle(transfer.purpose), systemImage: "play.circle") { store.resume(transfer.id) }
                                    .disabled(store.isPerforming).buttonStyle(V2ResourceTransferActionStyle())
                                    .accessibilityIdentifier("v2.resources.transfers.resume." + transfer.idLabel)
                            }
                            if let resource = transfer.resource {
                                NavigationLink(value: V2ResourceRoute.detail(resource)) { Label("查看资源", systemImage: "doc.text.magnifyingglass").frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(.rect) }
                            }
                            if transfer.hasBusinessOwners {
                                NavigationLink(value: V2ResourceRoute.businessOwners(transfer.id)) { Label("处理相关更改", systemImage: "person.crop.circle").frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(.rect) }
                                    .accessibilityIdentifier("v2.resources.transfers.owners." + transfer.idLabel)
                            }
                            }
                        }.padding(.vertical, 6).disabled(!store.hasCurrentPage)
                    }
                }
                } footer: { Text("文件传输完成后，仍需通过校验才能使用。").foregroundStyle(Color.primary) }
            if store.content.page != nil, let message = store.readFailure {
                Section {
                    Text(message + " 当前显示上次读取的记录，重新读取后可继续操作。")
                        .font(.footnote).foregroundStyle(.secondary)
                    Button("重新读取", systemImage: "arrow.clockwise") { store.retryRead() }
                        .disabled(store.isPerforming)
                        .accessibilityIdentifier("v2.resources.transfers.retry-read")
                }
            }
            if store.pageNumber > 1 || store.content.page?.nextCursor != nil {
                Section {
                    HStack {
                        Button("上一页") { store.previousPage() }.disabled(store.pageNumber == 1)
                        Spacer(); Text("第 \(store.pageNumber) 页").font(.footnote); Spacer()
                        Button("下一页") { store.nextPage() }.disabled(!store.canGoNextPage)
                    }
                }
            }
        }
        .accessibilityIdentifier("v2.resources.transfers")
        .id(dynamicTypeSize)
        .safeAreaInset(edge: .top, spacing: 0) {
            if let feedback = store.feedback {
                Text(feedback).font(.footnote).foregroundStyle(Color.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(Color(uiColor: .secondarySystemGroupedBackground))
                    .accessibilityIdentifier("v2.resources.transfers.feedback")
            }
        }
        .v2GroupedPageSurface().listRowSpacing(0)
        .navigationTitle("传输任务").navigationBarTitleDisplayMode(.inline).toolbar(.hidden, for: .tabBar)
        .toolbarBackground(Color(uiColor: .systemGroupedBackground), for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarColorScheme(colorScheme, for: .navigationBar)
        .toolbar {
            if store.batchSelection != nil || store.canBeginBatchSelection {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(store.batchSelection == nil ? "选择" : "完成", systemImage: store.batchSelection == nil ? "checkmark.circle" : "checkmark") { store.toggleBatchMode() }
                        .labelStyle(.iconOnly).foregroundStyle(Color.primary).frame(minWidth: 44, minHeight: 44)
                        .disabled(store.isPerforming)
                        .accessibilityIdentifier("v2.resources.transfers.selection.mode")
                }
            }
        }
        .alert("批量处理说明", isPresented: $showingBatchExplanation) {
            Button("好", role: .cancel) { }
        } message: {
            Text("只处理当前支持所选动作的任务。暂停的任务不会自动恢复；取消结果未知时只继续确认取消，不会重新发送。切换页码或任务分组会结束选择。")
        }
        .task(id: store.observationID) { await store.observe() }
        .task(id: store.command) { if let request = store.command { await store.execute(request) } }
        .task(id: store.batchCommand) { if let request = store.batchCommand { await store.executeBatch(request) } }
        .confirmationDialog("取消待发送消息", isPresented: Binding(get: { store.cancellationPlan != nil }, set: { if !$0 { store.dismissCancellation() } })) {
            if let plan = store.cancellationPlan {
                Button("取消 \(plan.messageCount) 条消息", role: .destructive) { store.confirmCancellation(plan) }
                    .accessibilityIdentifier("v2.resources.transfers.cancel-messages.confirm")
                Button("继续保留") { store.dismissCancellation() }
                    .accessibilityIdentifier("v2.resources.transfers.cancel-messages.keep")
            }
        } message: {
            if let plan = store.cancellationPlan { Text("将取消 \(plan.messageCount) 条待发送消息，并停止它们不再共用的附件准备。") }
        }
        .confirmationDialog("取消这个任务？", isPresented: Binding(get: { store.unboundCancellationPlan != nil }, set: { if !$0 { store.dismissUnboundCancellation() } })) {
            if let plan = store.unboundCancellationPlan {
                Button("取消任务", role: .destructive) { store.confirmUnboundCancellation(plan) }
                    .accessibilityIdentifier("v2.resources.transfers.cancel-unbound.confirm")
                Button("继续保留") { store.dismissUnboundCancellation() }
                    .accessibilityIdentifier("v2.resources.transfers.cancel-unbound.keep")
            }
        } message: {
            Text("已有消息和头像不会被删除，取消结果仍需确认。")
        }
        .sheet(item: $selection) { selected in
            NavigationStack {
                List {
                    if let transfer = store.content.page?.entries.first(where: { $0.id == selected.id }) {
                        Section {
                            Text(Self.name(transfer)).font(.headline).accessibilityLabel("文件名称").accessibilityValue(Self.name(transfer))
                            statusLabel(transfer)
                            Text(Self.explanation(transfer)).foregroundStyle(Color.primary)
                        }
                    } else { ContentUnavailableView("任务状态已更新", systemImage: "arrow.clockwise", description: Text("关闭后查看最新记录。")) }
                }.id(dynamicTypeSize).v2GroupedPageSurface().navigationTitle("传输状态").navigationBarTitleDisplayMode(.inline)
                    .toolbarBackground(Color(uiColor: .systemGroupedBackground), for: .navigationBar)
                    .toolbarBackground(.visible, for: .navigationBar)
                    .toolbarColorScheme(colorScheme, for: .navigationBar)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成", systemImage: "checkmark") { selection = nil }.labelStyle(.iconOnly).frame(minWidth: 44, minHeight: 44) } }
            }
        }
    }
    private func transferHeading(_ transfer: V2ManagedResourceTransfer) -> some View {
        HStack(alignment: .top, spacing: 12) {
                                Image(systemName: Self.symbol(transfer.purpose)).foregroundStyle(transfer.waitingReason == nil ? Self.color(transfer.phase) : .secondary)
                                    .font(.title2).frame(minWidth: 30).accessibilityHidden(true)
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(Self.name(transfer)).font(.body.weight(.medium)).lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                                        .accessibilityLabel("文件名称").accessibilityValue(Self.name(transfer))
                                        .accessibilityIdentifier("v2.resources.transfers.item." + transfer.idLabel)
                                    Text(transfer.createdAt, format: .dateTime.month().day().hour().minute()).font(.caption).foregroundStyle(Color.primary)
                                }
                            }
    }
    @ViewBuilder private var batchControls: some View {
        if let selected = store.batchSelection {
            Section {
                Button { store.selectBatchPage() } label: {
                    Label { Text("全选本页").fixedSize(horizontal: false, vertical: true) }
                    icon: { Image(systemName: "checkmark.circle").accessibilityHidden(true) }
                }.buttonStyle(V2ResourceTransferActionStyle()).disabled(store.isPerforming)
                    .accessibilityIdentifier("v2.resources.transfers.selection.all")
                Button { store.requestBatch(.retry) } label: {
                    Label { Text("重试失败任务").fixedSize(horizontal: false, vertical: true) }
                    icon: { Image(systemName: "arrow.clockwise").accessibilityHidden(true) }
                }.buttonStyle(V2ResourceTransferActionStyle())
                    .disabled(store.isPerforming || store.batchEligibleCount(.retry) == 0)
                    .accessibilityIdentifier("v2.resources.transfers.selection.retry")
                Button { store.requestBatch(.confirmCancellation) } label: {
                    Label { Text("继续确认所选取消").fixedSize(horizontal: false, vertical: true) }
                    icon: { Image(systemName: "arrow.triangle.2.circlepath").accessibilityHidden(true) }
                }.buttonStyle(V2ResourceTransferActionStyle())
                    .disabled(store.isPerforming || store.batchEligibleCount(.confirmCancellation) == 0)
                    .accessibilityIdentifier("v2.resources.transfers.selection.confirm-cancellation")
                Text("可重试 \(store.batchEligibleCount(.retry).formatted()) 项，可继续确认取消 \(store.batchEligibleCount(.confirmCancellation).formatted()) 项。")
                    .font(.footnote).foregroundStyle(Color.primary)
                Button { showingBatchExplanation = true } label: {
                    Label { Text("处理说明").fixedSize(horizontal: false, vertical: true) }
                    icon: { Image(systemName: "info.circle").accessibilityHidden(true) }
                }.buttonStyle(V2ResourceTransferActionStyle())
                    .accessibilityIdentifier("v2.resources.transfers.selection.explanation")
                if store.isBatchBusy { ProgressView("正在处理所选任务") }
            } header: { Text("已选择 \(selected.count.formatted()) 项").foregroundStyle(Color.primary) }
        }
        if !store.batchFailures.isEmpty {
            Section { ForEach(store.batchFailures, id: \.self) { Text($0).font(.footnote).foregroundStyle(Color.primary) } }
        }
    }
    private var statusPicker: some View {
        @Bindable var store = store
        return Picker("任务状态", selection: $store.group) {
            ForEach(V2ResourceTransferGroup.allCases, id: \.self) { group in
                Text(Self.title(group)).tag(group).accessibilityIdentifier("v2.resources.transfers.group." + String(describing: group))
            }
        }.accessibilityIdentifier("v2.resources.transfers.filter")
    }
    private func statusLabel(_ transfer: V2ManagedResourceTransfer) -> some View {
        Label {
            Text(Self.status(transfer)).foregroundStyle(Color.primary)
        } icon: {
            Image(systemName: "info.circle").foregroundStyle(transfer.waitingReason == nil ? Self.color(transfer.phase) : .secondary)
        }
    }
    private static func title(_ group: V2ResourceTransferGroup) -> String {
        switch group { case .active: "进行中"; case .attention: "需处理"; case .finished: "已结束" }
    }
    private static func empty(_ group: V2ResourceTransferGroup) -> String {
        switch group { case .active: "暂无进行中的任务"; case .attention: "暂无需要处理的任务"; case .finished: "暂无已结束的记录" }
    }
    private static func symbol(_ purpose: V2ResourceTransferPurpose) -> String {
        switch purpose { case .attachment: "arrow.up.doc"; case .personalAvatar: "person.crop.square"; case .groupAvatar: "person.2"; case .download: "arrow.down.doc"; case .serverImport: "doc.on.doc" }
    }
    private static func name(_ item: V2ManagedResourceTransfer) -> String {
        if let name = item.displayName { return name.value }
        switch item.purpose { case .download: return "下载文件"; case .serverImport: return "复制资源"; case .personalAvatar: return "个人头像"; case .groupAvatar: return "群头像"; case .attachment: return "消息附件" }
    }
    private static func status(_ phase: V2ManagedResourceTransferPhase) -> String {
        switch phase {
        case .queued: "已排队"
        case .resolvingMetadata: "等待资源信息"
        case .preparing: "正在准备"; case .transferring: "正在传输"; case .confirming: "正在确认原操作"; case .verifying: "正在校验"
        case .processing: "正在处理"; case .pausing: "正在暂停"; case .paused: "已暂停"; case .cancelling: "正在取消"; case .waitingRetry: "等待自动重试"
        case .requiresAttention(.cancellationUnconfirmed): "取消待确认"
        case .requiresAttention(.space), .failed(.space): "本机空间不足"
        case .requiresAttention: "需要处理"; case .completed: "传输完成"; case .cancelled: "已取消"; case .failed: "无法完成"
        }
    }
    private static func pauseTitle(_ purpose: V2ResourceTransferPurpose) -> String {
        switch purpose { case .download: "暂停下载"; case .serverImport: "暂停本机跟进"; default: "暂停上传" }
    }
    private static func resumeTitle(_ purpose: V2ResourceTransferPurpose) -> String {
        switch purpose { case .download: "继续下载"; case .serverImport: "继续跟进"; default: "继续上传" }
    }
    private static func status(_ transfer: V2ManagedResourceTransfer) -> String {
        if let waiting = transfer.waitingReason {
            return switch waiting {
            case .network: "等待网络"
            case .networkPolicy: "等待允许自动下载的网络"
            case .transferSlot: "等待传输名额"
            case .requestSlot: "等待请求名额"
            case .serviceCooldown: "等待服务恢复额度"
            }
        }
        if transfer.purpose == .serverImport {
            if transfer.phase == .pausing { return "正在暂停本机跟进" }
            if transfer.phase == .paused { return "本机跟进已暂停" }
        }
        return status(transfer.phase)
    }
    private static func explanation(_ transfer: V2ManagedResourceTransfer) -> String {
        if let waiting = transfer.waitingReason {
            return switch waiting {
            case .network: "尚未获得可用网络，自动下载意图已保留。网络恢复后会按原任务继续。"
            case .networkPolicy: "当前网络不符合自动下载条件。连接不受限的 Wi-Fi 后会继续；也可以主动下载该文件。"
            case .transferSlot: "其他实际传输仍占用名额。任务会在名额释放后继续，离开页面不会重复建立任务。"
            case .requestSlot: "账号中的其他请求正在执行。正在等待请求名额，不需要重复点击。"
            case .serviceCooldown: "服务端冷却或重试额度暂不允许请求。将按调度规则继续，不会跳过冷却时间。"
            }
        }
        if transfer.purpose == .serverImport {
            if transfer.phase == .pausing { return "已请求停止本机后续查询，正在等待当前请求结束。服务器仍可能继续复制和处理资源。" }
            if transfer.phase == .paused { return "本机已停止后续查询，服务器仍可能继续复制和处理资源。继续时将确认同一导入操作，不会新建复制任务。" }
        }
        return explanation(transfer.phase)
    }
    private static func color(_ phase: V2ManagedResourceTransferPhase) -> Color {
        switch phase { case .failed, .requiresAttention: .red; case .completed: .green; case .queued, .resolvingMetadata, .paused, .cancelled, .waitingRetry: .secondary; default: .accentColor }
    }
    private static func explanation(_ phase: V2ManagedResourceTransferPhase) -> String {
        switch phase {
        case .queued: "任务意图已保存在本机，等待账号调度。离开页面不会取消任务；开始前仍会验证当前权限和传输条件。"
        case .resolvingMetadata: "下载需求已保存在本机，正在等待获取资源版本、大小和访问许可。离开页面不会取消任务。"
        case .preparing: "正在准备原文件与传输条件。离开页面不会取消账号任务。"
        case .transferring: "正在传输文件。显示的已确认字节来自实际回执。"
        case .confirming: "原操作的结果仍需确认，将继续核对同一操作，避免重复提交。"
        case .verifying: "字节已到达，正在验证文件或等待验证结果。"
        case .processing: "服务端正在处理资源，完成后才能继续使用。"
        case .pausing: "正在停止本次传输，原文件和任务记录会保留，等待实际传输结束后才会显示已暂停。"
        case .paused: "本机传输已暂停。继续时会确认原操作和访问权限，上传可能从头重传；服务端已收到的操作仍可能继续处理。"
        case .cancelling: "取消已请求，正在等待实际传输停止并回收临时文件。"
        case .waitingRetry(let date): "暂时无法继续，最早将在 \(date.formatted(date: .omitted, time: .shortened)) 再次尝试。"
        case .requiresAttention(let reason), .failed(let reason):
            switch reason {
            case .automaticDownloadRestricted: "自动下载设置不允许此文件，可调整设置或主动下载。"
            case .network: "网络请求暂未完成。可继续处理原任务。"
            case .integrity: "下载文件未通过校验，请重新获取文件。"
            case .space: "本机空间不足，请释放空间后重新获取文件。"
            case .sourceUnavailable: "文件来源或访问权限当前不可用，请检查原消息或重新选择。"
            case .expired: "本次资源操作已过期，需要重新选择并发起操作。"
            case .rejected: "本次资源操作被拒绝或未通过验证，无法直接恢复。"
            case .needsAttention: "自动处理已暂停。若提供“继续处理”，可恢复同一任务；否则请从对应资源或消息查看处理方式。"
            case .cancellationUnconfirmed: "取消结果尚未确认，自动确认已暂停。可继续确认原取消操作；已取消的待发送消息不会恢复发送。"
            }
        case .completed: "资源传输已完成。消息的发送确认由聊天中的消息状态展示。"
        case .cancelled: "本次传输操作已取消。"
        }
    }
}

private extension V2ManagedResourceTransfer {
    var idLabel: String { switch id { case .upload(let id): "upload." + id.uuidString; case .download(let id): "download." + id.uuidString; case .serverImport(let id): "import." + id.uuidString } }
}

private struct V2ResourceTransferActionStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body)
            .foregroundStyle(Color.primary)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(.rect)
            .opacity(!isEnabled ? 0.5 : configuration.isPressed ? 0.65 : 1)
    }
}
