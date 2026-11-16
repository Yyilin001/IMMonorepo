import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_im/core/models.dart';
import 'package:local_im/core/profiles.dart';
import 'package:local_im/mock_main.dart';
import 'package:local_im/state/im_providers.dart';
import 'package:material_ui/material_ui.dart';

import 'support.dart';

void incoming(ProviderContainer c, int number, int id) => c
    .read(messageActionsProvider)
    .receive(
      ChatMessage(
        id: 'settings-$number',
        conversationId: id,
        text: 'new $number',
        timestamp: DateTime.now(),
      ),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  Future<ProviderContainer> mount(
    WidgetTester tester, {
    bool desktop = false,
  }) async {
    tester.view.physicalSize = desktop
        ? const Size(1380, 900)
        : const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    final c = createContainer();
    addTearDown(() {
      debugOnRebuildDirtyWidget = null;
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

  test('total unread publishes each arrival and clears on reading without reacting to pins or filters', () {
    final c = createContainer();
    addTearDown(c.dispose);
    c.read(conversationListProvider.notifier).markAllRead();
    var changes = 0;
    c.listen(totalUnreadProvider, (_, _) => changes++);
    for (var i = 0; i < 1000; i++) {
      incoming(c, i, 3);
      expect(c.read(totalUnreadProvider), i + 1);
      expect(changes, i + 1);
    }
    c.read(conversationListProvider.notifier).filter(query: 'none');
    c.read(chatSessionProvider(0).notifier).togglePinned();
    expect(changes, 1000);
    c.read(selectedConversationProvider.notifier).select(3);
    expect(c.read(totalUnreadProvider), 0);
    expect(changes, 1001);
    incoming(c, 1000, 3);
    expect(changes, 1001);
    incoming(c, 1001, 4);
    c.read(conversationListProvider.notifier).markAllRead();
    expect(c.read(totalUnreadProvider), 0);
    expect(changes, 1003);
  });

  test('contact collation handles Chinese, Latin, symbols and stable ties', () {
    final names = ['张三', 'alice', '李四', 'Bob', ' 陈一舟 ', '123', '🙂'];
    final contacts = [
      for (var i = 0; i < names.length; i++)
        ContactSummary(id: i, name: names[i], isGroup: false),
    ]..sort(ContactSummary.compare);
    expect(contacts.map((c) => c.initial), ['A', 'B', 'C', 'L', 'Z', '#', '#']);
    expect(contacts.take(5).map((c) => c.id), [1, 3, 4, 2, 0]);
    final ties = [
      ContactSummary(id: 5, name: '林', isGroup: false),
      ContactSummary(id: 2, name: '林', isGroup: false),
    ]..sort(ContactSummary.compare);
    expect(ties.map((c) => c.id), [2, 5]);
    final index = ContactListIndex(contacts);
    expect(index.letterOffsets['A'], 0);
    expect(index.letterOffsets['B'], 108);
    expect(index.rows.where((row) => row.contact != null).length, 7);
  });

  test('quiet and appearance choices survive chat session eviction', () async {
    final c = createContainer(maxRetainedSessions: 1);
    addTearDown(c.dispose);
    c.read(chatSessionProvider(0).notifier).setMuted(true);
    c.read(chatBackgroundProvider(0).notifier).select(ChatBackground.warm);
    c.read(selectedConversationProvider.notifier).select(1);
    await c.pump();
    c.read(selectedConversationProvider.notifier).select(0);
    expect(c.read(chatSessionProvider(0)).muted, isTrue);
    expect(c.read(engineProvider).conversation(0).muted, isTrue);
    expect(c.read(chatBackgroundProvider(0)), ChatBackground.warm);
    expect(c.read(chatBackgroundProvider(1)), ChatBackground.light);
  });

  testWidgets(
    'alphabet navigation finds late groups and search keeps collation',
    (tester) async {
      final c = await mount(tester);
      await tester.tap(find.byKey(const Key('nav-contacts')));
      await tester.pumpAndSettle();
      final before = c.read(contactIndexProvider);
      await tester.tap(find.byKey(const ValueKey('contact-letter-L')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('contact-1')).hitTestable(),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('contact-7')).hitTestable(),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('contact-section-L')), findsOneWidget);
      incoming(c, 0, 9999);
      expect(identical(c.read(contactIndexProvider), before), isTrue);
      await tester.tap(find.byKey(const Key('open-contact-search')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('contact-search')),
        'linzhixia',
      );
      await tester.pump();
      expect(c.read(contactResultsProvider).single.id, 1);
      expect(find.byKey(const ValueKey('contact-section-L')), findsOneWidget);
      await tester.enterText(find.byKey(const Key('contact-search')), '');
      await tester.tap(find.text('群聊'));
      await tester.pump();
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('contact-letter-F')));
      await tester.pump();
      expect(
        find.byKey(const ValueKey('contact-2')).hitTestable(),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  for (final desktop in [false, true]) {
    testWidgets(
      '${desktop ? "desktop" : "phone"} settings apply to the current chat and profile returns to the existing chat',
      (tester) async {
        final c = await mount(tester, desktop: desktop);
        Rect? chatBackBounds;
        if (!desktop) {
          await tester.tap(find.text('产品设计小组'));
          await tester.pumpAndSettle();
          chatBackBounds = tester.getRect(find.byType(BackButton));
        }
        await tester.tap(find.byKey(const Key('chat-settings')));
        await tester.pumpAndSettle();
        if (chatBackBounds != null) {
          expect(tester.getRect(find.byType(BackButton)), chatBackBounds);
        }
        expect(find.text('聊天设置'), findsOneWidget);
        await tester.tap(find.byKey(const Key('settings-pin')));
        await tester.pump();
        expect(c.read(engineProvider).conversation(0).pinned, isFalse);
        await tester.tap(find.byKey(const Key('settings-mute')));
        await tester.pump();
        expect(c.read(engineProvider).conversation(0).muted, isTrue);
        await tester.tap(find.byKey(const ValueKey('chat-background-mint')));
        await tester.pump();
        expect(c.read(chatBackgroundProvider(0)), ChatBackground.mint);
        var settingsBuilds = 0;
        debugOnRebuildDirtyWidget = (element, _) {
          if (element.widget.runtimeType.toString() == 'ChatSettingsPage') {
            settingsBuilds++;
          }
        };
        for (var i = 0; i < 1000; i++) {
          incoming(c, i, 0);
        }
        await tester.pump();
        expect(settingsBuilds, 0);
        debugOnRebuildDirtyWidget = null;
        await tester.tap(find.byKey(const Key('settings-profile')));
        await tester.pumpAndSettle();
        expect(find.text('群聊资料'), findsOneWidget);
        await tester.tap(find.byKey(const Key('profile-send-message')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('composer')), findsOneWidget);
        expect(find.text('聊天设置'), findsNothing);
        expect(
          tester
              .widget<ColoredBox>(find.byKey(const Key('chat-background')))
              .color,
          const Color(0xFFEAF4EE),
        );
        await tester.tap(find.byKey(const Key('chat-settings')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('settings-history')));
        await tester.pumpAndSettle();
        expect(c.read(chatSessionProvider(0)).frozen, isTrue);
        expect(find.byKey(const Key('composer')), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'iOS settings keep content inside cards at narrow widths and large text',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      try {
        await mount(tester);
        await tester.tap(find.text('产品设计小组'));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('chat-settings')));
        await tester.pumpAndSettle();
        for (final width in [320.0, 440.0]) {
          for (final scale in [1.0, 2.0]) {
            tester.view.physicalSize = Size(width, 956);
            tester.platformDispatcher.textScaleFactorTestValue = scale;
            await tester.pumpAndSettle();
            final pin = find.byKey(const Key('settings-pin'));
            final pinRect = tester.getRect(pin);
            final titleRect = tester.getRect(find.text('置顶聊天'));
            expect(titleRect.left - pinRect.left, greaterThanOrEqualTo(16));
            final control = find.descendant(
              of: pin,
              matching: find.byType(Switch),
            );
            final controlRect = tester.getRect(control);
            expect(pinRect.right - controlRect.right, greaterThanOrEqualTo(16));
            expect(titleRect.right, lessThanOrEqualTo(controlRect.left));
            final backgroundTitle = find.text('聊天背景');
            await tester.ensureVisible(backgroundTitle);
            await tester.pumpAndSettle();
            final card = find
                .ancestor(of: backgroundTitle, matching: find.byType(Material))
                .first;
            final cardRect = tester.getRect(card);
            final labelRect = tester.getRect(backgroundTitle);
            expect(labelRect.left - cardRect.left, 18);
            expect(labelRect.top - cardRect.top, greaterThanOrEqualTo(16));
            await tester.ensureVisible(
              find.byKey(const ValueKey('chat-background-warm')),
            );
            await tester.pumpAndSettle();
            await tester.tap(
              find.byKey(const ValueKey('chat-background-warm')),
            );
            await tester.pumpAndSettle();
            expect(tester.takeException(), isNull);
          }
        }
      } finally {
        tester.platformDispatcher.clearTextScaleFactorTestValue();
        debugDefaultTargetPlatformOverride = null;
      }
    },
  );

  testWidgets(
    'bottom badge hides at zero and opening the unread chat clears it',
    (tester) async {
      final c = await mount(tester);
      c.read(conversationListProvider.notifier).markAllRead();
      await tester.pump();
      expect(
        tester
            .widget<Badge>(find.byKey(const Key('total-unread-badge')))
            .isLabelVisible,
        isFalse,
      );
      for (var i = 0; i < 101; i++) {
        incoming(c, i, 3);
      }
      await tester.pump();
      final badge = tester.widget<Badge>(
        find.byKey(const Key('total-unread-badge')),
      );
      expect(badge.isLabelVisible, isTrue);
      expect((badge.label! as Text).data, '99+');
      await tester.tap(find.text('陈一舟'));
      await tester.pumpAndSettle();
      expect(c.read(totalUnreadProvider), 0);
      await tester.tap(find.byKey(const Key('back')));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<Badge>(find.byKey(const Key('total-unread-badge')))
            .isLabelVisible,
        isFalse,
      );
    },
  );

  testWidgets(
    'iOS scrollbar fades after scrolling and remains hidden on live appends',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      try {
        final c = await mount(tester);
        await tester.tap(find.text('产品设计小组'));
        await tester.pumpAndSettle();
        final scrollbar = find.descendant(
          of: find.byKey(const Key('message-scrollbar')),
          matching: find.byWidgetPredicate(
            (w) => w is CustomPaint && w.foregroundPainter is ScrollbarPainter,
          ),
        );
        final painter =
            tester.widget<CustomPaint>(scrollbar).foregroundPainter!
                as ScrollbarPainter;
        expect(painter.fadeoutOpacityAnimation.value, 0);
        final drag = await tester.startGesture(
          tester.getCenter(find.byKey(const Key('message-list'))),
        );
        await drag.moveBy(const Offset(0, 200));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 200));
        expect(painter.fadeoutOpacityAnimation.value, greaterThan(0));
        await drag.up();
        await tester.pump(const Duration(seconds: 2));
        await tester.pump(const Duration(seconds: 1));
        expect(painter.fadeoutOpacityAnimation.value, 0);
        incoming(c, 0, 0);
        await tester.pump();
        expect(painter.fadeoutOpacityAnimation.value, 0);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    },
  );
}
