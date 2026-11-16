import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:local_im/core/models.dart';
import 'package:local_im/mock_main.dart';
import 'package:local_im/state/im_providers.dart';
import 'package:local_im/ui/workspace.dart';

import 'support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('directory is stable, searchable and independent of message state', () {
    final c = createContainer();
    addTearDown(c.dispose);
    final directory = c.read(contactDirectoryProvider);
    expect(directory.friends.length + directory.groups.length, c.read(engineProvider).contactCount);
    expect(directory.friends.every((p) => !p.isGroup), isTrue);
    expect(directory.groups.every((p) => p.isGroup), isTrue);
    final profiles = c.read(contactResultsProvider);
    var changes = 0;
    c.listen(contactResultsProvider, (_, _) => changes++);
    for (var i = 0; i < 1000; i++) {
      c
          .read(messageActionsProvider)
          .receive(
            ChatMessage(
              id: 'directory-$i',
              conversationId: 9999,
              text: '$i',
              timestamp: DateTime.now(),
            ),
          );
    }
    expect(identical(profiles, c.read(contactResultsProvider)), isTrue);
    expect(changes, 0);
    expect(c.read(contactProfileProvider(9999).exists), isFalse);
    expect(c.read(chatSessionProvider(9999).exists), isFalse);
    c.read(contactFilterProvider.notifier).filter(query: ' RIPPLE_00001 ');
    expect(c.read(contactResultsProvider).single.id, 1);
    c.read(contactFilterProvider.notifier).filter(query: '', groups: true);
    expect(c.read(contactResultsProvider).length, directory.groups.length);
    expect(c.read(contactProfileProvider(0)).memberCount, 12);
    expect(() => directory.profile(-1), throwsRangeError);
  });

  test('personal edits notify only personal state and reject empty names', () {
    final c = createContainer();
    addTearDown(c.dispose);
    var personal = 0, contacts = 0;
    c.listen(myProfileProvider, (_, _) => personal++);
    c.listen(contactResultsProvider, (_, _) => contacts++);
    c
        .read(myProfileProvider.notifier)
        .save(name: '  小林 ', region: ' 杭州 ', bio: ' 你好 ');
    expect(c.read(myProfileProvider).name, '小林');
    expect(c.read(myProfileProvider).region, '杭州');
    expect(c.read(myProfileProvider).bio, '你好');
    expect((personal, contacts), (1, 0));
    c
        .read(myProfileProvider.notifier)
        .save(name: '小林', region: '杭州', bio: '你好');
    expect(personal, 1);
    expect(
      () => c
          .read(myProfileProvider.notifier)
          .save(name: ' ', region: '', bio: ''),
      throwsArgumentError,
    );
    expect(c.read(myProfileProvider).name, '小林');
  });

  Future<ProviderContainer> mount(
    WidgetTester tester, {
    bool desktop = false,
  }) async {
    tester.view.physicalSize = desktop
        ? const Size(1380, 900)
        : const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    final c = createContainer();
    addTearDown(() {
      debugOnRebuildDirtyWidget = null;
      c.dispose();
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    await tester.pumpWidget(
      UncontrolledProviderScope(container: c, child: const LocalImApp()),
    );
    await tester.pumpAndSettle();
    return c;
  }

  testWidgets(
    'contacts profile chat and back preserve search and do not duplicate chat',
    (tester) async {
      final c = await mount(tester);
      await tester.tap(find.byKey(const Key('nav-contacts')));
      await tester.pumpAndSettle();
      expect(find.byType(ChatAvatar).evaluate().length, lessThan(30));
      await tester.tap(find.byKey(const Key('open-contact-search')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('contact-search')), '林知夏');
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('contact-1')));
      await tester.pumpAndSettle();
      expect(find.text('个人资料'), findsOneWidget);
      expect(find.text('ripple_00001'), findsOneWidget);
      await tester.tap(find.byKey(const Key('profile-send-message')));
      await tester.pumpAndSettle();
      expect(c.read(selectedConversationProvider), 1);
      expect(find.byKey(const Key('composer')), findsOneWidget);
      await tester.tap(find.byKey(const Key('chat-profile')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('profile-send-message')));
      await tester.pumpAndSettle();
      expect(c.read(selectedConversationProvider), 1);
      await tester.tap(find.byKey(const Key('back')));
      await tester.pumpAndSettle();
      expect(find.text('个人资料'), findsOneWidget);
      expect(c.read(selectedConversationProvider), isNull);
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('contact-search')))
            .controller!
            .text,
        '林知夏',
      );
      expect(tester.takeException(), isNull);
    },
  );

  for (final group in [false, true]) {
    testWidgets(
      'message avatar opens the ${group ? "group member" : "contact"} profile and preserves the reading position',
      (tester) async {
        final c = await mount(tester);
        final id = group ? 0 : 1;
        final name = c.read(contactDisplayNameProvider(id));
        await tester.tap(find.text(name));
        await tester.pumpAndSettle();
        final scroll = tester
            .widget<CustomScrollView>(find.byKey(const Key('message-list')))
            .controller!;
        scroll.jumpTo(100);
        await tester.pumpAndSettle();
        final offset = scroll.offset;
        final messages = c.read(timelineStoreProvider(id)).value;
        final visible = messages
            .where((m) => !m.isMine)
            .firstWhere(
              (m) => find
                  .descendant(
                    of: find.byKey(ValueKey(m.id)),
                    matching: find.byType(ChatAvatar),
                  )
                  .hitTestable()
                  .evaluate()
                  .isNotEmpty,
            );
        final senderId = visible.senderId!;
        if (group) {
          expect(senderId, isNot(id));
          expect(
            messages
                .where((m) => !m.isMine)
                .map((m) => m.senderId)
                .toSet()
                .length,
            greaterThan(1),
          );
        }
        final senderName = c.read(contactDisplayNameProvider(senderId));
        final bubble = find.byKey(ValueKey(visible.id));
        final avatar = find.descendant(
          of: bubble,
          matching: find.bySemanticsLabel('查看$senderName的资料'),
        );
        expect(
          tester
              .widget<ChatAvatar>(
                find.descendant(of: bubble, matching: find.byType(ChatAvatar)),
              )
              .id,
          senderId,
        );
        expect(
          find.descendant(of: bubble, matching: find.text(senderName)),
          findsOneWidget,
        );
        await tester.tap(avatar);
        await tester.pumpAndSettle();
        expect(find.text('个人资料'), findsOneWidget);
        expect(
          tester.widget<ContactProfilePage>(find.byType(ContactProfilePage)).id,
          senderId,
        );
        await tester.pageBack();
        await tester.pumpAndSettle();
        expect(c.read(selectedConversationProvider), id);
        expect(scroll.offset, offset);
        expect(avatar, findsOneWidget);
        if (group) {
          await tester.tap(avatar);
          await tester.pumpAndSettle();
          await tester.tap(find.byKey(const Key('profile-send-message')));
          await tester.pumpAndSettle();
          expect(c.read(selectedConversationProvider), senderId);
        }
      },
    );
  }

  testWidgets('group directory opens group details and matching conversation', (
    tester,
  ) async {
    final c = await mount(tester);
    await tester.tap(find.byKey(const Key('nav-contacts')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('群聊'));
    await tester.pump();
    await tester.tap(find.byKey(const Key('open-contact-search')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('contact-search')),
      'no-result',
    );
    await tester.pump();
    expect(find.byKey(const Key('contacts-empty')), findsOneWidget);
    await tester.enterText(
      find.byKey(const Key('contact-search')),
      'group_00000',
    );
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('contact-0')));
    await tester.pumpAndSettle();
    expect(find.text('群聊资料'), findsOneWidget);
    expect(find.text('12 人'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('group-member-me')));
    await tester.pumpAndSettle();
    expect(find.text('我的资料'), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('查看全部成员'));
    await tester.tap(find.text('查看全部成员'));
    await tester.pumpAndSettle();
    final member = find.byKey(const ValueKey('group-member-21'));
    await tester.ensureVisible(member);
    final name = c.read(contactDisplayNameProvider(21));
    expect(
      find.descendant(of: member, matching: find.text(name)),
      findsOneWidget,
    );
    final avatar = find.descendant(
      of: member,
      matching: find.byType(ChatAvatar),
    );
    expect(tester.widget<ChatAvatar>(avatar).id, 21);
    await tester.tap(avatar);
    await tester.pumpAndSettle();
    expect(find.text('个人资料'), findsOneWidget);
    expect(find.text('ripple_00021'), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(member.hitTestable(), findsOneWidget);
    await tester.scrollUntilVisible(
      find.byKey(const Key('profile-send-message')),
      -220,
    );

    await tester.tap(find.byKey(const Key('profile-send-message')));
    await tester.pumpAndSettle();
    expect(c.read(selectedConversationProvider), 0);
    await tester.tap(find.byKey(const Key('chat-profile')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('group-member-1')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('profile-send-message')));
    await tester.pumpAndSettle();
    expect(c.read(selectedConversationProvider), 1);
    expect(find.byKey(const Key('composer')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'personal profile validates saves synchronizes and cancels edits',
    (tester) async {
      final c = await mount(tester);
      await tester.tap(find.byKey(const Key('nav-me')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('my-profile-card')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('profile-edit')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('profile-name')), ' ');
      await tester.tap(find.byKey(const Key('save-profile')));
      await tester.pump();
      expect(find.text('请输入昵称'), findsOneWidget);
      await tester.enterText(find.byKey(const Key('profile-name')), '新的昵称');
      await tester.enterText(find.byKey(const Key('profile-region')), '杭州');
      await tester.enterText(find.byKey(const Key('profile-bio')), '保持好奇');
      await tester.tap(find.byKey(const Key('save-profile')));
      await tester.pumpAndSettle();
      expect(find.text('我的资料'), findsOneWidget);
      expect(find.text('新的昵称'), findsWidgets);
      expect(c.read(myProfileProvider).bio, '保持好奇');
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.text('新的昵称'), findsOneWidget);
      await tester.tap(find.byKey(const Key('edit-my-profile')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('profile-name')), '未保存的修改');
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(c.read(myProfileProvider).name, '新的昵称');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'contact tab ignores live traffic while state still commits per message',
    (tester) async {
      final c = await mount(tester);
      await tester.tap(find.byKey(const Key('nav-contacts')));
      await tester.pumpAndSettle();
      final builds = <String>[];
      debugOnRebuildDirtyWidget = (element, _) =>
          builds.add(element.widget.runtimeType.toString());
      var notifications = 0;
      c.listen(conversationRowProvider(3), (_, _) => notifications++);
      for (var i = 0; i < 1000; i++) {
        c
            .read(messageActionsProvider)
            .receive(
              ChatMessage(
                id: 'hidden-$i',
                conversationId: 9999,
                text: '$i',
                timestamp: DateTime.now(),
              ),
            );
        expect(notifications, i + 1);
      }
      await tester.pump();
      expect(builds, isNot(contains('ContactsPane')));
      expect(builds, isNot(contains('ListTile')));
      expect(builds, isNot(contains('_ConversationRow')));
      expect(c.read(engineProvider).received, 1000);
    },
  );

  testWidgets(
    'desktop sections open profiles and return to the matching chat',
    (tester) async {
      final c = await mount(tester, desktop: true);
      await tester.tap(find.byKey(const Key('nav-contacts')));
      await tester.pumpAndSettle();
      expect(c.read(selectedConversationProvider), isNull);
      await tester.enterText(find.byKey(const Key('contact-search')), '陈一舟');
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('contact-3')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('profile-send-message')));
      await tester.pumpAndSettle();
      expect(c.read(workspaceSectionProvider), WorkspaceSection.messages);
      expect(c.read(selectedConversationProvider), 3);
      expect(find.byKey(const Key('composer')), findsOneWidget);
      await tester.tap(find.byKey(const Key('nav-me')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('my-profile-card')), findsOneWidget);
      expect(c.read(selectedConversationProvider), isNull);
      await tester.tap(find.byKey(const Key('nav-messages')));
      await tester.pumpAndSettle();
      expect(c.read(selectedConversationProvider), 3);
      expect(tester.takeException(), isNull);
    },
  );
}
