import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_im/core/history.dart';
import 'package:local_im/core/models.dart';
import 'package:local_im/mock_main.dart';
import 'package:local_im/mock/mock_history_repository.dart';
import 'package:local_im/state/im_providers.dart';
import 'package:material_ui/material_ui.dart';

import 'support.dart';

void receive(ProviderContainer c, int i) => c
    .read(messageActionsProvider)
    .receive(
      ChatMessage(
        id: 'continuous-$i',
        conversationId: 0,
        text: i.isEven ? '新消息 $i' : '不同高度的新消息 $i\n第二行\n第三行\n第四行',
        timestamp: DateTime.now(),
      ),
    );

void main() {
  Future<ProviderContainer> mount(
    WidgetTester tester, {
    bool mobile = false,
  }) async {
    tester.view.physicalSize = mobile
        ? const Size(440, 956)
        : const Size(1380, 900);
    tester.view.devicePixelRatio = 1;
    final c = createContainer();
    addTearDown(() {
      c.dispose();
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    await tester.pumpWidget(
      UncontrolledProviderScope(container: c, child: const LocalImApp()),
    );
    await tester.pump(const Duration(milliseconds: 400));
    if (mobile) {
      await tester.tap(find.text('产品设计小组'));
      await tester.pumpAndSettle();
    }
    await tester.pump();
    return c;
  }

  ScrollController controller(WidgetTester tester) => tester
      .widget<CustomScrollView>(find.byKey(const Key('message-list')))
      .controller!;
  Finder bubble(String id) => find.byWidgetPredicate(
    (w) =>
        w.runtimeType.toString() == '_MessageBubble' && w.key == ValueKey(id),
  );

  for (final mobile in [false, true]) {
    testWidgets(
      '${mobile ? "phone" : "desktop"} appends every arrival immediately while keeping visible old bubbles fixed',
      (tester) async {
        final c = await mount(tester, mobile: mobile);
        final scroll = controller(tester);
        scroll.jumpTo(300);
        await tester.pump();
        expect(c.read(chatSessionProvider(0)).frozen, isTrue);
        (c.read(historyRepositoryProvider) as MockHistoryRepository).network =
            HistoryNetwork.offline;
        final visible = find
            .byWidgetPredicate(
              (w) => w.runtimeType.toString() == '_MessageBubble',
            )
            .hitTestable()
            .first;
        final oldId = (tester.widget(visible).key! as ValueKey<String>).value;
        final before = tester.getTopLeft(bubble(oldId)).dy;
        final rebuiltOldBubbles = <String>[];
        debugOnRebuildDirtyWidget = (element, _) {
          final w = element.widget;
          if (w.runtimeType.toString() == '_MessageBubble' &&
              (w.key! as ValueKey<String>).value.startsWith('history-')) {
            rebuiltOldBubbles.add((w.key! as ValueKey<String>).value);
          }
        };
        addTearDown(() => debugOnRebuildDirtyWidget = null);
        var notifications = 0;
        final subscription = c.listen(
          timelineStructureProvider(0),
          (_, _) => notifications++,
        );
        for (var i = 0; i < 100; i++) {
          receive(c, i);
          // No timer, page request, or frame is needed to publish each message.
          expect(notifications, i + 1);
          expect(
            c.read(timelineStoreProvider(0)).value.first.id,
            'continuous-$i',
          );
          expect(c.read(timelineStoreProvider(0)).value.length, 101 + i);
          await tester.pump();
          expect(scroll.offset, 300);
          expect(tester.getTopLeft(bubble(oldId)).dy, closeTo(before, 0.5));
        }
        subscription.close();
        debugOnRebuildDirtyWidget = null;
        expect(rebuiltOldBubbles, isEmpty);
        expect(c.read(chatSessionProvider(0)).pending, 100);
        expect(c.read(chatSessionProvider(0)).unloadedNewer, 0);
        expect(c.read(chatSessionProvider(0)).newer.error, isNull);
        scroll.jumpTo(0);
        await tester.pump();
        await tester.drag(
          find.byKey(const Key('message-list')),
          const Offset(0, -220),
        );
        await tester.pumpAndSettle();
        expect(scroll.offset, lessThan(0));
        expect(find.textContaining('新消息'), findsWidgets);
        final offset = scroll.offset;
        final newBefore = tester.getTopLeft(bubble('continuous-0')).dy;
        receive(c, 100);
        await tester.pump();
        expect(scroll.offset, closeTo(offset, 0.5));
        expect(
          tester.getTopLeft(bubble('continuous-0')).dy,
          closeTo(newBefore, 0.5),
        );
        expect(c.read(chatSessionProvider(0)).pending, 101);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'newer cursor pages remain contiguous beyond the live cache and trim only oldest history',
    (tester) async {
      final c = createContainer(
        historyRepository: MockHistoryRepository(latency: Duration.zero),
      );
      addTearDown(c.dispose);
      await tester.pump(const Duration(milliseconds: 1));
      final session = c.read(chatSessionProvider(0).notifier)..freeze(true);
      for (var i = 0; i < 2300; i++) {
        receive(c, i);
      }
      expect(c.read(timelineStoreProvider(0)).value.length, 2000);
      expect(c.read(chatSessionProvider(0)).unloadedNewer, 400);
      var previous = 2260;
      while (c.read(chatSessionProvider(0)).unloadedNewer > 0) {
        if (session.needsNewerRebase) session.anchorAtNewerEdge();
        unawaited(session.loadNewer());
        await tester.pump(const Duration(milliseconds: 1));
        final messages = c.read(timelineStoreProvider(0)).value;
        expect(
          messages.first.historySequence,
          previous + (2660 - previous).clamp(0, 30),
        );
        previous = messages.first.historySequence!;
        expect(messages.length, lessThanOrEqualTo(2000));
        expect(
          messages.map((m) => m.historySequence),
          List.generate(messages.length, (i) => previous - i),
        );
        expect(
          c.read(chatSessionProvider(0)).readingAnchor,
          greaterThanOrEqualTo(messages.last.historySequence!),
        );
      }
      expect(previous, 2660);
      expect(c.read(engineProvider).cachedMessageCount, 500);
      expect(c.read(chatSessionProvider(0)).frozen, isTrue);
      session.anchorAtNewerEdge();
      session.followFromNewerEdge();
      expect(
        c.read(timelineStoreProvider(0)).value.map((m) => m.historySequence),
        List.generate(200, (i) => 2660 - i),
      );
      expect(c.read(chatSessionProvider(0)).frozen, isFalse);
    },
  );

  testWidgets(
    'newer loading retries, deduplicates overlap, and includes arrivals during the request on the following page',
    (tester) async {
      final repo = MockHistoryRepository();
      final c = createContainer(historyRepository: repo);
      addTearDown(c.dispose);
      await tester.pump(const Duration(milliseconds: 400));
      final session = c.read(chatSessionProvider(0).notifier)..freeze(true);
      for (var i = 0; i < 1940; i++) {
        receive(c, i);
      }
      repo.network = HistoryNetwork.offline;
      unawaited(session.loadNewer());
      await tester.pump(const Duration(milliseconds: 400));
      expect(c.read(chatSessionProvider(0)).newer.error, isNotNull);
      expect(
        c.read(timelineStoreProvider(0)).value.first.historySequence,
        2260,
      );
      repo.network = HistoryNetwork.overlapping;
      unawaited(session.loadNewer());
      receive(c, 1940);
      await tester.pump(const Duration(milliseconds: 400));
      expect(
        c.read(timelineStoreProvider(0)).value.first.historySequence,
        2290,
      );
      expect(c.read(chatSessionProvider(0)).unloadedNewer, 11);
      unawaited(session.loadNewer());
      await tester.pump(const Duration(milliseconds: 400));
      final messages = c.read(timelineStoreProvider(0)).value;
      expect(
        messages.map((m) => m.historySequence),
        List.generate(2000, (i) => 2301 - i),
      );
      expect(c.read(chatSessionProvider(0)).unloadedNewer, 0);
    },
  );

  testWidgets(
    'expired forward archive reports the gap without silently replacing the old window',
    (tester) async {
      final c = createContainer(
        historyRepository: MockHistoryRepository(
          latency: Duration.zero,
          maxLivePerConversation: 10,
        ),
      );
      addTearDown(c.dispose);
      await tester.pump(const Duration(milliseconds: 1));
      final session = c.read(chatSessionProvider(0).notifier)..freeze(true);
      for (var i = 0; i < 1940; i++) {
        receive(c, i);
      }
      final original = c.read(timelineStoreProvider(0)).value;
      unawaited(session.loadNewer());
      await tester.pump(const Duration(milliseconds: 1));
      expect(c.read(chatSessionProvider(0)).newer.hasExpiredGap, isTrue);
      expect(
        identical(c.read(timelineStoreProvider(0)).value, original),
        isTrue,
      );
      expect(c.read(chatSessionProvider(0)).pending, 1940);
    },
  );

  testWidgets('jump to latest invalidates a pending newer page', (
    tester,
  ) async {
    final c = createContainer();
    addTearDown(c.dispose);
    await tester.pump(const Duration(milliseconds: 400));
    final session = c.read(chatSessionProvider(0).notifier)..freeze(true);
    for (var i = 0; i < 1940; i++) {
      receive(c, i);
    }
    unawaited(session.loadNewer());
    session.freeze(false);
    final latest = c.read(timelineStoreProvider(0)).value;
    await tester.pump(const Duration(milliseconds: 400));
    expect(identical(c.read(timelineStoreProvider(0)).value, latest), isTrue);
    expect(c.read(chatSessionProvider(0)).newer.loading, isFalse);
    expect(c.read(chatSessionProvider(0)).readingAnchor, isNull);
  });

  testWidgets('switching chats retains the signed offset and reading origin', (
    tester,
  ) async {
    final c = await mount(tester);
    final scroll = controller(tester);
    scroll.jumpTo(300);
    await tester.pump();
    for (var i = 0; i < 100; i++) {
      receive(c, i);
    }
    scroll.jumpTo(0);
    await tester.pump(const Duration(milliseconds: 400));
    scroll.jumpTo(-200);
    await tester.pump();
    final origin = c.read(chatSessionProvider(0)).readingAnchor;
    final before = tester.getTopLeft(bubble('continuous-0')).dy;
    c.read(selectedConversationProvider.notifier).select(1);
    await tester.pump(const Duration(milliseconds: 400));
    c.read(selectedConversationProvider.notifier).select(0);
    await tester.pump();
    expect(controller(tester).offset, closeTo(-200, 0.5));
    expect(c.read(chatSessionProvider(0)).readingAnchor, origin);
    expect(tester.getTopLeft(bubble('continuous-0')).dy, closeTo(before, 0.5));
  });
  testWidgets(
    'reaching the real latest edge resumes following without a visual jump',
    (tester) async {
      final c = await mount(tester);
      final scroll = controller(tester);
      scroll.jumpTo(300);
      await tester.pump();
      receive(c, 0);
      scroll.jumpTo(0);
      await tester.pump(const Duration(milliseconds: 400));
      expect(c.read(chatSessionProvider(0)).pending, 1);
      // Stop just before the newer edge, then cross it by one pixel.
      scroll.jumpTo(scroll.position.minScrollExtent + 1);
      await tester.pump();
      final before = tester.getTopLeft(bubble('continuous-0')).dy;
      scroll.jumpTo(scroll.position.minScrollExtent);
      await tester.pump();
      expect(c.read(chatSessionProvider(0)).frozen, isFalse);
      expect(c.read(chatSessionProvider(0)).readingAnchor, isNull);
      expect(scroll.offset, 0);
      expect(
        tester.getTopLeft(bubble('continuous-0')).dy,
        closeTo(before - 1, 0.5),
      );
      expect(c.read(timelineStoreProvider(0)).value.length, 101);
      receive(c, 1);
      await tester.pump();
      expect(scroll.offset, 0);
      expect(bubble('continuous-1'), findsOneWidget);
    },
  );

  testWidgets(
    'a full reading window rebases at the loaded edge and continues without skipping messages',
    (tester) async {
      final c = await mount(tester);
      final scroll = controller(tester);
      scroll.jumpTo(300);
      await tester.pump();
      final session = c.read(chatSessionProvider(0).notifier);
      for (var i = 0; i < 2300; i++) {
        receive(c, i);
      }
      for (var i = 0; i < 3; i++) {
        unawaited(session.loadNewer());
        await tester.pump(const Duration(milliseconds: 400));
      }
      expect(
        c.read(timelineStoreProvider(0)).value.first.historySequence,
        2350,
      );
      expect(session.needsNewerRebase, isTrue);
      // Resolve lazy variable-height extent estimates near the loaded edge.
      for (var i = 0; i < 3; i++) {
        scroll.jumpTo(scroll.position.minScrollExtent + 1);
        await tester.pump();
      }
      final before = tester.getTopLeft(bubble('continuous-1989')).dy;
      scroll.jumpTo(scroll.position.minScrollExtent);
      await tester.pump();
      expect(c.read(chatSessionProvider(0)).readingAnchor, 2350);
      expect(
        tester.getTopLeft(bubble('continuous-1989')).dy,
        closeTo(before - 1, 0.5),
      );
      final anchored = tester.getTopLeft(bubble('continuous-1989')).dy;
      await tester.pump(const Duration(milliseconds: 400));
      final messages = c.read(timelineStoreProvider(0)).value;
      expect(messages.length, 2000);
      expect(
        messages.map((m) => m.historySequence),
        List.generate(2000, (i) => 2380 - i),
      );
      expect(
        tester.getTopLeft(bubble('continuous-1989')).dy,
        closeTo(anchored, 0.5),
      );
      expect(c.read(chatSessionProvider(0)).unloadedNewer, 280);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'reading before initial history completes establishes a valid forward anchor, including empty chats',
    (tester) async {
      for (final id in [0, 7]) {
        final c = createContainer();
        addTearDown(c.dispose);
        c.read(selectedConversationProvider.notifier).select(id);
        final session = c.read(chatSessionProvider(id).notifier)..freeze(true);
        c
            .read(messageActionsProvider)
            .receive(
              ChatMessage(
                id: 'early-$id',
                conversationId: id,
                text: 'early',
                timestamp: DateTime.now(),
              ),
            );
        await tester.pump(const Duration(milliseconds: 400));
        expect(c.read(chatSessionProvider(id)).pending, 1);
        unawaited(session.loadNewer());
        await tester.pump(const Duration(milliseconds: 400));
        expect(c.read(timelineStoreProvider(id)).value.first.id, 'early-$id');
        expect(
          c.read(chatSessionProvider(id)).readingAnchor,
          id == 0 ? 360 : 0,
        );
        expect(c.read(chatSessionProvider(id)).pending, 1);
      }
    },
  );
  testWidgets(
    'input before the next layout cannot mistake the old edge for the latest',
    (tester) async {
      final c = await mount(tester);
      final scroll = controller(tester);
      scroll.jumpTo(300);
      await tester.pump();
      for (var i = 0; i < 100; i++) {
        receive(c, i);
      }
      scroll.jumpTo(0); // Layout still has the old minScrollExtent.
      expect(c.read(chatSessionProvider(0)).frozen, isTrue);
      expect(c.read(chatSessionProvider(0)).readingAnchor, 360);
      await tester.pump();
      expect(scroll.offset, 0);
      expect(scroll.position.minScrollExtent, lessThan(0));
      expect(bubble('history-0-360'), findsOneWidget);
      expect(c.read(chatSessionProvider(0)).pending, 100);
    },
  );
}
