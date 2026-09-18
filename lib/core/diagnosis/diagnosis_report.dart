import '../bugreport/anr_trace_parser.dart';
import '../logcat/anr_detector.dart';
import '../logcat/logcat_parser.dart';
import '../perf/dumpsys_snapshot.dart';
import '../perfetto/perfetto_models.dart';
import 'watch_log_summary.dart';

/// Assembled ANR / perf snapshot for the report UI and DeepSeek.
///
/// DiagnosisController should populate this (bugreport + dumpsys + Perfetto
/// + logcat). [fromAnrEvent] is a thin fallback until that pipeline lands.
class DiagnosisReport {
  const DiagnosisReport({
    this.packageName,
    this.process,
    this.anrReason,
    this.subject,
    this.timestamp,
    this.mainThreadName,
    this.mainThreadState,
    this.mainThreadFrames = const [],
    this.lockedStacks = const [],
    this.gfx,
    this.mem,
    this.cpu,
    this.cpuSummary,
    this.memSummary,
    this.gfxSummary,
    this.perfettoFindings = const [],
    this.processorNote,
    this.logcatContext = const [],
    this.scannedLines = 0,
    this.errorLines = 0,
    this.warningLines = 0,
    this.logFindings = const [],
  });

  final String? packageName;
  final String? process;
  final String? anrReason;
  final String? subject;
  final DateTime? timestamp;
  final String? mainThreadName;
  final String? mainThreadState;
  final List<String> mainThreadFrames;
  final List<String> lockedStacks;
  final GfxInfoSnapshot? gfx;
  final MemInfoSnapshot? mem;
  final CpuInfoSnapshot? cpu;
  final String? cpuSummary;
  final String? memSummary;
  final String? gfxSummary;
  final List<PerfettoFinding> perfettoFindings;
  final String? processorNote;
  final List<String> logcatContext;

  /// Watch-buffer stats (phone Diagnose). Zero on a desktop ANR capture.
  final int scannedLines;
  final int errorLines;
  final int warningLines;
  final List<String> logFindings;

  bool get hasEvidence =>
      (anrReason != null && anrReason!.trim().isNotEmpty) ||
      (process != null && process!.trim().isNotEmpty) ||
      (packageName != null && packageName!.trim().isNotEmpty) ||
      mainThreadFrames.isNotEmpty ||
      lockedStacks.isNotEmpty ||
      gfx != null ||
      mem != null ||
      cpu != null ||
      (cpuSummary != null && cpuSummary!.trim().isNotEmpty) ||
      (memSummary != null && memSummary!.trim().isNotEmpty) ||
      (gfxSummary != null && gfxSummary!.trim().isNotEmpty) ||
      perfettoFindings.isNotEmpty ||
      logcatContext.isNotEmpty ||
      scannedLines > 0 ||
      logFindings.isNotEmpty;

  factory DiagnosisReport.fromAnrEvent(
    AnrEvent event, {
    String? packageName,
  }) {
    final pkg = (packageName != null && packageName.trim().isNotEmpty)
        ? packageName.trim()
        : (event.packageHint.isEmpty ? null : event.packageHint);
    return DiagnosisReport(
      packageName: pkg,
      process: event.packageHint.isEmpty ? null : event.packageHint,
      anrReason: event.reason,
      timestamp: event.time,
      logcatContext: event.context.map(formatLogcatLine).toList(),
    );
  }

  factory DiagnosisReport.fromAnrTrace(
    AnrTrace anr, {
    String? packageName,
    BugreportParseResult? bugreport,
    GfxInfoSnapshot? gfx,
    MemInfoSnapshot? mem,
    CpuInfoSnapshot? cpu,
    PerfettoCaptureResult? perfetto,
    AnrEvent? event,
  }) {
    return DiagnosisReport.assemble(
      packageName: packageName,
      event: event,
      anr: anr,
      bugreport: bugreport,
      gfx: gfx,
      mem: mem,
      cpu: cpu,
      perfetto: perfetto,
    );
  }

  /// Merge every Diagnose source the controller has. Trace stacks win over
  /// logcat-only hints; dumpsys snapshots win over bugreport excerpts.
  factory DiagnosisReport.assemble({
    String? packageName,
    AnrEvent? event,
    AnrTrace? anr,
    BugreportParseResult? bugreport,
    GfxInfoSnapshot? gfx,
    MemInfoSnapshot? mem,
    CpuInfoSnapshot? cpu,
    PerfettoCaptureResult? perfetto,
    WatchLogSummary? watchLogs,
  }) {
    final preferred = anr ?? bugreport?.preferredAnr(packageName);
    final main = preferred?.threads.where((t) => t.isMain).toList();
    final mainThread = (main != null && main.isNotEmpty) ? main.first : null;
    final eventPkg = event != null && event.packageHint.isNotEmpty
        ? event.packageHint
        : null;
    final pkg = _firstNonEmpty([
      packageName,
      preferred?.packageName,
      preferred?.process,
      eventPkg,
    ]);
    return DiagnosisReport(
      packageName: pkg,
      process: _firstNonEmpty([preferred?.process, eventPkg, pkg]),
      anrReason: _firstNonEmpty([preferred?.reason, event?.reason]),
      subject: preferred?.subject,
      timestamp: preferred?.timestamp ?? event?.time,
      mainThreadName: mainThread?.name,
      mainThreadState: mainThread?.state,
      mainThreadFrames: mainThread?.stackFrames ?? const [],
      lockedStacks: preferred?.lockedStacks ?? const [],
      gfx: gfx,
      mem: mem,
      cpu: cpu,
      cpuSummary: bugreport?.cpuSummary ?? dumpsysCpuSummary(cpu),
      memSummary: bugreport?.memSummary ?? dumpsysMemSummary(mem),
      gfxSummary: bugreport?.gfxSummary ?? dumpsysGfxSummary(gfx),
      perfettoFindings: perfetto?.findings ?? const [],
      processorNote: perfetto?.processorNote,
      logcatContext: (event != null && event.context.isNotEmpty)
          ? event.context.map(formatLogcatLine).toList()
          : (watchLogs?.highlights ?? const []),
      scannedLines: watchLogs?.lineCount ?? 0,
      errorLines: watchLogs?.errorCount ?? 0,
      warningLines: watchLogs?.warningCount ?? 0,
      logFindings: watchLogs?.findings ?? const [],
    );
  }
}

/// Input DTO for DeepSeek. Same shape as [DiagnosisReport] so the report
/// screen can pass its model through without a second copy.
typedef DiagnosisEvidence = DiagnosisReport;

String formatLogcatLine(LogcatLine line) {
  if (line.raw.trim().isNotEmpty) return line.raw;
  final tag = line.tag.isEmpty ? '' : '${line.tag}: ';
  final level = line.level.isEmpty ? '' : '${line.level} ';
  return '$level$tag${line.message}'.trim();
}

/// Wall time for Diagnose, with milliseconds so a 134ms run is `0.134 s`
/// instead of `0s`.
String formatDiagnosisElapsed(Duration elapsed) {
  final seconds = elapsed.inMicroseconds / Duration.microsecondsPerSecond;
  final clamped = seconds < 0 ? 0.0 : seconds;
  return '${clamped.toStringAsFixed(3)} s';
}

String? _firstNonEmpty(List<String?> values) {
  for (final value in values) {
    final trimmed = value?.trim();
    if (trimmed != null && trimmed.isNotEmpty) return trimmed;
  }
  return null;
}
