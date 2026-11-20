import 'package:flutter_test/flutter_test.dart';
import 'package:im_flutter_sdk/im_flutter_sdk.dart';

void main() {
  test('offline read-only is a known session state', () {
    expect(
      ImSessionState.values.byName('offlineReadOnly'),
      ImSessionState.offlineReadOnly,
    );
  });
}
