import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:im_flutter_sdk/im_flutter_sdk.dart';
import 'package:im_flutter_sdk/src/messages.g.dart' as wire;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('profiles, aliases and the selected profile cross the bridge', () async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final calls = <String, List<Object?>>{};
    for (final method in [
      'open',
      'restore',
      'profiles',
      'openProfile',
      'saveAlias',
      'clearProfiles',
      'close',
    ]) {
      final channel = BasicMessageChannel<Object?>(
        'dev.flutter.pigeon.im_flutter_sdk.ImHost.$method',
        wire.ImHost.pigeonChannelCodec,
      );
      messenger.setMockDecodedMessageHandler<Object?>(channel, (args) async {
        calls[method] = args as List<Object?>? ?? const [];
        switch (method) {
          case 'restore':
            return [wire.ImSession(state: 'ready', userId: 'user')];
          case 'profiles':
            return [
              [
                wire.ImProfile(
                  page: 'contacts',
                  userId: 'peer',
                  name: '备注名',
                  handle: '@peer',
                  alias: '备注名',
                  aliasRevision: 3,
                  remainingMilliseconds: 120000,
                ),
              ],
            ];
          case 'openProfile':
            return [
              [
                wire.ImProfile(
                  page: 'selected',
                  userId: 'peer',
                  name: '群昵称',
                  handle: '@peer',
                  groupNickname: '群昵称',
                  groupNicknameRevision: 4,
                  remainingMilliseconds: 90000,
                  avatar: Uint8List.fromList([1, 2, 3]),
                ),
              ],
            ];
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
    await client.restoreSession();

    final rows = await client.profiles(
      page: 'contacts',
      context: 'relationship',
      userIds: ['peer'],
    );
    expect(rows.single.name, '备注名');
    expect(rows.single.aliasRevision, 3);
    expect(calls['profiles'], [
      'contacts',
      'relationship',
      null,
      ['peer'],
    ]);

    final selected = await client.openProfile(
      'peer',
      context: 'room',
      roomId: 'room',
    );
    expect(selected.single.name, '群昵称');
    expect(selected.single.avatar, [1, 2, 3]);
    expect(calls['openProfile'], ['peer', 'room', 'room']);

    await client.saveAlias('peer', alias: '新备注', revision: 3);
    expect(calls['saveAlias'], ['peer', '新备注', 3]);

    await client.clearProfiles('contacts');
    expect(calls['clearProfiles'], ['contacts']);
    await client.close();
  });
}
