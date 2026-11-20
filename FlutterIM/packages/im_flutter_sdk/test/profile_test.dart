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
      'avatar',
      'openAvatarEditor',
      'changeAvatar',
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
          case 'avatar':
            return [
              wire.ImAvatarImage(
                bytes: Uint8List.fromList([4, 5, 6]),
                remainingMilliseconds: 45000,
              ),
            ];
          case 'openAvatarEditor':
            return [
              wire.ImAvatarEditor(
                revision: 8,
                canManage: true,
                remainingMilliseconds: 60000,
                hasAvatar: true,
                name: '我的昵称',
                handle: '@me',
                image: Uint8List.fromList([9, 8, 7]),
              ),
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

    final avatar = await client.avatar('peer');
    expect(avatar?.bytes, [4, 5, 6]);
    expect(avatar?.remaining, const Duration(seconds: 45));

    final editor = await client.openAvatarEditor();
    expect(editor?.revision, 8);
    expect(editor?.name, '我的昵称');
    expect(editor?.handle, '@me');
    expect(editor?.image, [9, 8, 7]);

    await client.changeAvatar(revision: 8, displayName: '新昵称');
    expect(calls['changeAvatar'], [null, 8, null, null, null, '新昵称', null]);

    await client.changeAvatar(
      revision: 9,
      jpeg: Uint8List.fromList([0xff, 0xd8, 0xff]),
      width: 512,
      height: 512,
      action: 'remove',
    );
    expect(calls['changeAvatar'], [
      null,
      9,
      [0xff, 0xd8, 0xff],
      512,
      512,
      null,
      'remove',
    ]);
    await client.close();
  });
}
