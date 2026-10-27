import CoreTransferable
import Foundation
import ImageIO
import IMV2ClientKit
import IMV2Core
import PhotosUI
import Synchronization
import SwiftUI
import UniformTypeIdentifiers
import UIKit

struct V2PhotoLibraryImage: Transferable, Sendable {
    enum ImportError: Error, Equatable { case tooLarge, unreadable }
    let content: V2NormalizedPhoto
    static let maximumInputBytes = 50 * 1_024 * 1_024
    static let maximumPixelSize = 2_048

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .image) { received in
            try prepare(from: received.file)
        }
    }

    /// ImageIO bounds decoded dimensions, applies orientation, and omits source
    /// metadata (including location). HEIC and other still images become JPEG;
    /// images with transparency remain PNG, matching the resource image worker.
    nonisolated static func prepare(from sourceURL: URL, maximumOutputBytes: Int = maximumInputBytes) throws -> Self {
        try Task.checkCancellation()
        guard maximumOutputBytes > 0, maximumOutputBytes <= maximumInputBytes else { throw ImportError.tooLarge }
        // URL resource values can cache a size from an earlier read. Stat the
        // current provider file before allowing ImageIO to decode it.
        let values = try FileManager.default.attributesOfItem(atPath: sourceURL.path)
        guard values[.type] as? FileAttributeType == .typeRegular,
              let size = values[.size] as? NSNumber, size.int64Value > 0 else { throw ImportError.unreadable }
        guard size.int64Value <= Int64(maximumInputBytes) else { throw ImportError.tooLarge }
        guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 80_000_000 / height,
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { throw ImportError.unreadable }
        try Task.checkCancellation()
        let transparent = try containsTransparency(image)
        let type: UTType = transparent ? .png : .jpeg
        let buffer = V2BoundedPhotoEncodingBuffer(maximumBytes: maximumOutputBytes)
        var callbacks = CGDataConsumerCallbacks(putBytes: { context, pointer, count in
            guard let context else { return 0 }
            return Unmanaged<V2BoundedPhotoEncodingBuffer>.fromOpaque(context).takeUnretainedValue().append(pointer, count: count)
        }, releaseConsumer: { context in
            if let context { Unmanaged<V2BoundedPhotoEncodingBuffer>.fromOpaque(context).release() }
        })
        let context = Unmanaged.passRetained(buffer).toOpaque()
        guard let consumer = CGDataConsumer(info: context, cbks: &callbacks) else {
            Unmanaged<V2BoundedPhotoEncodingBuffer>.fromOpaque(context).release()
            throw ImportError.unreadable
        }
        guard let destination = CGImageDestinationCreateWithDataConsumer(consumer, type.identifier as CFString, 1, nil) else { throw ImportError.unreadable }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        let finalized = CGImageDestinationFinalize(destination)
        try Task.checkCancellation()
        let data = try buffer.result()
        guard finalized, !data.isEmpty else { throw ImportError.unreadable }
        return .init(content: .init(data: data, format: transparent ? .png : .jpeg,
                                    imageDimensions: try .init(width: image.width, height: image.height)))
    }

    /// ImageIO can decode an opaque photo into an RGBA bitmap. An alpha
    /// channel alone must not turn a normal photo into a large lossless PNG.
    /// Inspect every alpha pixel so even isolated transparency is preserved.
    nonisolated private static func containsTransparency(_ image: CGImage) throws -> Bool {
        guard [CGImageAlphaInfo.first, .last, .premultipliedFirst, .premultipliedLast, .alphaOnly].contains(image.alphaInfo) else { return false }
        guard image.width > 0, image.height > 0,
              image.width <= maximumPixelSize, image.height <= maximumPixelSize else { throw ImportError.unreadable }
        try Task.checkCancellation()
        // Use a fixed RGBA8 layout rather than guessing the ImageIO bitmap's
        // byte order. The already bounded thumbnail caps this buffer at 16 MiB.
        var bitmap = Data(count: image.width * image.height * 4)
        return try bitmap.withUnsafeMutableBytes { bytes in
            guard let context = CGContext(data: bytes.baseAddress, width: image.width, height: image.height,
                                          bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue) else { throw ImportError.unreadable }
            context.setBlendMode(.copy)
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            let pixels = bytes.bindMemory(to: UInt8.self)
            for row in 0..<image.height {
                if row.isMultiple(of: 64) { try Task.checkCancellation() }
                let start = row * image.width * 4
                for offset in stride(from: start + 3, to: start + image.width * 4, by: 4) {
                    if pixels[offset] != 255 { return true }
                }
            }
            return false
        }
    }

    nonisolated static func preview(at url: URL) async -> V2SendableImage? {
        guard !Task.isCancelled,
              let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 160
              ] as CFDictionary), !Task.isCancelled else { return nil }
        return .init(image: UIImage(cgImage: image))
    }
}

/// ImageIO writes synchronously through a C callback. Bound each write before
/// allocating it; returning zero makes the encoder stop on overflow/cancel.
nonisolated private final class V2BoundedPhotoEncodingBuffer: Sendable {
    private struct State { var data = Data(); var exceeded = false; var cancelled = false }
    private let state = Mutex(State())
    private let maximumBytes: Int
    init(maximumBytes: Int) { self.maximumBytes = maximumBytes }
    func append(_ pointer: UnsafeRawPointer, count: Int) -> Int {
        state.withLock { state in
            if Task.isCancelled { state.cancelled = true }
            guard !state.exceeded, !state.cancelled else { return 0 }
            guard count >= 0, count <= maximumBytes - state.data.count else { state.exceeded = true; return 0 }
            state.data.append(pointer.assumingMemoryBound(to: UInt8.self), count: count)
            return count
        }
    }
    func result() throws -> Data {
        try state.withLock { state in
            if state.cancelled { throw CancellationError() }
            if state.exceeded { throw V2PhotoLibraryImage.ImportError.tooLarge }
            return state.data
        }
    }
}

@MainActor
private struct V2PhotoLibraryPicker: ViewModifier {
    @Binding var isPresented: Bool
    @Binding var isImporting: Bool
    let maximumSelectionCount: Int
    let onImport: @MainActor (V2NormalizedPhoto) async -> Void
    @State private var selection: [PhotosPickerItem] = []
    @State private var feedback: String?

    func body(content: Content) -> some View {
        content
            .photosPicker(isPresented: $isPresented, selection: $selection,
                          maxSelectionCount: max(1, maximumSelectionCount), selectionBehavior: .ordered,
                          matching: .images, preferredItemEncoding: .compatible)
            .task(id: selection) {
                guard !selection.isEmpty else { return }
                isImporting = true
                defer { isImporting = false }
                for item in selection {
                    do {
                        guard let photo = try await item.loadTransferable(type: V2PhotoLibraryImage.self) else {
                            throw V2PhotoLibraryImage.ImportError.unreadable
                        }
                        try Task.checkCancellation()
                        await onImport(photo.content)
                        try Task.checkCancellation()
                    } catch is CancellationError { return }
                    catch V2PhotoLibraryImage.ImportError.tooLarge { feedback = "图片不能超过 50 MB。" }
                    catch { feedback = "无法读取所选图片，请稍后重试或选择其他图片。" }
                }
                selection = []
            }
            .alert("无法添加图片", isPresented: Binding(get: { feedback != nil }, set: { if !$0 { feedback = nil } })) {
                Button("好", role: .cancel) { feedback = nil }
            } message: { Text(feedback ?? "") }
    }
}

extension View {
    func v2PhotoLibraryPicker(isPresented: Binding<Bool>, isImporting: Binding<Bool>, maximumSelectionCount: Int,
                              onImport: @escaping @MainActor (V2NormalizedPhoto) async -> Void) -> some View {
        modifier(V2PhotoLibraryPicker(isPresented: isPresented, isImporting: isImporting,
                                      maximumSelectionCount: maximumSelectionCount, onImport: onImport))
    }
}
