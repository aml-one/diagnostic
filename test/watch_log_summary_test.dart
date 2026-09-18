import 'package:diagnostic/core/diagnosis/diagnosis_report.dart';
import 'package:diagnostic/core/diagnosis/watch_log_summary.dart';
import 'package:diagnostic/core/logcat/logcat_parser.dart';
import 'package:diagnostic/core/perf/dumpsys_snapshot.dart';
import 'package:flutter_test/flutter_test.dart';

LogcatLine _line({
  required String level,
  String tag = 'Flutter',
  String message = 'hello',
}) {
  return LogcatLine(
    raw: '$level/$tag: $message',
    timestamp: DateTime(2026, 9, 17, 23, 30),
    level: level,
    tag: tag,
    message: message,
  );
}

void main() {
  test('empty Watch buffer explains how to retry', () {
    final summary = summarizeWatchLogs(const []);
    expect(summary.lineCount, 0);
    expect(summary.errorCount, 0);
    expect(summary.headline, contains('no log lines yet'));
  });

  test('counts errors and names the loudest tag', () {
    final summary = summarizeWatchLogs([
      _line(level: 'I', message: 'started'),
      _line(level: 'E', tag: 'DisplayBase', message: 'drop'),
      _line(level: 'E', tag: 'DisplayBase', message: 'again'),
      _line(level: 'E', tag: 'Flutter', message: 'once'),
      _line(level: 'W', tag: 'Choreographer', message: 'skipped'),
    ]);
    expect(summary.lineCount, 5);
    expect(summary.errorCount, 3);
    expect(summary.warningCount, 1);
    expect(summary.topTags.first.tag, 'DisplayBase');
    expect(summary.headline, contains('3 errors'));
    expect(summary.headline, contains('DisplayBase'));
    expect(summary.highlights.length, 3);
  });

  test('clean Watch is a finding, not an empty dash', () {
    final summary = summarizeWatchLogs([
      _line(level: 'I', message: 'ok'),
      _line(level: 'D', message: 'trace'),
    ]);
    expect(summary.errorCount, 0);
    expect(summary.headline, contains('no errors or warnings'));
    expect(summary.highlights, isEmpty);
  });

  test('surfaces a crash cue as the top finding', () {
    final summary = summarizeWatchLogs([
      _line(
        level: 'E',
        tag: 'AndroidRuntime',
        message: 'FATAL EXCEPTION: main',
      ),
    ]);
    expect(summary.headline, contains('FATAL EXCEPTION'));
  });

  test('mergeWatchLogLines keeps unique newest cap', () {
    final a = _line(level: 'E', message: 'first');
    final b = _line(level: 'E', message: 'second');
    final merged = mergeWatchLogLines([
      [a],
      [a, b],
    ]);
    expect(merged, hasLength(2));
    expect(merged.last.message, 'second');
  });

  test('extra dumpsys findings append after log counts', () {
    final summary = summarizeWatchLogs(
      [_line(level: 'I', message: 'ok')],
      extraFindings: const [kOnDeviceLighterDiagnosis],
    );
    expect(summary.findings.last, kOnDeviceLighterDiagnosis);
  });

  test('elapsed label keeps milliseconds', () {
    expect(
      formatDiagnosisElapsed(const Duration(milliseconds: 134)),
      '0.134 s',
    );
    expect(
      formatDiagnosisElapsed(const Duration(seconds: 2, milliseconds: 50)),
      '2.050 s',
    );
  });
}
