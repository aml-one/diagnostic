import 'package:flutter_test/flutter_test.dart';

import 'package:diagnostic/core/logcat/anr_detector.dart';
import 'package:diagnostic/core/logcat/logcat_parser.dart';

void main() {
  test('parses threadtime lines', () {
    const raw =
        '09-14 14:06:22.123  1234  5678 E ActivityManager: ANR in one.aml.messageme';
    final line = LogcatParser.parse(raw);
    expect(line.pid, 1234);
    expect(line.tid, 5678);
    expect(line.level, 'E');
    expect(line.tag, 'ActivityManager');
    expect(line.message, 'ANR in one.aml.messageme');
    expect(line.timestamp, isNotNull);
    expect(line.timestamp!.month, 9);
    expect(line.timestamp!.day, 14);
    expect(line.timestamp!.millisecond, 123);
  });

  test('keeps unparsed lines as raw message', () {
    const raw = '    at android.os.Looper.loop(Looper.java:123)';
    final line = LogcatParser.parse(raw);
    expect(line.isParsed, isFalse);
    expect(line.message, raw);
    expect(line.raw, raw);
  });

  test('detects ANR in plus Reason', () {
    final detector = AnrDetector(followLines: 8, contextLines: 20);
    final lines = [
      '09-14 14:06:22.100  1000  1100 I chatter: warmup',
      '09-14 14:06:22.123  1234  5678 E ActivityManager: ANR in one.aml.messageme',
      '09-14 14:06:22.124  1234  5678 E ActivityManager: PID: 4321',
      '09-14 14:06:22.125  1234  5678 E ActivityManager: Reason: Input dispatching timed out (Waiting)',
    ];
    AnrEvent? event;
    for (final raw in lines) {
      event = detector.add(LogcatParser.parse(raw)) ?? event;
    }
    event ??= detector.flush();
    expect(event, isNotNull);
    expect(event!.packageHint, 'one.aml.messageme');
    expect(event.reason, contains('Input dispatching timed out'));
    expect(event.context, isNotEmpty);
    expect(detector.recentBuffer.length, 4);
  });

  test('detects FATAL EXCEPTION', () {
    final detector = AnrDetector(followLines: 4);
    AnrEvent? event;
    for (final raw in [
      '09-14 14:06:22.200  88  88 E AndroidRuntime: FATAL EXCEPTION: main',
      '09-14 14:06:22.201  88  88 E AndroidRuntime: Process: one.aml.one_auth, PID: 88',
    ]) {
      event = detector.add(LogcatParser.parse(raw)) ?? event;
    }
    event ??= detector.flush();
    expect(event, isNotNull);
    expect(event!.packageHint, 'one.aml.one_auth');
    expect(event.reason, contains('FATAL EXCEPTION'));
  });
}
