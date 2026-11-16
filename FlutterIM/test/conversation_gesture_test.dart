import 'package:flutter/gestures.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_im/core/models.dart';
import 'package:local_im/mock_main.dart';
import 'package:local_im/state/im_providers.dart';
import 'package:material_ui/material_ui.dart';

import 'support.dart';

void main() {
  Future<ProviderContainer> mount(
    WidgetTester tester, {
    bool mobile = true,
  }) async {
    tester.view.physicalSize = mobile
        ? const Size(440, 956)
        : const Size(1380, 900);
    tester.view.devicePixelRatio = 1;
    final container = createContainer();
    addTearDown(() {
      container.dispose();
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const LocalImApp(),
      ),
    );
    await tester.pumpAndSettle();
    return container;
  }

  Finder row(int id) => find.byWidgetPredicate(
    (w) =>
        w.runtimeType.toString() == '_ConversationRow' && w.key == ValueKey(id),
  );

  void receive(ProviderContainer container, int id) {
    container
        .read(messageActionsProvider)
        .receive(
          ChatMessage(
            id: 'gesture-$id',
            conversationId: id,
            text: 'reorder $id',
            timestamp: DateTime.now(),
          ),
        );
  }

  for (final mobile in [true, false]) {
    testWidgets(
      '${mobile ? "touch" : "mouse"} opens the pressed conversation through repeated reorder',
      (tester) async {
        final container = await mount(tester, mobile: mobile);
        final original = container.read(conversationStoreProvider).value[3].id;
        var notifications = 0;
        final subscription = container.listen(
          conversationRowProvider(3),
          (_, _) => notifications++,
        );
        final gesture = await tester.startGesture(
          tester.getCenter(row(original)),
          kind: mobile ? PointerDeviceKind.touch : PointerDeviceKind.mouse,
        );
        // Rebuild between down/up: the pressed conversation leaves the viewport.
        for (var i = 0; i < 100; i++) {
          receive(container, 9900 + i);
          expect(notifications, i + 1);
          expect(
            container.read(conversationStoreProvider).value[3].id,
            9900 + i,
          );
          await tester.pump(const Duration(milliseconds: 1));
        }
        expect(row(original), findsNothing);
        await gesture.up();
        await tester.pumpAndSettle();
        expect(container.read(selectedConversationProvider), original);
        expect(tester.takeException(), isNull);
        subscription.close();
      },
    );
  }

  testWidgets(
    'pointer down uses painted identity even before a pending row rebuild',
    (tester) async {
      final container = await mount(tester);
      final original = container.read(conversationStoreProvider).value[3].id;
      final position = tester.getCenter(row(original));
      receive(
        container,
        9999,
      ); // Provider changed; screen has not painted it yet.
      final gesture = await tester.startGesture(position);
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();
      expect(container.read(selectedConversationProvider), original);
    },
  );

  testWidgets('cancelled press clears the captured identity for the next tap', (
    tester,
  ) async {
    final container = await mount(tester);
    final original = container.read(conversationStoreProvider).value[3].id;
    final gesture = await tester.startGesture(tester.getCenter(row(original)));
    receive(container, 9999);
    await tester.pump();
    await gesture.cancel();
    await tester.pumpAndSettle();
    expect(container.read(selectedConversationProvider), isNull);
    await tester.tap(row(9999));
    await tester.pumpAndSettle();
    expect(container.read(selectedConversationProvider), 9999);
  });

  testWidgets(
    'dragging a pressed row after reorder scrolls without opening a chat',
    (tester) async {
      final container = await mount(tester);
      final original = container.read(conversationStoreProvider).value[3].id;
      final gesture = await tester.startGesture(
        tester.getCenter(row(original)),
      );
      receive(container, 9999);
      await tester.pump();
      await gesture.moveBy(const Offset(0, -100));
      await tester.pump();
      await gesture.moveBy(const Offset(0, -100));
      await gesture.up();
      await tester.pumpAndSettle();
      expect(container.read(selectedConversationProvider), isNull);
      expect(container.read(conversationListProvider).frozen, isTrue);
      final visible = find
          .byWidgetPredicate(
            (w) => w.runtimeType.toString() == '_ConversationRow',
          )
          .hitTestable()
          .last;
      final nextId = (tester.widget(visible).key! as ValueKey<int>).value;
      await tester.tap(visible);
      await tester.pumpAndSettle();
      expect(container.read(selectedConversationProvider), nextId);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'accessibility activation after cancellation opens the displayed row',
    (tester) async {
      final semantics = tester.ensureSemantics();
      try {
        final container = await mount(tester);
        final original = container.read(conversationStoreProvider).value[3].id;
        final gesture = await tester.startGesture(
          tester.getCenter(row(original)),
        );
        receive(container, 9999);
        await tester.pump();
        await gesture.cancel();
        await tester.pumpAndSettle();
        final node = tester.getSemantics(row(9999));
        node.owner!.performAction(node.id, SemanticsAction.tap);
        await tester.pumpAndSettle();
        expect(container.read(selectedConversationProvider), 9999);
      } finally {
        semantics.dispose();
      }
    },
  );
}
