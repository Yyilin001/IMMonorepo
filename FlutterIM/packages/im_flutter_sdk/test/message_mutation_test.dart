import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:im_flutter_sdk/im_flutter_sdk.dart';
import 'package:im_flutter_sdk/src/messages.g.dart' as wire;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('message actions carry the displayed message revision', () async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final calls = <Object?>[];
    for (final method in [
      'open',
      'cancelPendingSend',
      'recoverSend',
      'forwardMessage',
      'editMessage',
      'withdrawMessage',
      'close',
    ]) {
      final channel = BasicMessageChannel<Object?>(
        'dev.flutter.pigeon.im_flutter_sdk.ImHost.$method',
        wire.ImHost.pigeonChannelCodec,
      );
      messenger.setMockDecodedMessageHandler<Object?>(channel, (args) async {
        if (method != 'open' && method != 'close') {
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
    await client.forwardMessageToRooms('room', 'incoming', 3, [
      'second',
      'first',
    ]);
    await client.recoverSend('unknown', resend: false);
    await client.recoverSend('unsent', resend: true);
    await client.cancelPendingSend('discarded');
    await client.editMessage('room', 'message', 4, 'updated');
    await client.withdrawMessage('room', 'message', 5);
    await client.close();
    expect(calls, [
      [
        'forwardMessage',
        [
          'room',
          'incoming',
          3,
          ['second', 'first'],
        ],
      ],
      [
        'recoverSend',
        ['unknown', false],
      ],
      [
        'recoverSend',
        ['unsent', true],
      ],
      [
        'cancelPendingSend',
        ['discarded'],
      ],
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
