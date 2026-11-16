import 'package:flutter_test/flutter_test.dart';
import 'package:local_im/core/models.dart';
import 'package:local_im/state/im_providers.dart';

import 'support.dart';

ChatMessage message(String id, String text, {int conversation = 3}) =>
    ChatMessage(
      id: id,
      conversationId: conversation,
      text: text,
      timestamp: DateTime(2026, 11, 13),
    );

void main() {
  testWidgets('keyed providers notify synchronously without unrelated fanout', (
    tester,
  ) async {
    final container = createContainer();
    addTearDown(container.dispose);
    var changed = 0, unrelated = 0, structures = 0;
    container.read(conversationListProvider.notifier).freeze(true);
    container.listen(conversationRowProvider(3), (_, _) => changed++);
    container.listen(conversationRowProvider(1), (_, _) => unrelated++);
    container.listen(timelineStructureProvider(0), (_, _) => structures++);
    for (var i = 0; i < 1000; i++) {
      container.read(messageActionsProvider).receive(message('row-$i', '$i'));
      expect(changed, i + 1);
      expect(container.read(conversationRowProvider(3))!.item.preview, '$i');
      expect(unrelated, 0);
      expect(structures, 0);
    }
    for (var i = 0; i < 1000; i++) {
      container
          .read(messageActionsProvider)
          .receive(message('active-$i', '$i', conversation: 0));
      expect(structures, i + 1);
      expect(
        container
            .read(
              timelineStoreProvider(
                container.read(selectedConversationProvider)!,
              ),
            )
            .value
            .first
            .id,
        'active-$i',
      );
    }
  });

  testWidgets('message updates and removals reach only the matching family', (
    tester,
  ) async {
    final container = createContainer();
    addTearDown(container.dispose);
    final first = message('first', 'original');
    final second = message('second', 'untouched');
    container.read(timelineStructureProvider(0).notifier).replace([
      first,
      second,
    ]);
    var firstChanges = 0, secondChanges = 0, structuralChanges = 0;
    container.listen(
      messageProvider((conversationId: 0, messageId: 'first')),
      (_, _) => firstChanges++,
    );
    container.listen(
      messageProvider((conversationId: 0, messageId: 'second')),
      (_, _) => secondChanges++,
    );
    container.listen(
      timelineStructureProvider(0),
      (_, _) => structuralChanges++,
    );
    for (var i = 0; i < 1000; i++) {
      container.read(timelineStructureProvider(0).notifier).replace([
        message('first', '$i'),
        second,
      ]);
      expect(firstChanges, i + 1);
      expect(
        container
            .read(messageProvider((conversationId: 0, messageId: 'first')))!
            .text,
        '$i',
      );
      expect(secondChanges, 0);
      expect(structuralChanges, 0);
    }
    container.read(timelineStructureProvider(0).notifier).replace([second]);
    expect(
      container.read(messageProvider((conversationId: 0, messageId: 'first'))),
      isNull,
    );
    expect(firstChanges, 1001);
    expect(secondChanges, 0);
    expect(structuralChanges, 1);
  });

  testWidgets('autoDispose releases view subscriptions but retains app data', (
    tester,
  ) async {
    final container = createContainer();
    addTearDown(container.dispose);
    final keys = container.read(listProviderRegistryProvider);
    final timeline = container.read(
      timelineStoreProvider(container.read(selectedConversationProvider)!),
    );
    container
        .read(messageActionsProvider)
        .receive(message('persisted', 'retained', conversation: 0));
    final rowSubscription = container.listen(
      conversationRowProvider(0),
      (_, _) {},
    );
    final messageSubscription = container.listen(
      messageProvider((conversationId: 0, messageId: 'persisted')),
      (_, _) {},
    );
    expect(keys.rowCount, 1);
    expect(keys.messageCount(0), 1);
    rowSubscription.close();
    messageSubscription.close();
    await tester.pump(Duration.zero);
    expect(keys.rowCount, 0);
    expect(keys.messageCount(0), 0);
    expect(container.read(engineProvider).conversation(0).preview, 'retained');
    expect(timeline.message('persisted')!.text, 'retained');
    container
        .read(messageActionsProvider)
        .receive(message('later', 'latest', conversation: 0));
    final resumed = container.listen(conversationRowProvider(0), (_, _) {});
    expect(resumed.read()!.item.preview, 'latest');
    resumed.close();
  });

  testWidgets('provider scopes isolate data and dispose pending replies', (
    tester,
  ) async {
    final first = createContainer();
    final second = createContainer();
    addTearDown(second.dispose);
    first.read(draftProvider(0).notifier).save('private draft');
    first.read(messageActionsProvider).send('local echo');
    final firstEngine = first.read(engineProvider);
    expect(firstEngine.sent, 1);
    expect(second.read(engineProvider).sent, 0);
    expect(second.read(draftStoreProvider).length, 0);
    first.dispose();
    await tester.pump(const Duration(seconds: 2));
    expect(firstEngine.received, 0);
    expect(tester.takeException(), isNull);
  });
}
