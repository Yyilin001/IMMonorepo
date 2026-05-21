import IMClientKit
import SwiftUI

struct IMMessageMediaBubble<Header: View>: View {
    let title: String
    let subtitle: String
    let mediaDownloadState: IMMediaDownloadState?
    let header: Header
    let onDownloadMedia: () -> Void
    let onCancelMediaDownload: () -> Void
    let onRetryMediaDownload: () -> Void
    let onOpenDownloadedMedia: (URL) -> Void
    let onDeleteDownloadedMedia: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            Text(title)
                .font(.body.weight(.medium))
                .lineLimit(2)
            if !subtitle.isEmpty {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            IMMessageMediaDownloadControls(
                mediaDownloadState: mediaDownloadState,
                onDownloadMedia: onDownloadMedia,
                onCancelMediaDownload: onCancelMediaDownload,
                onRetryMediaDownload: onRetryMediaDownload,
                onOpenDownloadedMedia: onOpenDownloadedMedia,
                onDeleteDownloadedMedia: onDeleteDownloadedMedia
            )
        }
    }
}

private struct IMMessageMediaDownloadControls: View {
    let mediaDownloadState: IMMediaDownloadState?
    let onDownloadMedia: () -> Void
    let onCancelMediaDownload: () -> Void
    let onRetryMediaDownload: () -> Void
    let onOpenDownloadedMedia: (URL) -> Void
    let onDeleteDownloadedMedia: () -> Void

    var body: some View {
        switch mediaDownloadState ?? .idle {
        case .idle:
            Button {
                onDownloadMedia()
            } label: {
                Label("下载附件", systemImage: "arrow.down.circle")
                    .font(.caption.weight(.semibold))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        case .downloading(let progress):
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    if let fractionCompleted = progress?.fractionCompleted {
                        ProgressView(value: fractionCompleted)
                            .controlSize(.small)
                    } else {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text(downloadStatusText(for: progress))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Button {
                    onCancelMediaDownload()
                } label: {
                    Label("暂停下载", systemImage: "pause.circle")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        case .paused(let progress):
            VStack(alignment: .leading, spacing: 6) {
                Text(pausedStatusText(for: progress))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack(spacing: 8) {
                    Button {
                        onDownloadMedia()
                    } label: {
                        Label("继续下载", systemImage: "arrow.clockwise.circle")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Button {
                        onDeleteDownloadedMedia()
                    } label: {
                        Label("重新开始", systemImage: "trash")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        case .downloaded(let fileURL):
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Label("已下载", systemImage: "checkmark.circle.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.green)

                    Text(fileURL.lastPathComponent)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                HStack(spacing: 8) {
                    Button {
                        onOpenDownloadedMedia(fileURL)
                    } label: {
                        Label("打开预览", systemImage: "eye")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    ShareLink(item: fileURL) {
                        Label("分享", systemImage: "square.and.arrow.up")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Button {
                        onDeleteDownloadedMedia()
                    } label: {
                        Label("删除", systemImage: "trash")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        case .failed(let message):
            VStack(alignment: .leading, spacing: 6) {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)

                Button {
                    onRetryMediaDownload()
                } label: {
                    Label("重试下载", systemImage: "arrow.clockwise")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }

    private func downloadStatusText(for progress: FileTransferProgress?) -> String {
        guard let progress else {
            return "正在下载…"
        }

        if let fractionCompleted = progress.fractionCompleted {
            let percentage = Int((fractionCompleted * 100).rounded())
            return "下载中 \(percentage)%"
        }

        return "已接收 \(ByteCountFormatter.string(fromByteCount: progress.transferredBytes, countStyle: .file))"
    }

    private func pausedStatusText(for progress: FileTransferProgress?) -> String {
        guard let progress else {
            return "下载已暂停"
        }

        if let fractionCompleted = progress.fractionCompleted {
            let percentage = Int((fractionCompleted * 100).rounded())
            return "下载已暂停 \(percentage)%"
        }

        return "已暂停，已接收 \(ByteCountFormatter.string(fromByteCount: progress.transferredBytes, countStyle: .file))"
    }
}
