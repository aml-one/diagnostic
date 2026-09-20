import 'package:diagnostic/services/settings_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('server upload is on until the user turns it off', () async {
    SharedPreferences.setMockInitialValues({});
    final store = SettingsStore();
    expect(await store.serverUploadEnabled(), isTrue);
    await store.setServerUploadEnabled(false);
    expect(await store.serverUploadEnabled(), isFalse);
    await store.setServerUploadEnabled(true);
    expect(await store.serverUploadEnabled(), isTrue);
  });
}
