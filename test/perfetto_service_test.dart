import 'package:flutter_test/flutter_test.dart';

import 'package:diagnostic/core/perfetto/perfetto_models.dart';
import 'package:diagnostic/core/perfetto/perfetto_service.dart';

void main() {
  test('builds short -t capture args with optional package', () {
    final args = buildPerfettoCaptureArgs(
      remotePath: '/data/misc/perfetto-traces/aml_diag.perfetto-trace',
      seconds: 10,
      packageName: 'one.aml.messageme',
    );
    expect(args, containsAllInOrder([
      'shell',
      'perfetto',
      '-o',
      '/data/misc/perfetto-traces/aml_diag.perfetto-trace',
      '-t',
      '10s',
      '--app',
      'one.aml.messageme',
      'sched',
      'view',
      'binder_driver',
    ]));
  });

  test('omits --app when package is blank', () {
    final args = buildPerfettoCaptureArgs(
      remotePath: '/data/misc/perfetto-traces/x.perfetto-trace',
      seconds: 12,
    );
    expect(args, isNot(contains('--app')));
    expect(args, contains('12s'));
  });

  test('text config includes atrace apps when targeting a package', () {
    final txt = buildPerfettoTextConfig(
      seconds: 10,
      packageName: 'one.aml.one_auth',
    );
    expect(txt, contains('duration_ms: 10000'));
    expect(txt, contains('atrace_apps: "one.aml.one_auth"'));
    expect(txt, contains('atrace_categories: "view"'));
  });

  test('parses pipe table into findings', () {
    const stdout = '''
thread_name | slice_name              | dur_ms
------------|-------------------------|-------
1.ui        | Choreographer#doFrame   | 48
1.main      | binder transaction      | 120
''';
    final rows = parseTraceProcessorTable(stdout);
    expect(rows, hasLength(2));
    final findings = findingsFromSliceRows(rows);
    expect(findings, hasLength(2));
    expect(findings[0].severity, PerfettoSeverity.warning);
    expect(findings[0].title, contains('48ms'));
    expect(findings[1].severity, PerfettoSeverity.severe);
    expect(findings[1].detail, 'binder transaction');
  });

  test('parses csv frame jank rows', () {
    const stdout = '''
"slice_name","dur_ms"
"FrameTimeline",22
"missed vsync",40
''';
    final findings = findingsFromFrameRows(parseTraceProcessorTable(stdout));
    expect(findings, hasLength(2));
    expect(findings[0].title, 'Frame jank (22ms)');
    expect(findings[0].severity, PerfettoSeverity.info);
    expect(findings[1].severity, PerfettoSeverity.warning);
  });
}
