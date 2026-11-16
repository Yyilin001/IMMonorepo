import 'dart:async';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:local_im/core/models.dart';
import 'package:local_im/mock/mock_transport.dart';
import 'package:local_im/state/im_providers.dart';

import 'support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('uniform selection ignores focus and covers the entire population', () {
    final random = Random(42), other = Random(42);
    final buckets = List.filled(10, 0);
    final seen = <int>{};
    for (var i = 0; i < 100000; i++) {
      final id = TrafficPattern.uniform.nextConversation(random, 10000, 9999);
      expect(id, TrafficPattern.uniform.nextConversation(other, 10000, null));
      buckets[id ~/ 1000]++;
      seen.add(id);
    }
    expect(seen.length, greaterThan(9900));
    for (final count in buckets) {
      expect(count, inInclusiveRange(9000, 11000));
    }
    for (final pattern in TrafficPattern.values) {
      expect(pattern.nextConversation(Random(42), 1, null), 0);
      expect(
        () => pattern.nextConversation(Random(42), 0, null),
        throwsArgumentError,
      );
    }
  });

  for (final pattern in TrafficPattern.values) {
    test('$pattern starts with a message from a contact without a chat', () async {
      final first = Completer<ChatMessage>();
      final transport = MockTransport(onMessage: (message) {
        if (!first.isCompleted) first.complete(message);
      });
      addTearDown(transport.dispose);
      transport.configure(running: true, rate: 100, pattern: pattern);
      await transport.initialize(100);
      final message = await first.future.timeout(const Duration(seconds: 3));
      expect(message.conversationId, greaterThanOrEqualTo(100));
      expect(message.senderId, message.conversationId);
      expect(message.isMine, isFalse);
    });
  }

  test('first contact publishes one chat, real history and unread while order is frozen', () async {
    final c = createContainer(conversationCount: 100);
    addTearDown(c.dispose);
    const id = 104;
    final engine = c.read(engineProvider);
    final directory = c.read(contactDirectoryProvider);
    expect(directory.profile(id).contact.isGroup, isFalse);
    final unread = engine.totalUnread;
    final original = engine.snapshot();
    final list = c.read(conversationListProvider.notifier)..freeze(true);
    final counts = <int>[];
    expect(c.read(totalConversationCountProvider), 100);
    c.listen(conversationCountProvider, (_, next) => counts.add(next));
    final archive = c.read(historyRepositoryProvider);
    expect(archive.latestAvailable(id), isNull);
    final receive = c.read(messageActionsProvider).receive;
    for (var i = 1; i <= 2; i++) {
      receive(ChatMessage(id: 'first-$i', conversationId: id, text: '你好 $i', timestamp: DateTime.now()));
      expect(engine.totalUnread, unread + i);
      expect(c.read(conversationStoreProvider).value.last.id, id);
      expect(engine.messages(id).first.historySequence, i);
    }
    expect(counts, [101]);
    expect(c.read(totalConversationCountProvider), 101);
    expect(engine.snapshot(freezeOrder: true).map((c) => c.id), [...original.map((c) => c.id), id]);
    list.freeze(false);
    expect(engine.conversationAt(3).id, id);
    expect(engine.conversation(id).preview, '你好 2');
    list.filter(query: '00104', unreadOnly: true);
    expect(c.read(conversationStoreProvider).value.single.id, id);
    expect(c.read(chatSessionsProvider).lookup(id), isNull);
    c.read(selectedConversationProvider.notifier).select(id);
    expect(c.read(conversationCountProvider), 0);
    expect(engine.totalUnread, unread);
    expect(c.read(contactDirectoryProvider), same(directory));
    final page = await archive.load(id);
    expect(page.messages.map((m) => m.id), ['first-2', 'first-1']);
    expect(page.hasMore, isFalse);
    expect(c.read(timelineStoreProvider(id)).value.map((m) => m.id), ['first-2', 'first-1']);
  });

  test('new-chat bursts stop and repeat with distinct senders while ordinary traffic stays paused', () async {
    final c = createContainer();
    addTearDown(c.dispose);
    final runtime = c.read(mockRuntimeProvider.notifier);
    final engine = c.read(engineProvider);
    final directory = c.read(contactDirectoryProvider);
    Future<NewChatBurst> finished() async {
      final future = Completer<NewChatBurst>();
      final sub = c.listen(newChatBurstProvider, (_, next) {
        if (!next.running && !future.isCompleted) future.complete(next);
      });
      try {
        return await future.future.timeout(const Duration(seconds: 5));
      } finally {
        sub.close();
      }
    }
    runtime.setRate(100);
    runtime.startBurst(count: 10000);
    final stopped = finished();
    final first = c.read(newChatBurstProvider).firstId;
    while (!engine.isListed(first)) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    runtime.stopBurst();
    final partial = await stopped;
    expect(partial.added, inInclusiveRange(1, 9999));
    runtime.setRate(5000);
    runtime.startBurst(count: 100);
    final complete = await finished();
    expect(complete.added, 100);
    expect(complete.firstId, greaterThan(first + partial.added - 1));
    expect(engine.conversationCount, 10100 + partial.added);
    expect(engine.totalUnread, greaterThanOrEqualTo(complete.added));
    expect(c.read(contactProfileProvider(complete.firstId)).contact.id, complete.firstId);
    expect(c.read(contactDirectoryProvider), same(directory));
    expect(c.read(mockRuntimeProvider).running, isFalse);
  });

  test('real isolate switches both ways without resetting or batching messages', () async {
    final done = Completer<void>();
    final modes = [
      TrafficPattern.hotspot,
      TrafficPattern.uniform,
      TrafficPattern.hotspot,
    ];
    final focused = [0, 0, 0];
    final recipients = List.generate(3, (_) => <int>{});
    var sequence = 0, phase = 0, receivedInPhase = 0;
    var images = 0;
    final imageSizes = <ImageMessageData>{};
    late final MockTransport transport;
    void configure() => transport.configure(
      running: true,
      rate: 5000,
      focus: 9999,
      pattern: modes[phase],
    );
    transport = MockTransport(
      onError: (error) {
        if (!done.isCompleted) done.completeError(StateError(error));
      },
      onMessage: (message) {
        if (done.isCompleted) return;
        // Every callback has one message, with continuous IDs across switches.
        if (message.id != 'mock-${sequence++}') {
          done.completeError(
            StateError('Message lost, duplicated or reordered'),
          );
          return;
        }
        receivedInPhase++;
        if (message.type == MessageType.image) {
          images++;
          imageSizes.add(message.image!);
        }
        // Already-sent events retain their original recipients. The transport
        // allows at most 64 in flight; exclude these from distribution checks.
        if (receivedInPhase > 64) {
          if (message.conversationId == 9999) focused[phase]++;
          recipients[phase].add(message.conversationId);
        }
        if (receivedInPhase == 1064) {
          if (phase == 2) {
            transport.configure(running: false, rate: 5000);
            done.complete();
          } else {
            phase++;
            receivedInPhase = 0;
            configure();
          }
        }
      },
    );
    addTearDown(transport.dispose);
    configure();
    await transport.initialize(10000);
    await done.future.timeout(const Duration(seconds: 15));
    expect(sequence, 3192);
    expect(images, 456);
    expect(imageSizes, mockImages.toSet());
    expect(focused[0], greaterThan(50));
    expect(focused[1], lessThan(10));
    expect(focused[2], greaterThan(50));
    expect(recipients[1].length, greaterThan(900));
  });

  test(
    'pattern persists through pause, rate and selected conversation changes',
    () {
      final c = createContainer();
      addTearDown(c.dispose);
      final runtime = c.read(mockRuntimeProvider.notifier);
      expect(c.read(mockRuntimeProvider).rate, 1 / 3);
      expect(c.read(mockRuntimeProvider).pattern, TrafficPattern.hotspot);
      runtime.setPattern(TrafficPattern.uniform);
      expect(c.read(mockRuntimeProvider).running, isFalse);
      runtime.setRate(3000);
      c.read(selectedConversationProvider.notifier).select(42);
      runtime.toggleRunning();
      expect(c.read(mockRuntimeProvider).pattern, TrafficPattern.uniform);
      expect(c.read(mockRuntimeProvider).rate, 3000);
      expect(c.read(mockRuntimeProvider).running, isTrue);
      runtime.setPattern(TrafficPattern.hotspot);
      expect(c.read(mockRuntimeProvider).running, isTrue);
      expect(c.read(mockRuntimeProvider).rate, 3000);
      runtime.toggleRunning();
      expect(c.read(mockRuntimeProvider).pattern, TrafficPattern.hotspot);
    },
  );

  test('three-second mode keeps its deadline through focus changes and switches back to fast traffic', () async {
    final events = <ChatMessage>[];
    final first = Completer<void>();
    final second = Completer<void>();
    final fast = Completer<void>();
    final elapsed = Stopwatch()..start();
    final arrivals = <int>[];
    final transport = MockTransport(
      onMessage: (message) {
        events.add(message);
        arrivals.add(elapsed.elapsedMilliseconds);
        if (events.length == 1) first.complete();
        if (events.length == 2) second.complete();
        if (events.length == 12) fast.complete();
      },
    );
    addTearDown(transport.dispose);
    transport.configure(running: true, rate: 1 / 3);
    await transport.initialize(10);
    await first.future.timeout(const Duration(seconds: 8));
    expect(arrivals.first, greaterThanOrEqualTo(2900));
    // A conversation or distribution change must not generate an extra message
    // or restart the three-second wait.
    await Future<void>.delayed(const Duration(seconds: 1));
    transport.configure(
      running: true,
      rate: 1 / 3,
      focus: 2,
      pattern: TrafficPattern.uniform,
    );
    await second.future.timeout(const Duration(seconds: 5));
    expect(arrivals[1] - arrivals[0], inInclusiveRange(2800, 3900));
    transport.configure(running: true, rate: 100);
    await fast.future.timeout(const Duration(seconds: 3));
    transport.configure(running: false, rate: 100);
    expect(
      events.take(12).map((m) => m.id),
      List.generate(12, (i) => 'mock-$i'),
    );
  });
}
