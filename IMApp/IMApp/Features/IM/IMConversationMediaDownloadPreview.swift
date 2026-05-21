import IMClientKit
import QuickLook
import SwiftUI

enum IMMediaDownloadState: Equatable {
    case idle
    case downloading(progress: FileTransferProgress?)
    case paused(progress: FileTransferProgress?)
    case downloaded(URL)
    case failed(String)
}

extension IMMediaAssetKind {
    var displayName: String {
        switch self {
        case .image:
            return "图片"
        case .audio:
            return "音频"
        case .file:
            return "文件"
        }
    }
}

struct IMDownloadedMediaPreviewItem: Identifiable, Equatable {
    let url: URL
    let title: String

    var id: String { url.absoluteString }
}

struct IMDownloadedMediaQuickLookSheet: UIViewControllerRepresentable {
    let item: IMDownloadedMediaPreviewItem

    func makeCoordinator() -> Coordinator {
        Coordinator(item: item)
    }

    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        controller.title = item.title
        return controller
    }

    func updateUIViewController(_ controller: QLPreviewController, context: Context) {
        context.coordinator.item = item
        controller.title = item.title
        controller.reloadData()
    }

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        var item: IMDownloadedMediaPreviewItem

        init(item: IMDownloadedMediaPreviewItem) {
            self.item = item
        }

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int {
            1
        }

        func previewController(
            _ controller: QLPreviewController,
            previewItemAt index: Int
        ) -> QLPreviewItem {
            item.url as NSURL
        }
    }
}

