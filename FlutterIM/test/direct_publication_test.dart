import 'package:flutter_test/flutter_test.dart';
import 'package:local_im/core/models.dart';
import 'package:local_im/core/timeline_store.dart';
import 'package:local_im/state/im_providers.dart';

import 'support.dart';

ChatMessage message(String id, {String text = 'text', int conversation = 0}) =>
    ChatMessage(
      id: id,
      conversationId: conversation,
      text: text,
      timestamp: DateTime(2026, 11, 13),
    );

void main() {
  test('timeline diff separates content, order, removals and rejects duplicates atomically', () {
    final store = TimelineStore();
    final a = message('a'), b = message('b');
    final initial = store.replace([a, b]);
    expect(initial.structureChanged, isTrue);
    expect(initial.changedIds, {'a', 'b'});
    final edited = message('a', text: 'edited');
    final content = store.replace([edited, b]);
    expect(content.structureChanged, isFalse);
    expect(content.changedIds, {'a'});
    final reordered = store.replace([b, edited]);
    expect(reordered.structureChanged, isTrue);
    expect(reordered.changedIds, isEmpty);
    expect(store.positionOf('a'), 1);
    final removed = store.replace([b]);
    expect(removed.structureChanged, isTrue);
    expect(removed.changedIds, {'a'});
    expect(store.message('a'), isNull);
    final revision = store.structure;
    final unchanged = store.replace([message('b')]);
    expect(unchanged.structureChanged, isFalse);
    expect(unchanged.changedIds, isEmpty);
    final before = store.value;
    expect(() => store.replace([b, b]), throwsArgumentError);
    expect(identical(store.value, before), isTrue);
    expect(store.structure, revision);
  });

  testWidgets(
    'publication never creates unobserved row, message or count providers',
    (tester) async {
      final c = createContainer();
      addTearDown(c.dispose);
      for (var i = 0; i < 1000; i++) {
        c.read(messageActionsProvider).receive(message('unobserved-$i'));
      }
      expect(c.read(listProviderRegistryProvider).rowCount, 0);
      expect(c.read(listProviderRegistryProvider).messageCount(0), 0);
      expect(c.read(conversationCountProvider.exists), isFalse);
      expect(c.read(conversationRowProvider(0).exists), isFalse);
      expect(
        c.read(
          messageProvider((conversationId: 0, messageId: 'unobserved-999'))
              .exists,
        ),
        isFalse,
      );
      final row = c.listen(conversationRowProvider(0), (_, _) {});
      final item = c.listen(
        messageProvider((conversationId: 0, messageId: 'unobserved-999')),
        (_, _) {},
      );
      expect(row.read()!.item.sequence, greaterThan(0));
      expect(item.read()!.id, 'unobserved-999');
      row.close();
      item.close();
      await tester.pump(Duration.zero);
      c.read(messageActionsProvider).receive(message('after-unmount'));
      expect(c.read(listProviderRegistryProvider).rowCount, 0);
      expect(c.read(listProviderRegistryProvider).messageCount(0), 0);
      expect(c.read(conversationRowProvider(0).exists), isFalse);
      expect(
        c.read(
          messageProvider((conversationId: 0, messageId: 'unobserved-999'))
              .exists,
        ),
        isFalse,
      );
    },
  );

  testWidgets(
    'same message ID in different sessions receives independent direct updates',
    (tester) async {
      final c = createContainer();
      addTearDown(c.dispose);
      c.read(selectedConversationProvider.notifier).select(1);
      final a = c.read(timelineStructureProvider(0).notifier);
      final b = c.read(timelineStructureProvider(1).notifier);
      a.replace([message('shared', text: 'a')]);
      b.replace([message('shared', text: 'b', conversation: 1)]);
      var aChanges = 0, bChanges = 0, structures = 0;
      final aProvider = messageProvider((
        conversationId: 0,
        messageId: 'shared',
      ));
      final bProvider = messageProvider((
        conversationId: 1,
        messageId: 'shared',
      ));
      c.listen(aProvider, (_, _) => aChanges++);
      c.listen(bProvider, (_, _) => bChanges++);
      c.listen(timelineStructureProvider(0), (_, _) => structures++);
      a.replace([message('shared', text: 'changed')]);
      expect(c.read(aProvider)!.text, 'changed');
      expect(c.read(bProvider)!.text, 'b');
      expect((aChanges, bChanges, structures), (1, 0, 0));
      a.replace([]);
      expect(c.read(aProvider), isNull);
      expect((aChanges, bChanges, structures), (2, 0, 1));
      a.replace([message('shared', text: 'reinserted')]);
      expect(c.read(aProvider)!.text, 'reinserted');
      expect((aChanges, bChanges, structures), (3, 0, 2));
    },
  );

  testWidgets(
    'family rebuilds retain notifier registration and count changes publish immediately',
    (tester) async {
      final c = createContainer();
      addTearDown(c.dispose);
      c.read(messageActionsProvider).receive(message('tracked'));
      final rowProvider = conversationRowProvider(0);
      final itemProvider = messageProvider((
        conversationId: 0,
        messageId: 'tracked',
      ));
      var rowChanges = 0, itemChanges = 0;
      final row = c.listen(rowProvider, (_, _) => rowChanges++);
      final item = c.listen(itemProvider, (_, _) => itemChanges++);
      c.invalidate(rowProvider);
      c.invalidate(itemProvider);
      row.read();
      item.read();
      expect(c.read(listProviderRegistryProvider).rowCount, 1);
      expect(c.read(listProviderRegistryProvider).messageCount(0), 1);
      rowChanges = 0;
      itemChanges = 0;
      c
          .read(messageActionsProvider)
          .receive(message('next', text: 'new preview'));
      c.read(timelineStructureProvider(0).notifier).replace([
        message('tracked', text: 'edited'),
      ]);
      expect(rowChanges, 1);
      expect(itemChanges, 1);
      final counts = <int>[];
      c.listen(conversationCountProvider, (_, next) => counts.add(next));
      c.read(conversationListProvider.notifier).filter(query: '09999');
      expect(counts, [1]);
      expect(row.read()!.item.id, 9999);
      c
          .read(conversationListProvider.notifier)
          .filter(query: '', unreadOnly: true);
      c.read(conversationListProvider.notifier).markAllRead();
      expect(counts.last, 0);
      expect(row.read(), isNull);
      row.close();
      item.close();
      await tester.pump(Duration.zero);
      expect(c.read(listProviderRegistryProvider).rowCount, 0);
      expect(c.read(listProviderRegistryProvider).messageCount(0), 0);
    },
  );
}
