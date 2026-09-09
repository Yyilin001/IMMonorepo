import Foundation
import Testing
import UIKit
@testable import IMApp

@MainActor
struct V2LocalMediaThumbnailCacheTests {
    @Test("real images are downsampled and cached until account close")
    func realImage() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "im-thumbnail-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appending(path: "image.png")
        let original = UIGraphicsImageRenderer(size: CGSize(width: 128, height: 64)).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 128, height: 64))
        }
        try #require(original.pngData()).write(to: file)
        let cache = V2LocalMediaThumbnailCache(directory: root)
        let thumbnail = try #require(await cache.thumbnail(fileURL: file, maximumPixelSize: 32))
        #expect(thumbnail.image.cgImage?.width == 32)
        #expect(thumbnail.image.cgImage?.height == 16)
        try FileManager.default.removeItem(at: file)
        let reused = await cache.thumbnail(fileURL: file, maximumPixelSize: 32)
        #expect(reused?.image === thumbnail.image)
        await cache.close()
        #expect(await cache.thumbnail(fileURL: file, maximumPixelSize: 32) == nil)
    }

    @Test("closing an account drains decoding and rejects late images and requests")
    func closeDuringDecode() async {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let image = V2SendableImage(image: UIImage())
        let entered = AsyncStream<Void>.makeStream()
        let cancelled = AsyncStream<Void>.makeStream()
        let gate = ThumbnailDecodeGate()
        let cache = V2LocalMediaThumbnailCache(directory: root) { _, _ in
            await withTaskCancellationHandler {
                await gate.suspend(entered: entered.continuation)
                return image // Models ImageIO finishing despite cancellation.
            } onCancel: {
                cancelled.continuation.yield(())
            }
        }
        let file = root.appending(path: "image.jpg")
        let request = Task { await cache.thumbnail(fileURL: file, maximumPixelSize: 960) }
        var starts = entered.stream.makeAsyncIterator()
        _ = await starts.next()
        let closing = Task { await cache.close() }
        var cancellations = cancelled.stream.makeAsyncIterator()
        _ = await cancellations.next()
        #expect(await cache.thumbnail(fileURL: file, maximumPixelSize: 960) == nil)
        await gate.release()
        await closing.value
        #expect(await request.value == nil)
        #expect(await cache.thumbnail(fileURL: file, maximumPixelSize: 960) == nil)
        await cache.close()
        entered.continuation.finish()
        cancelled.continuation.finish()
    }

    @Test("account caches retain independently and closing clears admission permanently")
    func independentAccounts() async {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let image = V2SendableImage(image: UIImage())
        let calls = ThumbnailDecodeCounter()
        let first = V2LocalMediaThumbnailCache(directory: root.appending(path: "first")) { _, _ in
            await calls.record()
            return image
        }
        let second = V2LocalMediaThumbnailCache(directory: root.appending(path: "second")) { _, _ in
            await calls.record()
            return image
        }
        let firstFile = root.appending(path: "first/image.jpg")
        let secondFile = root.appending(path: "second/image.jpg")
        #expect(await first.thumbnail(fileURL: firstFile, maximumPixelSize: 960) != nil)
        #expect(await second.thumbnail(fileURL: secondFile, maximumPixelSize: 960) != nil)
        await first.close()
        #expect(await first.thumbnail(fileURL: firstFile, maximumPixelSize: 960) == nil)
        #expect(await second.thumbnail(fileURL: secondFile, maximumPixelSize: 960) != nil)
        #expect(await calls.count == 2)
        await second.close()
    }

    @Test("scope boundaries and cancelled callers do not start image decoding")
    func admission() async {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let calls = ThumbnailDecodeCounter()
        let cache = V2LocalMediaThumbnailCache(directory: root) { _, _ in
            await calls.record()
            return nil
        }
        for file in [root, root.appending(path: "../outside.jpg"), URL(fileURLWithPath: root.path + "-other/image.jpg")] {
            #expect(await cache.thumbnail(fileURL: file, maximumPixelSize: 960) == nil)
        }
        let request = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await cache.thumbnail(fileURL: root.appending(path: "image.jpg"), maximumPixelSize: 960)
        }
        #expect(await request.value == nil)
        #expect(await calls.count == 0)
        await cache.close()
    }
}

private actor ThumbnailDecodeGate {
    private var continuation: CheckedContinuation<Void, Never>?
    func suspend(entered: AsyncStream<Void>.Continuation) async {
        await withCheckedContinuation {
            continuation = $0
            entered.yield(())
        }
    }
    func release() {
        continuation?.resume()
        continuation = nil
    }
}

private actor ThumbnailDecodeCounter {
    private(set) var count = 0
    func record() { count += 1 }
}
