@testable import IMV2ServerApplication
@testable import IMV2ServerContracts
#if canImport(ImageIO) && canImport(CoreGraphics)
import Crypto
import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import IMV2Server
@testable import IMV2ServerInfrastructure

struct V2ResourceTransformerContractTests {
    @Test func isolatedAvatarProcessorProducesFixedMetadataFreePNGs() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        let context=try #require(CGContext(data:nil,width:300,height:160,bitsPerComponent:8,bytesPerRow:1200,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red:0.2,green:0.5,blue:0.9,alpha:1));context.fill(CGRect(x:0,y:0,width:300,height:160))
        let image=try #require(context.makeImage())
        let original=root.appendingPathComponent("original.png")
        let destination=try #require(CGImageDestinationCreateWithURL(original as CFURL,UTType.png.identifier as CFString,1,nil))
        CGImageDestinationAddImage(destination,image,[kCGImagePropertyGPSDictionary:[kCGImagePropertyGPSLatitude:42]] as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        let data=try Data(contentsOf:original)
        let binding=try V2StorageBinding(id:"local",configurationRevision:1)
        let storage=try V2LocalResourceStorage(root:root.appendingPathComponent("objects"),binding:binding)
        let input=try await storage.write(storage.allocate(),byteCount:Int64(data.count),sha256:Data(SHA256.hash(data:data)),bytes:V2LocalResourceStorage.stream(file:original))
        let registry=try V2ResourceStorageRegistry(storages:[storage],defaultBinding:binding)
        let package=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let transformer=try V2LocalResourceTransformer(executable:package.appendingPathComponent(".build/debug/IMV2ResourceImageWorker"),temporaryDirectory:root.appendingPathComponent("work"))
        let outputs=try [128:storage.allocate(),256:storage.allocate()]
        let receipts=try await transformer.transform(input:input,recipe:.avatar,outputs:outputs,registry:registry)
        #expect(receipts.count==2)
        for receipt in receipts {
            let stream=try await storage.read(receipt.facts.reference)
            var bytes=Data();while let chunk=try await stream.next() {bytes.append(chunk)}
            let source=try #require(CGImageSourceCreateWithData(bytes as CFData,nil))
            let properties=try #require(CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [CFString:Any])
            #expect(properties[kCGImagePropertyPixelWidth] as? Int == receipt.size)
            #expect(properties[kCGImagePropertyPixelHeight] as? Int == receipt.size)
            #expect(properties[kCGImagePropertyGPSDictionary]==nil)
        }
    }
}
#endif
