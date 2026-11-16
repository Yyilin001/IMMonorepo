import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:local_im/core/chat_engine.dart';
import 'package:local_im/core/models.dart';
import 'package:local_im/mock/mock_transport.dart';
import 'package:local_im/mock/mock_history_repository.dart';

/// AOT single-message transport + immediate ordering, excluding Flutter paint.
Future<void> main(List<String> args) async {
  final seconds = args.isEmpty ? 20 : int.parse(args.first);
  if (seconds < 1) throw ArgumentError('Duration must be at least one second');
  final reports = <Map<String, Object>>[];
  for (final target in [1000, 3000, 5000]) {
    final engine = ChatEngine()..select(0);
    final archive = MockHistoryRepository();
    var maxMessage = 0;
    var peakRss = 0;
    final messageTimes = <int>[];
    final transport = MockTransport(
      onMessage: (ChatMessage message) {
        final timer = Stopwatch()..start();
        engine.receive(archive.record(message));
        // Validate the immediately updated index without a snapshot or timer.
        final latest = engine.conversationAt(0);
        if (!latest.pinned || engine.conversationCount != 10000) {
          throw StateError('Ordering/count invariant violated');
        }
        if (message.conversationId == engine.activeId) {
          engine.messages(engine.activeId!);
        }
        if (engine.cachedMessageCount > 40000) {
          throw StateError('Cache limit exceeded');
        }
        final elapsed = timer.elapsedMicroseconds;
        messageTimes.add(elapsed);
        if (elapsed > maxMessage) maxMessage = elapsed;
      },
    );
    await transport.initialize(10000);
    transport.configure(running: true, rate: target, focus: 0);
    // This timer samples memory only; it does not process/publish messages.
    final memorySampler = Timer.periodic(const Duration(milliseconds: 500), (
      _,
    ) {
      final rss = ProcessInfo.currentRss;
      if (rss > peakRss) peakRss = rss;
    });
    final clock = Stopwatch()..start();
    await Future<void>.delayed(Duration(seconds: seconds));
    transport.dispose();
    archive.dispose();
    memorySampler.cancel();
    clock.stop();
    final actual = engine.received / (clock.elapsedMicroseconds / 1e6);
    messageTimes.sort();
    final report = <String, Object>{
      'mode': 'immediate_per_message_with_history',
      'archived_messages': archive.retainedLiveCount,
      'target_per_second': target,
      'seconds': clock.elapsedMilliseconds / 1000,
      'received': engine.received,
      'actual_per_second': actual.round(),
      'cache_count': engine.cachedMessageCount,
      'evicted': engine.evicted,
      'message_p95_ms': messageTimes.isEmpty
          ? 0
          : messageTimes[(messageTimes.length * .95).ceil() - 1] / 1000,
      'message_max_ms': maxMessage / 1000,
      'peak_process_rss_mb': peakRss / 1024 / 1024,
    };
    reports.add(report);
    stdout.writeln(jsonEncode(report));
    if (actual < target * .90) exitCode = 1;
  }
  final output = File('build/benchmark_results.json');
  output.parent.createSync(recursive: true);
  output.writeAsStringSync(const JsonEncoder.withIndent('  ').convert(reports));
}
