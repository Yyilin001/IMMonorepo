import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/widgets.dart';
import 'package:material_ui/material_ui.dart' show FilledButton;
import 'package:integration_test/integration_test.dart';
import 'package:local_im/main.dart' as app;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('two Flutter clients exchange durable messages', (tester) async {
    // Drive the Flutter text fields through one IME while both real SDKs remain connected.
    tester.testTextInput.register();
    addTearDown(tester.testTextInput.unregister);
    const run = String.fromEnvironment('IM_E2E_RUN');
    expect(
      run,
      isNotEmpty,
      reason: 'Run tool/verify_shared_sdk.py with the isolated backend.',
    );
    final sender = Platform.isAndroid;
    final account = 'flutter_${run}_${sender ? "a" : "b"}';
    const password = String.fromEnvironment('IM_E2E_PASSWORD');
    const room = String.fromEnvironment('IM_E2E_ROOM');
    final hello = 'Android → iOS $run';
    final reply = 'iOS → Android $run';
    final ack = 'Android 已收到 $run';

    Future<void> until(Finder finder, String stage) async {
      final deadline = DateTime.now().add(const Duration(minutes: 2));
      while (finder.evaluate().isEmpty && DateTime.now().isBefore(deadline)) {
        final errors = tester
            .widgetList<Text>(find.byType(Text))
            .map((label) => label.data ?? '')
            .where(
              (s) => ['操作失败', '登录失败', '无法连接服务器', '本地存储暂不可用'].any(s.startsWith),
            );
        if (errors.isNotEmpty) fail('$stage: ${errors.first}');
        await tester.pump(const Duration(milliseconds: 250));
      }
      expect(finder, findsOneWidget, reason: stage);
      debugPrint("${Platform.operatingSystem}: $stage");
    }

    Finder bubble(String text) => find.descendant(
      of: find.byKey(const Key('shared-timeline')),
      matching: find.text(text),
    );
    Future<void> send(String text) async {
      final composer = find.byKey(const Key('composer'));
      await tester.tap(composer);
      await tester.pumpAndSettle();
      await tester.enterText(composer, text);
      await tester.pump(const Duration(milliseconds: 300));
      final field = tester.widget<EditableText>(
        find.descendant(
          of: find.byKey(const Key('composer')),
          matching: find.byType(EditableText),
        ),
      );
      expect(
        field.controller.text,
        text,
        reason: 'composer received the new draft',
      );
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();
      final button = find.byKey(const Key('send-message'));
      await tester.ensureVisible(button);
      await tester.tap(button);
      await tester.pump();
      final projected = find.descendant(
        of: find.byKey(const ValueKey('projected-message')),
        matching: find.text(text),
      );
      await until(projected, 'outgoing message confirmed by shared SDK');
    }

    await app.main();
    final entry = find.byWidgetPredicate(
      (w) =>
          w is FilledButton &&
          w.key == const Key('open-login') &&
          w.onPressed != null,
    );
    await until(entry, 'reference messages home');
    expect(find.byKey(const Key('main-navigation')), findsOneWidget);
    await tester.tap(entry);
    await tester.pumpAndSettle();
    final login = find.byKey(const Key('submit-login'));
    await until(login, 'login form');
    expect(find.byType(EditableText), findsNWidgets(2));
    expect(find.text('服务器设置'), findsNothing);
    await tester.enterText(find.byKey(const ValueKey('账号')), account);
    await tester.enterText(find.byKey(const ValueKey('密码')), password);
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pumpAndSettle();
    await tester.ensureVisible(login);
    await tester.tap(login);
    await until(find.byKey(const Key('main-navigation')), 'password sign-in');
    final tile = find.byKey(const ValueKey(room));
    await until(tile, 'signed in and synchronized the seeded conversation');
    if (!sender) {
      await until(find.text(hello), 'incoming preview in conversation list');
    }
    await tester.tap(tile.hitTestable());
    await tester.pumpAndSettle();
    await until(find.byKey(const Key('composer')), 'opened message timeline');
    if (sender) {
      await send(hello);
      await until(bubble(reply), 'received reply from iOS');
      await send(ack);
    } else {
      await until(bubble(hello), 'received from Android');
      await send(reply);
      await until(bubble(ack), 'Android confirmed receipt of reply');
    }
    // Wait for the confirmed text to survive closing and reopening its watch.
    await tester.pumpAndSettle();
    await tester.pageBack();
    await tester.pumpAndSettle();
    await until(tile, 'conversation list survived closing the timeline');
    await tester.tap(tile.hitTestable());
    await tester.pumpAndSettle();
    await until(bubble(reply), 'reply visible after reopening');
    await tester.pumpAndSettle();
    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('nav-contacts')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('open-contact-search')), findsOneWidget);
    await tester.tap(find.byKey(const Key('nav-me')));
    await tester.pumpAndSettle();
    final signOut = find.byKey(const Key('account-action'));
    await until(signOut, 'account actions');
    await tester.ensureVisible(signOut);
    await tester.tap(signOut);
    await until(entry, 'durable sign-out');
  }, timeout: const Timeout(Duration(minutes: 6)));
}
