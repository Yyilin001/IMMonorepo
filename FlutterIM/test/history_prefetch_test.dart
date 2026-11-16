import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_im/core/history.dart';
import 'package:local_im/core/models.dart';
import 'package:local_im/mock_main.dart';
import 'package:local_im/mock/mock_history_repository.dart';
import 'package:local_im/state/im_providers.dart';
import 'package:material_ui/material_ui.dart';

import 'support.dart';

class _RecordingHistory extends MockHistoryRepository {
  _RecordingHistory({super.latency});
  final cursors = <int?>[];
  final limits = <int>[];
  Completer<void>? gate;

  @override
  Future<HistoryPage> load(
    int conversationId, {
    int? before,
    int limit = 30,
  }) async {
    cursors.add(before);
    limits.add(limit);
    if (gate != null) await gate!.future;
    return super.load(conversationId, before: before, limit: limit);
  }
}

void main() {
  for (final mobile in [true, false]) {
    testWidgets(
      '${mobile ? "phone" : "desktop"} prefetches before the top, preserves reading position and does not retry in a loop',
      (tester) async {
        tester.view.physicalSize = mobile
            ? const Size(440, 956)
            : const Size(1380, 900);
        tester.view.devicePixelRatio = 1;
        final repository = _RecordingHistory();
        final c = createContainer(historyRepository: repository);
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
        }
        await tester.pumpAndSettle();
        final scroll = tester
            .widget<CustomScrollView>(find.byKey(const Key('message-list')))
            .controller!;
        expect(repository.cursors.length, 1);
        repository.network = HistoryNetwork.slow;
        // Ordinary movement far from the history edge must not fetch more pages.
        scroll.jumpTo(200);
        await tester.pump();
        scroll.jumpTo(100);
        await tester.pump();
        expect(repository.cursors.length, 1);
        // Move through real layouts so lazy extent estimates are refreshed.
        for (var i = 0; i < 100 && repository.cursors.length == 1; i++) {
          scroll.jumpTo(scroll.offset + 180);
          await tester.pump();
        }
        expect(repository.cursors.length, 2);
        expect(repository.cursors.last, 261);
        expect(repository.limits.last, 100);
        expect(
          scroll.position.extentAfter,
          greaterThan(scroll.position.viewportDimension * 2),
        );
        expect(c.read(chatSessionProvider(0)).history.loading, isTrue);
        for (var i = 0; i < 8; i++) {
          scroll.jumpTo(scroll.offset + 5);
          await tester.pump();
        }
        expect(repository.cursors.length, 2);
        final visible = find
            .byWidgetPredicate(
              (w) => w.runtimeType.toString() == '_MessageBubble',
            )
            .hitTestable()
            .first;
        final key = tester.widget(visible).key;
        final bubble = find.byWidgetPredicate(
          (w) => w.runtimeType.toString() == '_MessageBubble' && w.key == key,
        );
        final y = tester.getTopLeft(bubble).dy;
        final offset = scroll.offset;
        await tester.pump(const Duration(seconds: 2));
        await tester.pump();
        expect(c.read(timelineStoreProvider(0)).value.length, 200);
        expect(scroll.offset, closeTo(offset, 0.5));
        expect(tester.getTopLeft(bubble).dy, closeTo(y, 0.5));
        expect(repository.cursors.length, 2);
        repository.network = HistoryNetwork.offline;
        for (var i = 0; i < 100 && repository.cursors.length == 2; i++) {
          scroll.jumpTo(scroll.offset + 180);
          await tester.pump();
        }
        expect(repository.cursors.length, 3);
        await tester.pump(const Duration(seconds: 2));
        expect(c.read(chatSessionProvider(0)).history.error, isNotNull);
        for (var i = 0; i < 5; i++) {
          scroll.jumpTo(scroll.offset + 5);
          await tester.pump();
        }
        expect(repository.cursors.length, 3);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'a large page arriving during a fast fling keeps the visible message anchored',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      try {
        tester.view.physicalSize = const Size(440, 956);
        tester.view.devicePixelRatio = 1;
        final repository = _RecordingHistory(latency: Duration.zero);
        final c = createContainer(historyRepository: repository);
        addTearDown(() {
          c.dispose();
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
        });
        await tester.pumpWidget(
          UncontrolledProviderScope(container: c, child: const LocalImApp()),
        );
        await tester.pump();
        await tester.tap(find.text('产品设计小组'));
        await tester.pumpAndSettle();
        final list = find.byKey(const Key('message-list'));
        final scroll = tester.widget<CustomScrollView>(list).controller!;
        repository.gate = Completer<void>();
        // Reach the prefetch zone while the response is deliberately held back.
        for (var i = 0; i < 100 && repository.cursors.length == 1; i++) {
          scroll.jumpTo(scroll.offset + 180);
          await tester.pump();
        }
        expect(repository.cursors.length, 2);
        await tester.fling(list, const Offset(0, 500), 4000);
        await tester.pump(const Duration(milliseconds: 16));
        await tester.pump(const Duration(milliseconds: 16));
        expect(scroll.position.isScrollingNotifier.value, isTrue);
        expect(scroll.position.extentAfter, greaterThan(0));
        // Ballistic scrolling ignores pointer hit tests; locate the bubble by its
        // visible bounds while the scroll activity is still running.
        final viewport = tester.getRect(list).deflate(100);
        final visible = find
            .byWidgetPredicate(
              (w) => w.runtimeType.toString() == '_MessageBubble',
            )
            .evaluate()
            .firstWhere(
              (e) => viewport.contains(
                tester.getRect(find.byWidget(e.widget)).center,
              ),
            );
        final key = visible.widget.key;
        final bubble = find.byWidgetPredicate(
          (w) => w.runtimeType.toString() == '_MessageBubble' && w.key == key,
        );
        final offset = scroll.offset;
        final y = tester.getTopLeft(bubble).dy;
        var publications = 0;
        final subscription = c.listen(
          timelineStructureProvider(0),
          (_, _) => publications++,
        );
        // Live arrivals stay synchronous even with a larger page in flight.
        for (var i = 0; i < 20; i++) {
          c
              .read(messageActionsProvider)
              .receive(
                ChatMessage(
                  id: 'prefetch-live-$i',
                  conversationId: 0,
                  text: '实时消息 $i\n第二行',
                  timestamp: DateTime.now(),
                ),
              );
          expect(publications, i + 1);
        }
        repository.gate!.complete();
        await tester.pump();
        await tester.pump(Duration.zero);
        expect(c.read(timelineStoreProvider(0)).value.length, 220);
        expect(
          c.read(timelineStoreProvider(0)).value.map((m) => m.historySequence),
          List.generate(220, (i) => 380 - i),
        );
        expect(scroll.offset, closeTo(offset, 0.5));
        expect(tester.getTopLeft(bubble).dy, closeTo(y, 0.5));
        expect(scroll.position.isScrollingNotifier.value, isTrue);
        await tester.pump(const Duration(milliseconds: 16));
        expect(scroll.offset, greaterThan(offset));
        expect(
          tester.getTopLeft(bubble).dy - y,
          closeTo(scroll.offset - offset, 0.5),
        );
        expect(
          repository.cursors.length,
          2,
          reason:
              '${repository.cursors}; ${scroll.position.extentAfter} remaining',
        );
        subscription.close();
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    },
  );
}
