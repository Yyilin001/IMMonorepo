import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart' show PlatformException;
import 'package:image_picker/image_picker.dart' show ImageSource;

import 'package:local_im/state/photo_library.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_im/core/models.dart';
import 'package:local_im/core/timeline_store.dart';
import 'package:local_im/mock_main.dart';
import 'package:local_im/mock/mock_history_repository.dart';
import 'package:local_im/state/im_providers.dart';
import 'package:material_ui/material_ui.dart';

import 'support.dart';

ChatMessage picture(int i, {int id = 0}) => ChatMessage.image(
  id: 'picture-$i',
  conversationId: id,
  timestamp: DateTime(2026, 11, 14),
  image: mockImages[i % mockImages.length],
);

class _TestGallery extends PhotoLibrary {
  _TestGallery(this.source);
  final File source;
  bool cancel = false;
  int saves = 0;
  @override
  bool get supportsCamera => cameraEnabled;
  bool cameraEnabled = false;
  ImageSource? lastSource;
  PlatformException? error;
  @override
  Future<PhotoDraft?> pick(
    int conversationId, {
    required ImageSource source,
  }) async {
    lastSource = source;
    if (error case final failure?) throw failure;
    return cancel ? null : PhotoDraft(conversationId, this.source, 1, 1);
  }

  @override
  Future<ImageMessageData> save(PhotoDraft draft) async {
    saves++;
    return const ImageMessageData(
      width: 1,
      height: 1,
      localFileName: 'test-photo',
    );
  }

  @override
  File fileFor(String name) => source;
}

void main() {
  testWidgets(
    'each image publishes synchronously and survives live-cache eviction in the archive',
    (tester) async {
      final repository = MockHistoryRepository(latency: Duration.zero);
      final c = createContainer(historyRepository: repository);
      addTearDown(c.dispose);
      await tester.pump(Duration.zero);
      c.read(chatSessionProvider(0).notifier).freeze(true);
      var updates = 0;
      final subscription = c.listen(
        timelineStructureProvider(0),
        (_, _) => updates++,
      );
      for (var i = 0; i < 600; i++) {
        c.read(messageActionsProvider).receive(picture(i));
        expect(updates, i + 1);
        final message = c.read(timelineStoreProvider(0)).value.first;
        expect(message.type, MessageType.image);
        expect(message.image, mockImages[i % mockImages.length]);
        expect(message.historySequence, 361 + i);
        expect(c.read(engineProvider).conversation(0).preview, '[图片]');
      }
      expect(c.read(engineProvider).cachedMessageCount, 500);
      final request = repository.load(0, before: 961, limit: 600);
      await tester.pump(const Duration(milliseconds: 1));
      final page = await request;
      expect(page.messages.length, 600);
      for (var i = 0; i < 600; i++) {
        expect(page.messages[i].type, MessageType.image);
        expect(
          page.messages[i].image,
          mockImages[(599 - i) % mockImages.length],
        );
      }
      subscription.close();
    },
  );

  test('type and image-size changes notify only the affected message', () {
    final store = TimelineStore();
    final image = picture(0);
    final text = ChatMessage(
      id: image.id,
      conversationId: 0,
      text: '',
      timestamp: image.timestamp,
    );
    store.replace([text, picture(1)]);
    final changed = store.replace([image, picture(1)]);
    expect(changed.structureChanged, isFalse);
    expect(changed.changedIds, {image.id});
    final resized = ChatMessage.image(
      id: image.id,
      conversationId: 0,
      timestamp: image.timestamp,
      image: mockImages[1],
    );
    expect(store.replace([resized, picture(1)]).changedIds, {image.id});
    expect(store.replace([resized, picture(1)]).changedIds, isEmpty);
    final archived = resized.withHistorySequence(50);
    expect(archived.type, MessageType.image);
    expect(archived.image, resized.image);
    expect(archived.historySequence, 50);
  });

  test('seed history mixes deterministic landscape, portrait and square placeholders', () async {
    final repository = MockHistoryRepository(latency: Duration.zero);
    addTearDown(repository.dispose);
    final first = await repository.load(2, limit: 100);
    final again = await repository.load(2, limit: 100);
    expect(
      first.messages.map((m) => m.type),
      again.messages.map((m) => m.type),
    );
    expect(
      first.messages.map((m) => m.image).whereType<ImageMessageData>().toSet(),
      mockImages.toSet(),
    );
    expect(first.messages.where((m) => m.type == MessageType.text), isNotEmpty);
    expect(
      first.messages
          .where((m) => m.type == MessageType.image)
          .every((m) => m.preview == '[图片]' && m.text.isEmpty),
      isTrue,
    );
  });

  test(
    'a confirmed photo is copied locally and addresses the original chat',
    () async {
      final dir = await Directory.systemTemp.createTemp();
      addTearDown(() => dir.delete(recursive: true));
      final original = await File('${dir.path}/source').writeAsBytes([1, 2, 3]);
      final library = PhotoLibrary(supportDirectory: () async => dir);
      final image = await library.save(PhotoDraft(3, original, 240, 160));
      await original.delete();
      expect(await library.fileFor(image.localFileName!).readAsBytes(), [
        1,
        2,
        3,
      ]);
      final c = createContainer();
      addTearDown(c.dispose);
      c.read(selectedConversationProvider.notifier).select(1);
      expect(c.read(messageActionsProvider).sendImage(3, image), isTrue);
      expect(c.read(engineProvider).messages(3).first.image, image);
      expect(c.read(engineProvider).messages(1), isEmpty);
    },
  );

  for (final mobile in [true, false]) {
    testWidgets(
      '${mobile ? "phone" : "desktop"} confirms gallery photos, preserves drafts and previews via tap and long press',
      (tester) async {
        tester.view.physicalSize = mobile
            ? const Size(375, 812)
            : const Size(1380, 900);
        tester.view.devicePixelRatio = 1;
        final dir = Directory.systemTemp.createTempSync();
        addTearDown(() => dir.deleteSync(recursive: true));
        final file = File('${dir.path}/test.png')
          ..writeAsBytesSync(
            base64Decode(
              'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGNo+GUAAAOoAasOXWrzAAAAAElFTkSuQmCC',
            ),
          );
        final gallery = _TestGallery(file)..cameraEnabled = mobile;
        final c = ProviderContainer(
          overrides: [
            photoLibraryProvider.overrideWithValue(gallery),
            imConfigProvider.overrideWithValue(
              const ImConfig(autoStart: false),
            ),
          ],
        );
        addTearDown(() {
          c.dispose();
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
        });
        await tester.pumpWidget(
          UncontrolledProviderScope(container: c, child: const LocalImApp()),
        );
        await tester.pumpAndSettle();
        if (mobile) {
          await tester.tap(find.text('产品设计小组'));
          await tester.pumpAndSettle();
        }
        await tester.enterText(find.byKey(const Key('composer')), '保留这段草稿');
        gallery.cancel = true;
        final plus = find.byKey(const Key('chat-attachments'));
        final button = find.byKey(const Key('send-image'));
        final camera = find.byKey(const Key('take-photo'));
        Future<void> openPanel() async {
          await tester.tap(plus);
          await tester.pumpAndSettle();
          final panel = find.byKey(const Key('attachment-panel'));
          expect(
            tester.getTopLeft(panel).dy,
            greaterThanOrEqualTo(tester.getBottomLeft(plus).dy),
          );
          expect(
            find.descendant(of: button, matching: find.text('相册')),
            findsOneWidget,
          );
          expect(
            tester.getCenter(find.byIcon(Icons.image_outlined)).dy,
            lessThan(tester.getCenter(find.text('相册')).dy),
          );
          expect(
            tester
                .widget<TextField>(find.byKey(const Key('composer')))
                .focusNode!
                .hasFocus,
            isFalse,
          );
          expect(camera, mobile ? findsOneWidget : findsNothing);
        }

        expect(button, findsNothing);
        expect(camera, findsNothing);
        await openPanel();
        await tester.tap(plus);
        await tester.pumpAndSettle();
        expect(button, findsNothing);
        await openPanel();
        await tester.tap(find.byKey(const Key('composer')));
        await tester.pumpAndSettle();
        expect(button, findsNothing);
        if (mobile) {
          await openPanel();
          await tester.binding.handlePopRoute();
          await tester.pumpAndSettle();
          expect(button, findsNothing);
          expect(plus, findsOneWidget);
        }
        expect(gallery.lastSource, isNull);
        expect(c.read(draftProvider(0)), '保留这段草稿');
        await openPanel();
        await tester.tap(button);
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('photo-confirmation')), findsNothing);
        expect(gallery.lastSource, ImageSource.gallery);
        expect(camera, findsNothing);
        if (mobile) {
          await openPanel();
          await tester.tap(camera);
          await tester.pumpAndSettle();
          expect(gallery.lastSource, ImageSource.camera);
          expect(find.byKey(const Key('photo-confirmation')), findsNothing);
          expect(gallery.saves, 0);
          gallery.error = PlatformException(code: 'camera_access_denied');
          await openPanel();
          await tester.tap(camera);
          await tester.pumpAndSettle();
          expect(find.text('请在系统设置中允许涟漪使用相机。'), findsOneWidget);
          gallery.error = null;
          await tester.pump(const Duration(seconds: 5));
          await tester.pumpAndSettle();
        }
        gallery.cancel = false;
        await openPanel();
        await tester.tap(button);
        await tester.pumpAndSettle();
        expect(find.text('发送给产品设计小组'), findsOneWidget);
        await tester.tap(find.byKey(const Key('close-image-preview')));
        await tester.pumpAndSettle();
        expect(gallery.saves, 0);
        expect(c.read(engineProvider).sent, 0);
        await openPanel();
        await tester.tap(mobile ? camera : button);
        await tester.pumpAndSettle();
        expect(
          gallery.lastSource,
          mobile ? ImageSource.camera : ImageSource.gallery,
        );
        await tester.pumpAndSettle();
        final confirm = find.byKey(const Key('confirm-send-photo'));
        for (
          var i = 0;
          i < 40 && tester.widget<FilledButton>(confirm).onPressed == null;
          i++
        ) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
          await tester.pump();
        }
        await tester.tap(confirm);
        await tester.pump();
        expect(gallery.saves, 1);
        expect(c.read(engineProvider).sent, 1);
        expect(c.read(engineProvider).conversation(0).preview, '[图片]');
        expect(
          c.read(timelineStoreProvider(0)).value.first.type,
          MessageType.image,
        );
        expect(c.read(draftProvider(0)), '保留这段草稿');
        await tester.pumpAndSettle();
        final image = find.byKey(const ValueKey('image-local-0'));
        final thumbnailBounds = tester.getRect(image);
        final flight = find.byKey(const Key('message-image-flight'));
        await tester.tap(image);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));
        final opening = tester.getRect(flight);
        expect(opening.width, greaterThan(thumbnailBounds.width));
        await tester.pumpAndSettle();
        final fullImage = find.bySemanticsLabel('照片预览');
        expect(tester.getRect(fullImage).width, greaterThan(opening.width));
        expect(flight, findsNothing);
        expect(find.byKey(const Key('image-preview')), findsOneWidget);
        final viewer = find.byType(InteractiveViewer);
        final pages = tester
            .widget<PageView>(find.byKey(const Key('gallery-pages')))
            .controller!;
        final openedPage = pages.page!;
        final zoom = tester
            .widget<InteractiveViewer>(viewer)
            .transformationController!;
        final localTap = tester.getSize(viewer).center(Offset.zero) * .7;
        final tap = tester.getTopLeft(viewer) + localTap;
        Future<void> doubleTap() async {
          await tester.tapAt(tap);
          await tester.pump(const Duration(milliseconds: 70));
          await tester.tapAt(tap);
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 80));
          expect(
            zoom.value.getMaxScaleOnAxis(),
            allOf(greaterThan(1), lessThan(2)),
          );
        }

        await doubleTap();
        expect((zoom.toScene(localTap) - localTap).distance, lessThan(.01));
        await tester.pumpAndSettle();
        expect(zoom.value.getMaxScaleOnAxis(), 2);
        await tester.timedDrag(
          viewer,
          const Offset(100, 0),
          const Duration(milliseconds: 350),
        );
        await tester.pumpAndSettle();
        expect(pages.page, openedPage);
        await doubleTap();
        final drag = await tester.startGesture(tester.getCenter(viewer));
        await drag.moveBy(const Offset(-40, 0));
        await tester.pump();
        final intermediate = zoom.value.getMaxScaleOnAxis();
        expect(intermediate, greaterThan(1));
        await drag.moveBy(const Offset(-50, 0));
        await tester.pump(const Duration(milliseconds: 300));
        expect(zoom.value.getMaxScaleOnAxis(), closeTo(intermediate, .001));
        await drag.up();
        await tester.pumpAndSettle();
        await doubleTap();
        await tester.pumpAndSettle();
        expect(zoom.value.getMaxScaleOnAxis(), 1);
        c.read(messageActionsProvider).receive(picture(999));
        await tester.pump();
        expect(pages.page, openedPage);
        final slowDrag = await tester.startGesture(tester.getCenter(viewer));
        await slowDrag.moveBy(const Offset(24, 0));
        await slowDrag.moveBy(const Offset(42, 0));
        await tester.pump();
        expect(pages.page!, inExclusiveRange(openedPage - 1, openedPage));
        await tester.pump(const Duration(milliseconds: 200));
        await slowDrag.up();
        await tester.pumpAndSettle();
        expect(pages.page, openedPage);

        await tester.fling(viewer, const Offset(140, 0), 850);
        await tester.pumpAndSettle();
        expect(pages.page, openedPage - 1);
        expect(
          find.descendant(of: viewer, matching: find.text('图片占位')),
          findsOneWidget,
        );
        await tester.tap(find.byTooltip('下一张'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 90));
        expect(pages.page!, inExclusiveRange(openedPage - 1, openedPage));
        await tester.pumpAndSettle();
        expect(pages.page, openedPage);
        final galleryPage = find.byKey(const Key('image-preview'));
        final fullBounds = tester.getRect(fullImage);
        final interrupted = await tester.startGesture(tester.getCenter(viewer));
        await interrupted.moveBy(const Offset(0, 24));
        await interrupted.moveBy(const Offset(0, 40));
        await tester.pump();
        expect(tester.getRect(fullImage).width, lessThan(fullBounds.width));
        await interrupted.cancel();
        await tester.pumpAndSettle();
        expect(tester.getRect(fullImage), fullBounds);
        expect(pages.page, openedPage);
        final pull = await tester.startGesture(tester.getCenter(viewer));
        await pull.moveBy(const Offset(0, 24));
        await pull.moveBy(const Offset(5, 50));
        await tester.pump();
        final halfway = tester.getRect(fullImage);
        expect(halfway.width, lessThan(fullBounds.width));
        expect(halfway.center.dy, greaterThan(fullBounds.center.dy));
        expect(
          tester.widget<Scaffold>(galleryPage).backgroundColor!.a,
          lessThan(1),
        );
        await pull.moveBy(const Offset(5, 60));
        await tester.pump();
        final released = tester.getRect(fullImage);
        expect(released.width, lessThan(halfway.width));
        expect(released.center.dy, greaterThan(halfway.center.dy));
        await pull.up();
        await tester.pump();
        await tester.pump();
        final startOfFlight = tester.getRect(flight);
        expect(startOfFlight.width, closeTo(released.width, 1));
        expect((startOfFlight.center - released.center).distance, lessThan(1));
        await tester.pump(const Duration(milliseconds: 100));
        expect(tester.getRect(flight).width, lessThan(startOfFlight.width));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('image-preview')), findsNothing);
        await tester.longPress(image);
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('message-menu-copy')), findsNothing);
        expect(find.byKey(const Key('message-menu-delete')), findsOneWidget);
        await tester.tap(find.byKey(const Key('message-menu-preview')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('image-preview')), findsOneWidget);
        await tester.tap(find.byKey(const Key('close-image-preview')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 80));
        final closingWidth = tester.getRect(flight).width;
        await tester.pump(const Duration(milliseconds: 100));
        expect(tester.getRect(flight).width, lessThan(closingWidth));
        await tester.pumpAndSettle();
        final scroll = tester
            .widget<CustomScrollView>(find.byKey(const Key('message-list')))
            .controller!;
        scroll.jumpTo(350);
        await tester.pump();
        final visible = find
            .byWidgetPredicate(
              (w) => w.runtimeType.toString() == '_MessageBubble',
            )
            .hitTestable()
            .first;
        final key = tester.widget(visible).key;
        final anchor = find.byWidgetPredicate(
          (w) => w.runtimeType.toString() == '_MessageBubble' && w.key == key,
        );
        final y = tester.getTopLeft(anchor).dy;
        for (var i = 0; i < 20; i++) {
          c.read(messageActionsProvider).receive(picture(i));
          await tester.pump();
          expect(scroll.offset, 350);
          expect(tester.getTopLeft(anchor).dy, closeTo(y, .5));
        }
        expect(tester.takeException(), isNull);
      },
    );
  }
}
