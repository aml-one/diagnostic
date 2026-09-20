import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/adb/adb_client.dart';
import '../core/bugreport/anr_trace_parser.dart';
import '../core/bugreport/bugreport_service.dart';
import '../core/diagnosis/diagnosis_report.dart';
import '../core/diagnosis/diagnosis_report_export.dart';
import '../core/diagnosis/watch_log_summary.dart';
import '../core/diagnostics/app_log.dart';
import '../core/logcat/anr_detector.dart';
import '../core/logcat/logcat_parser.dart';
import '../core/onedrop/onedrop_watch.dart';
import '../core/perf/dumpsys_snapshot.dart';
import '../core/perfetto/perfetto_models.dart';
import '../core/perfetto/perfetto_service.dart';
import '../core/mobile/device_bridge.dart';
import '../core/mobile/phone_diagnostic.dart';
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
    this.includeBugreport = true,
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
  final bool includeBugreport;

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
    return topFindingFor(report);
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
      includeBugreport: includeBugreport,
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
  AdbCancelToken? _adbCancel;

  @override
  DiagnosisState build() {
    _disposed = false;
    ref.onDispose(() => _disposed = true);
    return const DiagnosisState();
  }

  void _emit(DiagnosisState next) {
    if (_disposed || _cancelRequested) return;
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
    _adbCancel = AdbCancelToken();
    final startedAt = DateTime.now();
    // Prefer the ANR the user tapped — its packageHint is the target.
    // Fall back to the caller's packageName (watched session) only when the
    // event has no package.
    final seedPkg = seedEvent?.packageHint.trim();
    final pkg = (seedPkg != null && seedPkg.isNotEmpty)
        ? seedPkg
        : ((packageName != null && packageName.trim().isNotEmpty)
              ? packageName.trim()
              : null);

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
    AppLog.i('diagnose', 'step: scanning logcat');

    final adb = ref.read(adbClientProvider);

    try {
      final anrEvents = _scanRecentAnrEvents(seedEvent: seedEvent);
      _emit(state.copyWith(anrEvents: anrEvents));
      if (_bail()) return;

      GfxInfoSnapshot? gfx;
      MemInfoSnapshot? mem;
      CpuInfoSnapshot? cpu;
      var oneDropRadio = const <String>[];
      if (includeDumpsys && pkg != null) {
        final oneDrop = isOneDropWatchPackage(pkg);
        _emit(
          state.copyWith(
            step: DiagnosisStep.dumpsys,
            progressText: oneDrop
                ? 'Capturing dumpsys gfx / mem / cpu / Wi-Fi…'
                : 'Capturing dumpsys gfx / mem / cpu…',
          ),
        );
        AppLog.i('diagnose', 'step: dumpsys');
        try {
          final snapshot = DumpsysSnapshot(adb: adb);
          final jobs = <Future<Object>>[
            snapshot.gfxinfo(serial, pkg, cancel: _adbCancel),
            snapshot.meminfo(serial, pkg, cancel: _adbCancel),
            snapshot.cpuinfo(serial, cancel: _adbCancel),
            if (oneDrop) snapshot.raw(serial, 'wifi', cancel: _adbCancel),
            if (oneDrop) snapshot.raw(serial, 'wifip2p', cancel: _adbCancel),
            if (oneDrop)
              snapshot.raw(serial, 'connectivity', cancel: _adbCancel),
          ];
          final results = await Future.wait<Object>(jobs);
          gfx = results[0] as GfxInfoSnapshot;
          mem = results[1] as MemInfoSnapshot;
          cpu = results[2] as CpuInfoSnapshot;
          if (oneDrop && results.length >= 6) {
            oneDropRadio = summarizeOneDropRadioDumpsys(
              wifi: results[3] as String,
              p2p: results[4] as String,
              connectivity: results[5] as String,
            );
          }
        } on AdbCancelled {
          return;
        } on Object catch (err) {
          AppLog.w('diagnose', 'dumpsys failed', err);
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
      AppLog.i('diagnose', 'step: bugreport');
      final bugreportResult = await BugreportService(adb: adb).capture(
        serial: serial,
        cancel: _adbCancel,
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
      AppLog.i('diagnose', 'step: parsing ANR traces');
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
        AppLog.i('diagnose', 'step: perfetto');
        try {
          perfettoResult = await PerfettoService(adb: adb).captureAndAnalyze(
            serial: serial,
            packageName: pkg,
            cancel: _adbCancel,
            onProgress: (message, {progress}) {
              _emit(
                state.copyWith(
                  step: DiagnosisStep.perfetto,
                  progressText: message,
                ),
              );
            },
          );
        } on AdbCancelled {
          return;
        } on PerfettoUnavailableException catch (err) {
          AppLog.w('diagnose', 'perfetto unavailable: ${err.message}', err);
          _emit(state.copyWith(progressText: err.message));
        } on Object catch (err) {
          AppLog.w('diagnose', 'perfetto capture failed', err);
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
      AppLog.i('diagnose', 'step: assembling');
      final preferredEvent =
          seedEvent ?? (anrEvents.isEmpty ? null : anrEvents.first);
      WatchLogSummary? watchLogs;
      if (isOneDropWatchPackage(pkg)) {
        final buffer =
            ref.read(logcatSessionProvider.notifier).session?.recentBuffer ??
            const <LogcatLine>[];
        watchLogs = summarizeWatchLogs(
          buffer,
          leadingFindings: oneDropDiagnosisFindings(buffer),
          extraFindings: oneDropRadio,
        );
      }
      final report = DiagnosisReport.assemble(
        packageName: pkg,
        event: preferredEvent,
        anr: bugreportParse.preferredAnr(pkg),
        bugreport: bugreportParse,
        gfx: gfx,
        mem: mem,
        cpu: cpu,
        perfetto: perfettoResult,
        watchLogs: watchLogs,
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
    } on AdbCancelled {
      return;
    } catch (err) {
      if (_cancelRequested || _disposed) return;
      AppLog.e('diagnose', 'pipeline failed at ${state.step.name}', err);
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

  /// Phone Watch Diagnose: dump live logcat, native Watch ring, optional
  /// local dumpsys. Skips ADB bugreport and Perfetto (those need a desktop
  /// host). Refresh always recaptures — it must not reuse the Watch snapshot
  /// from when this screen was opened.
  Future<void> runOnDevice({
    String? packageName,
    List<LogcatLine> lines = const [],
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
        progressText: 'Dumping live logcat…',
        serial: kOnDeviceSerial,
        packageName: pkg,
        includeDumpsys: true,
        includePerfetto: false,
        includeBugreport: false,
        startedAt: startedAt,
      ),
    );
    AppLog.i('diagnose', 'on-device: dumping live logcat');

    try {
      List<String> dumpedRaw = const [];
      List<String> ringRaw = const [];
      try {
        dumpedRaw = await deviceBridge.dumpLogcat();
      } on Object catch (err) {
        AppLog.w('diagnose', 'on-device logcat dump failed', err);
      }
      if (_bail()) return;
      try {
        ringRaw = await deviceBridge.snapshotLogs();
      } on Object catch (err) {
        AppLog.w('diagnose', 'on-device log ring failed', err);
      }
      if (_bail()) return;

      final collected = mergeWatchLogLines([
        dumpedRaw.map(LogcatParser.parse),
        ringRaw.map(LogcatParser.parse),
        lines,
      ]);
      _emit(
        state.copyWith(
          progressText: 'Reading ${collected.length} log lines…',
        ),
      );

      GfxInfoSnapshot? gfx;
      MemInfoSnapshot? mem;
      CpuInfoSnapshot? cpu;
      final extraFindings = <String>[];
      final oneDrop = isOneDropWatchPackage(pkg);
      _emit(
        state.copyWith(
          step: DiagnosisStep.dumpsys,
          progressText: pkg == null
              ? 'Capturing dumpsys cpu…'
              : oneDrop
              ? 'Capturing dumpsys gfx / mem / cpu / Wi-Fi…'
              : 'Capturing dumpsys gfx / mem / cpu…',
        ),
      );
      AppLog.i('diagnose', 'on-device: dumpsys');
      try {
        final gfxOut = pkg == null
            ? ''
            : await deviceBridge.dumpsys('gfxinfo $pkg');
        if (_bail()) return;
        final memOut = pkg == null
            ? ''
            : await deviceBridge.dumpsys('meminfo $pkg');
        if (_bail()) return;
        final cpuOut = await deviceBridge.dumpsys('cpuinfo');
        if (_bail()) return;
        var dumpsysLimited = false;
        if (pkg != null) {
          gfx = parseGfxInfo(gfxOut, package: pkg);
          mem = parseMemInfo(memOut, package: pkg);
          if (dumpsysLooksDenied(gfxOut) ||
              (gfx.totalFrames == null && gfx.jankyFrames == null)) {
            dumpsysLimited = true;
            gfx = null;
          }
          if (dumpsysLooksDenied(memOut) || mem.totalPssKb == null) {
            dumpsysLimited = true;
            mem = null;
          }
        }
        cpu = parseCpuInfo(cpuOut);
        if (dumpsysLooksDenied(cpuOut) ||
            (cpu.load == null && cpu.top.isEmpty)) {
          dumpsysLimited = true;
          cpu = null;
        }
        if (dumpsysLimited) {
          extraFindings.add(kOnDeviceLighterDiagnosis);
        }
        if (oneDrop) {
          extraFindings.addAll(await _oneDropRadioDumpsysOnDevice());
        }
      } on Object catch (err) {
        AppLog.w('diagnose', 'on-device dumpsys failed', err);
        extraFindings.add(kOnDeviceLighterDiagnosis);
      }
      if (_bail()) return;

      final watchLogs = summarizeWatchLogs(
        collected,
        leadingFindings: oneDrop
            ? oneDropDiagnosisFindings(collected)
            : const [],
        extraFindings: extraFindings,
      );
      final anrEvents = _scanLines(
        collected,
        window: const Duration(days: 365),
      );
      _emit(state.copyWith(anrEvents: anrEvents));
      if (_bail()) return;

      _emit(
        state.copyWith(
          step: DiagnosisStep.assembling,
          progressText: 'Assembling report…',
        ),
      );
      final preferredEvent = anrEvents.isEmpty ? null : anrEvents.first;
      final report = DiagnosisReport.assemble(
        packageName: pkg,
        event: preferredEvent,
        gfx: gfx,
        mem: mem,
        cpu: cpu,
        watchLogs: watchLogs,
      );

      _emit(
        state.copyWith(
          step: DiagnosisStep.done,
          progressText: 'Done',
          report: report,
          finishedAt: DateTime.now(),
        ),
      );
    } catch (err) {
      if (_cancelRequested || _disposed) return;
      AppLog.e('diagnose', 'on-device pipeline failed at ${state.step.name}', err);
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

  /// Kills in-flight `adb` (bugreport / dumpsys / perfetto) and returns to idle.
  /// The Diagnose screen pops itself; this must not leave a "stopped" card.
  void cancel() {
    if (!state.isRunning && !_cancelRequested) return;
    _cancelRequested = true;
    _adbCancel?.cancel();
    if (!_disposed) {
      state = const DiagnosisState();
    }
  }

  void reset() {
    _cancelRequested = false;
    _adbCancel = null;
    _emit(const DiagnosisState());
  }

  bool _bail() {
    return _disposed || _cancelRequested;
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
    for (final event in _scanLines(buffer, window: window, now: now)) {
      add(event);
    }

    out.sort((a, b) => b.time.compareTo(a.time));
    return out;
  }

  List<AnrEvent> _scanLines(
    List<LogcatLine> buffer, {
    Duration window = const Duration(minutes: 2),
    DateTime? now,
  }) {
    if (buffer.isEmpty) return const [];
    final at = now ?? DateTime.now();
    final out = <AnrEvent>[];
    final detector = AnrDetector(bufferSize: buffer.length + 8);
    for (final line in buffer) {
      final event = detector.add(line);
      if (event != null && at.difference(event.time) <= window) {
        out.add(event);
      }
    }
    final flushed = detector.flush();
    if (flushed != null && at.difference(flushed.time) <= window) {
      out.add(flushed);
    }
    out.sort((a, b) => b.time.compareTo(a.time));
    return out;
  }

  Future<List<String>> _oneDropRadioDumpsysOnDevice() async {
    if (_bail()) return const [];
    try {
      final results = await Future.wait([
        deviceBridge.dumpsys('wifi'),
        deviceBridge.dumpsys('wifip2p'),
        deviceBridge.dumpsys('connectivity'),
      ]);
      if (_bail()) return const [];
      return summarizeOneDropRadioDumpsys(
        wifi: results[0],
        p2p: results[1],
        connectivity: results[2],
      );
    } on Object catch (err) {
      AppLog.w('diagnose', 'OneDrop radio dumpsys failed', err);
      return const [];
    }
  }
}

final diagnosisControllerProvider =
    NotifierProvider<DiagnosisController, DiagnosisState>(
      DiagnosisController.new,
    );
