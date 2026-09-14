import 'package:diagnostic/core/ai/evidence_bundle.dart';
import 'package:diagnostic/core/diagnosis/diagnosis_report.dart';
import 'package:diagnostic/core/logcat/anr_detector.dart';
import 'package:diagnostic/core/logcat/logcat_parser.dart';
import 'package:diagnostic/core/perf/dumpsys_snapshot.dart';
import 'package:diagnostic/core/perfetto/perfetto_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('includes ANR reason, process, main frames, dumpsys, Perfetto, logcat', () {
    final bundle = EvidenceBundle.fromReport(
      DiagnosisReport(
        packageName: 'one.aml.messageme',
        process: 'one.aml.messageme',
        anrReason: 'Input dispatching timed out',
        mainThreadName: 'main',
        mainThreadState: 'Native',
        mainThreadFrames: const [
          'at android.os.MessageQueue.nativePollOnce',
          'at one.aml.messageme.HomeScreen.build',
        ],
        lockedStacks: const ['- waiting to lock <0x1> held by tid=12'],
        gfx: const GfxInfoSnapshot(
          package: 'one.aml.messageme',
          totalFrames: 100,
          jankyFrames: 42,
          jankyPercent: 42,
        ),
        mem: const MemInfoSnapshot(
          package: 'one.aml.messageme',
          totalPssKb: 180000,
        ),
        cpu: const CpuInfoSnapshot(
          load: 'Load: 4.52 / 3.1 / 2.0',
          top: [CpuProcessRow(percent: 40, pid: 4321, name: 'messageme')],
        ),
        perfettoFindings: const [
          PerfettoFinding(
            title: 'main thread slice',
            detail: 'Choreographer#doFrame 48ms',
            severity: PerfettoSeverity.warning,
          ),
        ],
        logcatContext: const ['ANR in one.aml.messageme', 'Reason: Input dispatching timed out'],
      ),
    );

    expect(bundle.text, contains('reason: Input dispatching timed out'));
    expect(bundle.text, contains('process: one.aml.messageme'));
    expect(bundle.text, contains('MessageQueue.nativePollOnce'));
    expect(bundle.text, contains('janky_frames: 42'));
    expect(bundle.text, contains('total_pss_kb: 180000'));
    expect(bundle.text, contains('Load: 4.52'));
    expect(bundle.text, contains('[warning] main thread slice'));
    expect(bundle.text, contains('ANR in one.aml.messageme'));
    expect(bundle.truncated, isFalse);
    expect(bundle.charCount, lessThanOrEqualTo(EvidenceBundle.maxChars));
  });

  test('caps total size and keeps the head of the bundle', () {
    final frames = List<String>.generate(80, (i) => 'at frame.Number$i(${'x' * 2500})');
    final logcat = List<String>.generate(
      400,
      (i) => '09-14 12:00:00.000  1  1 E AndroidRuntime: line $i ${'z' * 400}',
    );
    final bundle = EvidenceBundle.fromReport(
      DiagnosisReport(
        anrReason: 'Input dispatching timed out',
        process: 'one.aml.messageme',
        mainThreadFrames: frames,
        logcatContext: logcat,
        cpuSummary: 'cpu ' * 8000,
        memSummary: 'mem ' * 8000,
        gfxSummary: 'gfx ' * 8000,
      ),
    );

    expect(bundle.charCount, lessThanOrEqualTo(EvidenceBundle.maxChars));
    expect(bundle.text, contains('reason: Input dispatching timed out'));
    expect(bundle.truncated, isTrue);
  });

  test('fromAnrEvent maps logcat context', () {
    final event = AnrEvent(
      time: DateTime.utc(2026, 9, 14, 12),
      packageHint: 'one.aml.messageme',
      reason: 'Input dispatching timed out',
      context: const [
        LogcatLine(
          raw: 'ANR in one.aml.messageme',
          message: 'ANR in one.aml.messageme',
        ),
      ],
    );
    final bundle = EvidenceBundle.fromReport(
      DiagnosisReport.fromAnrEvent(event),
    );
    expect(bundle.text, contains('one.aml.messageme'));
    expect(bundle.text, contains('Input dispatching timed out'));
    expect(bundle.text, contains('ANR in one.aml.messageme'));
  });
}
