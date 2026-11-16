import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:local_im/state/im_providers.dart';

import 'support.dart';

import 'package:local_im/core/models.dart';
import 'package:local_im/mock_main.dart';
import 'package:local_im/ui/workspace.dart';

void main() {
  Future<ProviderContainer> mount(WidgetTester tester, Size size) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    final container = createContainer(autoStart: false);
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
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();
    return container;
  }

  testWidgets(
    'every message synchronously updates ordering and notifies without pumping',
    (tester) async {
      final container = createContainer(autoStart: false);
      addTearDown(container.dispose);
      var notifications = 0;
      var timelineNotifications = 0;
      container.listen(conversationRowProvider(3), (_, _) => notifications++);
      container.listen(
        timelineStructureProvider(0),
        (_, _) => timelineNotifications++,
      );
      for (var i = 0; i < 5000; i++) {
        final id = 3 + i % 9997;
        container
            .read(messageActionsProvider)
            .receive(
              ChatMessage(
                id: 'immediate-$i',
                conversationId: id,
                text: 'event $i',
                timestamp: DateTime.now(),
              ),
            );
        // No pump(), timers or frame callback between receipt and assertions.
        expect(notifications, i + 1);
        expect(container.read(conversationStoreProvider).value[3].id, id);
        expect(
          container.read(conversationStoreProvider).value[3].preview,
          'event $i',
        );
      }
      container
          .read(messageActionsProvider)
          .receive(
            ChatMessage(
              id: 'active',
              conversationId: 0,
              text: 'active immediately',
              timestamp: DateTime.now(),
            ),
          );
      expect(notifications, 5000);
      expect(timelineNotifications, 1);
      expect(
        container
            .read(
              timelineStoreProvider(
                container.read(selectedConversationProvider)!,
              ),
            )
            .value
            .first
            .id,
        'active',
      );
      expect(container.read(conversationStoreProvider).value.first.id, 0);
    },
  );

  testWidgets('desktop lazily renders 10k conversations and searches', (
    tester,
  ) async {
    final container = await mount(tester, const Size(1380, 900));
    expect(find.text('10,000'), findsWidgets);
    expect(find.byType(ChatAvatar).evaluate().length, lessThan(50));
    await tester.drag(
      find.byKey(const Key('conversation-list')),
      const Offset(0, -400),
    );
    await tester.pumpAndSettle();
    expect(container.read(conversationListProvider).frozen, isTrue);
    await tester.enterText(find.byKey(const Key('search')), '09999');
    await tester.pump();
    expect(find.text('本地好友 09999'), findsOneWidget);
    await tester.tap(find.text('本地好友 09999'));
    await tester.pump();
    expect(container.read(selectedConversationProvider), 9999);
    expect(tester.takeException(), isNull);
  });

  testWidgets('sending has local echo and delayed mock reply', (tester) async {
    final container = await mount(tester, const Size(1380, 900));
    await tester.enterText(find.byKey(const Key('composer')), '你好，本地世界');
    await tester.tap(find.byIcon(Icons.arrow_upward_rounded));
    await tester.pump();
    expect(find.text('你好，本地世界'), findsWidgets);
    expect(container.read(engineProvider).sent, 1);
    await tester.pump(const Duration(milliseconds: 700));
    expect(container.read(engineProvider).received, 1);
    expect(
      container
          .read(
            timelineStoreProvider(
              container.read(selectedConversationProvider)!,
            ),
          )
          .value
          .first
          .text,
      contains('收到你的消息'),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'reading older messages preserves existing rows while new messages append',
    (tester) async {
      final container = await mount(tester, const Size(1380, 900));
      await tester.drag(
        find.byKey(const Key('message-list')),
        const Offset(0, 300),
      );
      await tester.pump();
      expect(
        container
            .read(
              chatSessionProvider(
                container.read(selectedConversationProvider)!,
              ),
            )
            .frozen,
        isTrue,
      );
      final before = container
          .read(
            timelineStoreProvider(
              container.read(selectedConversationProvider)!,
            ),
          )
          .value;
      container
          .read(messageActionsProvider)
          .receive(
            ChatMessage(
              id: 'new',
              conversationId: 0,
              text: 'new incoming',
              timestamp: DateTime.now(),
            ),
          );
      final updated = container.read(timelineStoreProvider(0)).value;
      expect(updated.first.id, 'new');
      expect(updated.skip(1).map((m) => m.id), before.map((m) => m.id));
      await tester.tap(find.byKey(const Key('latest-messages')));
      await tester.pump();
      expect(
        container
            .read(
              timelineStoreProvider(
                container.read(selectedConversationProvider)!,
              ),
            )
            .value
            .first
            .id,
        'new',
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'older page insertion preserves visible anchor while live messages arrive',
    (tester) async {
      final c = await mount(tester, const Size(1380, 900));
      await tester.tap(find.byKey(const Key('open-history')));
      // Allow mixed-height slivers to resolve their estimated older edge.
      for (
        var i = 0;
        i < 20 && !c.read(chatSessionProvider(0)).history.loading;
        i++
      ) {
        await tester.pump();
      }
      expect(c.read(chatSessionProvider(0)).history.loading, isTrue);
      await tester.pump();
      final anchor = find.textContaining('历史 #261 ·');
      expect(anchor, findsOneWidget);
      final before = tester.getTopLeft(anchor);
      c
          .read(messageActionsProvider)
          .receive(
            ChatMessage(
              id: 'during-history',
              conversationId: 0,
              text: 'new during page request',
              timestamp: DateTime.now(),
            ),
          );
      await tester.pump(const Duration(milliseconds: 400));
      expect(
        c
            .read(timelineStoreProvider(c.read(selectedConversationProvider)!))
            .value
            .length,
        201,
      );
      expect(tester.getTopLeft(anchor).dy, closeTo(before.dy, 1));
      expect(
        c
            .read(chatSessionProvider(c.read(selectedConversationProvider)!))
            .pending,
        1,
      );
      expect(find.text('1 条新消息 · 回到最新'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'history failure displays retry and succeeds without losing old rows',
    (tester) async {
      final c = await mount(tester, const Size(1380, 900));
      c.read(historyScenarioProvider.notifier).failNextRequest();
      await tester.tap(find.byKey(const Key('open-history')));
      // Allow mixed-height slivers to resolve their estimated older edge.
      for (
        var i = 0;
        i < 20 && !c.read(chatSessionProvider(0)).history.loading;
        i++
      ) {
        await tester.pump();
      }
      expect(c.read(chatSessionProvider(0)).history.loading, isTrue);
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byKey(const Key('history-retry')), findsOneWidget);
      expect(
        c
            .read(timelineStoreProvider(c.read(selectedConversationProvider)!))
            .value
            .length,
        100,
      );
      await tester.tap(find.byKey(const Key('history-retry')));
      await tester.pump(const Duration(milliseconds: 400));
      expect(
        c
            .read(timelineStoreProvider(c.read(selectedConversationProvider)!))
            .value
            .length,
        200,
      );
      expect(
        c
            .read(chatSessionProvider(c.read(selectedConversationProvider)!))
            .history
            .error,
        isNull,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'drafts survive conversation switches and clear only after send',
    (tester) async {
      final container = await mount(tester, const Size(1380, 900));
      await tester.enterText(find.byKey(const Key('composer')), 'draft zero');
      container.read(selectedConversationProvider.notifier).select(1);
      await tester.pump();
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('composer')))
            .controller!
            .text,
        '',
      );
      await tester.enterText(find.byKey(const Key('composer')), 'draft one');
      container.read(selectedConversationProvider.notifier).select(0);
      await tester.pump();
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('composer')))
            .controller!
            .text,
        'draft zero',
      );
      await tester.tap(find.byIcon(Icons.arrow_upward_rounded));
      await tester.pump();
      expect(container.read(draftProvider(0)), '');
      expect(container.read(draftProvider(1)), 'draft one');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'switching chats restores the actual history viewport and pending badge',
    (tester) async {
      final c = await mount(tester, const Size(1380, 900));
      await tester.tap(find.byKey(const Key('open-history')));
      // Allow mixed-height slivers to resolve their estimated older edge.
      for (
        var i = 0;
        i < 20 && !c.read(chatSessionProvider(0)).history.loading;
        i++
      ) {
        await tester.pump();
      }
      expect(c.read(chatSessionProvider(0)).history.loading, isTrue);
      await tester.pump(const Duration(milliseconds: 400));
      final list = tester.widget<CustomScrollView>(
        find.byKey(const Key('message-list')),
      );
      final offset = list.controller!.offset;
      expect(offset, greaterThan(0));
      final anchor = find.textContaining('历史 #261 ·');
      final anchorY = tester.getTopLeft(anchor).dy;
      c.read(selectedConversationProvider.notifier).select(1);
      await tester.pump(const Duration(milliseconds: 400));
      c
          .read(messageActionsProvider)
          .receive(
            ChatMessage(
              id: 'while-away',
              conversationId: 0,
              text: 'while away',
              timestamp: DateTime.now(),
            ),
          );
      c.read(selectedConversationProvider.notifier).select(0);
      await tester.pump();
      expect(
        tester
            .widget<CustomScrollView>(find.byKey(const Key('message-list')))
            .controller!
            .offset,
        closeTo(offset, 1),
      );
      expect(tester.getTopLeft(anchor).dy, closeTo(anchorY, 1));
      expect(find.text('1 条新消息 · 回到最新'), findsOneWidget);
      expect(c.read(timelineStoreProvider(0)).value.length, 201);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('small phone keeps composer above keyboard and restores drafts', (
    tester,
  ) async {
    final c = await mount(tester, const Size(375, 667));
    await tester.tap(find.text('林知夏'));
    await tester.pumpAndSettle();
    expect(
      tester.getSize(find.byKey(const Key('mobile-composer-bar'))).height,
      lessThan(80),
    );
    final field = find.byKey(const Key('composer'));
    void expectAlignedActions() {
      final input = tester.getRect(field);
      Rect circleFor(String key) {
        final button = find.byKey(Key(key));
        expect(tester.getSize(button), const Size.square(44));
        return tester.getRect(
          find.descendant(
            of: button,
            matching: find.byWidgetPredicate(
              (w) =>
                  w is DecoratedBox &&
                  w.decoration is BoxDecoration &&
                  (w.decoration as BoxDecoration).shape == BoxShape.circle,
            ),
          ),
        );
      }

      final attachment = circleFor('chat-attachments');
      final send = circleFor('send-message');
      expect(attachment.size, const Size.square(28));
      expect(send.size, const Size.square(32));
      final left = attachment.center;
      final right = send.center;
      expect(left.dy, closeTo(right.dy, .01));
      expect(left.dy, closeTo(input.center.dy, .01));
      expect(input.left - left.dx, closeTo(right.dx - input.right, .01));
    }

    expectAlignedActions();
    await tester.enterText(field, '第一行\n第二行\n第三行');
    await tester.pumpAndSettle();
    expectAlignedActions();
    await tester.enterText(find.byKey(const Key('composer')), '手机上的草稿');
    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    await tester.pump();
    expect(
      tester.getBottomLeft(find.byKey(const Key('composer'))).dy,
      lessThanOrEqualTo(367),
    );
    expect(
      tester.getSize(find.byKey(const Key('message-list'))).height,
      greaterThan(180),
    );
    expect(tester.takeException(), isNull);
    final plus = find.byKey(const Key('chat-attachments'));
    final panel = find.byKey(const Key('attachment-panel'));
    await tester.tap(plus);
    await tester.pumpAndSettle();
    expect(tester.getBottomLeft(panel).dy, lessThanOrEqualTo(367));
    expect(
      tester.getSize(find.byKey(const Key('message-list'))).height,
      greaterThan(0),
    );
    tester.view.resetViewInsets();
    await tester.pumpAndSettle();
    expect(
      tester.getTopLeft(panel).dy,
      greaterThanOrEqualTo(tester.getBottomLeft(plus).dy),
    );
    await tester.tap(find.byKey(const Key('composer')));
    await tester.pumpAndSettle();
    expect(panel, findsNothing);
    expect(c.read(draftProvider(1)), '手机上的草稿');
    await tester.tap(find.byKey(const Key('back')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('林知夏'));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('composer')))
          .controller!
          .text,
      '手机上的草稿',
    );
    await tester.tap(find.byKey(const Key('send-message')));
    await tester.pump();
    expect(c.read(engineProvider).sent, 1);
    expect(c.read(draftProvider(1)), isEmpty);
    expect(find.text('手机上的草稿'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'folding after switching chats in the sidebar keeps the selected draft',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final c = await mount(tester, const Size(951, 669));
      final list = find.byKey(const Key('conversation-list'));
      final composer = find.byKey(const Key('composer'));
      await tester.tap(
        find.descendant(of: list, matching: find.text('产品设计小组')),
      );
      await tester.pumpAndSettle();
      await tester.enterText(composer, '群聊草稿');
      await tester.tap(find.descendant(of: list, matching: find.text('林知夏')));
      await tester.pumpAndSettle();
      final id = c.read(selectedConversationProvider);
      await tester.enterText(composer, '私聊草稿');
      for (final size in [
        const Size(466, 678),
        const Size(669, 951),
        const Size(678, 466),
      ]) {
        tester.view.physicalSize = size;
        await tester.pumpAndSettle();
        expect(list, size.shortestSide >= 600 ? findsOneWidget : findsNothing);
        expect(c.read(selectedConversationProvider), id);
        expect(tester.widget<TextField>(composer).controller!.text, '私聊草稿');
      }
      expect(c.read(draftProvider(0)), '群聊草稿');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('iPhone edge swipe returns to the same list viewport', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final c = await mount(tester, const Size(390, 844));
    await tester.drag(
      find.byKey(const Key('conversation-list')),
      const Offset(0, -250),
    );
    await tester.pumpAndSettle();
    final list = tester.widget<ListView>(
      find.byKey(const Key('conversation-list')),
    );
    final offset = list.controller!.offset;
    await tester.tap(find.byType(ChatAvatar).hitTestable().first);
    await tester.pumpAndSettle();
    expect(c.read(selectedConversationProvider), isNotNull);
    await tester.dragFrom(const Offset(1, 300), const Offset(350, 0));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('conversation-list')), findsOneWidget);
    expect(c.read(selectedConversationProvider), isNull);
    expect(
      tester
          .widget<ListView>(find.byKey(const Key('conversation-list')))
          .controller!
          .offset,
      closeTo(offset, 1),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('the iOS search transition preserves edge-swipe back', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    await mount(tester, const Size(390, 844));
    final entry = find.byKey(const Key('open-chat-search'));
    await tester.tap(entry);
    await tester.pumpAndSettle();
    expect(tester.testTextInput.isVisible, isTrue);
    await tester.dragFrom(const Offset(1, 300), const Offset(350, 0));
    await tester.pumpAndSettle();
    expect(entry.hitTestable(), findsOneWidget);
    expect(find.byKey(const Key('search')), findsNothing);
    expect(tester.testTextInput.isVisible, isFalse);
  });

  for (final contacts in [false, true]) {
    testWidgets(
      'focused ${contacts ? "contacts" : "chats"} search, dismiss, clear and cancel',
      (tester) async {
        await mount(tester, const Size(375, 667));
        if (contacts) {
          await tester.tap(find.byKey(const Key('nav-contacts')));
          await tester.pumpAndSettle();
        }
        final field = find.byKey(Key(contacts ? 'contact-search' : 'search'));
        final list = find.byKey(
          Key(contacts ? 'contacts-list' : 'conversation-list'),
        );
        final entry = find.byKey(
          Key(contacts ? 'open-contact-search' : 'open-chat-search'),
        );
        expect(field, findsNothing);
        Finder hintText(Finder parent, String hint) => find.descendant(
          of: parent,
          matching: find.byWidgetPredicate(
            (widget) => widget is RichText && widget.text.toPlainText() == hint,
          ),
        );
        Color? hintColor(Finder parent, String hint) =>
            tester.widget<RichText>(hintText(parent, hint)).text.style?.color;
        double hintLeft(Finder parent, String hint) =>
            tester.getTopLeft(hintText(parent, hint)).dx;
        double iconCenter(Finder parent) => tester
            .getCenter(
              find.descendant(
                of: parent,
                matching: find.byIcon(Icons.search_rounded),
              ),
            )
            .dx;

        final entryHint = contacts ? '搜索昵称、备注、标签或账号' : '搜索';
        final pageHint = contacts ? entryHint : '搜索会话名称、备注或编号';
        final originalColor = hintColor(entry, entryHint);
        expect(originalColor, isNotNull);
        final origin = tester.getRect(entry);
        final labelX = hintLeft(entry, entryHint);
        final iconX = iconCenter(entry);
        final flight = find.byKey(const Key('search-bar-flight'));
        await tester.tap(entry);
        await tester.pump();
        await tester.pump();
        expect(tester.getRect(flight).top, closeTo(origin.top, 1));
        await tester.pump(const Duration(milliseconds: 110));
        final middle = tester.getRect(flight);
        expect(hintColor(flight, pageHint), originalColor);
        expect(hintLeft(flight, pageHint), closeTo(labelX, .01));
        expect(iconCenter(flight), closeTo(iconX, .01));
        await tester.pumpAndSettle();
        final destination = tester.getRect(field);
        expect(middle.top, lessThan(origin.top));
        expect(middle.top, greaterThan(destination.top));
        expect(middle.left, closeTo(origin.left, 1));
        expect(destination.left, closeTo(origin.left, 1));

        expect(hintColor(field, pageHint), originalColor);
        expect(iconCenter(field), closeTo(iconX, .01));
        expect(hintLeft(field, pageHint), closeTo(labelX, .01));
        final node = tester.widget<TextField>(field).focusNode!;
        expect(node.hasPrimaryFocus, isTrue);
        expect(tester.testTextInput.isVisible, isTrue);
        expect(find.byKey(const Key('main-navigation')), findsNothing);
        expect(list, findsNothing);
        expect(find.text('取消'), findsOneWidget);
        tester.testTextInput.enterText('林知夏');
        await tester.pump();
        expect(list, findsOneWidget);
        await tester.tap(find.byTooltip('清除搜索'));
        await tester.pumpAndSettle();
        await tester.tapAt(const Offset(80, 400));
        await tester.pumpAndSettle();
        expect(node.hasFocus, isFalse);
        expect(hintColor(field, pageHint), originalColor);
        expect(list, findsNothing);
        await tester.enterText(field, 'none-12345');
        await tester.pumpAndSettle();
        await tester.tapAt(const Offset(80, 400));
        await tester.pumpAndSettle();
        expect(node.hasFocus, isFalse);
        expect(tester.widget<TextField>(field).controller!.text, 'none-12345');
        await tester.tap(find.byTooltip('清除搜索'));
        await tester.pumpAndSettle();
        expect(node.hasFocus, isTrue);
        expect(list, findsNothing);
        await tester.enterText(field, '林知夏');
        await tester.pumpAndSettle();
        expect(list, findsOneWidget);
        await tester.tap(find.text('取消'));
        await tester.pump();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 90));
        final returning = tester.getRect(flight);
        expect(returning.top, greaterThan(destination.top));
        expect(returning.top, lessThan(origin.top));
        expect(returning.left, closeTo(origin.left, 1));
        await tester.pumpAndSettle();
        expect(entry, findsOneWidget);
        expect(field, findsNothing);
        expect(tester.testTextInput.isVisible, isFalse);
        expect(list, findsOneWidget);
        await tester.tap(entry);
        await tester.pumpAndSettle();
        expect(find.text('最近搜索'), findsOneWidget);
        await tester.tap(find.widgetWithText(ActionChip, '林知夏'));
        await tester.pumpAndSettle();
        expect(tester.widget<TextField>(field).controller!.text, '林知夏');
        expect(list, findsOneWidget);
        await tester.tap(find.byTooltip('清除搜索'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('清空'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('取消'));
        await tester.pumpAndSettle();
        await tester.tap(entry);
        await tester.pumpAndSettle();
        expect(find.text('最近搜索'), findsNothing);
        expect(find.byType(ActionChip), findsNothing);
      },
    );
  }

  testWidgets('mobile navigation, search and metrics work without overflow', (
    tester,
  ) async {
    final container = await mount(tester, const Size(390, 844));
    expect(find.byKey(const Key('conversation-list')), findsOneWidget);
    expect(find.text('实时接收'), findsNothing);
    expect(container.read(selectedConversationProvider), isNull);
    await tester.tap(find.byKey(const Key('open-chat-search')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('search')), '林知夏');
    await tester.pump();
    await tester.tap(find.text('林知夏').last);
    await tester.pump();
    expect(container.read(selectedConversationProvider), 1);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('mobile-composer-bar')), findsOneWidget);
    await tester.tap(find.byKey(const Key('back')));
    await tester.pumpAndSettle();
    expect(container.read(selectedConversationProvider), isNull);
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('search')))
          .controller!
          .text,
      '林知夏',
    );
    await tester.tap(find.text('取消'));
    await tester.pump();
    await tester.tap(find.byTooltip('查看性能指标'));
    await tester.pumpAndSettle();
    expect(find.text('目标吞吐量'), findsOneWidget);
    await tester.tap(find.text('3 秒/条'));
    await tester.pump();
    expect(container.read(mockRuntimeProvider).rate, 1 / 3);
    expect(container.read(mockRuntimeProvider).running, isFalse);
    await tester.tap(find.text('100 / s'));
    await tester.pump();
    expect(container.read(mockRuntimeProvider).rate, 100);
    expect(container.read(mockRuntimeProvider).running, isFalse);
    await tester.tap(find.text('5k / s'));
    await tester.pump();
    expect(container.read(mockRuntimeProvider).rate, 5000);
    await tester.ensureVisible(find.text('全量均匀随机'));
    await tester.pump();
    await tester.tap(find.text('全量均匀随机'));
    await tester.pump();
    expect(container.read(mockRuntimeProvider).pattern, TrafficPattern.uniform);
    expect(container.read(mockRuntimeProvider).running, isFalse);
    expect(container.read(mockRuntimeProvider).rate, 5000);
    expect(find.text('每个会话等概率接收，置顶会话仍排在前面。'), findsOneWidget);
    await tester.ensureVisible(find.text('热点模式'));
    await tester.pump();
    await tester.tap(find.text('热点模式'));
    await tester.pump();
    expect(container.read(mockRuntimeProvider).pattern, TrafficPattern.hotspot);
    expect(tester.takeException(), isNull);
  });
}
