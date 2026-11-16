import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:local_im/core/history.dart';
import 'package:local_im/core/models.dart';
import 'package:local_im/mock_main.dart';
import 'package:local_im/mock/mock_history_repository.dart';
import 'package:local_im/state/im_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import 'support.dart';

class CountingHistory extends MockHistoryRepository {
  int olderRequests = 0;
  int newerRequests = 0;

  @override
  Future<HistoryPage> load(int conversationId, {int? before, int limit = 30}) {
    olderRequests++;
    return super.load(conversationId, before: before, limit: limit);
  }

  @override
  Future<HistoryPage> loadNewer(
    int conversationId, {
    required int after,
    int limit = 30,
  }) {
    newerRequests++;
    return super.loadNewer(conversationId, after: after, limit: limit);
  }
}

ChatMessage incoming(int i, {int conversation = 0}) => ChatMessage.image(
  id: 'jump-$conversation-$i',
  conversationId: conversation,
  timestamp: DateTime(2026, 11, 14),
  image: mockImages[i % mockImages.length],
);

void main() {
  testWidgets(
    'repeated jumps preserve loaded rows and never request history offline',
    (tester) async {
      final repository = CountingHistory();
      final c = createContainer(historyRepository: repository);
      addTearDown(c.dispose);
      await tester.pump(const Duration(milliseconds: 400));
      final session = c.read(chatSessionProvider(0).notifier)..freeze(true);
      unawaited(session.loadOlder());
      await tester.pump(const Duration(milliseconds: 400));
      c.read(messageActionsProvider).receive(incoming(0));
      final original = c.read(timelineStoreProvider(0)).value;
      final cursor = c.read(chatSessionProvider(0)).history.before;
      final requests = repository.olderRequests;
      repository.network = HistoryNetwork.offline;
      repository.failNext = true;
      var structures = 0;
      final subscription = c.listen(
        timelineStructureProvider(0),
        (_, _) => structures++,
      );
      for (var i = 0; i < 10; i++) {
        session.freeze(true);
        session.returnToLatest();
        expect(
          identical(c.read(timelineStoreProvider(0)).value, original),
          isTrue,
        );
        expect(c.read(chatSessionProvider(0)).history.before, cursor);
        expect(c.read(chatSessionProvider(0)).history.loading, isFalse);
        expect(c.read(chatSessionProvider(0)).pending, 0);
      }
      expect(structures, 0);
      expect(repository.olderRequests, requests);
      expect(repository.newerRequests, 0);
      expect(repository.failNext, isTrue);
      c.read(messageActionsProvider).receive(incoming(1));
      expect(structures, 1);
      expect(
        c.read(timelineStoreProvider(0)).value.skip(1).map((m) => m.id),
        original.take(original.length - 1).map((m) => m.id),
      );
      subscription.close();
    },
  );

  testWidgets(
    'jump cancels a pending older page without losing existing history',
    (tester) async {
      final repository = CountingHistory();
      final c = createContainer(historyRepository: repository);
      addTearDown(c.dispose);
      await tester.pump(const Duration(milliseconds: 400));
      final session = c.read(chatSessionProvider(0).notifier)..freeze(true);
      final original = c.read(timelineStoreProvider(0)).value;
      unawaited(session.loadOlder());
      expect(c.read(chatSessionProvider(0)).history.loading, isTrue);
      session.returnToLatest();
      expect(c.read(chatSessionProvider(0)).history.loading, isFalse);
      await tester.pump(const Duration(milliseconds: 400));
      expect(
        identical(c.read(timelineStoreProvider(0)).value, original),
        isTrue,
      );
      expect(repository.olderRequests, 2);
      session.freeze(true);
      unawaited(session.loadOlder());
      await tester.pump(const Duration(milliseconds: 400));
      expect(c.read(timelineStoreProvider(0)).value.length, 200);
    },
  );

  testWidgets('jump before initial data arrives keeps the original request', (
    tester,
  ) async {
    final repository = CountingHistory();
    final c = createContainer(historyRepository: repository);
    addTearDown(c.dispose);
    final session = c.read(chatSessionProvider(0).notifier)..freeze(true);
    session.returnToLatest();
    expect(repository.olderRequests, 1);
    await tester.pump(const Duration(milliseconds: 400));
    expect(c.read(timelineStoreProvider(0)).value.length, 100);
    expect(c.read(chatSessionProvider(0)).history.loading, isFalse);
  });

  for (final extra in [40, 600]) {
    testWidgets(
      'jump joins available suffix or uses local latest without a request: $extra arrivals beyond capacity',
      (tester) async {
        final repository = CountingHistory();
        final c = createContainer(historyRepository: repository);
        addTearDown(c.dispose);
        await tester.pump(const Duration(milliseconds: 400));
        final session = c.read(chatSessionProvider(0).notifier)..freeze(true);
        for (var i = 0; i < 1900 + extra; i++) {
          c.read(messageActionsProvider).receive(incoming(i));
        }
        expect(c.read(chatSessionProvider(0)).unloadedNewer, extra);
        repository.network = HistoryNetwork.offline;
        repository.failNext = true;
        session.returnToLatest();
        final messages = c.read(timelineStoreProvider(0)).value;
        expect(messages.length, extra == 40 ? 2000 : 500);
        expect(
          messages.map((m) => m.historySequence),
          List.generate(messages.length, (i) => 2260 + extra - i),
        );
        expect(c.read(chatSessionProvider(0)).unloadedNewer, 0);
        expect(c.read(chatSessionProvider(0)).history.loading, isFalse);
        expect(repository.olderRequests, 1);
        expect(repository.newerRequests, 0);
        expect(repository.failNext, isTrue);
      },
    );
  }

  testWidgets(
    'jump can still show the latest received message after global cache eviction',
    (tester) async {
      final repository = CountingHistory();
      final c = createContainer(historyRepository: repository);
      addTearDown(c.dispose);
      await tester.pump(const Duration(milliseconds: 400));
      final session = c.read(chatSessionProvider(0).notifier)..freeze(true);
      for (var i = 0; i < 1940; i++) {
        c.read(messageActionsProvider).receive(incoming(i));
      }
      final engine = c.read(engineProvider);
      // Populate distinct chats to exceed the total cache, not its per-chat cap.
      for (var i = 0; i < 40001; i++) {
        engine.receive(incoming(i, conversation: 1 + i % 100));
      }
      expect(engine.messages(0), isEmpty);
      repository.network = HistoryNetwork.offline;
      session.returnToLatest();
      expect(c.read(timelineStoreProvider(0)).value.single.id, 'jump-0-1939');
      expect(c.read(chatSessionProvider(0)).history.loading, isFalse);
      expect(repository.olderRequests, 1);
    },
  );

  for (final mobile in [true, false]) {
    testWidgets(
      '${mobile ? "phone" : "desktop"} jump shows the latest image without a spinner or replacing loaded history',
      (tester) async {
        tester.view.physicalSize = mobile
            ? const Size(440, 956)
            : const Size(1380, 900);
        tester.view.devicePixelRatio = 1;
        final repository = CountingHistory();
        final c = createContainer(historyRepository: repository);
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
        final scroll = tester
            .widget<CustomScrollView>(find.byKey(const Key('message-list')))
            .controller!;
        scroll.jumpTo(400);
        await tester.pump();
        c.read(messageActionsProvider).receive(incoming(0));
        await tester.pump();
        final original = c.read(timelineStoreProvider(0)).value;
        final requests = repository.olderRequests;
        repository.network = HistoryNetwork.offline;
        await tester.tap(find.byKey(const Key('latest-messages')));
        for (var i = 0; i < 8; i++) {
          await tester.pump(const Duration(milliseconds: 16));
          expect(find.byType(CircularProgressIndicator), findsNothing);
          expect(c.read(chatSessionProvider(0)).history.loading, isFalse);
        }
        expect(
          identical(c.read(timelineStoreProvider(0)).value, original),
          isTrue,
        );
        expect(repository.olderRequests, requests);
        expect(scroll.offset, 0);
        expect(
          find.byKey(const ValueKey('image-jump-0-0')).hitTestable(),
          findsOneWidget,
        );
        expect(c.read(chatSessionProvider(0)).frozen, isFalse);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
