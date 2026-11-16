// Run on a closed Duo simulator with its software keyboard enabled. Use Device
// Hub's Open and Closed controls when prompted. Dimensions come from iOS.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:local_im/core/models.dart';
import 'package:local_im/mock_main.dart';
import 'package:local_im/state/im_providers.dart';
import 'package:material_ui/material_ui.dart';

import '../test/support.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('Duo preserves the visible history row and a focused draft', (
    tester,
  ) async {
    final c = createContainer();
    addTearDown(c.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(container: c, child: const LocalImApp()),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('林知夏'));
    await tester.pumpAndSettle();
    final id = c.read(selectedConversationProvider)!;
    final list = find.byKey(const Key('message-list'));
    final composer = find.byKey(const Key('composer'));
    final sidebar = find.byKey(const Key('conversation-list'));
    final view = WidgetsBinding.instance.platformDispatcher.views.first;
    final controller = tester.widget<CustomScrollView>(list).controller!;
    // Long rows change height when the sidebar appears.
    for (var i = 0; i < 35; i++) {
      c
          .read(messageActionsProvider)
          .receive(
            ChatMessage(
              id: 'duo-$i',
              conversationId: id,
              text: "消息 $i · ${'测试换行后保留当前阅读位置。' * (i % 4 + 2)}",
              timestamp: DateTime.now(),
            ),
          );
    }
    await tester.pumpAndSettle();
    controller.jumpTo(2400);
    await tester.pumpAndSettle();
    expect(c.read(chatSessionProvider(id)).frozen, isTrue);

    Finder topRow() {
      final y = tester.getTopLeft(list).dy + .5;
      final bubbles = find.byWidgetPredicate(
        (w) => w.runtimeType.toString() == '_MessageBubble',
      );
      final row = bubbles.evaluate().firstWhere((e) {
        final rect = tester.getRect(find.byWidget(e.widget));
        return rect.top <= y && rect.bottom > y;
      });
      final key = row.widget.key;
      return find.byWidgetPredicate(
        (w) => w.runtimeType.toString() == '_MessageBubble' && w.key == key,
      );
    }

    Future<void> waitFor(bool Function() condition, String reason) async {
      final clock = Stopwatch()..start();
      while (!condition() && clock.elapsed < const Duration(seconds: 60)) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(condition(), isTrue, reason: reason);
      await tester.pump(const Duration(milliseconds: 650));
    }

    final row = topRow();
    double readingY() => tester.getTopLeft(row).dy - tester.getTopLeft(list).dy;
    final startY = readingY();
    final field = tester.widget<TextField>(composer);
    await tester.tap(composer);
    await waitFor(
      () => view.viewInsets.bottom > 0,
      'native iOS keyboard appears',
    );
    const draft = 'Duo 草稿';
    tester
        .state<EditableTextState>(
          find.descendant(of: composer, matching: find.byType(EditableText)),
        )
        .updateEditingValue(
          const TextEditingValue(
            text: draft,
            selection: TextSelection.collapsed(offset: 3),
          ),
        );
    await tester.pump();
    for (final split in [true, false]) {
      debugPrint('DUO_DEVICE_HUB: ${split ? "OPEN" : "CLOSED"}');
      await waitFor(
        () =>
            sidebar.evaluate().isNotEmpty == split &&
            view.viewInsets.bottom > 0,
        'Device Hub changes the active display',
      );
      if (split) {
        expect(
          tester.getRect(sidebar).right,
          lessThanOrEqualTo(tester.getRect(list).left),
        );
      }
      expect(c.read(selectedConversationProvider), id);
      expect(
        identical(
          field.focusNode,
          tester.widget<TextField>(composer).focusNode,
        ),
        isTrue,
      );
      expect(field.focusNode!.hasFocus, isTrue);
      expect(c.read(draftProvider(id)), draft);
      expect(field.controller!.selection.baseOffset, 3);
      expect(view.viewInsets.bottom, greaterThan(0));
      expect(
        tester.getRect(composer).bottom,
        lessThanOrEqualTo(
          (view.physicalSize.height - view.viewInsets.bottom) /
                  view.devicePixelRatio +
              1,
        ),
      );
      expect(
        readingY(),
        closeTo(startY, 1),
        reason: 'same message at the same viewport position',
      );
      debugPrint(
        'DUO_VERIFIED split=$split row=${row.evaluate().single.widget.key} y=${readingY()} keyboard=${view.viewInsets.bottom / view.devicePixelRatio}',
      );
    }
    await tester.tap(find.byKey(const Key('send-message')));
    await tester.pumpAndSettle();
    expect(field.controller!.text, isEmpty);
    expect(
      c
          .read(timelineStoreProvider(id))
          .value
          .where((message) => message.isMine && message.text == draft),
      hasLength(1),
    );
  });
}
