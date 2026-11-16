part of 'workspace.dart';

class _MessageImage extends ConsumerWidget {
  const _MessageImage({super.key, required this.message, this.preview = false});
  final ChatMessage message;
  final bool preview;

  @override
  Widget build(BuildContext context, WidgetRef ref) => LayoutBuilder(
    builder: (context, constraints) {
      final image = message.image!;
      final name = image.localFileName;
      final ratio = preview && name != null
          ? image.aspectRatio
          : image.aspectRatio.clamp(.65, 1.8);
      final maxWidth = preview ? constraints.maxWidth : 224.0;
      var width = min(maxWidth, constraints.maxWidth);
      if (ratio < 1 && (!preview || name == null)) {
        width = min(width, maxWidth * .78);
      }
      if (constraints.hasBoundedHeight) {
        width = min(width, constraints.maxHeight * ratio);
      }
      final height = width / ratio;
      final density = MediaQuery.devicePixelRatioOf(context);
      final Widget content;
      if (name == null) {
        content = _ImagePlaceholder(message: message, width: width);
      } else {
        final file = FileImage(ref.read(photoLibraryProvider).fileFor(name));
        final provider = preview
            ? ResizeImage(
                file,
                width: max(1, (constraints.maxWidth * density * 2).ceil()),
                height: max(1, (constraints.maxHeight * density * 2).ceil()),
                policy: ResizeImagePolicy.fit,
              )
            : ResizeImage.resizeIfNeeded(
                image.aspectRatio <= ratio
                    ? min(image.width, max(1, (width * density).ceil()))
                    : null,
                image.aspectRatio > ratio
                    ? min(image.height, max(1, (height * density).ceil()))
                    : null,
                file,
              );
        content = Image(
          image: provider,
          fit: BoxFit.cover,
          semanticLabel: preview ? '照片预览' : '聊天图片',
          errorBuilder: (_, _, _) => const Center(
            child: Icon(
              Icons.broken_image_outlined,
              semanticLabel: '图片无法显示',
              color: muted,
            ),
          ),
        );
      }
      final visual = ClipRRect(
        borderRadius: BorderRadius.circular(preview && name != null ? 0 : 16),
        child: content,
      );
      return SizedBox(
        width: width,
        height: height,
        child: Hero(
          tag: (message.conversationId, message.id),
          createRectTween: (begin, end) => RectTween(begin: begin, end: end),
          flightShuttleBuilder: _imageFlight,
          child: visual,
        ),
      );
    },
  );
}

// Keep the decoded thumbnail visible until the larger image has its first frame.
Widget _imageFlight(
  BuildContext context,
  Animation<double> animation,
  HeroFlightDirection direction,
  BuildContext from,
  BuildContext to,
) {
  final push = direction == HeroFlightDirection.push;
  final thumb = ((push ? from : to).widget as Hero).child as ClipRRect;
  final large = ((push ? to : from).widget as Hero).child as ClipRRect;
  final full = large.child!;
  final child = full is Image
      ? Image(
          image: full.image,
          fit: BoxFit.cover,
          errorBuilder: (_, _, _) => thumb.child!,
          frameBuilder: (_, image, frame, _) =>
              frame == null ? thumb.child! : image,
        )
      : full;
  return AnimatedBuilder(
    animation: animation,
    child: Material(type: MaterialType.transparency, child: child),
    builder: (_, child) => ClipRRect(
      key: const Key('message-image-flight'),
      borderRadius: BorderRadiusGeometry.lerp(
        thumb.borderRadius,
        large.borderRadius,
        animation.value,
      )!,
      child: child,
    ),
  );
}

class _ImagePlaceholder extends StatelessWidget {
  const _ImagePlaceholder({required this.message, required this.width});
  final ChatMessage message;
  final double width;
  @override
  Widget build(BuildContext context) {
    final mine = message.isMine;
    final image = message.image!;
    return Semantics(
      label: '图片占位，${image.width} × ${image.height}',
      image: true,
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: mine ? const Color(0xFFCEE2D5) : const Color(0xFFDAE3E8),
          ),
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: mine
                ? const [Color(0xFFE7F2E9), Color(0xFFCDE1D6)]
                : const [Color(0xFFEDF2F5), Color(0xFFD6E2E8)],
          ),
        ),
        child: Stack(
          children: [
            Center(
              child: Icon(
                Icons.landscape_rounded,
                size: min(56, width * .3),
                color: mine ? const Color(0xFF739D88) : const Color(0xFF8FA5AF),
              ),
            ),
            Positioned(
              left: 12,
              bottom: 11,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: .65),
                  borderRadius: BorderRadius.circular(7),
                ),
                child: const Text(
                  '图片占位',
                  style: TextStyle(fontSize: 11, color: Color(0xFF61796E)),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

void _showImagePreview(BuildContext context, ChatMessage message) {
  final container = ProviderScope.containerOf(context, listen: false);
  final timeline = container
      .read(timelineStoreProvider(message.conversationId))
      .value;
  final pictures = timeline.reversed
      .where((m) => m.type == MessageType.image)
      .toList();
  final index = pictures.indexWhere((m) => m.id == message.id);
  // A long press can outlive its row in a rapidly advancing chat.
  final reducedMotion = MediaQuery.disableAnimationsOf(context);
  Navigator.of(context, rootNavigator: true).push(
    PageRouteBuilder<void>(
      settings: RouteSettings(name: '/image/${message.id}'),
      opaque: false,
      transitionDuration: Duration(milliseconds: reducedMotion ? 0 : 360),
      reverseTransitionDuration: Duration(
        milliseconds: reducedMotion ? 0 : 300,
      ),
      pageBuilder: (_, _, _) => HeroMode(
        enabled: !reducedMotion,
        child: _MessageGallery(
          pictures: index < 0 ? [message] : pictures,
          initialIndex: index < 0 ? 0 : index,
        ),
      ),
      transitionsBuilder: (_, animation, _, child) => FadeTransition(
        opacity: animation.drive(CurveTween(curve: Curves.easeOut)),
        child: child,
      ),
    ),
  );
}

class _MessageGallery extends ConsumerStatefulWidget {
  const _MessageGallery({required this.pictures, required this.initialIndex});
  final List<ChatMessage> pictures;
  final int initialIndex;

  @override
  ConsumerState<_MessageGallery> createState() => _MessageGalleryState();
}

class _MessageGalleryState extends ConsumerState<_MessageGallery>
    with TickerProviderStateMixin {
  late int index = widget.initialIndex;
  late final pages = PageController(initialPage: index, keepPage: false);
  Drag? pageDrag;
  Axis? swipeAxis;
  final transform = TransformationController();
  final zoomTween = Matrix4Tween();
  late final AnimationController zoomAnimation =
      AnimationController(
        vsync: this,
        duration: const Duration(milliseconds: 240),
      )..addListener(() {
        transform.value = zoomTween.transform(
          Curves.easeOutCubic.transform(zoomAnimation.value),
        );
      });
  final pull = ValueNotifier(Offset.zero);
  Offset settleFrom = Offset.zero;
  Offset pullAnchor = Offset.zero;
  bool cancelled = false;
  late final AnimationController settle =
      AnimationController(
        vsync: this,
        duration: const Duration(milliseconds: 180),
      )..addListener(() {
        pull.value =
            settleFrom * (1 - Curves.easeOutCubic.transform(settle.value));
      });

  void restorePull() {
    if (pull.value == Offset.zero) return;
    if (MediaQuery.disableAnimationsOf(context)) {
      pull.value = Offset.zero;
    } else {
      settleFrom = pull.value;
      settle.forward(from: 0);
    }
  }

  Offset tapPosition = Offset.zero;
  Offset swipeStart = Offset.zero;
  Offset swipeDelta = Offset.zero;
  bool canSwipe = false;

  bool get fitted => transform.value.getMaxScaleOnAxis() <= 1.001;

  void move(int step) {
    final next = index + step;
    if (next < 0 || next >= widget.pictures.length) return;
    zoomAnimation.stop();
    transform.value = Matrix4.identity();
    if (MediaQuery.disableAnimationsOf(context)) {
      pages.jumpToPage(next);
    } else {
      pages.animateToPage(
        next,
        duration: const Duration(milliseconds: 260),
        curve: Curves.easeOutCubic,
      );
    }
  }

  void startInteraction(ScaleStartDetails details) {
    zoomAnimation.stop();
    if (details.pointerCount > 1 && pages.page != index.toDouble()) {
      pages.jumpToPage(index);
    }
    settle.stop();
    if (details.pointerCount > 1) pull.value = Offset.zero;
    cancelled = false;
    swipeStart = details.localFocalPoint - pull.value;
    if (pull.value == Offset.zero) pullAnchor = swipeStart;
    swipeDelta = Offset.zero;
    swipeAxis = pull.value == Offset.zero ? null : Axis.vertical;
    canSwipe = fitted && details.pointerCount == 1;
  }

  void updateInteraction(ScaleUpdateDetails details) {
    if (!fitted || details.pointerCount != 1 || details.scale != 1) {
      canSwipe = false;
      pageDrag?.cancel();
      if (pull.value != Offset.zero) restorePull();
      return;
    }
    if (!canSwipe) return;
    final previous = swipeDelta;
    swipeDelta = details.localFocalPoint - swipeStart;
    if (swipeAxis == null) {
      if (swipeDelta.distance < 4) return;
      swipeAxis = swipeDelta.dx.abs() > swipeDelta.dy.abs()
          ? Axis.horizontal
          : Axis.vertical;
    }
    if (swipeAxis == Axis.vertical) {
      pull.value = swipeDelta.dy > 0 ? swipeDelta : Offset.zero;
      return;
    }
    if (widget.pictures.length < 2) return;

    // Forward one-finger movement to Flutter's pager. Keeping a single scale
    // recognizer lets a pinch and a zoomed pan stay with InteractiveViewer.
    final delta = pageDrag == null
        ? swipeDelta.dx
        : swipeDelta.dx - previous.dx;
    pageDrag ??= pages.position.drag(
      DragStartDetails(
        globalPosition: details.focalPoint,
        sourceTimeStamp: details.sourceTimeStamp,
      ),
      () => pageDrag = null,
    );
    pageDrag!.update(
      DragUpdateDetails(
        globalPosition: details.focalPoint,
        sourceTimeStamp: details.sourceTimeStamp,
        delta: Offset(delta, 0),
        primaryDelta: delta,
      ),
    );
  }

  void endInteraction(ScaleEndDetails details) {
    final drag = pageDrag;
    if (drag != null) {
      final velocity = details.pointerCount == 0
          ? details.velocity.pixelsPerSecond.dx
          : 0.0;
      drag.end(
        DragEndDetails(
          velocity: Velocity(pixelsPerSecond: Offset(velocity, 0)),
          primaryVelocity: velocity,
        ),
      );
    } else if (pull.value.dy > 0) {
      if (canSwipe && fitted && !cancelled && details.pointerCount == 0) {
        Navigator.pop(context);
      } else {
        restorePull();
      }
    }
    canSwipe = false;
  }

  void toggleZoom() {
    final zoomIn = zoomAnimation.isAnimating
        ? zoomTween.end!.isIdentity()
        : fitted;
    final target = zoomIn
        ? (Matrix4.identity()
            ..translateByDouble(-tapPosition.dx, -tapPosition.dy, 0, 1)
            ..scaleByDouble(2, 2, 1, 1))
        : Matrix4.identity();
    zoomAnimation.stop();
    if (MediaQuery.disableAnimationsOf(context)) {
      transform.value = target;
      return;
    }
    zoomTween
      ..begin = transform.value
      ..end = target;
    zoomAnimation.forward(from: 0);
  }

  @override
  void dispose() {
    settle.dispose();
    pull.dispose();
    pages.dispose();
    zoomAnimation.dispose();
    transform.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final count = widget.pictures.length;
    final distance = MediaQuery.sizeOf(context).height * .65;
    double progress(Offset delta) => (delta.dy / distance).clamp(0.0, 1.0);
    return ValueListenableBuilder<Offset>(
      valueListenable: pull,
      child: Listener(
        onPointerCancel: (_) => cancelled = true,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => Navigator.pop(context),
          onDoubleTapDown: (details) => tapPosition = details.localPosition,
          onDoubleTap: toggleZoom,
          child: InteractiveViewer(
            clipBehavior: Clip.none,
            transformationController: transform,
            minScale: 1,
            maxScale: 4,
            trackpadScrollCausesScale: true,
            onInteractionStart: startInteraction,
            onInteractionUpdate: updateInteraction,
            onInteractionEnd: endInteraction,
            child: ValueListenableBuilder<Offset>(
              valueListenable: pull,
              builder: (context, delta, child) {
                final scale = 1 - .45 * progress(delta);
                return Transform(
                  transform: Matrix4.identity()
                    ..translateByDouble(
                      delta.dx + pullAnchor.dx * (1 - scale),
                      delta.dy + pullAnchor.dy * (1 - scale),
                      0,
                      1,
                    )
                    ..scaleByDouble(scale, scale, 1, 1),
                  child: child,
                );
              },
              child: PageView.builder(
                key: const Key('gallery-pages'),
                controller: pages,
                physics: const NeverScrollableScrollPhysics(
                  parent: BouncingScrollPhysics(),
                ),
                onPageChanged: (page) => setState(() => index = page),
                itemCount: count,
                itemBuilder: (_, page) {
                  final message = widget.pictures[page];
                  return HeroMode(
                    enabled:
                        page == index &&
                        !MediaQuery.disableAnimationsOf(context),
                    child: Center(
                      child: _MessageImage(message: message, preview: true),
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      ),
      builder: (context, delta, viewer) {
        final fraction = progress(delta);
        final chrome = 1 - (fraction * 2.5).clamp(0.0, 1.0);
        return Scaffold(
          key: const Key('image-preview'),
          backgroundColor: Colors.black.withValues(alpha: 1 - fraction * .9),
          appBar: AppBar(
            backgroundColor: Colors.transparent,
            foregroundColor: Colors.white.withValues(alpha: chrome),
            leading: const CloseButton(key: Key('close-image-preview')),
            centerTitle: true,
            title: Text(count == 1 ? '图片' : '${index + 1} / $count'),
          ),
          body: SafeArea(
            child: Column(
              children: [
                Expanded(child: viewer!),
                if (count > 1)
                  Opacity(
                    opacity: chrome,
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        IconButton(
                          tooltip: '上一张',
                          onPressed: index > 0 ? () => move(-1) : null,
                          color: Colors.white,
                          disabledColor: Colors.white30,
                          icon: const Icon(Icons.chevron_left),
                        ),
                        const SizedBox(width: 24),
                        IconButton(
                          tooltip: '下一张',
                          onPressed: index + 1 < count ? () => move(1) : null,
                          color: Colors.white,
                          disabledColor: Colors.white30,
                          icon: const Icon(Icons.chevron_right),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _AttachmentPanel extends ConsumerWidget {
  const _AttachmentPanel({required this.onPick});
  final ValueChanged<ImageSource> onPick;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final size = MediaQuery.sizeOf(context);
    final supportsCamera = ref.watch(photoLibraryProvider).supportsCamera;
    final keyboard = MediaQuery.viewInsetsOf(context).bottom;
    final available = size.height - MediaQuery.paddingOf(context).vertical - keyboard;
    return Container(
      key: const Key('attachment-panel'),
      width: double.infinity,
      constraints: BoxConstraints(maxHeight: max(0, available * .36)),
      decoration: const BoxDecoration(
        color: Color(0xFFF4F6F5),
        border: Border(top: BorderSide(color: line, width: .5)),
      ),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(12, 14, 12, 18),
        child: LayoutBuilder(
          builder: (_, constraints) {
            final tileWidth = min(96.0, constraints.maxWidth / 4);
            return Wrap(
              children: [
                for (final source in [
                  ImageSource.gallery,
                  if (supportsCamera) ImageSource.camera,
                ])
                  SizedBox(
                    width: tileWidth,
                    child: _AttachmentTile(source: source, onPick: onPick),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _AttachmentTile extends StatelessWidget {
  const _AttachmentTile({required this.source, required this.onPick});
  final ImageSource source;
  final ValueChanged<ImageSource> onPick;

  @override
  Widget build(BuildContext context) {
    final gallery = source == ImageSource.gallery;
    return TextButton(
      key: Key(gallery ? 'send-image' : 'take-photo'),
      onPressed: () => onPick(source),
      style: TextButton.styleFrom(
        padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 2),
        foregroundColor: ink,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 58,
            height: 58,
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(15),
            ),
            child: Icon(
              gallery ? Icons.image_outlined : Icons.photo_camera_outlined,
              color: green,
              size: 28,
            ),
          ),
          const SizedBox(height: 7),
          Text(gallery ? '相册' : '拍照', style: const TextStyle(fontSize: 13)),
        ],
      ),
    );
  }
}

Future<bool> _composePhoto(
  BuildContext context,
  WidgetRef ref, {
  int? conversationId,
  ImageSource source = ImageSource.gallery,
}) async {
  final library = ref.read(photoLibraryProvider);
  if (library.busy) return false;
  library.busy = true;
  try {
    final draft = conversationId == null
        ? await library.recover()
        : await library.pick(conversationId, source: source);
    if (draft == null || !context.mounted) return false;
    final id = draft.conversationId;
    if (!ref.read(engineProvider).hasContact(id) ||
        ref.read(contactDeletedProvider(id))) {
      return false;
    }
    final recipient = ref.read(contactDisplayNameProvider(id));
    final confirmed = await Navigator.of(context, rootNavigator: true)
        .push<bool>(
          MaterialPageRoute(
            builder: (_) =>
                _PhotoConfirmation(file: draft.file, recipient: recipient),
          ),
        );
    if (confirmed != true ||
        !context.mounted ||
        ref.read(contactDeletedProvider(id))) {
      return false;
    }
    final image = await library.save(draft);
    if (context.mounted &&
        ref.read(messageActionsProvider).sendImage(id, image)) {
      return true;
    }
    await library.fileFor(image.localFileName!).delete();
  } catch (error) {
    if (context.mounted) {
      final message = switch (error) {
        PlatformException(code: 'camera_access_denied') => '请在系统设置中允许涟漪使用相机。',
        PlatformException(code: 'camera_access_restricted') => '此设备已限制相机使用，可从相册选择图片。',
        PlatformException(code: 'no_available_camera') => '未找到可用相机，可从相册选择图片。',
        _ => '图片处理失败，请重试。',
      };
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
    }
  } finally {
    library.busy = false;
  }
  return false;
}

class _PhotoConfirmation extends StatelessWidget {
  const _PhotoConfirmation({required this.file, required this.recipient});
  final File file;
  final String recipient;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      key: const Key('photo-confirmation'),
      backgroundColor: const Color(0xFF16221E),
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        foregroundColor: Colors.white,
        leading: CloseButton(key: const Key('close-image-preview')),
        title: Text(
          '发送给$recipient',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final scale = MediaQuery.devicePixelRatioOf(context);
            return Image(
              image: ResizeImage(
                FileImage(file),
                width: (constraints.maxWidth * scale * 2).ceil(),
                height: (constraints.maxHeight * scale * 2).ceil(),
                policy: ResizeImagePolicy.fit,
              ),
              fit: BoxFit.contain,
              semanticLabel: '照片预览',
              errorBuilder: (_, _, _) => const Center(
                child: Text('无法读取这张图片', style: TextStyle(color: Colors.white)),
              ),
              frameBuilder: (context, child, frame, _) => Column(
                children: [
                  Expanded(
                    child: Center(child: InteractiveViewer(child: child)),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
                    child: SizedBox(
                      width: double.infinity,
                      child: FilledButton(
                        key: const Key('confirm-send-photo'),
                        onPressed: frame == null
                            ? null
                            : () {
                                if (ModalRoute.of(context)?.isCurrent == true) {
                                  Navigator.of(context).pop(true);
                                }
                              },
                        child: const Text('发送'),
                      ),
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}
