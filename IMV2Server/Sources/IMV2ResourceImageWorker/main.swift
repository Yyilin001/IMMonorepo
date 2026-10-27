import Foundation
#if os(Linux)
import Glibc
#endif
#if canImport(ImageIO) && canImport(CoreGraphics)
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers
import Darwin
_ = setpgid(0,0)

// This process receives only service-owned paths, never URLs or user-supplied recipes.
// OS resource ceilings contain decoder expansion independently of the parent event loop.
var cpu = rlimit(rlim_cur: 15, rlim_max: 15)
_ = setrlimit(RLIMIT_CPU, &cpu)
var files = rlimit(rlim_cur: 64, rlim_max: 64)
_ = setrlimit(RLIMIT_NOFILE, &files)
var outputLimit = rlimit(rlim_cur: 8 * 1_024 * 1_024, rlim_max: 8 * 1_024 * 1_024)
_ = setrlimit(RLIMIT_FSIZE, &outputLimit)

let args = CommandLine.arguments
if args.count == 2, args[1] == "--check" { exit(0) }
 guard args.count == 4, ["avatar", "preview"].contains(args[3]) else { exit(2) }
let sourceURL = URL(fileURLWithPath: args[1])
let directory = URL(fileURLWithPath: args[2],isDirectory: true)
guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
      CGImageSourceGetCount(source) <= 200,
      let properties = CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [CFString:Any],
      let width = properties[kCGImagePropertyPixelWidth] as? Int,
      let height = properties[kCGImagePropertyPixelHeight] as? Int,
      width > 0, height > 0, width <= 16_384, height <= 16_384,
      Int64(width) * Int64(height) <= 40_000_000 else { exit(3) }
let swapsAxes = (5...8).contains(properties[kCGImagePropertyOrientation] as? Int ?? 1)
let metadata = Data("{\"width\":\(swapsAxes ? height : width),\"height\":\(swapsAxes ? width : height)}".utf8)
do { try metadata.write(to: directory.appendingPathComponent("source-dimensions.json"), options: .atomic) }
catch { exit(8) }
let sizes = args[3] == "avatar" ? [128,256] : [320,1280]
for size in sizes {
    guard let image = CGImageSourceCreateThumbnailAtIndex(source,0,[
        kCGImageSourceCreateThumbnailFromImageAlways:true,
        kCGImageSourceCreateThumbnailWithTransform:true,
        kCGImageSourceThumbnailMaxPixelSize: min(4096, args[3] == "avatar" ? size * 4 : size),
        kCGImageSourceShouldCacheImmediately:true
    ] as CFDictionary) else { exit(4) }
    let outWidth: Int, outHeight: Int
    if args[3] == "avatar" { outWidth=size;outHeight=size }
    else { outWidth=image.width;outHeight=image.height }
    guard let context = CGContext(data:nil,width:outWidth,height:outHeight,bitsPerComponent:8,bytesPerRow:outWidth * 4,
        space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else { exit(5) }
    context.interpolationQuality = .high
    let scale = max(Double(outWidth)/Double(image.width),Double(outHeight)/Double(image.height))
    let drawWidth=Double(image.width)*scale, drawHeight=Double(image.height)*scale
    context.draw(image,in:CGRect(x:(Double(outWidth)-drawWidth)/2,y:(Double(outHeight)-drawHeight)/2,width:drawWidth,height:drawHeight))
    guard let rendered=context.makeImage(),
          let destination=CGImageDestinationCreateWithURL(directory.appendingPathComponent("\(size).png") as CFURL,UTType.png.identifier as CFString,1,nil)
    else { exit(6) }
    // New pixel buffer + no copied source properties removes EXIF/GPS and animation frames.
    CGImageDestinationAddImage(destination,rendered,[:] as CFDictionary)
    guard CGImageDestinationFinalize(destination) else { exit(7) }
}
#else
_ = setpgid(0,0)
let args = CommandLine.arguments
if args.count == 2, args[1] == "--check" {
    exit(FileManager.default.isExecutableFile(atPath:"/usr/bin/convert") && FileManager.default.isExecutableFile(atPath:"/usr/bin/identify") && FileManager.default.fileExists(atPath:"/etc/ImageMagick-6/policy.xml") ? 0 : 78)
}
guard args.count == 4, ["avatar","preview"].contains(args[3]),
      FileManager.default.isExecutableFile(atPath:"/usr/bin/convert") else { exit(78) }
func execute(_ path:String,_ arguments:[String],capture:Bool=false) -> Data? {
    let process=Process();process.executableURL=URL(fileURLWithPath:path);process.arguments=arguments
    process.environment=["PATH":"/usr/bin:/bin","MAGICK_THREAD_LIMIT":"1","MAGICK_TMPDIR":args[2]]
    process.standardInput=FileHandle.nullDevice;process.standardError=FileHandle.nullDevice
    let pipe=Pipe();process.standardOutput=capture ? pipe : FileHandle.nullDevice
    do { try process.run();let result=capture ? pipe.fileHandleForReading.readDataToEndOfFile() : Data();process.waitUntilExit();return process.terminationStatus==0 && result.count<=128 ? result : nil }
    catch { return nil }
}
guard let facts=execute("/usr/bin/identify",["-ping","-format","%w %h %[orientation]",args[1]+"[0]"],capture:true),
      let dimensions=String(data:facts,encoding:.utf8)?.split(separator:" "),dimensions.count==3,
      let width=Int64(dimensions[0]),let height=Int64(dimensions[1]),width>0,height>0,width<=16384,height<=16384,width*height<=40_000_000 else { exit(3) }
let swapsAxes = ["LeftTop","RightTop","RightBottom","LeftBottom"].contains(String(dimensions[2]))
let metadata = Data("{\"width\":\(swapsAxes ? height : width),\"height\":\(swapsAxes ? width : height)}".utf8)
do { try metadata.write(to: URL(fileURLWithPath: args[2]).appendingPathComponent("source-dimensions.json"), options: .atomic) }
catch { exit(8) }
let sizes=args[3]=="avatar" ? [128,256] : [320,1280]
for size in sizes {
    var parameters=["-limit","memory","128MiB","-limit","map","128MiB","-limit","disk","256MiB","-limit","time","15",args[1]+"[0]","-auto-orient","-strip"]
    if args[3]=="avatar" { parameters += ["-thumbnail","\(size)x\(size)^","-gravity","center","-extent","\(size)x\(size)"] }
    else {
        // Lanczos thumbnailing a full RGBA photo can require several original-
        // sized pixel caches. Area-reduce to twice the preview size first so
        // normal camera images fit the existing decoder memory/disk ceilings.
        parameters += ["-scale","\(size * 2)x\(size * 2)>","-thumbnail","\(size)x\(size)>"]
    }
    parameters += ["PNG:"+URL(fileURLWithPath:args[2]).appendingPathComponent("\(size).png").path]
    guard execute("/usr/bin/convert",parameters) != nil else { exit(4) }
}
#endif
