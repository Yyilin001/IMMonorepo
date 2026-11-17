import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:im_flutter_sdk/im_flutter_sdk.dart';
import 'package:im_flutter_sdk/src/messages.g.dart' as wire;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('invitations, previews and decisions cross the bridge', () async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final calls = <String, List<Object?>>{};
    for (final method in [
      'open',
      'restore',
      'invitations',
      'previewInvite',
      'refreshInvite',
      'inviteAction',
      'submitJoin',
      'cancelJoin',
      'muteMember',
      'messageReaders',
      'updateGroupPermissions',
      'moderateMemberRemoval',
      'groupNickname',
      'saveGroupNickname',
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
          case 'invitations':
            return [
              wire.ImCommunity(
                roomId: 'room',
                invites: [
                  wire.ImInvite(
                    id: 'invite',
                    url: 'iim://group-invite?token=secret',
                    expires: 7200000,
                    used: 3,
                    maximum: 100,
                  ),
                ],
                requests: [
                  wire.ImJoinRequest(
                    id: 'request',
                    userId: 'peer',
                    note: '想加入',
                    state: 'pending',
                  ),
                ],
                hasMore: true,
              ),
            ];
          case 'groupNickname':
            return [
              wire.ImGroupNickname(
                roomId: 'room',
                name: '群里的我',
                revision: 3,
              ),
            ];
          case 'messageReaders':
            return [
              wire.ImReaders(
                roomId: 'room',
                messageId: 'message',
                users: ['a', 'b'],
                hasNext: true,
                remainingMilliseconds: 30000,
              ),
            ];
          case 'previewInvite':
            return [
              wire.ImCommunity(
                roomId: 'room',
                invites: [],
                requests: [],
                hasMore: false,
                preview: wire.ImInvitePreview(
                  roomId: 'room',
                  title: '测试群',
                  member: false,
                  canSubmit: true,
                  canCancel: false,
                ),
              ),
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

    final page = await client.invitations('room');
    expect(page.roomId, 'room');
    expect(page.invites.single.used, 3);
    expect(page.invites.single.maximum, 100);
    expect(page.requests.single.note, '想加入');
    expect(page.hasMore, true);
    expect(calls['invitations'], ['room']);

    final preview = await client.previewInvite(
      ' iim://group-invite?token=secret ',
    );
    expect(preview.preview?.title, '测试群');
    expect(preview.preview?.canSubmit, true);
    expect(calls['previewInvite'], ['iim://group-invite?token=secret']);

    await client.inviteAction('room', 7, 'create');
    expect(calls['inviteAction'], ['room', 7, 'create', null, null]);
    await client.inviteAction('room', 7, 'approve', intentId: 'request');
    expect(calls['inviteAction'], ['room', 7, 'approve', 'request', null]);

    await client.submitJoin('说明');
    expect(calls['submitJoin'], ['说明']);
    await client.cancelJoin('room');
    expect(calls['cancelJoin'], ['room']);
    await client.muteMember('room', 'peer', 7);
    expect(calls['muteMember'], ['room', 'peer', 7]);
    final readers = await client.messageReaders('room', 'message');
    expect(readers.users, ['a', 'b']);
    expect(readers.hasNext, true);
    expect(readers.remainingMilliseconds, 30000);
    expect(calls['messageReaders'], ['room', 'message', false]);
    await client.messageReaders('room', 'message', next: true);
    expect(calls['messageReaders'], ['room', 'message', true]);

    await client.updateGroupPermissions('room', 7, 'member', {
      'send_messages',
    });
    expect(calls['updateGroupPermissions'], [
      'room',
      7,
      'member',
      ['send_messages'],
    ]);
    await client.moderateMemberRemoval('room', 'peer', 7);
    expect(calls['moderateMemberRemoval'], ['room', 'peer', 7]);

    final nickname = await client.groupNickname('room');
    expect(nickname?.name, '群里的我');
    expect(nickname?.revision, 3);
    expect(calls['groupNickname'], ['room']);
    await client.saveGroupNickname('room', '新群昵称', revision: 3);
    expect(calls['saveGroupNickname'], ['room', '新群昵称', 3]);
    await client.close();
  });
}
