import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:im_flutter_sdk/im_flutter_sdk.dart';
import 'package:im_flutter_sdk/src/messages.g.dart' as wire;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'transfer snapshots preserve unknown byte counts and SDK actions',
    () async {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      for (final method in ['open', 'transfers', 'transferAction', 'close']) {
        final channel = BasicMessageChannel<Object?>(
          'dev.flutter.pigeon.im_flutter_sdk.ImHost.$method',
          wire.ImHost.pigeonChannelCodec,
        );
        messenger.setMockDecodedMessageHandler<Object?>(channel, (args) async {
          if (method == 'transfers') {
            return [
              [
                wire.Transfer(
                  id: 'job',
                  name: 'note.txt',
                  kind: 'download',
                  phase: 'waitingRetry',
                  total: null,
                  confirmed: 17,
                  actions: ['retry'],
                ),
              ],
            ];
          }
          if (method == 'transferAction') expect(args, ['job', 'retry']);
          return [null];
        });
        addTearDown(
          () => messenger.setMockDecodedMessageHandler(channel, null),
        );
      }
      final client = await ImClient.open(
        accountUrl: Uri.parse('https://example.test'),
        gatewayHost: 'example.test',
        gatewayPort: 7443,
      );
      final row = (await client.transfers()).single;
      expect(row.total, isNull);
      expect(row.confirmed, 17);
      expect(row.phase, 'waitingRetry');
      expect(row.actions, ['retry']);
      await client.transferAction(row.id, row.actions.single);
      await client.close();
    },
  );
}
