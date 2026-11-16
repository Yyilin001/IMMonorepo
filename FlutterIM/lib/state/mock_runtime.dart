import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../mock/mock_transport.dart';
import '../mock/traffic_pattern.dart';
import 'resources.dart';
import 'selection.dart';
import 'session_cache.dart';
import 'message_actions.dart';
import 'metrics.dart';

const messageRates = <num>[defaultMessageRate, 100, 1000, 3000, 5000];

class MockRuntimeState {
  const MockRuntimeState({
    this.running = true,
    this.rate = defaultMessageRate,
    this.pattern = TrafficPattern.hotspot,
    this.error,
  });
  final bool running;
  final num rate;
  final TrafficPattern pattern;
  final String? error;
}

final mockRuntimeProvider =
    NotifierProvider<MockRuntimeNotifier, MockRuntimeState>(
      MockRuntimeNotifier.new,
    );

class MockRuntimeNotifier extends Notifier<MockRuntimeState> {
  late MockTransport _transport;
  final _burstClock = Stopwatch();
  bool _started = false;
  @override
  MockRuntimeState build() {
    final config = ref.watch(imConfigProvider);
    _transport = MockTransport(
      onMessage: (message) {
        ref.read(messageActionsProvider).receive(message);
        final run = ref.read(newChatBurstProvider);
        if (run.running &&
            message.conversationId >= run.firstId &&
            message.conversationId < run.firstId + run.target &&
            ref.read(engineProvider).isListed(message.conversationId)) {
          ref.read(newChatBurstProvider.notifier).recordArrival();
        }
      },
      onError: _fail,
      onBurstEnd: _finishBurst,
    );
    ref.onDispose(_transport.dispose);
    ref.listen(selectedConversationProvider, (_, _) => _configure());
    return MockRuntimeState(running: config.autoStart);
  }

  void start() {
    if (_started) return;
    _started = true;
    ref.read(metricsProvider);
    _configure();
    unawaited(
      _transport
          .initialize(ref.read(imConfigProvider).conversationCount)
          .catchError((Object error) {
            if (ref.mounted) _fail('$error');
          }),
    );
    final id = ref.read(selectedConversationProvider);
    if (id != null) ref.read(chatSessionsProvider).open(id);
  }

  void startBurst({int count = 10000}) {
    if (ref.read(newChatBurstProvider).running) return;
    RangeError.checkValueInInterval(count, 1, 10000, 'count');
    final engine = ref.read(engineProvider);
    final first = engine.reserveFirstContactIds(count);
    final rate = state.rate < 1 ? 1000 : state.rate;
    ref.read(newChatBurstProvider.notifier).start(first, count, rate);
    _burstClock
      ..reset()
      ..start();
    _transport.startBurst(first, count, rate);
  }

  void stopBurst() => _transport.stopBurst();

  void _finishBurst() {
    _burstClock.stop();
    ref.read(newChatBurstProvider.notifier).finish(_burstClock.elapsed);
  }

  void _fail(String message) {
    if (ref.read(newChatBurstProvider).running) _finishBurst();
    if (ref.mounted) {
      state = MockRuntimeState(
        running: false,
        rate: state.rate,
        pattern: state.pattern,
        error: message,
      );
    }
  }

  void _configure() => _transport.configure(
    running: state.running,
    rate: state.rate,
    focus: ref.read(selectedConversationProvider),
    pattern: state.pattern,
  );
  void toggleRunning() {
    state = MockRuntimeState(
      running: !state.running,
      rate: state.rate,
      pattern: state.pattern,
      error: state.error,
    );
    _configure();
  }

  void setPattern(TrafficPattern pattern) {
    if (state.pattern == pattern) return;
    state = MockRuntimeState(
      running: state.running,
      rate: state.rate,
      pattern: pattern,
      error: state.error,
    );
    _configure();
  }

  void setRate(num rate) {
    if (!messageRates.contains(rate)) throw ArgumentError.value(rate);
    if (state.rate == rate) return;
    state = MockRuntimeState(
      running: state.running,
      rate: rate,
      pattern: state.pattern,
      error: state.error,
    );
    _configure();
  }
}

class NewChatBurst {
  const NewChatBurst({
    this.firstId = 0,
    this.target = 0,
    this.rate = 0,
    this.added = 0,
    this.elapsed,
  });
  final int firstId, target, added;
  final num rate;
  final Duration? elapsed;
  bool get running => target > 0 && elapsed == null;
}

final newChatBurstProvider =
    NotifierProvider<NewChatBurstNotifier, NewChatBurst>(
      NewChatBurstNotifier.new,
    );

class NewChatBurstNotifier extends Notifier<NewChatBurst> {
  int _added = 0;
  @override
  NewChatBurst build() => const NewChatBurst();
  void start(int first, int target, num rate) {
    _added = 0;
    state = NewChatBurst(firstId: first, target: target, rate: rate);
  }

  void recordArrival() => _added++;
  void finish(Duration elapsed) {
    state = NewChatBurst(
      firstId: state.firstId,
      target: state.target,
      rate: state.rate,
      added: _added,
      elapsed: elapsed,
    );
  }
}
