import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:im_flutter_sdk/im_flutter_sdk.dart';
import 'package:im_flutter_sdk/src/messages.g.dart' as wire;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('edit and withdrawal carry the displayed message revision', () async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final calls = <Object?>[];
    for (final method in ['open', 'editMessage', 'withdrawMessage', 'close']) {
      final channel = BasicMessageChannel<Object?>(
        'dev.flutter.pigeon.im_flutter_sdk.ImHost.$method',
        wire.ImHost.pigeonChannelCodec,
      );
      messenger.setMockDecodedMessageHandler<Object?>(channel, (args) async {
        if (method == 'editMessage' || method == 'withdrawMessage') {
          calls.add([method, args]);
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
    await client.editMessage('room', 'message', 4, 'updated');
    await client.withdrawMessage('room', 'message', 5);
    await client.close();
    expect(calls, [
      [
        'editMessage',
        ['room', 'message', 4, 'updated'],
      ],
      [
        'withdrawMessage',
        ['room', 'message', 5],
      ],
    ]);
  });
}
