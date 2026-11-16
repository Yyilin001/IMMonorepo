// Run in profile or release on a phone. Results are written to the app's
// Documents/new-chat-benchmark.json for collection with devicectl or adb.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:ui' show FramePhase;

import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:local_im/mock_main.dart';
import 'package:local_im/state/im_providers.dart';
import 'package:path_provider/path_provider.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final container = ProviderContainer(
    overrides: [
      imConfigProvider.overrideWithValue(const ImConfig(autoStart: false)),
    ],
  );
  runApp(
    UncontrolledProviderScope(container: container, child: const LocalImApp()),
  );
  await Future<void>.delayed(const Duration(seconds: 2));
  ScrollController? controller;
  void locate(Element element) {
    final widget = element.widget;
    if (widget is ListView && widget.key == const Key('conversation-list')) {
      controller = widget.controller;
      return;
    }
    element.visitChildren(locate);
  }

  final file = File(
    '${(await getApplicationDocumentsDirectory()).path}/new-chat-benchmark.json',
  );
  try {
    WidgetsBinding.instance.rootElement!.visitChildren(locate);
    final list = controller!;
    final runtime = container.read(mockRuntimeProvider.notifier);
    final engine = container.read(engineProvider);
    final reports = <Map<String, Object>>[];
    Future<void> scroll() async {
      final distance = list.offset < 1000 ? 2000.0 : 0.0;
      await list.animateTo(
        distance,
        duration: const Duration(milliseconds: 900),
        curve: Curves.linear,
      );
    }

    await scroll();
    await scroll();
    for (final target in [0, 1000, 3000, 5000]) {
      final frames = <FrameTiming>[];
      final binding = SchedulerBinding.instance;
      void collect(List<FrameTiming> values) => frames.addAll(values);
      binding.addTimingsCallback(collect);
      final before = engine.conversationCount;
      final start = DateTime.now().microsecondsSinceEpoch;
      if (target > 0) {
        runtime.setRate(target);
        runtime.startBurst();
      }
      final timeout = Stopwatch()..start();
      do {
        await scroll();
        if (timeout.elapsed > const Duration(seconds: 45)) {
          throw StateError('Timed out at $target');
        }
      } while (target == 0
          ? timeout.elapsedMilliseconds < 4500
          : container.read(newChatBurstProvider).running);
      final end = DateTime.now().microsecondsSinceEpoch;
      // Release engine callbacks can deliver timings in arrears.
      await Future<void>.delayed(const Duration(milliseconds: 1250));
      binding.removeTimingsCallback(collect);
      frames.removeWhere((f) {
        final wall = f.timestampInMicroseconds(FramePhase.rasterFinishWallTime);
        return wall < start || wall > end;
      });
      if (frames.length < 20) {
        throw StateError('Insufficient frame timings: ${frames.length}');
      }
      final work =
          frames
              .map(
                (f) =>
                    max(
                      f.buildDuration.inMicroseconds,
                      f.rasterDuration.inMicroseconds,
                    ) /
                    1000,
              )
              .toList()
            ..sort();
      final intervals = [
        for (int i = 1; i < frames.length; i++)
          (frames[i].timestampInMicroseconds(FramePhase.vsyncStart) -
                  frames[i - 1].timestampInMicroseconds(
                    FramePhase.vsyncStart,
                  )) /
              1000,
      ]..sort();
      double percentile(List<double> values, double p) =>
          values[(values.length * p).ceil() - 1];
      final elapsed = target == 0
          ? timeout.elapsedMicroseconds / 1e6
          : container.read(newChatBurstProvider).elapsed!.inMicroseconds / 1e6;
      final added = engine.conversationCount - before;
      if (target > 0 && added != 10000) {
        throw StateError('Expected 10000 new chats, got $added');
      }
      reports.add({
        'target_per_second': target,
        'initial_chats': before,
        'added': added,
        'new_per_second': added / elapsed,
        'frames': frames.length,
        'work_p95_ms': percentile(work, .95),
        'work_p99_ms': percentile(work, .99),
        'vsync_gap_p95_ms': percentile(intervals, .95),
        'vsync_gap_max_ms': intervals.last,
        'work_over_16_67_ms': work.where((ms) => ms > 16.67).length,
        'vsync_gaps_over_33_ms': intervals.where((ms) => ms > 33.33).length,
      });
      await file.writeAsString(
        jsonEncode({'complete': target == 5000, 'runs': reports}),
        flush: true,
      );
    }
  } catch (error, stack) {
    await file.writeAsString(
      jsonEncode({'error': '$error', 'stack': '$stack'}),
      flush: true,
    );
    rethrow;
  }
}
