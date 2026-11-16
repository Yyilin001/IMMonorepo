import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_im/core/history.dart';
import 'package:local_im/mock_main.dart';
import 'package:local_im/state/im_providers.dart';
import 'package:material_ui/material_ui.dart';

import 'support.dart';

void main() {
  for (final scale in [1.0, 1.6]) {
    testWidgets(
      'mobile configuration remains readable and usable at text scale $scale',
      (tester) async {
        tester.view.physicalSize = const Size(320, 568);
        tester.view.devicePixelRatio = 1;
        final c = createContainer();
        addTearDown(() {
          c.dispose();
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
        });
        await tester.pumpWidget(
          UncontrolledProviderScope(container: c, child: const LocalImApp()),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('查看性能指标'));
        await tester.pumpAndSettle();
        final panel = tester.widget(
          find.byWidgetPredicate(
            (w) => w.runtimeType.toString() == '_MobileMetricsPanel',
          ),
        );
        // Isolate the configuration page from the conversation list's typography.
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: c,
            child: MaterialApp(
              home: MediaQuery(
                data: MediaQueryData(
                  size: const Size(320, 568),
                  padding: const EdgeInsets.symmetric(vertical: 24),
                  textScaler: TextScaler.linear(scale),
                ),
                child: Scaffold(body: SafeArea(child: panel)),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        for (final rate in messageRates) {
          expect(
            tester.getSize(find.byKey(ValueKey('rate-$rate'))).height,
            greaterThanOrEqualTo(48),
          );
        }
        await tester.tap(find.text('3 秒/条'));
        await tester.pump();
        expect(c.read(mockRuntimeProvider).rate, 1 / 3);
        final toggle = find.byKey(const Key('toggle-load'));
        await tester.tap(toggle);
        await tester.pump();
        expect(c.read(mockRuntimeProvider).running, isTrue);
        await tester.tap(toggle);
        await tester.pump();
        expect(c.read(mockRuntimeProvider).rate, 1 / 3);
        expect(c.read(mockRuntimeProvider).running, isFalse);
        final scrollable = find.descendant(
          of: find.byKey(const Key('mobile-metrics-scroll')),
          matching: find.byType(Scrollable),
        );
        await tester.scrollUntilVisible(
          find.byKey(const Key('history-network')),
          180,
          scrollable: scrollable,
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('history-network')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('历史服务离线').last);
        await tester.pumpAndSettle();
        expect(c.read(historyScenarioProvider).network, HistoryNetwork.offline);
        await tester.scrollUntilVisible(
          find.byKey(const Key('fail-next-history')),
          100,
          scrollable: scrollable,
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('fail-next-history')));
        await tester.pump();
        expect(c.read(historyScenarioProvider).failNext, isTrue);
        expect(toggle.hitTestable(), findsOneWidget);
        expect(tester.getRect(toggle).bottom, lessThanOrEqualTo(544));
        expect(tester.takeException(), isNull);
      },
    );
  }
}
