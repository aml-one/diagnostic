import '../diagnosis/diagnosis_report.dart';
import '../perf/dumpsys_snapshot.dart';
import '../perfetto/perfetto_models.dart';

/// Capped text evidence for one DeepSeek call. Keep well under model context.
class EvidenceBundle {
  const EvidenceBundle({required this.text, this.truncated = false});

  /// ~60k of 40–80k so a reasoner prompt plus reply still fits.
  static const int maxChars = 60000;
  static const int mainFrameCap = 32;
  static const int logcatLineCap = 80;
  static const int perfettoCap = 16;
  static const int cpuRowCap = 8;
  static const int excerptCap = 4000;

  final String text;
  final bool truncated;

  int get charCount => text.length;

  factory EvidenceBundle.fromReport(DiagnosisReport report) =>
      EvidenceBundle.fromEvidence(report);

  factory EvidenceBundle.fromEvidence(DiagnosisEvidence evidence) {
    final writer = _BudgetWriter(maxChars);
    writer.line('# AmL Diagnostic evidence');
    writer.field('package', evidence.packageName);
    writer.field('process', evidence.process);
    writer.field('reason', evidence.anrReason);
    writer.field('subject', evidence.subject);
    if (evidence.timestamp != null) {
      writer.field('timestamp', evidence.timestamp!.toIso8601String());
    }

    writer.section('Main thread');
    final threadBits = <String>[
      if (evidence.mainThreadName != null &&
          evidence.mainThreadName!.trim().isNotEmpty)
        'name=${evidence.mainThreadName}',
      if (evidence.mainThreadState != null &&
          evidence.mainThreadState!.trim().isNotEmpty)
        'state=${evidence.mainThreadState}',
    ];
    if (threadBits.isNotEmpty) writer.line(threadBits.join(' '));
    final frames = evidence.mainThreadFrames.take(mainFrameCap).toList();
    if (frames.isEmpty) {
      writer.line('(no main-thread frames)');
    } else {
      for (final frame in frames) {
        writer.line(frame);
      }
      if (evidence.mainThreadFrames.length > mainFrameCap) {
        writer.line(
          '… ${evidence.mainThreadFrames.length - mainFrameCap} more frames omitted',
        );
      }
    }

    if (evidence.lockedStacks.isNotEmpty) {
      writer.section('Locks');
      for (final line in evidence.lockedStacks.take(24)) {
        writer.line(line);
      }
    }

    _writeGfx(writer, evidence.gfx, evidence.gfxSummary);
    _writeMem(writer, evidence.mem, evidence.memSummary);
    _writeCpu(writer, evidence.cpu, evidence.cpuSummary);
    _writePerfetto(
      writer,
      evidence.perfettoFindings,
      evidence.processorNote,
    );
    _writeLogcat(writer, evidence.logcatContext);

    return EvidenceBundle(text: writer.toString(), truncated: writer.truncated);
  }
}

void _writeGfx(_BudgetWriter writer, GfxInfoSnapshot? gfx, String? summary) {
  if (gfx == null && (summary == null || summary.trim().isEmpty)) return;
  writer.section('dumpsys gfx');
  if (gfx != null) {
    writer.field('package', gfx.package);
    if (gfx.totalFrames != null) {
      writer.field('total_frames', '${gfx.totalFrames}');
    }
    if (gfx.jankyFrames != null) {
      writer.field('janky_frames', '${gfx.jankyFrames}');
    }
    if (gfx.jankyPercent != null) {
      writer.field('janky_percent', gfx.jankyPercent!.toStringAsFixed(1));
    }
    writer.excerpt(gfx.rawExcerpt);
  }
  if (summary != null && summary.trim().isNotEmpty) {
    writer.excerpt(summary);
  }
}

void _writeMem(_BudgetWriter writer, MemInfoSnapshot? mem, String? summary) {
  if (mem == null && (summary == null || summary.trim().isEmpty)) return;
  writer.section('dumpsys mem');
  if (mem != null) {
    writer.field('package', mem.package);
    if (mem.totalPssKb != null) writer.field('total_pss_kb', '${mem.totalPssKb}');
    if (mem.nativeHeapPssKb != null) {
      writer.field('native_heap_pss_kb', '${mem.nativeHeapPssKb}');
    }
    if (mem.dalvikHeapPssKb != null) {
      writer.field('dalvik_heap_pss_kb', '${mem.dalvikHeapPssKb}');
    }
    writer.excerpt(mem.rawExcerpt);
  }
  if (summary != null && summary.trim().isNotEmpty) {
    writer.excerpt(summary);
  }
}

void _writeCpu(_BudgetWriter writer, CpuInfoSnapshot? cpu, String? summary) {
  if (cpu == null && (summary == null || summary.trim().isEmpty)) return;
  writer.section('dumpsys cpu');
  if (cpu != null) {
    writer.field('load', cpu.load);
    for (final row in cpu.top.take(EvidenceBundle.cpuRowCap)) {
      final pid = row.pid == null ? '' : ' pid=${row.pid}';
      writer.line('${row.percent.toStringAsFixed(1)}%$pid ${row.name}');
    }
    writer.excerpt(cpu.rawExcerpt);
  }
  if (summary != null && summary.trim().isNotEmpty) {
    writer.excerpt(summary);
  }
}

void _writePerfetto(
  _BudgetWriter writer,
  List<PerfettoFinding> findings,
  String? processorNote,
) {
  if (findings.isEmpty && (processorNote == null || processorNote.trim().isEmpty)) {
    return;
  }
  writer.section('Perfetto');
  if (processorNote != null && processorNote.trim().isNotEmpty) {
    writer.line(processorNote.trim());
  }
  for (final finding in findings.take(EvidenceBundle.perfettoCap)) {
    writer.line(
      '[${finding.severity.name}] ${finding.title}: ${finding.detail}',
    );
  }
  if (findings.length > EvidenceBundle.perfettoCap) {
    writer.line(
      '… ${findings.length - EvidenceBundle.perfettoCap} more findings omitted',
    );
  }
}

void _writeLogcat(_BudgetWriter writer, List<String> lines) {
  if (lines.isEmpty) return;
  writer.section('Logcat ANR context');
  final take = lines.length > EvidenceBundle.logcatLineCap
      ? lines.sublist(lines.length - EvidenceBundle.logcatLineCap)
      : lines;
  if (lines.length > EvidenceBundle.logcatLineCap) {
    writer.line(
      '… ${lines.length - EvidenceBundle.logcatLineCap} earlier lines omitted',
    );
  }
  for (final line in take) {
    writer.line(line);
  }
}

class _BudgetWriter {
  _BudgetWriter(this.maxChars);

  final int maxChars;
  final _buf = StringBuffer();
  var truncated = false;

  void section(String title) {
    line('');
    line('## $title');
  }

  void field(String name, String? value) {
    final trimmed = value?.trim();
    if (trimmed == null || trimmed.isEmpty) return;
    line('$name: $trimmed');
  }

  void excerpt(String? raw) {
    final trimmed = raw?.trim();
    if (trimmed == null || trimmed.isEmpty) return;
    final cut = trimmed.length <= EvidenceBundle.excerptCap
        ? trimmed
        : '${trimmed.substring(0, EvidenceBundle.excerptCap)}\n… excerpt truncated';
    line(cut);
  }

  void line(String value) {
    if (truncated) return;
    final next = _buf.isEmpty ? value : '\n$value';
    if (_buf.length + next.length <= maxChars) {
      _buf.write(next);
      return;
    }
    final remaining = maxChars - _buf.length;
    if (remaining > 16) {
      _buf.write(next.substring(0, remaining - 14));
      _buf.write('\n… truncated');
    }
    truncated = true;
  }

  @override
  String toString() => _buf.toString();
}
