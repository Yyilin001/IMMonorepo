import IMV2ClientKit
import SwiftUI

struct V2ResourceSelectionCleanupView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.colorScheme) private var colorScheme
    @Bindable var selection: V2ResourceSelectionStore
    let preview: V2ResourceSelectionCleanupPlan
    var body: some View {
        NavigationStack {
            List {
                Section {
                    V2ResourceMetadataRow(title: "所选资源", value: preview.resourceCount.formatted())
                    V2ResourceMetadataRow(title: "预计释放", value: V2ResourceFormatting.bytes(preview.plan.estimatedBytes))
                    V2ResourceMetadataRow(title: "可清理本机文件", value: preview.plan.fileIDs.count.formatted())
                    V2ResourceMetadataRow(title: "未下载资源", value: preview.absentResourceCount.formatted())
                    V2ResourceMetadataRow(title: "当前不可访问资源", value: preview.unavailableResourceCount.formatted())
                    V2ResourceMetadataRow(title: "受保护文件", value: preview.plan.skippedCount.formatted())
                }
                Section {
                    Text("仅清理所选资源对应的本机缓存，不删除消息或云端资源。多个来源可能共用同一文件，清理后都可能需要重新下载。使用中、保留本机及待发送原件会跳过；执行前再次核对，最终释放量以实际结果为准。")
                        .foregroundStyle(Color.primary)
                    Button(role: .destructive) { selection.commitCleanup() } label: {
                        if selection.isBusy { ProgressView("正在清理") }
                        else { Text("清理所选缓存") }
                    }.buttonStyle(V2PrimaryButtonStyle())
                        .disabled(selection.isBusy || preview.plan.fileIDs.isEmpty)
                        .accessibilityIdentifier("v2.resources.selection.cleanup.confirm")
                }
            }.id(dynamicTypeSize).v2GroupedPageSurface()
                .navigationTitle("所选缓存清理").navigationBarTitleDisplayMode(.inline)
                .toolbarBackground(Color(uiColor: .systemGroupedBackground), for: .navigationBar)
                .toolbarBackground(.visible, for: .navigationBar)
                .toolbarColorScheme(colorScheme, for: .navigationBar)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("完成", systemImage: "checkmark") { selection.dismissCleanup() }
                            .labelStyle(.iconOnly).frame(minWidth: 44, minHeight: 44).disabled(selection.isBusy)
                            .accessibilityIdentifier("v2.resources.selection.cleanup.done")
                    }
                }
                .interactiveDismissDisabled(selection.isBusy)
        }
    }
}
