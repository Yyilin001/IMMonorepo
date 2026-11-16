import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:local_im/state/im_providers.dart';

import 'support.dart';

import 'package:local_im/core/models.dart';
import 'package:local_im/mock_main.dart';

ChatMessage incoming(String id, int conversation) => ChatMessage(
  id: id,
  conversationId: conversation,
  text: 'updated $id',
  timestamp: DateTime.now(),
);

class _BuildTrace {
  final rows = <int>[];
  final messages = <String>[];
  final keys = <Key?>[];
  void record(Element element, bool builtBefore) {
    final widget = element.widget;
    keys.add(widget.key);
    if (widget.runtimeType.toString() == '_ConversationRow') {
      rows.add((widget.key! as ValueKey<int>).value);
    }
    if (widget.runtimeType.toString() == '_MessageBubble') {
      messages.add((widget.key! as ValueKey<String>).value);
    }
  }

  void clear() {
    rows.clear();
    messages.clear();
    keys.clear();
  }

  void expectNoListOrHeaderBuilds() {
    expect(keys, isNot(contains(const Key('conversation-list'))));
    expect(keys, isNot(contains(const Key('message-list'))));
    expect(keys, isNot(contains(const Key('pin-action'))));
  }
}

void main() {
  Future<ProviderContainer> mount(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1380, 900);
    tester.view.devicePixelRatio = 1;
    final c = createContainer(autoStart: false);
    addTearDown(() {
      debugOnRebuildDirtyWidget = null;
      c.dispose();
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    await tester.pumpWidget(
      UncontrolledProviderScope(container: c, child: const LocalImApp()),
    );
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();
    return c;
  }

  testWidgets(
    'offscreen frozen conversation rebuilds no lists, rows, bubbles or pin',
    (tester) async {
      final c = await mount(tester);
      c.read(conversationListProvider.notifier).freeze(true);
      await tester.pump();
      final trace = _BuildTrace();
      debugOnRebuildDirtyWidget = trace.record;
      c.read(messageActionsProvider).receive(incoming('offscreen', 9999));
      await tester.pump();
      expect(trace.rows, isEmpty);
      expect(trace.messages, isEmpty);
      trace.expectNoListOrHeaderBuilds();
      expect(c.read(listProviderRegistryProvider).rowCount, lessThan(30));
    },
  );

  testWidgets('visible frozen row changes without rebuilding its neighbors', (
    tester,
  ) async {
    final c = await mount(tester);
    c.read(conversationListProvider.notifier).freeze(true);
    await tester.pump();
    final trace = _BuildTrace();
    debugOnRebuildDirtyWidget = trace.record;
    c.read(messageActionsProvider).receive(incoming('visible', 1));
    await tester.pump();
    expect(trace.rows, [1]);
    expect(trace.messages, isEmpty);
    trace.expectNoListOrHeaderBuilds();
  });

  testWidgets(
    'reordering updates affected slots without rebuilding the list widget',
    (tester) async {
      final c = await mount(tester);
      final trace = _BuildTrace();
      debugOnRebuildDirtyWidget = trace.record;
      c.read(messageActionsProvider).receive(incoming('move-to-front', 9999));
      await tester.pump();
      expect(trace.rows, contains(9999));
      expect(trace.rows, isNot(anyOf(contains(0), contains(1), contains(2))));
      expect(trace.rows.length, lessThan(20));
      expect(trace.messages, isEmpty);
      trace.expectNoListOrHeaderBuilds();
      expect(find.text('本地好友 09999'), findsOneWidget);
    },
  );

  testWidgets('new active message reuses mounted old message bubbles', (
    tester,
  ) async {
    final c = await mount(tester);
    final previousIds = find
        .byWidgetPredicate((w) => w.runtimeType.toString() == '_MessageBubble')
        .evaluate()
        .map((e) => (e.widget.key! as ValueKey<String>).value)
        .toSet();
    final trace = _BuildTrace();
    debugOnRebuildDirtyWidget = trace.record;
    c.read(messageActionsProvider).receive(incoming('fresh', 0));
    await tester.pump();
    expect(trace.rows, [0]);
    expect(trace.messages, contains('fresh'));
    expect(trace.messages.where(previousIds.contains), isEmpty);
    expect(trace.keys, isNot(contains(const Key('conversation-list'))));
    expect(trace.keys, isNot(contains(const Key('pin-action'))));
    expect(
      trace.keys,
      contains(const Key('message-list')),
    ); // Structural insertion.
    expect(
      c
          .read(listProviderRegistryProvider)
          .messageCount(c.read(selectedConversationProvider)!),
      lessThan(30),
    );
  });

  testWidgets('editing one message only rebuilds that bubble', (tester) async {
    final c = await mount(tester);
    final target = c
        .read(timelineStoreProvider(c.read(selectedConversationProvider)!))
        .value
        .first;
    final trace = _BuildTrace();
    debugOnRebuildDirtyWidget = trace.record;
    c
        .read(
          timelineStructureProvider(c.read(selectedConversationProvider)!)
              .notifier,
        )
        .replace([
          for (final m
              in c
                  .read(
                    timelineStoreProvider(
                      c.read(selectedConversationProvider)!,
                    ),
                  )
                  .value)
            m.id == target.id
                ? ChatMessage(
                    id: m.id,
                    conversationId: m.conversationId,
                    text: 'edited content',
                    timestamp: m.timestamp,
                    isMine: m.isMine,
                    historySequence: m.historySequence,
                  )
                : m,
        ]);
    await tester.pump();
    expect(trace.messages, [target.id]);
    expect(trace.rows, isEmpty);
    trace.expectNoListOrHeaderBuilds();
  });

  testWidgets('nonmatching filtered traffic has no list or row rebuild', (
    tester,
  ) async {
    final c = await mount(tester);
    await tester.enterText(find.byKey(const Key('search')), '09999');
    await tester.pump();
    final trace = _BuildTrace();
    debugOnRebuildDirtyWidget = trace.record;
    c.read(messageActionsProvider).receive(incoming('filtered-away', 6));
    await tester.pump();
    expect(trace.rows, isEmpty);
    trace.expectNoListOrHeaderBuilds();
    c.read(messageActionsProvider).receive(incoming('matching', 9999));
    await tester.pump();
    expect(trace.rows, [9999]);
    trace.expectNoListOrHeaderBuilds();
  });

  testWidgets(
    'selection only rebuilds previous and next visible row selection',
    (tester) async {
      final c = await mount(tester);
      final trace = _BuildTrace();
      debugOnRebuildDirtyWidget = trace.record;
      c.read(selectedConversationProvider.notifier).select(1);
      await tester.pump();
      expect(trace.rows.toSet(), {0, 1});
      expect(trace.keys, isNot(contains(const Key('conversation-list'))));
    },
  );

  testWidgets(
    'background cached session updates do not rebuild the active chat',
    (tester) async {
      final c = await mount(tester);
      c.read(chatSessionProvider(0).notifier).freeze(true);
      c.read(selectedConversationProvider.notifier).select(1);
      c.read(conversationListProvider.notifier).freeze(true);
      await tester.pump(const Duration(milliseconds: 400));
      final trace = _BuildTrace();
      debugOnRebuildDirtyWidget = trace.record;
      c.read(messageActionsProvider).receive(incoming('background', 0));
      await tester.pump();
      expect(trace.messages, isEmpty);
      expect(trace.rows, [0]);
      trace.expectNoListOrHeaderBuilds();
      expect(c.read(chatSessionProvider(0)).pending, 1);
      expect(c.read(chatSessionProvider(1)).pending, 0);
    },
  );

  testWidgets(
    'history insertion reuses old bubbles and all subscriptions release',
    (tester) async {
      final c = await mount(tester);
      c
          .read(
            chatSessionProvider(c.read(selectedConversationProvider)!).notifier,
          )
          .freeze(true);
      final previousIds = find
          .byWidgetPredicate(
            (w) => w.runtimeType.toString() == '_MessageBubble',
          )
          .evaluate()
          .map((e) => (e.widget.key! as ValueKey<String>).value)
          .toSet();
      final trace = _BuildTrace();
      debugOnRebuildDirtyWidget = trace.record;
      final loading = c
          .read(
            chatSessionProvider(c.read(selectedConversationProvider)!).notifier,
          )
          .loadOlder();
      await tester.pump(const Duration(milliseconds: 400));
      await loading;
      expect(
        c
            .read(timelineStoreProvider(c.read(selectedConversationProvider)!))
            .value
            .length,
        200,
      );
      expect(trace.messages.where(previousIds.contains), isEmpty);
      await tester.pumpWidget(
        UncontrolledProviderScope(container: c, child: const SizedBox.shrink()),
      );
      await tester.pump();
      expect(c.read(listProviderRegistryProvider).rowCount, 0);
      expect(
        c
            .read(listProviderRegistryProvider)
            .messageCount(c.read(selectedConversationProvider)!),
        0,
      );
    },
  );
}
