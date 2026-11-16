import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
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
    return c;
  }

  Finder row(int id) => find.byWidgetPredicate(
    (w) =>
        w.runtimeType.toString() == '_ConversationRow' && w.key == ValueKey(id),
  );
  void receive(ProviderContainer c, int i, int id, {bool mine = false}) => c
      .read(messageActionsProvider)
      .receive(
        ChatMessage(
          id: 'menu-$i',
          conversationId: id,
          text: '消息内容 $i',
          timestamp: DateTime.now(),
          isMine: mine,
        ),
      );

  for (final mobile in [true, false]) {
    testWidgets(
      '${mobile ? "long press" : "right click"} acts on the pressed chat after repeated reorder without opening it',
      (tester) async {
        final c = await mount(tester, mobile: mobile);
        final original = c.read(conversationStoreProvider).value[3].id;
        final selected = c.read(selectedConversationProvider);
        final sessions = c.read(chatSessionsProvider).length;
        final gesture = await tester.startGesture(
          tester.getCenter(row(original)),
          kind: mobile ? PointerDeviceKind.touch : PointerDeviceKind.mouse,
          buttons: mobile ? kPrimaryButton : kSecondaryButton,
        );
        for (var i = 0; i < 100; i++) {
          receive(c, i, 9900 + i);
          await tester.pump(const Duration(milliseconds: 1));
        }
        expect(row(original), findsNothing);
        if (mobile) await tester.pump(kLongPressTimeout);
        await gesture.up();
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('conversation-menu-pin')), findsOneWidget);
        receive(c, 100, 9000);
        await tester.pump();
        await tester.tap(find.byKey(const Key('conversation-menu-pin')));
        await tester.pumpAndSettle();
        expect(c.read(engineProvider).conversation(original).pinned, isTrue);
        expect(c.read(engineProvider).conversation(9999).pinned, isFalse);
        expect(c.read(selectedConversationProvider), selected);
        expect(c.read(chatSessionsProvider).length, sessions);
        expect(c.read(chatSessionProvider(original).exists), isFalse);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'chat menu marks only its target read and mute stays in sync with cached settings',
    (tester) async {
      final c = await mount(tester);
      final sessions = c.read(chatSessionsProvider).length;
      c.read(conversationListProvider.notifier).markAllRead();
      receive(c, 1, 3);
      receive(c, 2, 4);
      await tester.pump();
      await tester.longPress(row(3));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('conversation-menu-read')));
      await tester.pumpAndSettle();
      expect(c.read(engineProvider).conversation(3).unread, 0);
      expect(c.read(engineProvider).conversation(4).unread, 1);
      expect(c.read(totalUnreadProvider), 1);
      expect(c.read(selectedConversationProvider), isNull);
      expect(c.read(chatSessionsProvider).length, sessions);
      // Open once so the next list action must also update retained chat state.
      await tester.tap(row(3));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('back')));
      await tester.pumpAndSettle();
      await tester.longPress(row(3));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('conversation-menu-mute')));
      await tester.pumpAndSettle();
      expect(c.read(engineProvider).conversation(3).muted, isTrue);
      expect(c.read(chatSessionProvider(3)).muted, isTrue);
      await tester.longPress(row(3));
      await tester.pumpAndSettle();
      expect(find.text('关闭免打扰'), findsOneWidget);
      await tester.tap(find.byKey(const Key('conversation-menu-mute')));
      await tester.pumpAndSettle();
      expect(c.read(chatSessionProvider(3)).muted, isFalse);
      expect(tester.takeException(), isNull);
    },
  );

  for (final mobile in [true, false]) {
    testWidgets(
      '${mobile ? "long press" : "right click"} copies the chosen message even after its bubble leaves the live window',
      (tester) async {
        final c = await mount(tester, mobile: mobile);
        if (mobile) {
          await tester.tap(find.text('产品设计小组'));
          await tester.pumpAndSettle();
        }
        receive(c, 0, 0, mine: !mobile);
        await tester.pumpAndSettle();
        String? clipboard;
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          (call) async {
            if (call.method == 'Clipboard.setData') {
              clipboard = (call.arguments as Map)['text'] as String;
            }
            return null;
          },
        );
        addTearDown(
          () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            SystemChannels.platform,
            null,
          ),
        );
        if (mobile) {
          await tester.longPress(find.text('消息内容 0'));
        } else {
          await tester.tap(
            find.descendant(
              of: find.byWidgetPredicate(
                (w) => w.runtimeType.toString() == '_MessageActionsRegion',
              ),
              matching: find.text('消息内容 0'),
            ),
            buttons: kSecondaryButton,
          );
        }
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('message-menu-copy')), findsOneWidget);
        var changes = 0;
        final subscription = c.listen(
          timelineStructureProvider(0),
          (_, _) => changes++,
        );
        for (var i = 1; i <= 300; i++) {
          receive(c, i, 0);
          expect(changes, i);
        }
        await tester.pump();
        expect(find.text('消息内容 0'), findsNothing);
        await tester.tap(find.byKey(const Key('message-menu-copy')));
        await tester.pumpAndSettle();
        expect(clipboard, '消息内容 0');
        expect(find.text('已复制消息'), findsOneWidget);
        subscription.close();
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('delete acts on the pressed message while new messages arrive', (
    tester,
  ) async {
    final c = await mount(tester);
    await tester.tap(find.text('产品设计小组'));
    await tester.pumpAndSettle();
    receive(c, 1, 0);
    await tester.pumpAndSettle();
    await tester.longPress(find.text('消息内容 1'));
    await tester.pumpAndSettle();
    receive(c, 2, 0, mine: true);
    await tester.tap(find.byKey(const Key('message-menu-delete')));
    await tester.pumpAndSettle();
    final feed = c.read(timelineStoreProvider(0));
    expect(feed.message('menu-1'), isNull);
    expect(feed.value.first.id, 'menu-2');
    expect(c.read(engineProvider).conversation(0).preview, '消息内容 2');
    final previous = feed.value[1];
    await tester.longPress(find.text('消息内容 2'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('message-menu-delete')));
    await tester.pumpAndSettle();
    expect(feed.value.first.id, previous.id);
    final chat = c.read(engineProvider).conversation(0);
    expect(chat.preview, previous.preview);
    expect(chat.updatedAt, previous.timestamp);
    expect(c.read(engineProvider).messages(0), isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'history messages support copying and dismissing a menu does not change the viewport',
    (tester) async {
      await mount(tester);
      await tester.tap(find.text('产品设计小组'));
      await tester.pumpAndSettle();
      final scroll = tester
          .widget<CustomScrollView>(find.byKey(const Key('message-list')))
          .controller!;
      scroll.jumpTo(400);
      await tester.pump();
      final message = find.textContaining('历史 #').hitTestable().first;
      final text = tester.widget<Text>(message).data;
      final offset = scroll.offset;
      await tester.longPress(message);
      await tester.pumpAndSettle();
      await tester.tapAt(const Offset(430, 100));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('message-menu-copy')), findsNothing);
      expect(scroll.offset, offset);
      await tester.longPress(find.text(text!));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('message-menu-copy')));
      await tester.pumpAndSettle();
      expect(scroll.offset, offset);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'redesigned menus fit a narrow screen with large text and safe areas',
    (tester) async {
      final c = await mount(tester);
      tester.view.physicalSize = const Size(320, 568);
      tester.view.padding = const FakeViewPadding(top: 48, bottom: 24);
      addTearDown(() {
        tester.view.resetPadding();
        tester.platformDispatcher.clearTextScaleFactorTestValue();
      });
      await tester.pumpAndSettle();
      await tester.longPress(row(0));
      await tester.pumpAndSettle();
      final sheetWidget = tester.widget(
        find.byWidgetPredicate(
          (w) => w.runtimeType.toString() == '_ConversationActionSheet',
        ),
      );
      // Exercise the menu's text scaling independently of fixed-height list rows.
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Align(alignment: Alignment.bottomCenter, child: sheetWidget),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final sheet = tester.getRect(
        find.byKey(const Key('conversation-action-sheet')),
      );
      expect(sheet.left, greaterThanOrEqualTo(16));
      expect(sheet.right, lessThanOrEqualTo(304));
      final cancel = find.byKey(const Key('conversation-menu-cancel'));
      await tester.ensureVisible(cancel);
      await tester.pumpAndSettle();
      expect(tester.getRect(cancel).bottom, lessThanOrEqualTo(544));
      tester.platformDispatcher.textScaleFactorTestValue = 1;
      await tester.pumpWidget(
        UncontrolledProviderScope(container: c, child: const LocalImApp()),
      );
      await tester.pumpAndSettle();
      await tester.tap(row(0));
      await tester.pumpAndSettle();
      final text = find.textContaining('历史 #').hitTestable().first;
      final region = tester.widget(
        find
            .ancestor(
              of: text,
              matching: find.byWidgetPredicate(
                (w) => w.runtimeType.toString() == '_MessageActionsRegion',
              ),
            )
            .first,
      );
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: MaterialApp(
            home: Scaffold(
              body: SafeArea(
                child: Align(alignment: Alignment.bottomRight, child: region),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.longPress(find.textContaining('历史 #'));
      await tester.pumpAndSettle();
      final copy = find.byKey(const Key('message-menu-copy'));
      final rect = tester.getRect(copy);
      final delete = tester.getRect(
        find.byKey(const Key('message-menu-delete')),
      );
      expect(delete.center.dy, closeTo(rect.center.dy, .01));
      expect(delete.left, greaterThanOrEqualTo(rect.right));
      expect(delete.right, lessThanOrEqualTo(312));
      expect(rect.height, greaterThanOrEqualTo(44));
      final toolbar = tester.getRect(find.byKey(const Key('message-toolbar')));
      expect(
        toolbar.bottom,
        lessThan(tester.getTopLeft(find.textContaining('历史 #')).dy),
      );
      expect(rect.left, greaterThanOrEqualTo(8));
      expect(rect.right, lessThanOrEqualTo(312));
      expect(rect.top, greaterThanOrEqualTo(48));
      expect(rect.bottom, lessThanOrEqualTo(544));
      await tester.tap(copy);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );
}
