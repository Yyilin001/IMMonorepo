import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:local_im/core/chat_engine.dart';
import 'package:local_im/core/models.dart';

ChatMessage message(int n, int conversation, {bool mine = false}) =>
    ChatMessage(
      id: 'test-$n',
      conversationId: conversation,
      text: 'Message $n',
      timestamp: DateTime(2026, 11, 13).add(Duration(milliseconds: n)),
      isMine: mine,
    );

void main() {
  test('10,000 conversations and 100,000 incoming messages stay bounded', () {
    final engine = ChatEngine();
    engine.markAllRead();
    engine.select(0);
    for (var batch = 0; batch < 1000; batch++) {
      engine.ingest(
        List.generate(100, (i) {
          final n = batch * 100 + i;
          return message(n, n % 10000);
        }),
      );
      if (batch % 5 == 0) expect(engine.snapshot().length, 10000);
    }
    expect(engine.received, 100000);
    expect(engine.totalUnread, 99990);
    expect(engine.conversation(0).unread, 0);
    expect(engine.cachedMessageCount, 40000);
    expect(engine.evicted, 60000);
    expect(engine.messages(9999).map((m) => m.id), [
      'test-99999',
      'test-89999',
      'test-79999',
      'test-69999',
    ]);
  });

  test('hot conversation eviction removes entries from both indexes', () {
    final engine = ChatEngine(
      conversationCount: 10,
      maxCachedMessages: 100,
      maxMessagesPerConversation: 20,
    );
    engine.ingest(List.generate(2000, (i) => message(i, 0)));
    expect(engine.cachedMessageCount, 20);
    expect(engine.messages(0).length, 20);
    expect(engine.messages(0).first.id, 'test-1999');
    engine.ingest(List.generate(1000, (i) => message(i + 2000, i % 10)));
    expect(engine.cachedMessageCount, 100);
    expect(engine.evicted, 2900);
    expect(
      List.generate(
        10,
        (id) => engine.messages(id).length,
      ).reduce((a, b) => a + b),
      100,
    );
  });

  test(
    'snapshots are immutable, pinned first, and frozen order stays stable',
    () {
      final engine = ChatEngine(conversationCount: 20);
      final before = engine.snapshot();
      engine.ingest([message(1, 19)]);
      final frozen = engine.snapshot(freezeOrder: true);
      expect(frozen.map((c) => c.id), before.map((c) => c.id));
      expect(frozen.last.preview, 'Message 1');
      expect(before.last.preview, isNot('Message 1'));
      expect(engine.snapshot().take(4).map((c) => c.id), [0, 1, 2, 19]);
      engine.togglePinned(19);
      expect(engine.snapshot().first.id, 19);
      expect(() => before.clear(), throwsUnsupportedError);
    },
  );

  test(
    'selection, outgoing messages and mark all read maintain unread totals',
    () {
      final engine = ChatEngine(conversationCount: 10);
      engine.markAllRead();
      engine.ingest([message(1, 3), message(2, 3), message(3, 4)]);
      expect(engine.totalUnread, 3);
      engine.select(3);
      expect(engine.totalUnread, 1);
      engine.ingest([message(4, 3), message(5, 4, mine: true)]);
      expect(engine.conversation(3).unread, 0);
      expect(engine.totalUnread, 1);
      expect(engine.sent, 1);
      engine.select(null);
      engine.ingest([message(6, 3)]);
      expect(engine.totalUnread, 2);
      engine.markAllRead();
      expect(engine.totalUnread, 0);
      expect(engine.snapshot().every((c) => c.unread == 0), isTrue);
    },
  );

  test(
    'indexed ordering matches full ordering across pinned and frozen updates',
    () {
      final random = Random(19);
      final engine = ChatEngine(conversationCount: 1000);
      for (var round = 0; round < 80; round++) {
        engine.ingest(
          List.generate(
            50,
            (i) => message(round * 50 + i, random.nextInt(1000)),
          ),
        );
        engine.togglePinned(random.nextInt(1000));
        if (round % 3 == 0) engine.snapshot(freezeOrder: true);
        final sorted = engine.snapshot().toList()
          ..sort((a, b) {
            if (a.pinned != b.pinned) return a.pinned ? -1 : 1;
            final recent = b.sequence.compareTo(a.sequence);
            return recent == 0 ? a.id.compareTo(b.id) : recent;
          });
        expect(engine.snapshot().map((c) => c.id), sorted.map((c) => c.id));
      }
    },
  );

  test('indexed positions are correct before requesting any snapshot', () {
    final random = Random(71);
    final engine = ChatEngine(conversationCount: 1000);
    for (var round = 0; round < 100; round++) {
      final id = random.nextInt(1000);
      engine.receive(message(round, id));
      if (round % 7 == 0) engine.togglePinned(id);
      final reference = List.generate(1000, engine.conversation)
        ..sort((a, b) {
          if (a.pinned != b.pinned) return a.pinned ? -1 : 1;
          final recent = b.sequence.compareTo(a.sequence);
          return recent == 0 ? a.id.compareTo(b.id) : recent;
        });
      for (final position in [0, 1, 2, 3, 50, 500, 999]) {
        expect(engine.conversationAt(position).id, reference[position].id);
      }
    }
    expect(() => engine.conversationAt(-1), throwsRangeError);
    expect(() => engine.conversationAt(1000), throwsRangeError);
  });

  test('global eviction of the active conversation invalidates timeline', () {
    final engine = ChatEngine(conversationCount: 10, maxCachedMessages: 30);
    engine.select(0);
    engine.receive(message(-1, 0));
    final revision = engine.timelineRevision;
    engine.ingest(List.generate(40, (i) => message(i, 1)));
    expect(engine.messages(0), isEmpty);
    expect(engine.timelineRevision, greaterThan(revision));
    expect(engine.cachedMessageCount, 30);
  });
}
