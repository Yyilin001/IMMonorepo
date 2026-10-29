import AVFoundation
import ImageIO
import IMV2ClientKit
import IMV2Core
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Photo decoding and export are bounded and run away from the UI actor.
actor V2ProfileAvatarImageProcessor {
    enum Failure: Error, Equatable { case unreadable, invalidCrop }
    func image(_ photo: V2NormalizedPhoto) throws -> V2SendableImage {
        try Task.checkCancellation()
        guard let source = CGImageSourceCreateWithData(photo.data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 2048,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { throw Failure.unreadable }
        return .init(image: UIImage(cgImage: image))
    }
    func file(_ url: URL) throws -> V2NormalizedPhoto { try V2PhotoLibraryImage.prepare(from: url).content }
    func camera(_ captured: V2SendableImage) throws -> V2NormalizedPhoto {
        try Task.checkCancellation()
        let source = captured.image
        let size = source.size
        guard size.width > 0, size.height > 0 else { throw Failure.unreadable }
        let ratio = min(1, 2048 / max(size.width, size.height))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1; format.opaque = true
        let output = UIGraphicsImageRenderer(size: .init(width: size.width * ratio, height: size.height * ratio), format: format).image { context in
            UIColor.white.setFill(); context.fill(.init(x: 0, y: 0, width: size.width * ratio, height: size.height * ratio))
            source.draw(in: .init(x: 0, y: 0, width: size.width * ratio, height: size.height * ratio))
        }
        guard let data = output.jpegData(compressionQuality: 0.9), let cg = output.cgImage else { throw Failure.unreadable }
        return .init(data: data, format: .jpeg, imageDimensions: try .init(width: cg.width, height: cg.height))
    }
    func crop(_ photo: V2NormalizedPhoto, unitRect: CGRect) throws -> V2NormalizedPhoto {
        guard [unitRect.minX, unitRect.minY, unitRect.width, unitRect.height].allSatisfy(\.isFinite),
              unitRect.width > 0, unitRect.height > 0 else { throw Failure.invalidCrop }
        let prepared = try image(photo)
        guard let source = prepared.image.cgImage else { throw Failure.unreadable }
        let bounds = CGRect(x: 0, y: 0, width: source.width, height: source.height)
        let requested = CGRect(x: unitRect.minX * bounds.width, y: unitRect.minY * bounds.height,
                               width: unitRect.width * bounds.width, height: unitRect.height * bounds.height)
            .intersection(bounds).integral
        let side = min(requested.width, requested.height)
        guard side >= 1, let cropped = source.cropping(to: .init(x: requested.minX, y: requested.minY, width: side, height: side)) else { throw Failure.invalidCrop }
        let outputSize = min(1024, Int(side))
        guard let context = CGContext(data: nil, width: outputSize, height: outputSize, bitsPerComponent: 8,
            bytesPerRow: outputSize * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { throw Failure.unreadable }
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(.init(x: 0, y: 0, width: outputSize, height: outputSize))
        context.interpolationQuality = .high
        context.draw(cropped, in: .init(x: 0, y: 0, width: outputSize, height: outputSize))
        guard let result = context.makeImage() else { throw Failure.unreadable }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { throw Failure.unreadable }
        CGImageDestinationAddImage(destination, result, [kCGImageDestinationLossyCompressionQuality: 0.88] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw Failure.unreadable }
        try Task.checkCancellation()
        return .init(data: data as Data, format: .jpeg, imageDimensions: try .init(width: outputSize, height: outputSize))
    }
}

struct V2ProfileAvatarEditor: View {
    let store: V2PublicIdentitySettingsStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.v2ResourceManagement) private var resources
    @State private var modal: SourceModal?
    @State private var path: [UUID] = []
    @State private var photo: V2NormalizedPhoto?
    @State private var chosenResource: V2AvatarResourceSelection?
    @State private var task: Task<Void, Never>?
    @State private var isImporting = false
    @State private var feedback: String?
    @State private var processor = V2ProfileAvatarImageProcessor()
    private enum SourceModal: String, Identifiable {
        case library, camera, files, resources, remove, cameraPermission
        var id: String { rawValue }
    }
    var body: some View {
        NavigationStack(path: $path) {
            List {
                Section {
                    V2ProfileAvatarThumbnail(store: store, size: 144)
                        .frame(maxWidth: .infinity).padding(.vertical, 24)
                }.listRowBackground(Color.clear)
                Section {
                    Button("从相册选择", systemImage: "photo.on.rectangle") { modal = .library }
                        .accessibilityIdentifier("v2.profile.avatar.library")
                    if UIImagePickerController.isSourceTypeAvailable(.camera) {
                        Button("拍照", systemImage: "camera") { requestCamera() }
                            .accessibilityIdentifier("v2.profile.avatar.camera")
                    }
                    if resources != nil {
                        Button("从聊天图片选择", systemImage: "bubble.left.and.text.bubble.right") { modal = .resources }
                            .accessibilityIdentifier("v2.profile.avatar.choose-resource")
                    }
                    Button("从文件选择", systemImage: "folder") { modal = .files }
                        .accessibilityIdentifier("v2.profile.avatar.files")
                }.disabled(isImporting || !store.canEdit)
                if store.currentAvatar != nil || store.stagedAvatar != nil || store.existingAvatar != nil {
                    Section {
                        Button("移除头像", role: .destructive) { modal = .remove }
                            .disabled(isImporting || store.isSaving).accessibilityIdentifier("v2.profile.avatar.remove")
                    }
                }
                if isImporting { Section { ProgressView("正在读取照片…") } }
                if let feedback { Section { Text(feedback).foregroundStyle(.secondary) } }
            }
            .v2GroupedPageSurface().navigationTitle("更换头像").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() }.disabled(store.isSaving) } }
            .navigationDestination(for: UUID.self) { _ in
                if let photo {
                    V2ProfileAvatarCropView(photo: photo, processor: processor) { cropped in
                        let saved = await store.saveAvatar(cropped)
                        if saved { dismiss() }
                        return saved ? nil : (store.feedback ?? "头像未能保存，请重试。")
                    }
                }
            }
        }
        .interactiveDismissDisabled(store.isSaving)
        .v2PhotoLibraryPicker(isPresented: binding(.library), isImporting: $isImporting, maximumSelectionCount: 1) { photo in
            self.photo = photo; path = [UUID()]
        }
        .fileImporter(isPresented: binding(.files), allowedContentTypes: [.image]) { result in
            guard case .success(let url) = result else { return }
            run {
                let accessed = url.startAccessingSecurityScopedResource()
                defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                do { photo = try await processor.file(url); try Task.checkCancellation(); path = [UUID()] }
                catch is CancellationError { }
                catch { feedback = "无法读取这张图片，请选择其他照片。" }
            }
        }
        .sheet(isPresented: binding(.resources), onDismiss: {
            guard let selected = chosenResource else { return }
            chosenResource = nil
            run {
                if await store.saveAvatarResource(selected) { dismiss() }
                else { feedback = store.feedback }
            }
        }) {
            if let resources { V2AvatarResourcePicker(service: resources) { chosenResource = $0 } }
        }
        .fullScreenCover(isPresented: binding(.camera)) {
            V2ProfileAvatarCamera { captured in
                modal = nil
                guard let captured else { return }
                run {
                    do { photo = try await processor.camera(captured); try Task.checkCancellation(); path = [UUID()] }
                    catch is CancellationError { }
                    catch { feedback = "照片处理失败，请重试。" }
                }
            }.ignoresSafeArea()
        }
        .confirmationDialog("移除当前头像？", isPresented: binding(.remove), titleVisibility: .visible) {
            Button("移除头像", role: .destructive) {
                run { if await store.removeAndSaveAvatar() { dismiss() } else { feedback = store.feedback } }
            }.accessibilityIdentifier("v2.profile.avatar.remove.confirm")
            Button("取消", role: .cancel) { }
        }
        .alert("无法使用相机", isPresented: binding(.cameraPermission)) {
            Button("打开设置") { if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) } }
            Button("取消", role: .cancel) { }
        } message: { Text("请在系统设置中允许相机访问，以拍摄头像。") }
        .onDisappear { task?.cancel() }
    }
    private func binding(_ source: SourceModal) -> Binding<Bool> {
        .init(get: { modal == source }, set: { if $0 { modal = source } else if modal == source { modal = nil } })
    }
    private func run(_ action: @escaping @MainActor () async -> Void) {
        task?.cancel()
        task = Task { isImporting = true; defer { isImporting = false }; await action() }
    }
    private func requestCamera() {
        run {
            let allowed = switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .authorized: true
            case .notDetermined: await AVCaptureDevice.requestAccess(for: .video)
            default: false
            }
            guard !Task.isCancelled else { return }
            modal = allowed ? .camera : .cameraPermission
        }
    }
}

private struct V2ProfileAvatarCamera: UIViewControllerRepresentable {
    var capture: @MainActor (V2SendableImage?) -> Void
    func makeCoordinator() -> Coordinator { .init(capture: capture) }
    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera; picker.mediaTypes = [UTType.image.identifier]
        picker.delegate = context.coordinator
        return picker
    }
    func updateUIViewController(_ controller: UIImagePickerController, context: Context) { context.coordinator.capture = capture }
    static func dismantleUIViewController(_ controller: UIImagePickerController, coordinator: Coordinator) { controller.delegate = nil }
    final class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        var capture: @MainActor (V2SendableImage?) -> Void
        init(capture: @escaping @MainActor (V2SendableImage?) -> Void) { self.capture = capture }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { capture(nil) }
        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            capture((info[.originalImage] as? UIImage).map { .init(image: $0) })
        }
    }
}

struct V2ProfileAvatarCropView: View {
    let photo: V2NormalizedPhoto
    let processor: V2ProfileAvatarImageProcessor
    let save: @MainActor (V2NormalizedPhoto) async -> String?
    @State private var image: V2SendableImage?
    @State private var crop = V2ProfileAvatarCropController()
    @State private var saving = false
    @State private var feedback: String?
    @State private var task: Task<Void, Never>?
    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 24) {
                Text("移动和缩放照片，调整头像显示范围。")
                    .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Spacer(minLength: 0)
                if let image {
                    V2ProfileAvatarCropCanvas(image: image.image, controller: crop)
                        .frame(width: side(geometry.size), height: side(geometry.size))
                        .overlay { Circle().stroke(.white.opacity(0.9), lineWidth: 1).allowsHitTesting(false) }
                        .clipped()
                        .accessibilityLabel("头像裁剪区域")
                        .accessibilityHint("拖动调整位置，双指缩放照片")
                        .accessibilityAdjustableAction { crop.zoom($0 == .increment ? 1.2 : 1 / 1.2) }
                        .accessibilityIdentifier("v2.profile.avatar.crop.canvas")
                } else { ProgressView("正在读取照片…").frame(maxWidth: .infinity, maxHeight: .infinity) }
                Spacer(minLength: 0)
                if saving { ProgressView("正在保存头像…") }
                if let feedback { Text(feedback).font(.footnote).foregroundStyle(.secondary) }
            }.frame(maxWidth: .infinity).padding(24)
        }
        .background(.black).preferredColorScheme(.dark)
        .navigationTitle("调整头像").navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(saving)
        .toolbar { ToolbarItem(placement: .confirmationAction) {
            Button("使用") {
                task?.cancel()
                task = Task {
                    saving = true; defer { saving = false }
                    do {
                        let result = try await processor.crop(photo, unitRect: crop.unitRect)
                        try Task.checkCancellation()
                        feedback = await save(result)
                    } catch is CancellationError { }
                    catch { feedback = "无法处理这张照片，请重新选择。" }
                }
            }.disabled(image == nil || saving).accessibilityIdentifier("v2.profile.avatar.crop.confirm")
        } }
        .task {
            do { image = try await processor.image(photo) }
            catch { feedback = "无法读取这张照片。" }
        }
        .onDisappear { task?.cancel() }
    }
    private func side(_ size: CGSize) -> CGFloat { max(120, min(size.width - 48, size.height - 200, 420)) }
}

/// UIKit owns the transient pan/zoom geometry. Export reads it once on explicit
/// confirmation, avoiding SwiftUI writes during UIScrollView layout callbacks.
@MainActor
private final class V2ProfileAvatarCropController {
    weak var scroll: V2AvatarCropScrollView?
    var unitRect: CGRect {
        guard let scroll, scroll.zoomScale > 0 else { return .zero }
        let size = scroll.imageView.bounds.size
        return .init(x: scroll.contentOffset.x / scroll.zoomScale / size.width,
                     y: scroll.contentOffset.y / scroll.zoomScale / size.height,
                     width: scroll.bounds.width / scroll.zoomScale / size.width,
                     height: scroll.bounds.height / scroll.zoomScale / size.height)
    }
    func zoom(_ factor: CGFloat) {
        guard let scroll else { return }
        scroll.setZoomScale(min(scroll.maximumZoomScale, max(scroll.minimumZoomScale, scroll.zoomScale * factor)), animated: true)
    }
}

private struct V2ProfileAvatarCropCanvas: UIViewRepresentable {
    let image: UIImage
    let controller: V2ProfileAvatarCropController
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> V2AvatarCropScrollView {
        let view = V2AvatarCropScrollView(image: image)
        view.delegate = context.coordinator; controller.scroll = view
        return view
    }
    func updateUIView(_ view: V2AvatarCropScrollView, context: Context) { controller.scroll = view }
    static func dismantleUIView(_ view: V2AvatarCropScrollView, coordinator: Coordinator) { view.delegate = nil }
    final class Coordinator: NSObject, UIScrollViewDelegate {
        func viewForZooming(in scrollView: UIScrollView) -> UIView? { (scrollView as? V2AvatarCropScrollView)?.imageView }
    }
}

private final class V2AvatarCropScrollView: UIScrollView {
    let imageView: UIImageView
    private var previousSize = CGSize.zero
    init(image: UIImage) {
        imageView = UIImageView(image: image)
        super.init(frame: .zero)
        imageView.frame = .init(origin: .zero, size: image.size)
        addSubview(imageView)
        showsVerticalScrollIndicator = false; showsHorizontalScrollIndicator = false
        bounces = false; bouncesZoom = false; contentInsetAdjustmentBehavior = .never
    }
    required init?(coder: NSCoder) { nil }
    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 0, bounds.height > 0, bounds.size != previousSize else { return }
        previousSize = bounds.size
        let size = imageView.bounds.size
        minimumZoomScale = max(bounds.width / size.width, bounds.height / size.height)
        maximumZoomScale = minimumZoomScale * 6
        zoomScale = minimumZoomScale
        contentSize = .init(width: size.width * zoomScale, height: size.height * zoomScale)
        contentOffset = .init(x: max(0, (contentSize.width - bounds.width) / 2), y: max(0, (contentSize.height - bounds.height) / 2))
    }
}
