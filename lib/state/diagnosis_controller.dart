import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/bugreport/anr_trace_parser.dart';
import '../core/bugreport/bugreport_service.dart';
import '../core/diagnosis/diagnosis_report.dart';
import '../core/logcat/anr_detector.dart';
import '../core/logcat/logcat_parser.dart';
import '../core/perf/dumpsys_snapshot.dart';
import '../core/perfetto/perfetto_models.dart';
import '../core/perfetto/perfetto_service.dart';
import 'adb_providers.dart';
import 'logcat_providers.dart';

/// Diagnose pipeline phase. UI renders one row per step in this order.
enum DiagnosisStep {
  idle,
  scanningLogcat,
  dumpsys,
  bugreport,
  parsing,
  perfetto,
  assembling,
  done,
  failed,
}

/// Full state for one Diagnose run: which step is active, its status text,
/// every raw artifact collected so far, and the assembled [DiagnosisReport]
/// once [DiagnosisStep.done]. Kept separate from [DiagnosisReport] (owned by
/// the DeepSeek/report-model layer) so this controller never has to touch
/// that file.
class DiagnosisState {
  const DiagnosisState({
    this.step = DiagnosisStep.idle,
    this.progressText = '',
    this.error,
    this.failedStep,
    this.serial,
    this.packageName,
    this.includeDumpsys = true,
    this.includePerfetto = true,
    this.anrEvents = const <AnrEvent>[],
    this.bugreportResult,
    this.bugreportParse,
    this.perfettoResult,
    this.report,
    this.startedAt,
    this.finishedAt,
  });

  final DiagnosisStep step;
  final String progressText;
  final String? error;

  /// Step that was active when [step] became [DiagnosisStep.failed] (or when
  /// the user cancelled) — lets the UI put the X on the right row.
  final DiagnosisStep? failedStep;

  final String? serial;
  final String? packageName;
  final bool includeDumpsys;
  final bool includePerfetto;

  /// Recent (last couple of minutes) ANR/crash events seen in the live
  /// logcat ring buffer, most recent first.
  final List<AnrEvent> anrEvents;

  final BugreportResult? bugreportResult;
  final BugreportParseResult? bugreportParse;
  final PerfettoCaptureResult? perfettoResult;

  /// Final merged report — set once [step] reaches [DiagnosisStep.done].
  final DiagnosisReport? report;

  final DateTime? startedAt;
  final DateTime? finishedAt;

  bool get isIdle => step == DiagnosisStep.idle;
  bool get isDone => step == DiagnosisStep.done;
  bool get isFailed => step == DiagnosisStep.failed;
  bool get isRunning => !isIdle && !isDone && !isFailed;

  Duration? get elapsed {
    final start = startedAt;
    if (start == null) return null;
    return (finishedAt ?? DateTime.now()).difference(start);
  }

  /// Bugreport traces are the authoritative count; logcat-only events are the
  /// fallback when no bugreport ANR was parsed (e.g. bugreport too slow to
  /// catch it, or the device did not reproduce it during capture).
  int get anrCount {
    final traceCount = bugreportParse?.anrs.length ?? 0;
    return traceCount > 0 ? traceCount : anrEvents.length;
  }

  /// One-line headline for the "Top finding" stat card.
  String get topFinding {
    final report = this.report;
    if (report == null) return 'No issues found yet';
    final reason = report.anrReason?.trim();
    if (reason != null && reason.isNotEmpty) return reason;
    if (report.perfettoFindings.isNotEmpty) {
      final sorted = [...report.perfettoFindings]
        ..sort((a, b) => b.severity.index.compareTo(a.severity.index));
      return sorted.first.title;
    }
    return 'No ANR or jank evidence captured';
  }

  DiagnosisState copyWith({
    DiagnosisStep? step,
    String? progressText,
    String? error,
    DiagnosisStep? failedStep,
    List<AnrEvent>? anrEvents,
    BugreportResult? bugreportResult,
    BugreportParseResult? bugreportParse,
    PerfettoCaptureResult? perfettoResult,
    DiagnosisReport? report,
    DateTime? finishedAt,
  }) {
    return DiagnosisState(
      step: step ?? this.step,
      progressText: progressText ?? this.progressText,
      error: error ?? this.error,
      failedStep: failedStep ?? this.failedStep,
      serial: serial,
      packageName: packageName,
      includeDumpsys: includeDumpsys,
      includePerfetto: includePerfetto,
      anrEvents: anrEvents ?? this.anrEvents,
      bugreportResult: bugreportResult ?? this.bugreportResult,
      bugreportParse: bugreportParse ?? this.bugreportParse,
      perfettoResult: perfettoResult ?? this.perfettoResult,
      report: report ?? this.report,
      startedAt: startedAt,
      finishedAt: finishedAt ?? this.finishedAt,
    );
  }
}

/// Runs the Diagnose pipeline: scan logcat ring buffer → optional dumpsys
/// snapshot → adb bugreport → parse ANR traces → optional Perfetto capture →
/// assemble [DiagnosisReport]. Reuses [AdbClient]-backed services already in
/// `core/` — never talks to `adb` directly.
class DiagnosisController extends Notifier<DiagnosisState> {
  bool _disposed = false;
  bool _cancelRequested = false;

  @override
  DiagnosisState build() {
    _disposed = false;
    ref.onDispose(() => _disposed = true);
    return const DiagnosisState();
  }

  void _emit(DiagnosisState next) {
    if (_disposed) return;
    state = next;
  }

  /// Starts a fresh run. No-op while already running. [seedEvent] is the ANR
  /// (if any) the user tapped to get here — it always wins as the report's
  /// preferred ANR even if the live scan finds a more recent one.
  Future<void> run({
    required String serial,
    String? packageName,
    AnrEvent? seedEvent,
    bool includeDumpsys = true,
    bool includePerfetto = true,
  }) async {
    if (state.isRunning) return;
    _cancelRequested = false;
    final startedAt = DateTime.now();
    final pkg = (packageName != null && packageName.trim().isNotEmpty)
        ? packageName.trim()
        : null;

    _emit(
      DiagnosisState(
        step: DiagnosisStep.scanningLogcat,
        progressText: 'Scanning recent logcat for ANRs…',
        serial: serial,
        packageName: pkg,
        includeDumpsys: includeDumpsys,
        includePerfetto: includePerfetto,
        startedAt: startedAt,
      ),
    );

    final adb = ref.read(adbClientProvider);

    try {
      final anrEvents = _scanRecentAnrEvents(seedEvent: seedEvent);
      _emit(state.copyWith(anrEvents: anrEvents));
      if (_bail()) return;

      GfxInfoSnapshot? gfx;
      MemInfoSnapshot? mem;
      CpuInfoSnapshot? cpu;
      if (includeDumpsys && pkg != null) {
        _emit(
          state.copyWith(
            step: DiagnosisStep.dumpsys,
            progressText: 'Capturing dumpsys gfx / mem / cpu…',
          ),
        );
        try {
          final snapshot = DumpsysSnapshot(adb: adb);
          final results = await Future.wait<Object>([
            snapshot.gfxinfo(serial, pkg),
            snapshot.meminfo(serial, pkg),
            snapshot.cpuinfo(serial),
          ]);
          gfx = results[0] as GfxInfoSnapshot;
          mem = results[1] as MemInfoSnapshot;
          cpu = results[2] as CpuInfoSnapshot;
        } on Object {
          // Non-fatal — the bugreport dumpstate excerpt still carries gfx/mem
          // text even when a live dumpsys call fails or times out.
        }
        if (_bail()) return;
      }

      _emit(
        state.copyWith(
          step: DiagnosisStep.bugreport,
          progressText: 'Starting bugreport…',
        ),
      );
      final bugreportResult = await BugreportService(adb: adb).capture(
        serial: serial,
        onProgress: (status) {
          _emit(
            state.copyWith(step: DiagnosisStep.bugreport, progressText: status),
          );
        },
      );
      if (_bail()) return;

      _emit(
        state.copyWith(
          step: DiagnosisStep.parsing,
          progressText: 'Parsing ANR traces…',
        ),
      );
      final bugreportParse = await AnrTraceParser.parseExtractDir(
        bugreportResult.extractDir,
        packageFilter: pkg,
      );
      _emit(
        state.copyWith(
          bugreportResult: bugreportResult,
          bugreportParse: bugreportParse,
        ),
      );
      if (_bail()) return;

      PerfettoCaptureResult? perfettoResult;
      if (includePerfetto) {
        _emit(
          state.copyWith(
            step: DiagnosisStep.perfetto,
            progressText: 'Recording a short Perfetto trace…',
          ),
        );
        try {
          perfettoResult = await PerfettoService(adb: adb).captureAndAnalyze(
            serial: serial,
            packageName: pkg,
            onProgress: (message, {progress}) {
              _emit(
                state.copyWith(
                  step: DiagnosisStep.perfetto,
                  progressText: message,
                ),
              );
            },
          );
        } on PerfettoUnavailableException catch (err) {
          _emit(state.copyWith(progressText: err.message));
        } on Object {
          _emit(state.copyWith(progressText: 'Perfetto capture skipped.'));
        }
        if (_bail()) return;
      }

      _emit(
        state.copyWith(
          step: DiagnosisStep.assembling,
          progressText: 'Assembling report…',
        ),
      );
      final preferredEvent =
          seedEvent ?? (anrEvents.isEmpty ? null : anrEvents.first);
      final report = DiagnosisReport.assemble(
        packageName: pkg,
        event: preferredEvent,
        anr: bugreportParse.preferredAnr(pkg),
        bugreport: bugreportParse,
        gfx: gfx,
        mem: mem,
        cpu: cpu,
        perfetto: perfettoResult,
      );

      _emit(
        state.copyWith(
          step: DiagnosisStep.done,
          progressText: 'Done',
          perfettoResult: perfettoResult,
          report: report,
          finishedAt: DateTime.now(),
        ),
      );
    } catch (err) {
      _emit(
        state.copyWith(
          step: DiagnosisStep.failed,
          failedStep: state.step,
          error: '$err',
          finishedAt: DateTime.now(),
        ),
      );
    }
  }

  /// Best-effort: `adb bugreport` / `perfetto` have no cancel hook exposed by
  /// the services, so a cancel mid-phase takes effect at the next checkpoint
  /// (right after that phase's await resolves) rather than killing it early.
  void cancel() {
    if (!state.isRunning) return;
    _cancelRequested = true;
    _emit(state.copyWith(progressText: 'Cancelling…'));
  }

  void reset() {
    _cancelRequested = false;
    _emit(const DiagnosisState());
  }

  bool _bail() {
    if (!_disposed && !_cancelRequested) return false;
    if (_disposed) return true;
    _emit(
      state.copyWith(
        step: DiagnosisStep.failed,
        failedStep: state.step,
        error: 'Cancelled',
        finishedAt: DateTime.now(),
      ),
    );
    return true;
  }

  /// Re-scans the live [LogcatSession] ring buffer (fresh [AnrDetector], so
  /// this never mutates the live session's own detector) plus whatever the
  /// live session already emitted, for ANR/crash signals in the last two
  /// minutes.
  List<AnrEvent> _scanRecentAnrEvents({AnrEvent? seedEvent}) {
    const window = Duration(minutes: 2);
    final now = DateTime.now();
    final out = <AnrEvent>[];
    final seen = <String>{};
    void add(AnrEvent event) {
      final key =
          '${event.time.millisecondsSinceEpoch}|${event.reason}|${event.packageHint}';
      if (seen.add(key)) out.add(event);
    }

    if (seedEvent != null) add(seedEvent);

    final view = ref.read(logcatSessionProvider);
    for (final event in view.recentAnrs) {
      if (now.difference(event.time) <= window) add(event);
    }

    final session = ref.read(logcatSessionProvider.notifier).session;
    final buffer = session?.recentBuffer ?? const <LogcatLine>[];
    if (buffer.isNotEmpty) {
      final detector = AnrDetector(bufferSize: buffer.length + 8);
      for (final line in buffer) {
        final event = detector.add(line);
        if (event != null && now.difference(event.time) <= window) {
          add(event);
        }
      }
      final flushed = detector.flush();
      if (flushed != null && now.difference(flushed.time) <= window) {
        add(flushed);
      }
    }

    out.sort((a, b) => b.time.compareTo(a.time));
    return out;
  }
}

final diagnosisControllerProvider =
    NotifierProvider<DiagnosisController, DiagnosisState>(
      DiagnosisController.new,
    );
