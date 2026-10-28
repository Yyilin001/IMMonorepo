import IMV2ClientKit
import IMV2Core
import Testing
import UIKit
@testable import IMApp

@MainActor
struct V2ProfileAvatarImageProcessorTests {
    @Test func cropExportsTheSelectedRegionAsABoundedSquare() async throws {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let image = UIGraphicsImageRenderer(size: .init(width: 200, height: 100), format: format).image { context in
            UIColor.red.setFill(); context.fill(.init(x: 0, y: 0, width: 100, height: 100))
            UIColor.blue.setFill(); context.fill(.init(x: 100, y: 0, width: 100, height: 100))
        }
        let photo = V2NormalizedPhoto(data: try #require(image.pngData()), format: .png)
        let processor = V2ProfileAvatarImageProcessor()
        let result = try await processor.crop(photo, unitRect: .init(x: 0.5, y: 0, width: 0.5, height: 1))
        #expect(result.imageDimensions?.width == 100 && result.imageDimensions?.height == 100)
        #expect(result.contentType == "image/jpeg")
        let decoded = try #require(UIImage(data: result.data)?.cgImage)
        var pixel = [UInt8](repeating: 0, count: 4)
        pixel.withUnsafeMutableBytes { bytes in
            let context = CGContext(data: bytes.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(decoded, in: .init(x: 0, y: 0, width: 1, height: 1))
        }
        #expect(pixel[2] > 220 && pixel[0] < 30 && pixel[1] < 30)
    }

    @Test func largePhotosAreReducedAndInvalidCropsAreRejected() async throws {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let image = UIGraphicsImageRenderer(size: .init(width: 2048, height: 2048), format: format).image { context in
            UIColor.green.setFill(); context.fill(.init(x: 0, y: 0, width: 2048, height: 2048))
        }
        let photo = V2NormalizedPhoto(data: try #require(image.pngData()), format: .png)
        let processor = V2ProfileAvatarImageProcessor()
        let result = try await processor.crop(photo, unitRect: .init(x: 0, y: 0, width: 1, height: 1))
        #expect(result.imageDimensions?.width == 1024 && result.imageDimensions?.height == 1024)
        await #expect(throws: V2ProfileAvatarImageProcessor.Failure.invalidCrop) {
            try await processor.crop(photo, unitRect: .zero)
        }
        await #expect(throws: V2ProfileAvatarImageProcessor.Failure.invalidCrop) {
            try await processor.crop(photo, unitRect: .init(x: 2, y: 2, width: 1, height: 1))
        }
    }

    @Test func cameraOutputNormalizesOrientationAndLimitsDimensions() async throws {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let image = UIGraphicsImageRenderer(size: .init(width: 120, height: 60), format: format).image { context in
            UIColor.blue.setFill(); context.fill(.init(x: 0, y: 0, width: 120, height: 60))
        }
        let rotated = UIImage(cgImage: try #require(image.cgImage), scale: 1, orientation: .right)
        let processor = V2ProfileAvatarImageProcessor()
        let photo = try await processor.camera(.init(image: rotated))
        #expect(UIImage(data: photo.data)?.imageOrientation == .up)
        #expect((photo.imageDimensions?.width ?? 0) > 0 && (photo.imageDimensions?.height ?? 0) > 0)
        #expect((photo.imageDimensions?.width ?? 0) <= 2048 && (photo.imageDimensions?.height ?? 0) <= 2048)
    }
}
