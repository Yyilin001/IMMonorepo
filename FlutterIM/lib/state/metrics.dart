import 'dart:async';
import 'dart:collection';
import 'dart:math';

import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/chat_engine.dart';
import 'resources.dart';

class RuntimeStats {
  const RuntimeStats({
    this.received = 0,
    this.sent = 0,
    this.rate = 0,
    this.cached = 0,
    this.evicted = 0,
    this.unread = 0,
    this.messageMs = 0,
    this.notificationMs = 0,
    this.frameP95 = 0,
    this.slowFrames = 0,
    this.frameSamples = 0,
    this.history = const [],
  });
  final int received, sent, cached, evicted, unread, slowFrames, frameSamples;
  final double rate, messageMs, notificationMs, frameP95;
  final List<double> history;
}

final metricsProvider = NotifierProvider<MetricsNotifier, RuntimeStats>(
  MetricsNotifier.new,
);

class MetricsNotifier extends Notifier<RuntimeStats> {
  late ChatEngine engine;
  final Stopwatch _sampleClock = Stopwatch();
  final Queue<double> _frameTimes = Queue();
  final Queue<double> _rates = Queue();
  int _lastReceived = 0;
  double _messageMs = 0, _notificationMs = 0;

  @override
  RuntimeStats build() {
    engine = ref.watch(engineProvider);
    _sampleClock.start();
    final timer = Timer.periodic(
      const Duration(milliseconds: 500),
      (_) => _publishStats(),
    );
    SchedulerBinding.instance.addTimingsCallback(_recordFrames);
    ref.onDispose(() {
      timer.cancel();
      SchedulerBinding.instance.removeTimingsCallback(_recordFrames);
    });
    return const RuntimeStats();
  }

  void record({required double messageMs, required double notificationMs}) {
    _messageMs = max(_messageMs, messageMs);
    _notificationMs = max(_notificationMs, notificationMs);
  }

  void _recordFrames(List<FrameTiming> timings) {
    for (final frame in timings) {
      _frameTimes.add(
        max(
              frame.buildDuration.inMicroseconds,
              frame.rasterDuration.inMicroseconds,
            ) /
            1000,
      );
      if (_frameTimes.length > 240) _frameTimes.removeFirst();
    }
  }

  void _publishStats() {
    final seconds = _sampleClock.elapsedMicroseconds / 1000000;
    final rate = seconds == 0
        ? 0.0
        : (engine.received - _lastReceived) / seconds;
    _sampleClock.reset();
    _lastReceived = engine.received;
    _rates.add(rate);
    if (_rates.length > 60) _rates.removeFirst();
    final sorted = _frameTimes.toList()..sort();
    state = RuntimeStats(
      received: engine.received,
      sent: engine.sent,
      cached: engine.cachedMessageCount,
      evicted: engine.evicted,
      unread: engine.totalUnread,
      rate: rate,
      messageMs: _messageMs,
      notificationMs: _notificationMs,
      frameP95: sorted.isEmpty ? 0 : sorted[(sorted.length * .95).ceil() - 1],
      slowFrames: sorted.where((ms) => ms > 16.67).length,
      frameSamples: sorted.length,
      history: List.unmodifiable(_rates),
    );
    _messageMs = 0;
    _notificationMs = 0;
  }
}
