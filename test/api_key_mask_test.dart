import 'package:diagnostic/services/settings_store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('masks saved keys and never prints the tail in full', () {
    expect(maskDeepSeekApiKey(null), 'No key saved');
    expect(maskDeepSeekApiKey(''), 'No key saved');
    expect(maskDeepSeekApiKey('sk-abcdefghijklmnopqrstuv'), 'Saved · sk-••••stuv');
    expect(maskDeepSeekApiKey('sk-abcdefghijklmnopqrstuv'), isNot(contains('abcdefgh')));
  });
}
