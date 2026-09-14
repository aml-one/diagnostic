import 'package:diagnostic/core/diagnostics/app_log.dart';
import 'package:diagnostic/core/diagnostics/app_log_export.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  setUp(AppLog.clear);
  tearDown(AppLog.clear);

  test('ring buffer drops the oldest entries past maxEntries', () {
    for (var i = 0; i < AppLog.maxEntries + 5; i++) {
      AppLog.i('t', '$i');
    }
    final snap = AppLog.snapshot();
    expect(snap, hasLength(AppLog.maxEntries));
    expect(snap.first.message, '5');
    expect(snap.last.message, '${AppLog.maxEntries + 4}');
  });

  test('renderText is oldest-first with level tags and indented detail', () {
    final older = AppLogEntry(
      time: DateTime(2026, 9, 14, 16, 7, 1, 2),
      level: AppLogLevel.info,
      tag: 'adb',
      message: 'first',
    );
    final newer = AppLogEntry(
      time: DateTime(2026, 9, 14, 16, 7, 2, 250),
      level: AppLogLevel.error,
      tag: 'zone',
      message: 'boom',
      detail: 'stack\nline2',
    );
    final text = AppLogExport.renderText(entries: [older, newer]);
    expect(text, isNotEmpty);
    expect(text, contains('16:07:01.002 [INFO] adb: first'));
    expect(text, contains('16:07:02.250 [ERROR] zone: boom'));
    expect(text, contains('  stack'));
    expect(text, contains('  line2'));
    expect(text.indexOf('first'), lessThan(text.indexOf('boom')));
  });
}
