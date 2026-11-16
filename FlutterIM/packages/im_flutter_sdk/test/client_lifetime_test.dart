import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:im_flutter_sdk/im_flutter_sdk.dart';
import 'package:im_flutter_sdk/src/messages.g.dart' as wire;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'cancel drains a waiting window and a failed client close can be retried',
    () async {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      void handle(String method, Future<Object?> Function(Object?) action) {
        final channel = BasicMessageChannel<Object?>(
          'dev.flutter.pigeon.im_flutter_sdk.ImHost.$method',
          wire.ImHost.pigeonChannelCodec,
        );
        messenger.setMockDecodedMessageHandler<Object?>(channel, action);
        addTearDown(
          () => messenger.setMockDecodedMessageHandler<Object?>(channel, null),
        );
      }

      final waiting = Completer<void>();
      final update = Completer<Object?>();
      var releasedWindows = 0;
      var closeAttempts = 0;
      handle('open', (_) async => [null]);
      handle(
        'restore',
        (_) async => [wire.ImSession(state: 'ready', userId: 'account')],
      );
      handle('openWindow', (_) async => ['window']);
      handle('nextUpdate', (_) {
        waiting.complete();
        return update.future;
      });
      handle('closeWindow', (args) async {
        expect(args, ['window']);
        releasedWindows++;
        update.complete(['closed', null, null]);
        return [null];
      });
      handle(
        'close',
        (_) async => ++closeAttempts == 1 ? ['busy', null, null] : [null],
      );

      final client = await ImClient.open(
        accountUrl: Uri.parse('https://example.test'),
        gatewayHost: 'example.test',
        gatewayPort: 7443,
      );
      await client.setForeground(false);
      await client.restoreSession();
      final subscription = client.watchConversations().listen(
        (_) => fail('late update'),
      );
      await waiting.future.timeout(const Duration(seconds: 3));
      await subscription.cancel();
      expect(releasedWindows, 1);
      await expectLater(client.close(), throwsA(isA<PlatformException>()));
      await Future.wait([client.close(), client.close()]);
      expect(closeAttempts, 2);
    },
  );
}
