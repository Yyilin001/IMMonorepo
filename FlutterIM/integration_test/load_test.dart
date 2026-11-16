import 'dart:io';
import 'dart:math';

import 'package:flutter/scheduler.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:local_im/state/im_providers.dart';

import '../test/support.dart';

import 'package:local_im/core/history.dart';
import 'package:local_im/mock_main.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
  testWidgets('10k conversations under sustained real isolate traffic', (
    tester,
  ) async {
    binding.testTextInput.register();
    addTearDown(binding.testTextInput.unregister);
    final container = createContainer(autoStart: false);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const LocalImApp(),
      ),
    );
    await tester.pumpAndSettle();
    // Exercise a full bounded session cache, not just one active window.
    for (var id = 1; id <= 24; id++) {
      container.read(selectedConversationProvider.notifier).select(id);
    }
    container.read(selectedConversationProvider.notifier).select(0);
    await tester.pump(const Duration(milliseconds: 500));
    expect(container.read(chatSessionsProvider).length, 20);
    final reports = <Map<String, Object>>[];
    final frames = <double>[];
    void recordFrames(List<FrameTiming> timings) {
      for (final frame in timings) {
        frames.add(
          max(
                frame.buildDuration.inMicroseconds,
                frame.rasterDuration.inMicroseconds,
              ) /
              1000,
        );
      }
    }

    binding.addTimingsCallback(recordFrames);
    addTearDown(() => binding.removeTimingsCallback(recordFrames));
    for (final rate in [1000, 5000]) {
      container.read(mockRuntimeProvider.notifier).setRate(rate);
      if (!container.read(mockRuntimeProvider).running) {
        container.read(mockRuntimeProvider.notifier).toggleRunning();
      }
      // Warm up shader and initial layout before sampling.
      await tester.pump(const Duration(seconds: 2));
      frames.clear();
      final start = container.read(engineProvider).received;
      final clock = Stopwatch()..start();
      for (var i = 0; i < 80; i++) {
        await tester.pump(const Duration(milliseconds: 250));
        if (i == 10) {
          await tester.drag(
            find.byKey(const Key('conversation-list')),
            const Offset(0, -400),
          );
        }
        if (i == 20) {
          await tester.enterText(find.byKey(const Key('search')), '09999');
          await tester.pump(const Duration(milliseconds: 350));
          await tester.tap(
            find.descendant(
              of: find.byKey(const Key('conversation-list')),
              matching: find.text('本地好友 09999'),
            ),
          );
          await tester.pump();
          await tester.enterText(find.byKey(const Key('composer')), '压测期间发送');
          await tester.tap(find.byIcon(Icons.arrow_upward_rounded));
        }
        if (i == 40) {
          container
              .read(historyScenarioProvider.notifier)
              .setNetwork(HistoryNetwork.overlapping);
          await tester.tap(find.byKey(const Key('open-history')));
        }
        if (i == 45) {
          expect(
            container
                .read(
                  chatSessionProvider(
                    container.read(selectedConversationProvider)!,
                  ),
                )
                .history
                .error,
            isNull,
          );
          final messages = container
              .read(
                timelineStoreProvider(
                  container.read(selectedConversationProvider)!,
                ),
              )
              .value;
          expect(messages.map((m) => m.id).toSet().length, messages.length);
          for (var j = 1; j < messages.length; j++) {
            expect(
              messages[j - 1].historySequence!,
              greaterThan(messages[j].historySequence!),
            );
          }
          expect(
            container
                .read(
                  chatSessionProvider(
                    container.read(selectedConversationProvider)!,
                  ),
                )
                .pending,
            greaterThan(0),
          );
          await tester.tap(find.byKey(const Key('latest-messages')));
          container
              .read(historyScenarioProvider.notifier)
              .setNetwork(HistoryNetwork.normal);
        }
        if (i == 30) {
          await tester.enterText(find.byKey(const Key('search')), '');
        }
      }
      clock.stop();
      final actual =
          (container.read(engineProvider).received - start) /
          (clock.elapsedMicroseconds / 1e6);
      final stats = container.read(metricsProvider);
      frames.sort();
      final frameP95 = frames.isEmpty
          ? 0.0
          : frames[(frames.length * .95).ceil() - 1];
      reports.add({
        'mode': 'riverpod_direct_notifiers_per_message',
        'retained_sessions': container.read(chatSessionsProvider).length,
        'target_per_second': rate,
        'actual_per_second': actual,
        'sample_seconds': clock.elapsedMicroseconds / 1e6,
        'frame_p95_ms': frameP95,
        'slow_frames': frames.where((ms) => ms > 16.67).length,
        'frame_samples': frames.length,
        'rss_mb': ProcessInfo.currentRss / 1024 / 1024,
        'cached_messages': stats.cached,
      });
      expect(actual, greaterThan(rate * .90));
      expect(frames.length, greaterThan(40));
      expect(frameP95, lessThan(16.67));
      expect(
        container.read(engineProvider).cachedMessageCount,
        lessThanOrEqualTo(40000),
      );
      expect(tester.takeException(), isNull);
    }
    binding.reportData = {'load_tests': reports};
    container.read(mockRuntimeProvider.notifier).toggleRunning();
    await tester.pumpWidget(const SizedBox.shrink());
    container.dispose();
  });
}
