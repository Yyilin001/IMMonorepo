import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:im_flutter_sdk/im_flutter_sdk.dart';
import 'package:im_flutter_sdk/src/messages.g.dart' as wire;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('registration forwards the public identity and publishes the session', () async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final calls = <Object?>[];
    final lifecycle = <Object?>[];
    for (final method in ['open', 'register', 'passwordLifecycle', 'close']) {
      final channel = BasicMessageChannel<Object?>(
        'dev.flutter.pigeon.im_flutter_sdk.ImHost.$method',
        wire.ImHost.pigeonChannelCodec,
      );
      messenger.setMockDecodedMessageHandler<Object?>(channel, (args) async {
        switch (method) {
          case 'register':
            calls.add(args);
            return [wire.ImSession(state: 'ready', userId: 'user')];
          case 'passwordLifecycle':
            lifecycle.add(args);
        }
        return [null];
      });
      addTearDown(() => messenger.setMockDecodedMessageHandler(channel, null));
    }
    final client = await ImClient.open(
      accountUrl: Uri.parse('https://example.test'),
      gatewayHost: 'example.test',
      gatewayPort: 7443,
    );
    await client.register('alice', 'a-long-password', '@alice', 'Alice');
    expect(calls.single, ['alice', 'a-long-password', '@alice', 'Alice']);
    expect(client.session.userId, 'user');
    await client.passwordLifecycle(
      account: 'alice',
      action: 'change',
      currentPassword: 'old-password',
      newPassword: 'new-password',
    );
    expect(lifecycle.single, [
      'alice',
      'change',
      'old-password',
      'new-password',
      null,
    ]);
    await client.close();
  });
}
