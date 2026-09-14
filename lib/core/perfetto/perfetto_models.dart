import 'dart:io';

/// How serious a canned Perfetto SQL finding is for the engineer.
enum PerfettoSeverity { info, warning, severe }

/// One hotspot from `trace_processor_shell` SQL (main-thread slice or frame jank).
class PerfettoFinding {
  const PerfettoFinding({
    required this.title,
    required this.detail,
    required this.severity,
  });

  final String title;
  final String detail;
  final PerfettoSeverity severity;
}

/// Local trace plus optional SQL summary.
class PerfettoCaptureResult {
  const PerfettoCaptureResult({
    required this.traceFile,
    required this.findings,
    this.processorNote,
  });

  final File traceFile;
  final List<PerfettoFinding> findings;

  /// Set when the Windows processor binary could not be downloaded or run.
  /// UI copy: drag [traceFile] into https://ui.perfetto.dev
  final String? processorNote;
}

/// Result of opening the Perfetto UI in a browser.
class PerfettoUiLaunch {
  const PerfettoUiLaunch({
    required this.openedBrowser,
    required this.tracePath,
    required this.instruction,
  });

  final bool openedBrowser;

  /// Absolute path of the `.perfetto-trace` to drag onto the UI tab.
  final String tracePath;

  final String instruction;
}

/// Device has no `perfetto` binary, or capture could not write a trace.
class PerfettoUnavailableException implements Exception {
  PerfettoUnavailableException(this.message);

  final String message;

  @override
  String toString() => message;
}
