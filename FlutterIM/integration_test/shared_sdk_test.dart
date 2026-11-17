import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart' show PlatformException;
import 'package:im_flutter_sdk/src/messages.g.dart' as wire;

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
    // Exercise the real platform binding and shared transfer services using an
    // app-owned fixture in place of the external document picker.
    final mediaHost = wire.ImHost();
    for (final origin in ['android', 'ios']) {
      final name = 'payload-$origin-$run.bin';
      final caption = '附件 $origin $run';
      final verified = '附件字节已校验 $origin $run';
      final bytes = Uint8List.fromList(
        List.generate(280001, (i) => (i * 17 + origin.length) & 255),
      );
      final directory = await Directory.systemTemp.createTemp(
        'im-paired-media-',
      );
      try {
        if (origin == Platform.operatingSystem) {
          final source = File('${directory.path}/$name');
          await source.writeAsBytes(bytes);
          await mediaHost.sendAttachment(
            room,
            source.path,
            name,
            'application/octet-stream',
            caption,
          );
          await until(
            bubble(name),
            'uploaded attachment reached the sender timeline',
          );
          await until(
            bubble(verified),
            'peer verified exported attachment bytes',
          );
        } else {
          await until(
            bubble(name),
            'attachment and filename arrived at receiver',
          );
          final timeline = await mediaHost.openWindow(room);
          late final wire.ImMessage message;
          try {
            final view = await mediaHost.nextUpdate(timeline);
            message = view.messages.singleWhere(
              (m) => m.text == caption && m.hasMedia,
            );
          } finally {
            await mediaHost.closeWindow(timeline);
          }
          final media = message.attachments.single;
          expect(media.name, name);
          expect(media.bytes, bytes.length);
          await mediaHost.downloadAttachment(room, message.id, media.id);
          final output = File('${directory.path}/export.bin');
          final deadline = DateTime.now().add(const Duration(minutes: 2));
          while (true) {
            try {
              await mediaHost.exportAttachment(
                room,
                message.id,
                media.id,
                output.path,
              );
              break;
            } on PlatformException {
              if (DateTime.now().isAfter(deadline)) rethrow;
              await tester.pump(const Duration(milliseconds: 500));
            }
          }
          expect(await output.readAsBytes(), orderedEquals(bytes));
          await send(verified);
        }
      } finally {
        await directory.delete(recursive: true);
      }
    }
    // Wait for the confirmed text to survive closing and reopening its watch.
    await tester.pumpAndSettle();
    await tester.pageBack();
    await tester.pumpAndSettle();
    await until(tile, 'conversation list survived closing the timeline');
    await tester.tap(tile.hitTestable());
    await tester.pumpAndSettle();
    await until(
      bubble('附件字节已校验 ios $run'),
      'attachment acknowledgement visible after reopening',
    );
    final destinations = sender
        ? const [
            String.fromEnvironment('IM_ANDROID_FORWARD_FIRST'),
            String.fromEnvironment('IM_ANDROID_FORWARD_SECOND'),
          ]
        : const [
            String.fromEnvironment('IM_IOS_FORWARD_FIRST'),
            String.fromEnvironment('IM_IOS_FORWARD_SECOND'),
          ];
    // Select the newest confirmed message, then verify each server projection.
    final timeline = await mediaHost.openWindow(room);
    late final wire.ImMessage source;
    try {
      source = (await mediaHost.nextUpdate(timeline)).messages
          .singleWhere((m) => m.text == '附件字节已校验 ios $run');
    } finally {
      await mediaHost.closeWindow(timeline);
    }
    final menu = find.descendant(
      of: find.byKey(ValueKey(source.id)),
      matching: find.byTooltip('消息操作'),
    );
    await tester.ensureVisible(menu);
    await tester.tap(menu);
    await tester.pumpAndSettle();
    await tester.tap(find.text('转发'));
    await tester.pumpAndSettle();
    for (final id in destinations) {
      final choice = find.byKey(ValueKey('forward-target-$id'));
      await tester.ensureVisible(choice);
      await tester.tap(choice);
      await tester.pump();
    }
    await tester.tap(find.text('转发（2/10）'));
    await tester.pumpAndSettle();
    await tester.pageBack();
    await tester.pumpAndSettle();
    for (final id in destinations) {
      final destination = find.byKey(ValueKey(id));
      await until(destination, 'forward destination in conversation list');
      await tester.ensureVisible(destination);
      await tester.tap(destination);
      await until(bubble(source.text), 'forward delivered to destination');
      await until(bubble('转发的消息'), 'destination retained forward attribution');
      await tester.pageBack();
      await tester.pumpAndSettle();
    }
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
