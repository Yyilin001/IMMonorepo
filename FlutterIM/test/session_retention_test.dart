import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:local_im/core/models.dart';
import 'package:local_im/state/im_providers.dart';

import 'support.dart';

ChatMessage incoming(int id, int conversation) => ChatMessage(
  id: 'retention-$id',
  conversationId: conversation,
  text: '$id',
  timestamp: DateTime(2026, 11, 13),
);

void main() {
  testWidgets(
    'cached histories retain cursor, old records, offset and pending count while appending',
    (tester) async {
      final c = createContainer();
      addTearDown(c.dispose);
      await tester.pump(const Duration(milliseconds: 400));
      final a = c.read(chatSessionProvider(0).notifier);
      a.freeze(true);
      a.saveScrollOffset(125);
      unawaited(a.loadOlder());
      await tester.pump(const Duration(milliseconds: 400));
      final window = c.read(timelineStoreProvider(0)).value;
      final cursor = c.read(chatSessionProvider(0)).history.before;
      c.read(selectedConversationProvider.notifier).select(1);
      await tester.pump(const Duration(milliseconds: 400));
      var bUpdates = 0;
      c.listen(chatSessionProvider(1), (_, _) => bUpdates++);
      for (var i = 0; i < 1000; i++) {
        c.read(messageActionsProvider).receive(incoming(i, 0));
      }
      expect(bUpdates, 0);
      expect(
        c.read(timelineStoreProvider(0)).value.skip(1000).map((m) => m.id),
        window.map((m) => m.id),
      );
      c.read(selectedConversationProvider.notifier).select(0);
      final restored = c.read(chatSessionProvider(0));
      expect(restored.history.before, cursor);
      expect(restored.history.loaded, 1200);
      expect(restored.scrollOffset, 125);
      expect(restored.frozen, isTrue);
      expect(restored.pending, 1000);
      expect(c.read(chatSessionProvider(1)).history.loaded, 8);
      a.freeze(false);
      expect(c.read(chatSessionProvider(0)).scrollOffset, 0);
      expect(c.read(chatSessionProvider(0)).pending, 0);
      expect(c.read(timelineStoreProvider(0)).value.first.id, 'retention-999');
    },
  );

  testWidgets(
    'opening many sessions evicts least recently opened windows and keeps drafts',
    (tester) async {
      final c = createContainer(maxRetainedSessions: 3);
      addTearDown(c.dispose);
      final cache = c.read(chatSessionsProvider);
      c.read(draftProvider(0).notifier).save('keep this draft');
      for (var id = 1; id <= 50; id++) {
        c.read(selectedConversationProvider.notifier).select(id);
        expect(cache.length, lessThanOrEqualTo(3));
        await tester.pump(Duration.zero);
      }
      await tester.pump(const Duration(milliseconds: 400));
      expect(cache.retainedIds, [48, 49, 50]);
      expect(c.read(chatSessionProvider(0).exists), isFalse);
      expect(c.read(timelineStoreProvider(0).exists), isFalse);
      expect(c.read(draftProvider(0)), 'keep this draft');
      c.read(selectedConversationProvider.notifier).select(48);
      c.read(selectedConversationProvider.notifier).select(51);
      await tester.pump(Duration.zero);
      expect(cache.retainedIds, [50, 48, 51]);
      expect(c.read(chatSessionProvider(49).exists), isFalse);
      expect(c.read(timelineStoreProvider(49).exists), isFalse);
    },
  );

  testWidgets(
    'traffic to unopened conversations never creates chat providers',
    (tester) async {
      final c = createContainer();
      addTearDown(c.dispose);
      final cache = c.read(chatSessionsProvider);
      for (var id = 1; id < 10000; id++) {
        c.read(messageActionsProvider).receive(incoming(id, id));
      }
      expect(cache.retainedIds, [0]);
      expect(c.read(chatSessionProvider(9999).exists), isFalse);
      expect(c.read(timelineStoreProvider(9999).exists), isFalse);
      c.read(selectedConversationProvider.notifier).select(9999);
      expect(
        c.read(timelineStoreProvider(9999)).value.single.id,
        'retention-9999',
      );
      c.read(messageActionsProvider).receive(incoming(10000, 9999));
      expect(c.read(timelineStoreProvider(9999)).value.map((m) => m.id), [
        'retention-10000',
        'retention-9999',
      ]);
    },
  );

  testWidgets(
    'draft families notify independently and persist after autoDispose',
    (tester) async {
      final c = createContainer();
      addTearDown(c.dispose);
      var firstChanges = 0, secondChanges = 0;
      final first = c.listen(draftProvider(0), (_, _) => firstChanges++);
      final second = c.listen(draftProvider(1), (_, _) => secondChanges++);
      c.read(draftProvider(0).notifier).save('first');
      expect(firstChanges, 1);
      expect(secondChanges, 0);
      first.close();
      second.close();
      await tester.pump(Duration.zero);
      expect(c.read(draftProvider(0).exists), isFalse);
      expect(c.read(draftProvider(0)), 'first');
      c.read(draftProvider(0).notifier).save('');
      expect(c.read(draftStoreProvider).length, 0);
    },
  );
}
