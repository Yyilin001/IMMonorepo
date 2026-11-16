import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_im/core/models.dart';
import 'package:local_im/mock_main.dart';
import 'package:local_im/state/im_providers.dart';
import 'package:local_im/ui/workspace.dart';
import 'package:material_ui/material_ui.dart';

import 'support.dart';

void main() {
  test('preferences survive serialization and tolerate missing or invalid saved fields', () {
    const value = AppPreferences(
      textSize: ChatTextSize.extraLarge,
      background: ChatBackground.warm,
      messageAnimations: false,
      haptics: false,
      unreadBadge: false,
      messagePreview: false,
    );
    expect(AppPreferences.decode(value.encode()).encode(), value.encode());
    for (final input in [
      null,
      'broken',
      '[]',
      '{"textSize":"unknown","background":3,"haptics":"no"}',
    ]) {
      expect(
        AppPreferences.decode(input).encode(),
        const AppPreferences().encode(),
      );
    }
  });

  test('settings update immediately, serialize saves, restore and recover after a failed write', () async {
    var saved = '';
    var fail = false;
    final gate = Completer<void>();
    var calls = 0;
    final c = ProviderContainer(
      overrides: [
        settingsPersistenceProvider.overrideWithValue(
          SettingsPersistence(
            write: (value) async {
              calls++;
              if (calls == 1) await gate.future;
              if (fail) throw StateError('disk unavailable');
              saved = value.encode();
            },
          ),
        ),
      ],
    );
    addTearDown(c.dispose);
    final controller = c.read(appSettingsProvider.notifier);
    final first = controller.update(const AppPreferences(haptics: false));
    final second = controller.update(
      const AppPreferences(haptics: true, messagePreview: false),
    );
    expect(c.read(appSettingsProvider).messagePreview, isFalse);
    expect(saved, isEmpty);
    gate.complete();
    await Future.wait([first, second]);
    expect(calls, 2);
    final restored = ProviderContainer(
      overrides: [
        settingsPersistenceProvider.overrideWithValue(
          SettingsPersistence(
            initial: AppPreferences.decode(saved),
            write: (_) async {},
          ),
        ),
      ],
    );
    addTearDown(restored.dispose);
    expect(restored.read(appSettingsProvider).messagePreview, isFalse);
    fail = true;
    await controller.update(const AppPreferences(unreadBadge: false));
    expect(c.read(settingsSaveErrorProvider), isNotNull);
    fail = false;
    await controller.retrySave();
    expect(c.read(settingsSaveErrorProvider), isNull);
    expect(AppPreferences.decode(saved).unreadBadge, isFalse);
  });

  test('default background respects explicit per-chat overrides including the current default', () async {
    final c = createContainer();
    addTearDown(c.dispose);
    c.read(chatBackgroundProvider(1).notifier).select(ChatBackground.light);
    await c
        .read(appSettingsProvider.notifier)
        .update(const AppPreferences(background: ChatBackground.mint));
    expect(c.read(chatBackgroundProvider(0)), ChatBackground.mint);
    expect(c.read(chatBackgroundProvider(1)), ChatBackground.light);
    c.read(chatBackgroundProvider(2).notifier).select(ChatBackground.warm);
    await c.read(appSettingsProvider.notifier).reset();
    expect(c.read(chatBackgroundProvider(0)), ChatBackground.light);
    expect(c.read(chatBackgroundProvider(2)), ChatBackground.warm);
  });

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

  for (final desktop in [false, true]) {
    testWidgets(
      '${desktop ? "desktop" : "phone"} personal and profile settings entry, controls, reset and message isolation',
      (tester) async {
        final c = await mount(tester, desktop: desktop);
        await tester.tap(find.byKey(const Key('nav-me')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('my-profile-card')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('open-app-settings')));
        await tester.pumpAndSettle();
        expect(find.byType(AppSettingsPage), findsOneWidget);
        var rebuilds = 0;
        debugOnRebuildDirtyWidget = (element, _) {
          if (element.widget is AppSettingsPage) rebuilds++;
        };
        for (var i = 0; i < 1000; i++) {
          c
              .read(messageActionsProvider)
              .receive(
                ChatMessage(
                  id: 'settings-load-$i',
                  conversationId: 9999,
                  text: '$i',
                  timestamp: DateTime.now(),
                ),
              );
        }
        await tester.pump();
        expect(rebuilds, 0);
        debugOnRebuildDirtyWidget = null;
        await tester.tap(find.byKey(const Key('settings-appearance')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('settings-font-large')));
        await tester.pump();
        expect(c.read(appSettingsProvider).textSize, ChatTextSize.large);
        await tester.ensureVisible(
          find.byKey(const ValueKey('settings-default-background-mint')),
        );
        await tester.tap(
          find.byKey(const ValueKey('settings-default-background-mint')),
        );
        await tester.pump();
        expect(c.read(chatBackgroundProvider(0)), ChatBackground.mint);
        await tester.pageBack();
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.byKey(const Key('settings-reset')));
        await tester.tap(find.byKey(const Key('settings-reset')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('取消'));
        await tester.pumpAndSettle();
        expect(c.read(appSettingsProvider).textSize, ChatTextSize.large);
        await tester.tap(find.byKey(const Key('settings-reset')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('confirm-reset-settings')));
        await tester.pumpAndSettle();
        expect(
          c.read(appSettingsProvider).encode(),
          const AppPreferences().encode(),
        );
        expect(c.read(engineProvider).received, 1000);
        await tester.pageBack();
        await tester.pumpAndSettle();
        await tester.pageBack();
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('open-app-settings')));
        await tester.pumpAndSettle();
        expect(find.byType(AppSettingsPage), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'privacy, badge, font, background, animation and haptic controls affect actual chat UI',
    (tester) async {
      final c = await mount(tester);
      final settings = c.read(appSettingsProvider.notifier);
      final preview = c.read(engineProvider).conversation(0).preview;
      await settings.update(
        const AppPreferences(
          messagePreview: false,
          unreadBadge: false,
          textSize: ChatTextSize.extraLarge,
          background: ChatBackground.warm,
          messageAnimations: false,
          haptics: false,
        ),
      );
      await tester.pump();
      expect(find.byKey(const Key('total-unread-badge')), findsNothing);
      expect(find.text(preview), findsNothing);
      expect(find.text('消息内容已隐藏'), findsWidgets);
      await tester.tap(find.text('产品设计小组'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<ColoredBox>(find.byKey(const Key('chat-background')))
            .color,
        const Color(0xFFFAF1E5),
      );
      c
          .read(messageActionsProvider)
          .receive(
            ChatMessage(
              id: 'preference-text',
              conversationId: 0,
              text: '字号和触感验证',
              timestamp: DateTime.now(),
            ),
          );
      await tester.pump();
      expect(tester.widget<Text>(find.text('字号和触感验证')).style!.fontSize, 20);
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('composer')))
            .style!
            .fontSize,
        20,
      );
      expect(
        find.byKey(const ValueKey('message-entrance-preference-text')),
        findsNothing,
      );
      var haptics = 0;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'HapticFeedback.vibrate') haptics++;
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      await tester.longPress(find.text('字号和触感验证'));
      await tester.pumpAndSettle();
      expect(haptics, 0);
      Navigator.of(tester.element(find.text('字号和触感验证'))).pop();
      await tester.pumpAndSettle();
      await settings.update(
        c.read(appSettingsProvider).copyWith(haptics: true),
      );
      await tester.longPress(find.text('字号和触感验证'));
      await tester.pumpAndSettle();
      expect(haptics, greaterThan(0));
      Navigator.of(tester.element(find.text('字号和触感验证'))).pop();
      await tester.pumpAndSettle();
      await settings.update(
        c.read(appSettingsProvider).copyWith(messageAnimations: true),
      );
      c
          .read(messageActionsProvider)
          .receive(
            ChatMessage(
              id: 'settings-animation',
              conversationId: 0,
              text: '动画开关验证',
              timestamp: DateTime.now(),
            ),
          );
      await tester.pump();
      final fade = find.descendant(
        of: find.byKey(const ValueKey('message-entrance-settings-animation')),
        matching: find.byType(FadeTransition),
      );
      expect(tester.widget<FadeTransition>(fade).opacity.value, lessThan(1));
      await settings.update(
        c.read(appSettingsProvider).copyWith(messageAnimations: false),
      );
      await tester.pump();
      expect(tester.widget<FadeTransition>(fade).opacity.value, 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'long sender names leave the timestamp visible on a narrow phone',
    (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      final c = createContainer();
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
        c.dispose();
      });
      const name = '长昵称的产品设计与工程协作讨论小组';
      await c
          .read(contactEditActionsProvider)
          .save(1, remark: name, tags: [], phone: '', description: '');
      await c
          .read(appSettingsProvider.notifier)
          .update(const AppPreferences(textSize: ChatTextSize.extraLarge));
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: MaterialApp(
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: TextScaler.linear(1.6)),
              child: child!,
            ),
            home: const Scaffold(body: ChatPane(mobile: true)),
          ),
        ),
      );
      await tester.pumpAndSettle();
      c
          .read(messageActionsProvider)
          .receive(
            ChatMessage(
              id: 'long-sender',
              conversationId: 0,
              senderId: 1,
              text: '你好',
              timestamp: DateTime(2026, 11, 14, 9, 35),
            ),
          );
      await tester.pumpAndSettle();
      final bubble = find.byWidgetPredicate(
        (w) =>
            w.runtimeType.toString() == '_MessageBubble' &&
            w.key == const ValueKey('long-sender'),
      );
      final sender = find.descendant(of: bubble, matching: find.text(name));
      final time = find.descendant(of: bubble, matching: find.text('09:35'));
      expect(
        tester.getSize(
          find.descendant(of: bubble, matching: find.byType(ChatAvatar)),
        ),
        const Size.square(44),
      );
      expect(tester.widget<Text>(sender).style!.fontSize, 19);
      expect(tester.getRect(sender).right, lessThan(tester.getRect(time).left));
      expect(tester.getRect(time).right, lessThanOrEqualTo(320));
      expect(tester.takeException(), isNull);
    },
  );

  for (final scale in [1.0, 1.6]) {
    testWidgets('settings pages work at 320px and text scale $scale', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(320, 568);
      tester.view.devicePixelRatio = 1;
      final c = createContainer();
      addTearDown(() {
        c.dispose();
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: MaterialApp(
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: TextScaler.linear(scale)),
              child: child!,
            ),
            home: const AppSettingsPage(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const Key('settings-appearance')));
      await tester.tap(find.byKey(const Key('settings-appearance')));
      await tester.pumpAndSettle();
      await tester.ensureVisible(
        find.byKey(const ValueKey('settings-font-extraLarge')),
      );
      await tester.tap(find.byKey(const ValueKey('settings-font-extraLarge')));
      await tester.pump();
      await tester.scrollUntilVisible(
        find.byKey(const Key('settings-message-animation')),
        180,
      );
      await tester.tap(find.byKey(const Key('settings-message-animation')));
      await tester.pump();
      expect(c.read(appSettingsProvider).messageAnimations, isFalse);
      expect(tester.takeException(), isNull);
      await tester.pageBack();
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const Key('settings-privacy')));
      await tester.tap(find.byKey(const Key('settings-privacy')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('settings-unread-badge')));
      await tester.ensureVisible(
        find.byKey(const Key('settings-message-preview')),
      );
      await tester.tap(find.byKey(const Key('settings-message-preview')));
      await tester.pump();
      expect(c.read(appSettingsProvider).unreadBadge, isFalse);
      expect(c.read(appSettingsProvider).messagePreview, isFalse);
      expect(tester.takeException(), isNull);
    });
  }
}
