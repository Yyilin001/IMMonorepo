import ConversationListKit
import SwiftUI
import UIKit

struct V2ConversationPerformanceConfigView: View {
    @State private var config = V2ConversationLoadConfig()

    var body: some View {
        Form {
            Section {
                Picker("模拟场景", selection: Binding(get: { config.scenario }, set: { scenario in
                    var preset = V2ConversationLoadConfig(scenario)
                    preset.seconds = config.seconds
                    config = preset
                })) {
                    ForEach(V2ConversationLoadScenario.allCases, id: \.self) { scenario in
                        Text(scenario.rawValue).tag(scenario)
                    }
                }
                .accessibilityIdentifier("v2.performance.scenario")
            } header: {
                Text("场景")
            } footer: {
                Text(config.scenario.detail)
            }
            Section("负载配置") {
                Picker("初始会话数", selection: $config.count) {
                    ForEach(config.scenario.sizes, id: \.self) { count in Text(count.formatted()).tag(count) }
                }
                Picker(config.scenario == .seek ? "每秒跳转" : "每秒事件", selection: $config.rate) {
                    ForEach(config.scenario.rates, id: \.self) { rate in Text(rate.formatted()).tag(rate) }
                }
                Picker("持续时间", selection: $config.seconds) {
                    ForEach([5, 15, 30, 60], id: \.self) { seconds in Text("\(seconds) 秒").tag(seconds) }
                }
                .accessibilityIdentifier("v2.performance.duration")
                LabeledContent("列表数据源", value: config.scenario.usesWindow ? "有序窗口" : "增量排序")
            }
            Section {
                NavigationLink {
                    V2ConversationPerformanceRunView(config: config)
                } label: {
                    Label("开始测试", systemImage: "play.fill")
                }
                .accessibilityIdentifier("v2.performance.start")
            } footer: {
                Text("会话和事件在本机内存中生成。相同配置使用固定随机种子。点击会话可查看本地聊天，返回列表后继续计时。右滑置顶，左滑隐藏或设置免打扰。")
            }
        }
        .navigationTitle("本地性能测试配置")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct V2ConversationPerformanceRunView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismiss) private var dismiss
    @State private var selectedID: Int?
    @State private var run: V2ConversationPerformanceRun

    init(config: V2ConversationLoadConfig) {
        _run = State(initialValue: V2ConversationPerformanceRun(config))
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(run.phase.rawValue).font(.headline).accessibilityIdentifier("v2.performance.phase")
                    Spacer()
                    Text("\(run.metrics.elapsed, specifier: "%.1f") / \(run.config.seconds) 秒")
                }
                Text("初始 \(run.config.count) 条 · 目标 \(run.config.rate) 次/秒 · \(Self.environmentLabel)")
                    .foregroundStyle(.secondary)
                ProgressView(value: min(run.metrics.elapsed, Double(run.config.seconds)), total: Double(run.config.seconds))
                Text("会话 \(run.metrics.count)　已投递 \(run.metrics.events)　实际 \(run.metrics.throughput, specifier: "%.1f") 次/秒")
                    .accessibilityIdentifier("v2.performance.events")
                let fps = formatted(run.metrics.fps)
                let p95 = formatted(run.metrics.frameP95)
                Text("显示回调 \(fps) FPS　帧间隔 P95 \(p95) ms")
                Text("数据准备 \(formatted(run.preparationMS)) ms　行配置 \(run.metrics.cells) 次")
            }
            .font(.footnote).monospacedDigit().padding(.horizontal).padding(.vertical, 8)
            Divider()
            if run.preparationMS != nil {
                V2ConversationPerformanceList(run: run) { id in
                    if selectedID == nil, run.openChat(id: id) { selectedID = id }
                }
            } else if run.phase == .preparing || run.phase == .idle {
                ProgressView("生成本地会话…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView(run.phase.rawValue, systemImage: "stop.circle")
            }
        }
        .navigationTitle(run.config.scenario.rawValue)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                switch run.phase {
                case .finished, .stopped, .failed:
                    Button("返回配置") { dismiss() }.accessibilityIdentifier("v2.performance.configure")
                default:
                    Button("停止") { run.stop() }.accessibilityIdentifier("v2.performance.stop")
                }
            }
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            if phase == .active { run.prepare() }
            else if phase == .background { run.stop() }
        }
        .navigationDestination(item: $selectedID) { id in
            if let store = run.detailStore(for: id) {
                V2ConversationDetailView(store: store)
                    .task { await run.markChatRead(id: id) }
                    .environment(\.v2AvatarPipeline, nil)
                    .environment(\.v2AuthorPresentationPageScope, nil)
                    .environment(\.v2UserInteractionContext, nil)
                    .environment(\.v2ResourceNavigation, nil)
                    .environment(\.v2ResourceManagement, nil)
                    .environment(\.v2MediaThumbnailCache, nil)
                    .onChange(of: scenePhase) { _, phase in
                        if phase == .background { run.stop() }
                    }
            }
        }
        .onChange(of: selectedID) { _, id in
            if id == nil { run.returnFromChat() }
        }
        .onAppear { if selectedID == nil { run.returnFromChat() } }
        .onDisappear { if selectedID == nil { run.stop() } }
    }

    private static var environmentLabel: String {
        #if targetEnvironment(simulator)
        let device = "模拟器"
        #else
        let device = "真机"
        #endif
        #if DEBUG
        return device + " Debug"
        #else
        return device + " Release"
        #endif
    }

    private func formatted(_ value: Double?) -> String {
        value?.formatted(.number.precision(.fractionLength(1))) ?? "—"
    }
}

private struct V2ConversationPerformanceList: UIViewControllerRepresentable {
    let run: V2ConversationPerformanceRun
    let openChat: (Int) -> Void
    typealias Controller = FixedPositionListController<V2ConversationLoadRow>

    func makeUIViewController(context: Context) -> Controller {
        let controller = Controller(source: run.source, configuration: .init(configure: { cell, row in
            run.cellConfigured()
            cell.accessibilityIdentifier = "v2.performance.cell.\(row.id)"
            let item = run.presentation(for: row)
            cell.contentConfiguration = UIHostingConfiguration {
                Button { openChat(row.id) } label: {
                    V2ConversationSummaryRow(item: item)
                        .environment(\.v2AvatarPipeline, nil)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("v2.performance.room.\(row.id)")
                .id(item.id)
            }.margins(.horizontal, 16).margins(.vertical, 0)
        }, leadingActions: { row in
            V2ConversationSwipeAction.leading(isPinned: row.isPinned) { await run.applySwipe($0, to: row.id) }
        }, trailingActions: { row in
            V2ConversationSwipeAction.trailing(isArchived: false, isMuted: row.isMuted) { await run.applySwipe($0, to: row.id) }
        }, visibleRowsChanged: { rows, _ in
            if !rows.isEmpty { run.firstRowsVisible() }
        }))
        controller.view.accessibilityIdentifier = "v2.performance.list"
        run.controller = controller
        return controller
    }

    func updateUIViewController(_ controller: Controller, context: Context) {}

    static func dismantleUIViewController(_ controller: Controller, coordinator: ()) { controller.stop() }
}

// 旧渲染器保留为性能对照；正式会话页使用 SwiftUI 快照列表。
@MainActor
private extension V2ConversationSwipeAction {
    static func leading(isPinned: Bool, perform: @escaping (Self) async -> Void) -> UISwipeActionsConfiguration {
        actions([action(isPinned ? "取消置顶" : "置顶", image: isPinned ? "pin.slash" : "pin", color: .systemOrange) {
            await perform(.pin(!isPinned))
        }])
    }

    static func trailing(isArchived: Bool, isMuted: Bool, perform: @escaping (Self) async -> Void) -> UISwipeActionsConfiguration {
        actions([
            action(isArchived ? "取消隐藏" : "隐藏", image: "eye.slash", color: .systemIndigo) {
                await perform(.archive(!isArchived))
            },
            action(isMuted ? "恢复提醒" : "免打扰", image: "bell.slash", color: .systemGray) {
                await perform(.mute(!isMuted))
            }
        ])
    }

    private static func actions(_ actions: [UIContextualAction]) -> UISwipeActionsConfiguration {
        let configuration = UISwipeActionsConfiguration(actions: actions)
        configuration.performsFirstActionWithFullSwipe = false
        return configuration
    }

    private static func action(_ title: String, image: String, color: UIColor,
                               perform: @escaping @MainActor () async -> Void) -> UIContextualAction {
        let action = UIContextualAction(style: .normal, title: title) { _, _, complete in
            complete(true)
            Task { await perform() }
        }
        action.image = UIImage(systemName: image)
        action.backgroundColor = color
        return action
    }
}
