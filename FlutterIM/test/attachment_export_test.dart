import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:local_im/state/attachment_export.dart';

void main() {
  for (final cancelled in [false, true]) {
    test(
      'isolates the selected filename and cleans up after picker (cancelled=$cancelled)',
      () async {
        late File staging;
        final result = await saveAttachmentCopy(
          name: '../../a.txt',
          write: (path) async {
            staging = File(path);
            expect(staging.parent.parent.path, Directory.systemTemp.path);
            await staging.writeAsString('payload');
          },
          chooseDestination: (path) async {
            expect(await File(path).readAsString(), 'payload');
            return cancelled ? null : 'saved';
          },
        );
        expect(result, cancelled ? null : 'saved');
        expect(await staging.parent.exists(), false);
      },
    );
  }
  test('a failed SDK read never offers a partial copy', () async {
    late File staging;
    await expectLater(
      saveAttachmentCopy(
        name: '..',
        write: (path) async {
          staging = File(path);
          await staging.writeAsString('partial');
          throw StateError('revoked');
        },
        chooseDestination: (_) async => fail('unexpected picker'),
      ),
      throwsStateError,
    );
    expect(await staging.parent.exists(), false);
  });
}
