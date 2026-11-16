import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:local_im/state/im_providers.dart';

import 'support.dart';

import 'package:local_im/core/history.dart';
import 'package:local_im/core/models.dart';
import 'package:local_im/mock/mock_history_repository.dart';

ChatMessage incoming(int i, {int conversation = 0}) => ChatMessage(
  id: 'incoming-$i',
  conversationId: conversation,
  text: 'live $i',
  timestamp: DateTime.now(),
);

void main() {
  testWidgets(
    'deleting the last message keeps an empty chat empty after reopening',
    (tester) async {
      final c = createContainer(maxRetainedSessions: 1);
      addTearDown(c.dispose);
      final selection = c.read(selectedConversationProvider.notifier);
      selection.select(7);
      await tester.pump(const Duration(milliseconds: 101));
      final session = c.read(chatSessionProvider(7).notifier)..freeze(true);
      final actions = c.read(messageActionsProvider);
      actions.receive(incoming(1, conversation: 7));
      final message = c.read(timelineStoreProvider(7)).value.single;
      expect(c.read(chatSessionProvider(7)).pending, 1);
      actions.deleteMessage(message);
      expect(c.read(timelineStoreProvider(7)).value, isEmpty);
      expect(c.read(chatSessionProvider(7)).pending, 0);
      expect(c.read(engineProvider).conversation(7).preview, '暂无消息');
      actions.receive(incoming(2, conversation: 7));
      expect(c.read(chatSessionProvider(7)).unloadedNewer, 0);
      session.returnToLatest();
      actions.deleteMessage(c.read(timelineStoreProvider(7)).value.single);
      selection.select(1);
      await tester.pump();
      selection.select(7);
      await tester.pump(const Duration(milliseconds: 101));
      expect(c.read(timelineStoreProvider(7)).value, isEmpty);
      expect(c.read(chatSessionProvider(7)).history.hasMore, isFalse);
    },
  );

  test(
    'deleted seed image stays out of overlapping and in-flight pages',
    () async {
      final history = MockHistoryRepository(latency: Duration.zero)
        ..network = HistoryNetwork.overlapping;
      addTearDown(history.dispose);
      final initial = await history.load(1);
      final image = initial.messages.firstWhere((m) => m.historySequence == 7);
      expect(image.type, MessageType.image);
      final older = history.load(1, before: 8);
      final newer = history.loadNewer(1, after: 6);
      expect(history.delete(image), isTrue);
      expect(history.delete(image), isFalse);
      for (final page in [
        await older,
        await newer,
        await history.load(1),
        await history.loadNewer(1, after: 6),
      ]) {
        expect(page.messages.map((m) => m.id), isNot(contains(image.id)));
        expect(page.hasExpiredGap, isFalse);
      }
      expect(history.visibleCount(1, 6, 8), 1);
    },
  );

  test(
    'group sender IDs survive archiving and paging in both directions',
    () async {
      final repo = MockHistoryRepository(latency: Duration.zero);
      addTearDown(repo.dispose);
      final saved = repo.record(
        ChatMessage.image(
          id: 'group-image',
          conversationId: 0,
          senderId: 3,
          timestamp: DateTime(2026),
        ),
      );
      final older = await repo.load(0, limit: 40);
      final newer = await repo.loadNewer(
        0,
        after: older.before! - 1,
        limit: 40,
      );
      expect(older.messages.first.senderId, 3);
      expect(newer.messages.last.senderId, saved.senderId);
      expect(
        newer.messages.map((m) => (m.id, m.senderId)),
        older.messages.reversed.map((m) => (m.id, m.senderId)),
      );
      for (final type in MessageType.values) {
        final members = older.messages
            .where((m) => !m.isMine && m.type == type)
            .map((m) => m.senderId)
            .toSet();
        expect(members.length, greaterThan(1));
        expect(members, isNot(contains(null)));
      }
    },
  );

  testWidgets('opening a chat with a small live cache fills the initial page', (
    tester,
  ) async {
    final c = createContainer();
    addTearDown(c.dispose);
    for (var i = 0; i < 5; i++) {
      c.read(messageActionsProvider).receive(incoming(i, conversation: 3));
    }
    c.read(selectedConversationProvider.notifier).select(3);
    expect(c.read(timelineStoreProvider(3)).value.length, 5);
    expect(c.read(chatSessionProvider(3)).history.loading, isTrue);
    await tester.pump(const Duration(milliseconds: 400));
    final messages = c.read(timelineStoreProvider(3)).value;
    expect(messages.length, 100);
    expect(
      messages.map((m) => m.historySequence),
      List.generate(100, (i) => 455 - i),
    );
    expect(messages.map((m) => m.id).toSet().length, 100);
    expect(c.read(engineProvider).received, 5);
    unawaited(c.read(chatSessionProvider(3).notifier).loadOlder());
    await tester.pump(const Duration(milliseconds: 400));
    expect(c.read(timelineStoreProvider(3)).value.length, 200);
  });

  testWidgets(
    'initial and older pages leave previews, ordering and unread unchanged',
    (tester) async {
      final c = createContainer(autoStart: false);
      addTearDown(c.dispose);
      final before = c.read(engineProvider).snapshot();
      final unread = c.read(engineProvider).totalUnread;
      expect(
        c
            .read(chatSessionProvider(c.read(selectedConversationProvider)!))
            .history
            .loading,
        isTrue,
      );
      expect(
        c
            .read(timelineStoreProvider(c.read(selectedConversationProvider)!))
            .value,
        isEmpty,
      );
      await tester.pump(const Duration(milliseconds: 400));
      expect(
        c
            .read(timelineStoreProvider(c.read(selectedConversationProvider)!))
            .value
            .length,
        100,
      );
      expect(
        c
            .read(chatSessionProvider(c.read(selectedConversationProvider)!))
            .history
            .before,
        261,
      );
      c
          .read(
            chatSessionProvider(c.read(selectedConversationProvider)!).notifier,
          )
          .freeze(true);
      final pending = c
          .read(
            chatSessionProvider(c.read(selectedConversationProvider)!).notifier,
          )
          .loadOlder();
      await tester.pump(const Duration(milliseconds: 400));
      await pending;
      expect(
        c
            .read(timelineStoreProvider(c.read(selectedConversationProvider)!))
            .value
            .length,
        200,
      );
      expect(
        c
            .read(chatSessionProvider(c.read(selectedConversationProvider)!))
            .history
            .before,
        161,
      );
      expect(c.read(engineProvider).totalUnread, unread);
      expect(c.read(engineProvider).received, 0);
      expect(c.read(engineProvider).cachedMessageCount, 0);
      expect(
        c.read(engineProvider).snapshot().map((m) => m.id),
        before.map((m) => m.id),
      );
      expect(
        c.read(engineProvider).conversation(0).preview,
        before.first.preview,
      );
    },
  );

  testWidgets(
    'A-B-A reuses requests and background pages only update their own session',
    (tester) async {
      final repository = _ControlledHistory();
      final c = createContainer(historyRepository: repository);
      addTearDown(c.dispose);
      unawaited(c.read(chatSessionProvider(0).notifier).loadOlder());
      unawaited(c.read(chatSessionProvider(0).notifier).loadOlder());
      expect(repository.requests.length, 1);
      c.read(selectedConversationProvider.notifier).select(1);
      c.read(selectedConversationProvider.notifier).select(0);
      expect(repository.requests.length, 2);
      repository.finish(1, 'page-b');
      await tester.pump();
      expect(c.read(timelineStoreProvider(0)).value, isEmpty);
      expect(c.read(timelineStoreProvider(1)).value.single.id, 'page-b');
      repository.finish(0, 'page-a');
      await tester.pump();
      expect(c.read(timelineStoreProvider(0)).value.single.id, 'page-a');
      c.read(selectedConversationProvider.notifier).select(1);
      expect(c.read(timelineStoreProvider(1)).value.single.id, 'page-b');
      expect(repository.requests.length, 2);
    },
  );

  testWidgets(
    'evicted request cannot overwrite a reopened session before disposal',
    (tester) async {
      final repository = _ControlledHistory();
      final c = createContainer(
        historyRepository: repository,
        maxRetainedSessions: 1,
      );
      addTearDown(c.dispose);
      c.read(selectedConversationProvider.notifier).select(1);
      c.read(selectedConversationProvider.notifier).select(0);
      expect(repository.requests.length, 3);
      repository.finish(0, 'expired-a');
      repository.finish(1, 'expired-b');
      repository.finish(2, 'current-a');
      await tester.pump(Duration.zero);
      expect(c.read(timelineStoreProvider(0)).value.single.id, 'current-a');
      expect(c.read(chatSessionsProvider).retainedIds, [0]);
    },
  );

  testWidgets(
    'failed request preserves cursor and retries without duplicate messages',
    (tester) async {
      final c = createContainer(autoStart: false);
      addTearDown(c.dispose);
      await tester.pump(const Duration(milliseconds: 400));
      final ids = c
          .read(timelineStoreProvider(c.read(selectedConversationProvider)!))
          .value
          .map((m) => m.id)
          .toList();
      c
          .read(
            chatSessionProvider(c.read(selectedConversationProvider)!).notifier,
          )
          .freeze(true);
      c.read(historyScenarioProvider.notifier).failNextRequest();
      unawaited(
        c
            .read(
              chatSessionProvider(c.read(selectedConversationProvider)!)
                  .notifier,
            )
            .loadOlder(),
      );
      await tester.pump(const Duration(milliseconds: 400));
      expect(
        c
            .read(chatSessionProvider(c.read(selectedConversationProvider)!))
            .history
            .error,
        contains('模拟请求失败'),
      );
      expect(
        c
            .read(chatSessionProvider(c.read(selectedConversationProvider)!))
            .history
            .before,
        261,
      );
      expect(
        c
            .read(timelineStoreProvider(c.read(selectedConversationProvider)!))
            .value
            .map((m) => m.id),
        ids,
      );
      unawaited(
        c
            .read(
              chatSessionProvider(c.read(selectedConversationProvider)!)
                  .notifier,
            )
            .loadOlder(),
      );
      await tester.pump(const Duration(milliseconds: 400));
      expect(
        c
            .read(chatSessionProvider(c.read(selectedConversationProvider)!))
            .history
            .error,
        isNull,
      );
      expect(
        c
            .read(timelineStoreProvider(c.read(selectedConversationProvider)!))
            .value
            .length,
        200,
      );
      expect(
        c
            .read(timelineStoreProvider(c.read(selectedConversationProvider)!))
            .value
            .map((m) => m.id)
            .toSet()
            .length,
        200,
      );
    },
  );

  testWidgets(
    'offline recovery and overlapping unordered pages remain contiguous',
    (tester) async {
      final c = createContainer(autoStart: false);
      addTearDown(c.dispose);
      await tester.pump(const Duration(milliseconds: 400));
      c
          .read(
            chatSessionProvider(c.read(selectedConversationProvider)!).notifier,
          )
          .freeze(true);
      c
          .read(historyScenarioProvider.notifier)
          .setNetwork(HistoryNetwork.offline);
      unawaited(
        c
            .read(
              chatSessionProvider(c.read(selectedConversationProvider)!)
                  .notifier,
            )
            .loadOlder(),
      );
      await tester.pump(const Duration(milliseconds: 400));
      expect(
        c
            .read(chatSessionProvider(c.read(selectedConversationProvider)!))
            .history
            .error,
        contains('离线'),
      );
      c
          .read(historyScenarioProvider.notifier)
          .setNetwork(HistoryNetwork.overlapping);
      unawaited(
        c
            .read(
              chatSessionProvider(c.read(selectedConversationProvider)!)
                  .notifier,
            )
            .loadOlder(),
      );
      await tester.pump(const Duration(milliseconds: 400));
      expect(
        c
            .read(timelineStoreProvider(c.read(selectedConversationProvider)!))
            .value
            .map((m) => m.historySequence),
        List.generate(200, (i) => 360 - i),
      );
      expect(
        c
            .read(chatSessionProvider(c.read(selectedConversationProvider)!))
            .history
            .before,
        161,
      );
    },
  );

  testWidgets(
    'history loading preserves old records while live arrivals append immediately',
    (tester) async {
      final c = createContainer(autoStart: false);
      addTearDown(c.dispose);
      await tester.pump(const Duration(milliseconds: 400));
      c
          .read(
            chatSessionProvider(c.read(selectedConversationProvider)!).notifier,
          )
          .freeze(true);
      final original = c
          .read(timelineStoreProvider(c.read(selectedConversationProvider)!))
          .value;
      unawaited(
        c
            .read(
              chatSessionProvider(c.read(selectedConversationProvider)!)
                  .notifier,
            )
            .loadOlder(),
      );
      for (var i = 0; i < 1000; i++) {
        c.read(messageActionsProvider).receive(incoming(i));
      }
      expect(
        c.read(timelineStoreProvider(0)).value.skip(1000).map((m) => m.id),
        original.map((m) => m.id),
      );
      expect(c.read(timelineStoreProvider(0)).value.first.id, 'incoming-999');
      expect(
        c
            .read(chatSessionProvider(c.read(selectedConversationProvider)!))
            .pending,
        1000,
      );
      expect(c.read(engineProvider).received, 1000);
      expect(c.read(engineProvider).conversation(0).preview, 'live 999');
      await tester.pump(const Duration(milliseconds: 400));
      expect(
        c
            .read(timelineStoreProvider(c.read(selectedConversationProvider)!))
            .value
            .skip(1000)
            .take(original.length)
            .map((m) => m.id),
        original.map((m) => m.id),
      );
      expect(
        c
            .read(timelineStoreProvider(c.read(selectedConversationProvider)!))
            .value
            .length,
        1200,
      );
      c
          .read(
            chatSessionProvider(c.read(selectedConversationProvider)!).notifier,
          )
          .freeze(false);
      expect(
        c
            .read(chatSessionProvider(c.read(selectedConversationProvider)!))
            .pending,
        0,
      );
      expect(
        c
            .read(timelineStoreProvider(c.read(selectedConversationProvider)!))
            .value
            .first
            .id,
        'incoming-999',
      );
      expect(
        c
            .read(timelineStoreProvider(c.read(selectedConversationProvider)!))
            .value
            .length,
        1200,
      );
      c
          .read(
            chatSessionProvider(c.read(selectedConversationProvider)!).notifier,
          )
          .freeze(true);
      unawaited(
        c
            .read(
              chatSessionProvider(c.read(selectedConversationProvider)!)
                  .notifier,
            )
            .loadOlder(),
      );
      await tester.pump(const Duration(milliseconds: 400));
      expect(
        c
            .read(timelineStoreProvider(c.read(selectedConversationProvider)!))
            .value
            .map((m) => m.historySequence),
        List.generate(1300, (i) => 1360 - i),
      );
    },
  );

  testWidgets(
    'a slow initial page cannot create a hole after live window truncation',
    (tester) async {
      final c = createContainer(autoStart: false);
      addTearDown(c.dispose);
      for (var i = 0; i < 500; i++) {
        c.read(messageActionsProvider).receive(incoming(i));
      }
      await tester.pump(const Duration(milliseconds: 400));
      expect(
        c
            .read(timelineStoreProvider(c.read(selectedConversationProvider)!))
            .value
            .length,
        200,
      );
      expect(
        c
            .read(chatSessionProvider(c.read(selectedConversationProvider)!))
            .history
            .before,
        661,
      );
      c
          .read(
            chatSessionProvider(c.read(selectedConversationProvider)!).notifier,
          )
          .freeze(true);
      unawaited(
        c
            .read(
              chatSessionProvider(c.read(selectedConversationProvider)!)
                  .notifier,
            )
            .loadOlder(),
      );
      await tester.pump(const Duration(milliseconds: 400));
      expect(
        c
            .read(timelineStoreProvider(c.read(selectedConversationProvider)!))
            .value
            .map((m) => m.historySequence),
        List.generate(300, (i) => 860 - i),
      );
    },
  );

  testWidgets('empty and short histories stop requesting at the end', (
    tester,
  ) async {
    final c = createContainer(autoStart: false);
    addTearDown(c.dispose);
    c.read(selectedConversationProvider.notifier).select(7);
    await tester.pump(const Duration(milliseconds: 400));
    expect(
      c
          .read(timelineStoreProvider(c.read(selectedConversationProvider)!))
          .value,
      isEmpty,
    );
    expect(
      c
          .read(chatSessionProvider(c.read(selectedConversationProvider)!))
          .history
          .hasMore,
      isFalse,
    );
    c.read(selectedConversationProvider.notifier).select(1);
    await tester.pump(const Duration(milliseconds: 400));
    expect(
      c
          .read(timelineStoreProvider(c.read(selectedConversationProvider)!))
          .value
          .length,
      8,
    );
    expect(
      c
          .read(chatSessionProvider(c.read(selectedConversationProvider)!))
          .history
          .hasMore,
      isFalse,
    );
    await c
        .read(
          chatSessionProvider(c.read(selectedConversationProvider)!).notifier,
        )
        .loadOlder();
    expect(
      c
          .read(chatSessionProvider(c.read(selectedConversationProvider)!))
          .history
          .loading,
      isFalse,
    );
  });

  testWidgets(
    'long histories stay within the reading window and can return to latest',
    (tester) async {
      final c = createContainer(
        autoStart: false,
        historyRepository: MockHistoryRepository(latency: Duration.zero),
      );
      addTearDown(c.dispose);
      c.read(selectedConversationProvider.notifier).select(2);
      await tester.pump();
      c
          .read(
            chatSessionProvider(c.read(selectedConversationProvider)!).notifier,
          )
          .freeze(true);
      for (var i = 0; i < 75; i++) {
        unawaited(
          c
              .read(
                chatSessionProvider(c.read(selectedConversationProvider)!)
                    .notifier,
              )
              .loadOlder(),
        );
        await tester.pump(const Duration(milliseconds: 1));
      }
      expect(
        c
            .read(timelineStoreProvider(c.read(selectedConversationProvider)!))
            .value
            .length,
        2000,
      );
      expect(
        c
            .read(chatSessionProvider(c.read(selectedConversationProvider)!))
            .history
            .atWindowLimit,
        isTrue,
      );
      expect(
        c
            .read(chatSessionProvider(c.read(selectedConversationProvider)!))
            .history
            .before,
        10001,
      );
      c
          .read(
            chatSessionProvider(c.read(selectedConversationProvider)!).notifier,
          )
          .freeze(false);
      expect(
        c
            .read(timelineStoreProvider(c.read(selectedConversationProvider)!))
            .value
            .length,
        2000,
      );
      expect(
        c
            .read(chatSessionProvider(c.read(selectedConversationProvider)!))
            .history
            .atWindowLimit,
        isTrue,
      );
      expect(
        c
            .read(chatSessionProvider(c.read(selectedConversationProvider)!))
            .history
            .before,
        10001,
      );
    },
  );

  testWidgets(
    'expired live archive reports the gap and terminates pagination',
    (tester) async {
      final repository = MockHistoryRepository(
        latency: Duration.zero,
        maxLiveMessages: 10,
        maxLivePerConversation: 10,
      );
      addTearDown(repository.dispose);
      for (var i = 0; i < 30; i++) {
        repository.record(incoming(i, conversation: 7));
      }
      final future = repository.load(7, limit: 20);
      await tester.pump(const Duration(milliseconds: 1));
      final page = await future;
      expect(repository.retainedLiveCount, 10);
      expect(page.messages.length, 10);
      expect(page.hasExpiredGap, isTrue);
      expect(page.hasMore, isFalse);
    },
  );

  testWidgets(
    'disposing with history in flight does not notify disposed state',
    (tester) async {
      final c = createContainer(autoStart: false);
      c.dispose();
      await tester.pump(const Duration(seconds: 2));
      expect(tester.takeException(), isNull);
    },
  );
}

class _ControlledHistory extends MockHistoryRepository {
  final requests = <(int, Completer<HistoryPage>)>[];
  @override
  Future<HistoryPage> load(int conversationId, {int? before, int limit = 30}) {
    final completer = Completer<HistoryPage>();
    requests.add((conversationId, completer));
    return completer.future;
  }

  @override
  Future<HistoryPage> loadNewer(
    int conversationId, {
    required int after,
    int limit = 30,
  }) => load(conversationId, before: after, limit: limit);

  void finish(int index, String id) {
    final request = requests[index];
    request.$2.complete(
      HistoryPage(
        messages: [
          ChatMessage(
            id: id,
            conversationId: request.$1,
            text: id,
            timestamp: DateTime.now(),
            historySequence: 1,
          ),
        ],
        hasMore: false,
        before: 1,
      ),
    );
  }

  @override
  void dispose() {
    super.dispose();
    for (final request in requests) {
      if (!request.$2.isCompleted) {
        request.$2.completeError(StateError('disposed'));
      }
    }
  }
}
