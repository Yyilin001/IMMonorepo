import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:local_im/core/chat_engine.dart';
import 'package:local_im/core/conversation_store.dart';
import 'package:local_im/core/models.dart';

void main() {
  test('incremental filtered projection stays correct through unread, pins and frozen order', () {
    final engine = ChatEngine(conversationCount: 1000);
    final feed = ConversationStore(engine);
    final random = Random(7);
    feed.setFilter(query: '1', unreadOnly: true);
    Map<int, int>? frozenRanks;
    for (var step = 0; step < 200; step++) {
      final id = random.nextInt(1000);
      engine.receive(
        ChatMessage(
          id: 'm-$step',
          conversationId: id,
          text: '$step',
          timestamp: DateTime.now(),
        ),
      );
      if (step % 7 == 0) engine.togglePinned(id);
      if (step % 13 == 0) engine.select(id);
      if (step == 60) {
        var index = 0;
        frozenRanks = {
          for (final c in engine.orderedConversations) c.id: index++,
        };
        feed.setOrderFrozen(true);
      }
      if (step == 120) {
        feed.setOrderFrozen(false);
        frozenRanks = null;
      }
      if (step == 160) engine.markAllRead();
      feed.refresh(engine.takeChangedConversationIds());
      final expected = engine.orderedConversations
          .where(
            (c) =>
                c.unread > 0 &&
                (c.id.toString().contains('1') ||
                    c.name.toLowerCase().contains('1')),
          )
          .toList();
      if (frozenRanks != null) {
        expected.sort(
          (a, b) => frozenRanks![a.id]!.compareTo(frozenRanks[b.id]!),
        );
      }
      expect(feed.rowCount, expected.length);
      expect(feed.value.map((c) => c.id), expected.map((c) => c.id));
      if (expected.isNotEmpty) {
        expect(feed.value.first.unread, expected.first.unread);
      }
    }
  });
}
