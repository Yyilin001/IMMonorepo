import Foundation
import IMV2ClientKit
import IMV2Core
import ImageIO
import Testing
import UniformTypeIdentifiers
import SwiftUI
import UIKit
@testable import IMApp

struct V2PhotoLibraryImageTests {
    @Test func normalizesOrientationBoundsPixelsAndDropsLocation() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try fixture(in: root, width: 5_000, height: 100, transparent: false, type: .jpeg,
                                 properties: [kCGImagePropertyOrientation: 6,
                                              kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 1.23,
                                                                             kCGImagePropertyGPSLatitudeRef: "N"]] as CFDictionary)
        let photo = try V2PhotoLibraryImage.prepare(from: source)
        let image = try #require(CGImageSourceCreateWithData(photo.content.data as CFData, nil))
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [String: Any])
        let width = try #require(properties[kCGImagePropertyPixelWidth as String] as? Int)
        let height = try #require(properties[kCGImagePropertyPixelHeight as String] as? Int)
        #expect(max(width, height) == V2PhotoLibraryImage.maximumPixelSize)
        #expect(height > width)
        #expect(photo.content.imageDimensions?.width == width)
        #expect(photo.content.imageDimensions?.height == height)
        #expect(properties[kCGImagePropertyGPSDictionary as String] == nil)
        #expect(CGImageSourceGetType(image) as String? == UTType.jpeg.identifier)
        #expect(photo.content.contentType == "image/jpeg")
    }

    @Test func preservesTransparencyAsPNG() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try fixture(in: root, width: 80, height: 60, transparent: true, type: .png)
        let photo = try V2PhotoLibraryImage.prepare(from: source)
        let image = try #require(CGImageSourceCreateWithData(photo.content.data as CFData, nil))
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [String: Any])
        #expect(CGImageSourceGetType(image) as String? == UTType.png.identifier)
        #expect(properties[kCGImagePropertyHasAlpha as String] as? Bool == true)
        #expect(photo.content.contentType == "image/png")
    }

    @Test func opaqueImageWithAlphaChannelUsesJPEG() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try fixture(in: root, width: 320, height: 240, transparent: true, type: .png, alpha: 1)
        let original = try #require(CGImageSourceCreateWithURL(source as CFURL, nil))
        let originalProperties = try #require(CGImageSourceCopyPropertiesAtIndex(original, 0, nil) as? [String: Any])
        #expect(originalProperties[kCGImagePropertyHasAlpha as String] as? Bool == true)
        let photo = try V2PhotoLibraryImage.prepare(from: source)
        #expect(photo.content.contentType == "image/jpeg")
    }

    @Test func evenOneTransparentPixelStaysPNG() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let context = try #require(CGContext(data: nil, width: 128, height: 96, bitsPerComponent: 8,
                                            bytesPerRow: 128 * 4, space: CGColorSpaceCreateDeviceRGB(),
                                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 128, height: 96))
        context.clear(CGRect(x: 117, y: 83, width: 1, height: 1))
        let source = root.appending(path: "one-transparent-pixel.png")
        let destination = try #require(CGImageDestinationCreateWithURL(source as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try #require(context.makeImage()), nil)
        #expect(CGImageDestinationFinalize(destination))
        #expect(try V2PhotoLibraryImage.prepare(from: source).content.contentType == "image/png")
    }

    @Test func rejectsInvalidAndOversizedFiles() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appending(path: "bad.jpg")
        try Data([1, 2, 3]).write(to: source)
        #expect(throws: V2PhotoLibraryImage.ImportError.unreadable) { try V2PhotoLibraryImage.prepare(from: source) }
        let file = try FileHandle(forWritingTo: source)
        try file.truncate(atOffset: UInt64(V2PhotoLibraryImage.maximumInputBytes + 1))
        try file.close()
        #expect(throws: V2PhotoLibraryImage.ImportError.tooLarge) { try V2PhotoLibraryImage.prepare(from: source) }
    }

    @Test func rejectsEncodedOutputBeyondItsBound() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try fixture(in: root, width: 32, height: 32, transparent: false, type: .jpeg)
        #expect(throws: V2PhotoLibraryImage.ImportError.tooLarge) {
            try V2PhotoLibraryImage.prepare(from: source, maximumOutputBytes: 8)
        }
    }

    @MainActor @Test func normalizationUsesNoTemporaryDiskCopyAndPublishesOneAccountOriginal() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try fixture(in: root, width: 32, height: 32, transparent: false, type: .jpeg)
        let before = try FileManager.default.contentsOfDirectory(atPath: root.path)
        let photo = try V2PhotoLibraryImage.prepare(from: source)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == before)
        let fixture = try await V2OriginalResourceTestFixture(root: root)
        let attachment = try await fixture.stager.stageNormalizedPhoto(photo.content, purpose: .personalAvatar)
        #expect(FileManager.default.fileExists(atPath: source.path))
        #expect(try await fixture.read(.selection(attachment.localAssetID)) == photo.content.data)
        #expect(attachment.contentType == "image/jpeg")
        #expect(attachment.byteCount > 0)
        #expect(attachment.imageDimensions == photo.content.imageDimensions)
        let usage = try await fixture.resources.storageSnapshot()
        #expect(usage.files.count == 1 && usage.transferReservedBytes == 0 && usage.transferAllocatedBytes == 0)
        try await fixture.close()
    }

    @MainActor @Test func imageLayoutReservesIdenticalSpaceBeforeAndAfterDecode() throws {
        let dimensions = try V2LocalResourceImageDimensions(width: 1536, height: 2048)
        let expected = CGSize(width: 240, height: 320)
        #expect(V2ConversationImageLayout.size(dimensions: dimensions) == expected)
        #expect(V2ConversationImageLayout.size(dimensions: dimensions, availableWidth: 180) == CGSize(width: 180, height: 240))
        let placeholder = ImageRenderer(content: V2ConversationImageLayout(dimensions: dimensions) {
            V2ConversationMediaPlaceholder()
        })
        let decoded = ImageRenderer(content: V2ConversationImageLayout(dimensions: dimensions) {
            Image(systemName: "photo").resizable().scaledToFit()
        })
        placeholder.proposedSize = .init(width: 260, height: nil)
        decoded.proposedSize = .init(width: 260, height: nil)
        #expect(try #require(placeholder.uiImage).size == expected)
        #expect(try #require(decoded.uiImage).size == expected)
    }

    @MainActor @Test func preparingAttachmentKeepsPlaceholderAcrossProcessingUpdates() throws {
        let id = UUID()
        let date = Date()
        func rendered(completed: Int, status: String) throws -> CGSize {
            let pending = V2DurableConversationSendService.Pending(id: id, createdAt: date, text: "",
                completed: completed, total: 1, status: status, canRetry: false, retryTitle: "重试", canCancel: true)
            let renderer = ImageRenderer(content: V2PendingMessageRow(pending: pending, retry: {}, cancel: {}))
            renderer.proposedSize = .init(width: 390, height: nil)
            return try #require(renderer.uiImage).size
        }
        let preparing = try rendered(completed: 0, status: "正在准备附件")
        let processing = try rendered(completed: 1, status: "正在安全处理")
        #expect(preparing == processing)
        #expect(preparing.height >= 120)
    }

    @MainActor @Test func cacheLookupAndDownloadPlaceholdersKeepImageGeometry() throws {
        let dimensions = try V2LocalResourceImageDimensions(width: 1536, height: 2048)
        for availability in V2ConversationImageAvailabilityPlaceholder.Availability.allCases {
            let renderer = ImageRenderer(content: V2ConversationImageLayout(dimensions: dimensions) {
                V2ConversationImageAvailabilityPlaceholder(availability: availability, download: {})
            })
            renderer.proposedSize = .init(width: 260, height: nil)
            #expect(try #require(renderer.uiImage).size == CGSize(width: 240, height: 320))
        }
    }

    @MainActor @Test func preparedImageIsVisibleInTheFirstRenderedFrame() async throws {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 80, height: 120)).image { context in
            UIColor.blue.setFill(); context.fill(CGRect(x: 0, y: 0, width: 80, height: 120))
        }
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = try V2ClientMediaTransferTarget(downloadPlan: .init(mode: .httpGet,
            url: #require(URL(string: "https://media.invalid/first-frame")), expiresAt: .distantFuture,
            expectedByteCount: 4, checksum: .init(value: "9f64a747e1b97f131fabb6b447296c9b6f0201e79fb3c5356e6c77e89b6a806a")))
        let files = try await makeResourceMediaTestDownloader(downloader: .init(
            targetResolver: FirstFrameTargetResolver(target: target), byteTransfer: ResourceMediaSeedBytes(Data([1, 2, 3, 4]))), directory: root)
        let file = try await files.download(.init(mediaID: .init(uuid: UUID())))
        let decoded = V2SendableImage(image: image)
        let thumbnails = V2LocalMediaThumbnailCache(directories: [root]) { _, _ in decoded }
        let renderer = ImageRenderer(content: V2LocalMediaImagePreview(downloaded: file,
            accessibilityLabel: "图片", accessibilityValue: "", accessibilityIdentifier: "first-frame",
            initialImage: image, onUnavailable: {}).frame(width: 240, height: 320)
            .environment(\.v2MediaThumbnailCache, thumbnails))
        let rendered = try #require(renderer.uiImage?.cgImage)
        try renderer.uiImage?.pngData()?.write(to: URL(fileURLWithPath: "/tmp/im-resource-first-frame-render-20261027.png"))
        var pixel = [UInt8](repeating: 0, count: 4)
        try pixel.withUnsafeMutableBytes { bytes in
            let context = try #require(CGContext(data: bytes.baseAddress, width: 1, height: 1, bitsPerComponent: 8,
                bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(rendered, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        #expect(pixel[2] > 200 && pixel[0] < 50 && pixel[1] < 50, "First-frame RGBA: \(pixel)")
        await thumbnails.close()
        try await files.close()
    }

    @MainActor @Test func fullScreenImageFitsAndKeepsZoomUntilViewportChanges() {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 120, height: 80)).image { context in
            UIColor.blue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 120, height: 80))
        }
        let view = V2ConversationImageZoomView.ImageScrollView()
        let coordinator = V2ConversationImageZoomView.Coordinator()
        view.delegate = coordinator
        view.imageView.image = image
        view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        view.layoutIfNeeded()
        #expect(view.imageView.bounds.size == CGSize(width: 390, height: 260))
        #expect(view.contentInset.top == 292)
        view.setZoomScale(3, animated: false)
        view.setNeedsLayout()
        view.layoutIfNeeded()
        #expect(view.zoomScale == 3)
        view.frame = CGRect(x: 0, y: 0, width: 844, height: 390)
        view.layoutIfNeeded()
        #expect(view.zoomScale == 1)
        #expect(view.imageView.bounds.size == CGSize(width: 585, height: 390))
        #expect(view.contentInset.left == 129.5)
    }

    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "photo-import-test-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func fixture(in root: URL, width: Int, height: Int, transparent: Bool, type: UTType,
                         properties: CFDictionary? = nil, alpha: CGFloat? = nil) throws -> URL {
        let info: CGImageAlphaInfo = transparent ? .premultipliedLast : .noneSkipLast
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.6, alpha: alpha ?? (transparent ? 0.5 : 1)))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try #require(context.makeImage())
        let url = root.appending(path: "source.\(type.preferredFilenameExtension ?? "img")")
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, properties)
        #expect(CGImageDestinationFinalize(destination))
        return url
    }
}

private actor FirstFrameTargetResolver: V2ClientMediaDownloadTargetResolver {
    let target: V2ClientMediaTransferTarget
    init(target: V2ClientMediaTransferTarget) { self.target = target }
    func resolveDownloadTarget(mediaID: MediaID, message: V2MediaMessageLocation?) -> V2ClientMediaTransferTarget { target }
}
