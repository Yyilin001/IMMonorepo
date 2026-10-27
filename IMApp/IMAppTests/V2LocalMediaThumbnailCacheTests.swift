import Foundation
import AVFoundation
import Testing
import UIKit
@testable import IMApp

@MainActor
struct V2LocalMediaThumbnailCacheTests {
    @Test func persistentAndCacheRootsAreAllowedButSymlinkEscapeIsNot() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "thumbnail-roots-\(UUID())")
        let persistent = root.appending(path: "account"), cacheRoot = root.appending(path: "cache"), foreign = root.appending(path: "foreign")
        defer { try? FileManager.default.removeItem(at: root) }
        for path in [persistent, cacheRoot, foreign] { try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true) }
        let calls = ThumbnailDecodeCounter()
        let cache = V2LocalMediaThumbnailCache(directories: [persistent, cacheRoot]) { _, _ in await calls.record(); return V2SendableImage(image: UIImage()) }
        #expect(await cache.thumbnail(fileURL: persistent.appending(path: "one"), maximumPixelSize: 64) != nil)
        #expect(await cache.thumbnail(fileURL: cacheRoot.appending(path: "two"), maximumPixelSize: 64) != nil)
        try FileManager.default.createSymbolicLink(at: cacheRoot.appending(path: "escape"), withDestinationURL: foreign)
        #expect(await cache.thumbnail(fileURL: cacheRoot.appending(path: "escape/secret"), maximumPixelSize: 64) == nil)
        #expect(await calls.count == 2)
        await cache.close()
    }

    @Test func thirdDecodeWaitsForBoundedCapacityAndFinishesAfterOtherReaders() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "thumbnail-queue-\(UUID())")
        let gate = ThumbnailDecodeQueueGate(), starts = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(2))
        let cache = V2LocalMediaThumbnailCache(directories: [root]) { _, _ in
            await gate.wait(starts.continuation); return V2SendableImage(image: UIImage())
        }
        let first = Task { await cache.thumbnail(fileURL: root.appending(path: "one"), maximumPixelSize: 64) }
        let second = Task { await cache.thumbnail(fileURL: root.appending(path: "two"), maximumPixelSize: 64) }
        var iterator = starts.stream.makeAsyncIterator()
        _ = await iterator.next(); _ = await iterator.next()
        let third = Task { await cache.thumbnail(fileURL: root.appending(path: "three"), maximumPixelSize: 64) }
        let deadline = ContinuousClock.now + .seconds(5)
        while await cache.decodeCounts.waiting != 1 { try #require(ContinuousClock.now < deadline); try await Task.sleep(for: .milliseconds(10)) }
        #expect(await cache.decodeCounts.active == 2)
        await gate.release()
        #expect(await first.value != nil); #expect(await second.value != nil); #expect(await third.value != nil)
        await cache.close()
    }

    @Test func realLocalVideoProducesABoundedStillFrame() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "thumbnail-video-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appending(path: "clip.mov")
        let writer = try AVAssetWriter(outputURL: file, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 32])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
        writer.add(input)
        try #require(writer.startWriting()); writer.startSession(atSourceTime: .zero)
        var buffer: CVPixelBuffer?
        try #require(CVPixelBufferCreate(kCFAllocatorDefault, 64, 32, kCVPixelFormatType_32ARGB, nil, &buffer) == kCVReturnSuccess)
        let pixel = try #require(buffer)
        CVPixelBufferLockBaseAddress(pixel, [])
        let address = try #require(CVPixelBufferGetBaseAddress(pixel))
        address.assumingMemoryBound(to: UInt8.self).update(repeating: 255, count: CVPixelBufferGetBytesPerRow(pixel) * 32)
        CVPixelBufferUnlockBaseAddress(pixel, [])
        let deadline = ContinuousClock.now + .seconds(10)
        while !input.isReadyForMoreMediaData { try #require(ContinuousClock.now < deadline); try await Task.sleep(for: .milliseconds(10)) }
        try #require(adaptor.append(pixel, withPresentationTime: .zero))
        input.markAsFinished(); await writer.finishWriting()
        try #require(writer.status == .completed)
        let cache = V2LocalMediaThumbnailCache(directories: [root])
        let frame = try #require(await cache.thumbnail(fileURL: file, maximumPixelSize: 32, kind: .video))
        #expect(try #require(frame.image.cgImage).width <= 32)
        #expect(try #require(frame.image.cgImage).height <= 32)
        await cache.close()
    }

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
        let cache = V2LocalMediaThumbnailCache(directories: [root])
        let thumbnail = try #require(await cache.thumbnail(fileURL: file, maximumPixelSize: 32))
        #expect(thumbnail.image.cgImage?.width == 32)
        #expect(thumbnail.image.cgImage?.height == 16)
        try FileManager.default.removeItem(at: file)
        let reused = await cache.thumbnail(fileURL: file, maximumPixelSize: 32)
        #expect(reused?.image === thumbnail.image)
        #expect(await cache.cachedThumbnail(fileURL: file, maximumPixelSize: 32)?.image === thumbnail.image)
        #expect(await cache.cachedThumbnail(fileURL: file, maximumPixelSize: 1280) == nil)
        await cache.close()
        #expect(await cache.thumbnail(fileURL: file, maximumPixelSize: 32) == nil)
        #expect(await cache.cachedThumbnail(fileURL: file, maximumPixelSize: 32) == nil)
    }

    @Test("chat preview retains enough pixels for a 320 point bubble on a 3x display")
    func retinaChatPreview() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "im-retina-preview-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appending(path: "image.png")
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let original = UIGraphicsImageRenderer(size: CGSize(width: 1600, height: 1200), format: format).image { context in
            UIColor.red.setFill(); context.fill(CGRect(x: 0, y: 0, width: 1600, height: 1200))
        }
        try #require(original.pngData()).write(to: file)
        let cache = V2LocalMediaThumbnailCache(directories: [root])
        let preview = try #require(await cache.thumbnail(fileURL: file, maximumPixelSize: 1280))
        #expect(preview.image.cgImage?.width == 1280)
        #expect(preview.image.cgImage?.height == 960)
        #expect((preview.image.cgImage?.width ?? 0) >= 320 * 3)
        let warm = await cache.thumbnail(fileURL: file, maximumPixelSize: 1280)
        #expect(warm?.image === preview.image)
        await cache.close()
    }

    @Test("closing an account drains decoding and rejects late images and requests")
    func closeDuringDecode() async {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let image = V2SendableImage(image: UIImage())
        let entered = AsyncStream<Void>.makeStream()
        let cancelled = AsyncStream<Void>.makeStream()
        let gate = ThumbnailDecodeGate()
        let cache = V2LocalMediaThumbnailCache(directories: [root]) { _, _ in
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
        // A first-frame cache query must miss immediately instead of joining
        // this suspended decode and holding the entire initial timeline.
        #expect(await cache.cachedThumbnail(fileURL: file, maximumPixelSize: 960) == nil)
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
        let first = V2LocalMediaThumbnailCache(directories: [root.appending(path: "first")]) { _, _ in
            await calls.record()
            return image
        }
        let second = V2LocalMediaThumbnailCache(directories: [root.appending(path: "second")]) { _, _ in
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
    func admission() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let calls = ThumbnailDecodeCounter()
        let cache = V2LocalMediaThumbnailCache(directories: [root]) { _, _ in
            await calls.record()
            return nil
        }
        for file in [root, root.appending(path: "../outside.jpg"), URL(fileURLWithPath: root.path + "-other/image.jpg"), try #require(URL(string: "https://outside.invalid"))] {
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

private actor ThumbnailDecodeQueueGate {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait(_ events: AsyncStream<Void>.Continuation) async {
        if opened { return }
        await withCheckedContinuation { waiters.append($0); events.yield(()) }
    }
    func release() {
        opened = true
        let pending = waiters; waiters.removeAll()
        for waiter in pending { waiter.resume() }
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
