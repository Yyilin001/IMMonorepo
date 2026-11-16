import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_im/core/models.dart';
import 'package:local_im/mock_main.dart';
import 'package:local_im/state/im_providers.dart';
import 'package:material_ui/material_ui.dart';

import 'support.dart';

void main() {
  Future<ProviderContainer> mount(WidgetTester tester) async {
    tester.view.physicalSize = const Size(440, 956);
    tester.view.devicePixelRatio = 1;
    final c = createContainer();
    addTearDown(() {
      debugOnRebuildDirtyWidget = null;
      c.dispose();
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
      tester.platformDispatcher.clearAccessibilityFeaturesTestValue();
    });
    await tester.pumpWidget(
      UncontrolledProviderScope(container: c, child: const LocalImApp()),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('产品设计小组'));
    await tester.pumpAndSettle();
    return c;
  }

  ChatMessage message(String id, {bool image = false, bool mine = false}) =>
      image
      ? ChatMessage.image(
          id: id,
          conversationId: 0,
          timestamp: DateTime.now(),
          isMine: mine,
        )
      : ChatMessage(
          id: id,
          conversationId: 0,
          text: id,
          timestamp: DateTime.now(),
          isMine: mine,
        );
  Finder entrance(String id) => find.byKey(ValueKey('message-entrance-$id'));
  Finder fade(String id) =>
      find.descendant(of: entrance(id), matching: find.byType(FadeTransition));
  double opacity(WidgetTester tester, String id) =>
      tester.widget<FadeTransition>(fade(id)).opacity.value;
  ScrollController scroll(WidgetTester tester) => tester
      .widget<CustomScrollView>(find.byKey(const Key('message-list')))
      .controller!;

  testWidgets(
    'live text and image fade in without delaying publication, relayout or rebuilding older bubbles',
    (tester) async {
      final c = await mount(tester);
      expect(
        find.byWidgetPredicate(
          (w) => w.runtimeType.toString() == '_MessageEntrance',
        ),
        findsNothing,
      );
      var notifications = 0;
      final subscription = c.listen(
        timelineStructureProvider(0),
        (_, _) => notifications++,
      );
      for (final image in [false, true]) {
        final id = image ? 'animated-image' : 'animated-text';
        c.read(messageActionsProvider).receive(message(id, image: image));
        expect(c.read(timelineStoreProvider(0)).value.first.id, id);
        expect(notifications, image ? 2 : 1);
        await tester.pump();
        expect(opacity(tester, id), closeTo(.3, .01));
        final size = tester.getSize(entrance(id));
        var oldBubbleBuilds = 0;
        debugOnRebuildDirtyWidget = (element, _) {
          if (element.widget.runtimeType.toString() == '_MessageBubble') {
            oldBubbleBuilds++;
          }
        };
        await tester.pump(const Duration(milliseconds: 90));
        expect(opacity(tester, id), inExclusiveRange(.3, 1));
        expect(tester.getSize(entrance(id)), size);
        await tester.pump(const Duration(milliseconds: 120));
        expect(opacity(tester, id), 1);
        expect(scroll(tester).offset, 0);
        expect(oldBubbleBuilds, 0);
        debugOnRebuildDirtyWidget = null;
      }
      subscription.close();
      // Scrolling a completed message out and back must not replay its entrance.
      scroll(tester).jumpTo(1500);
      await tester.pumpAndSettle();
      scroll(tester).jumpTo(0);
      await tester.pumpAndSettle();
      expect(fade('animated-image'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'history reading and reduced motion skip entry effects while incoming updates remain immediate',
    (tester) async {
      final c = await mount(tester);
      scroll(tester).jumpTo(400);
      await tester.pump();
      final anchor = find
          .byWidgetPredicate(
            (w) => w.runtimeType.toString() == '_MessageBubble',
          )
          .hitTestable()
          .first;
      final anchorKey = tester.widget(anchor).key;
      final retainedAnchor = find.byWidgetPredicate(
        (w) =>
            w.runtimeType.toString() == '_MessageBubble' && w.key == anchorKey,
      );
      final y = tester.getTopLeft(anchor).dy;
      c
          .read(messageActionsProvider)
          .receive(message('reading-image', image: true));
      await tester.pump();
      expect(entrance('reading-image'), findsNothing);
      expect(scroll(tester).offset, 400);
      expect(tester.getTopLeft(retainedAnchor).dy, closeTo(y, .5));
      await tester.tap(find.byKey(const Key('latest-messages')));
      await tester.pumpAndSettle();
      expect(c.read(chatSessionProvider(0)).frozen, isFalse);
      expect(scroll(tester).offset, 0);
      tester.platformDispatcher.accessibilityFeaturesTestValue =
          const FakeAccessibilityFeatures(disableAnimations: true);
      await tester.pump();
      c.read(messageActionsProvider).receive(message('no-motion'));
      await tester.pump();
      expect(entrance('no-motion'), findsNothing);
      expect(find.text('no-motion'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'high-rate reception skips animations but a manual send still animates',
    (tester) async {
      final c = await mount(tester);
      c.read(mockRuntimeProvider.notifier).toggleRunning();
      c.read(mockRuntimeProvider.notifier).setRate(5000);
      var publications = 0;
      final subscription = c.listen(
        timelineStructureProvider(0),
        (_, _) => publications++,
      );
      for (var i = 0; i < 1000; i++) {
        c.read(messageActionsProvider).receive(message('burst-$i'));
        expect(publications, i + 1);
      }
      await tester.pump();
      expect(
        find.byWidgetPredicate(
          (w) => w.runtimeType.toString() == '_MessageEntrance',
        ),
        findsNothing,
      );
      c.read(messageActionsProvider).send('manual-send');
      await tester.pump();
      expect(opacity(tester, 'local-0'), lessThan(1));
      await tester.pump(const Duration(milliseconds: 200));
      expect(opacity(tester, 'local-0'), 1);
      subscription.close();
      c.read(mockRuntimeProvider.notifier).toggleRunning();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'unconfigured bursts have a bounded animation budget and dragging completes active animations',
    (tester) async {
      final c = await mount(tester);
      for (var i = 0; i < 12; i++) {
        c.read(messageActionsProvider).receive(message('limited-$i'));
      }
      await tester.pump();
      expect(
        find
            .byWidgetPredicate(
              (w) => w.runtimeType.toString() == '_MessageEntrance',
            )
            .evaluate()
            .length,
        lessThanOrEqualTo(4),
      );
      await tester.pump(const Duration(milliseconds: 200));
      c.read(messageActionsProvider).receive(message('before-drag'));
      await tester.pump();
      expect(opacity(tester, 'before-drag'), lessThan(1));
      await tester.drag(
        find.byKey(const Key('message-list')),
        const Offset(0, 80),
      );
      await tester.pump();
      expect(opacity(tester, 'before-drag'), 1);
      expect(tester.takeException(), isNull);
    },
  );
}
