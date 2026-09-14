import 'dart:async';

import 'package:aml_ui/aml_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/diagnosis/diagnosis_report.dart';
import '../core/diagnosis/diagnosis_report_export.dart';
import '../core/logcat/anr_detector.dart';
import '../core/perfetto/perfetto_models.dart';
import '../core/perfetto/perfetto_service.dart';
import '../state/diagnosis_controller.dart';
import '../widgets/ai_diagnosis_panel.dart';

/// Diagnose host: runs [DiagnosisController]'s pipeline for [serial] /
/// [packageName] (seeded by [event] when opened from an ANR banner), shows
/// step-by-step progress, then the assembled report with stat cards, an
/// expandable ANR stack, Perfetto findings, export, and [AiDiagnosisPanel].
class DiagnoseScreen extends ConsumerStatefulWidget {
  const DiagnoseScreen({
    super.key,
    required this.serial,
    this.packageName,
    this.event,
  });

  final String serial;
  final String? packageName;
  final AnrEvent? event;

  @override
  ConsumerState<DiagnoseScreen> createState() => _DiagnoseScreenState();
}

class _DiagnoseScreenState extends ConsumerState<DiagnoseScreen> {
  Timer? _tick;
  bool _exporting = false;
  String? _exportMessage;

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _start());
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  void _start() {
    ref.read(diagnosisControllerProvider.notifier).run(
      serial: widget.serial,
      packageName: widget.packageName,
      seedEvent: widget.event,
    );
  }

  Future<void> _export(bool asJson) async {
    final state = ref.read(diagnosisControllerProvider);
    final report = state.report;
    if (report == null) return;
    setState(() {
      _exporting = true;
      _exportMessage = null;
    });
    try {
      final file = asJson
          ? await DiagnosisReportExport.writeJson(
              report: report,
              serial: state.serial ?? widget.serial,
              packageName: state.packageName ?? widget.packageName,
              anrEvents: state.anrEvents,
              startedAt: state.startedAt,
              finishedAt: state.finishedAt,
              bugreportZipPath: state.bugreportResult?.zipPath,
              bugreportExtractDir: state.bugreportResult?.extractDir,
              perfettoTracePath: state.perfettoResult?.traceFile.path,
              perfettoProcessorNote: state.perfettoResult?.processorNote,
            )
          : await DiagnosisReportExport.writeMarkdown(
              report: report,
              serial: state.serial ?? widget.serial,
              packageName: state.packageName ?? widget.packageName,
              anrEvents: state.anrEvents,
              startedAt: state.startedAt,
              finishedAt: state.finishedAt,
              bugreportZipPath: state.bugreportResult?.zipPath,
              bugreportExtractDir: state.bugreportResult?.extractDir,
              perfettoTracePath: state.perfettoResult?.traceFile.path,
              perfettoProcessorNote: state.perfettoResult?.processorNote,
            );
      if (!mounted) return;
      setState(() {
        _exporting = false;
        _exportMessage = 'Saved to ${file.path}';
      });
    } catch (err) {
      if (!mounted) return;
      setState(() {
        _exporting = false;
        _exportMessage = 'Could not save report: $err';
      });
    }
  }

  Future<void> _openInPerfetto() async {
    final trace = ref.read(diagnosisControllerProvider).perfettoResult?.traceFile;
    final launch = await PerfettoService().openInPerfettoUi(traceFile: trace);
    if (!mounted) return;
    setState(() => _exportMessage = launch.instruction);
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(diagnosisControllerProvider);
    return SettingsPageScaffold(
      title: 'Diagnose',
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          if (state.isDone)
            _ReportView(
              state: state,
              exporting: _exporting,
              exportMessage: _exportMessage,
              onExport: _export,
              onOpenPerfetto: _openInPerfetto,
              onRunAgain: _start,
            )
          else
            _ProgressCard(
              state: state,
              onCancel: () =>
                  ref.read(diagnosisControllerProvider.notifier).cancel(),
              onRetry: _start,
            ),
        ],
      ),
    );
  }
}

enum _RowStatus { pending, active, done, skipped, error }

class _StepInfo {
  const _StepInfo(this.step, this.label, this.icon, this.enabled);

  final DiagnosisStep step;
  final String label;
  final IconData icon;
  final bool enabled;
}

_RowStatus _statusFor(DiagnosisState state, DiagnosisStep step, bool enabled) {
  if (!enabled) return _RowStatus.skipped;
  final order = DiagnosisStep.values;
  final stepIdx = order.indexOf(step);
  if (state.step == DiagnosisStep.failed) {
    final failedIdx = order.indexOf(state.failedStep ?? DiagnosisStep.idle);
    if (stepIdx < failedIdx) return _RowStatus.done;
    if (stepIdx == failedIdx) return _RowStatus.error;
    return _RowStatus.pending;
  }
  if (state.step == DiagnosisStep.done) return _RowStatus.done;
  final currentIdx = order.indexOf(state.step);
  if (stepIdx < currentIdx) return _RowStatus.done;
  if (stepIdx == currentIdx) return _RowStatus.active;
  return _RowStatus.pending;
}

class _ProgressCard extends StatelessWidget {
  const _ProgressCard({
    required this.state,
    required this.onCancel,
    required this.onRetry,
  });

  final DiagnosisState state;
  final VoidCallback onCancel;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final ink = AmlTheme.inkOf(context);
    final muted = AmlTheme.mutedOf(context);
    final elapsed = state.elapsed;
    final elapsedLabel = elapsed == null
        ? null
        : '${elapsed.inMinutes}:${(elapsed.inSeconds % 60).toString().padLeft(2, '0')}';

    final steps = <_StepInfo>[
      _StepInfo(
        DiagnosisStep.scanningLogcat,
        'Scan logcat for ANRs',
        Icons.subject_rounded,
        true,
      ),
      _StepInfo(
        DiagnosisStep.dumpsys,
        'Dumpsys gfx / mem / cpu',
        Icons.speed_rounded,
        state.includeDumpsys && state.packageName != null,
      ),
      _StepInfo(
        DiagnosisStep.bugreport,
        'Pull bugreport',
        Icons.description_rounded,
        true,
      ),
      _StepInfo(
        DiagnosisStep.parsing,
        'Parse ANR traces',
        Icons.manage_search_rounded,
        true,
      ),
      _StepInfo(
        DiagnosisStep.perfetto,
        'Record Perfetto trace',
        Icons.timeline_rounded,
        state.includePerfetto,
      ),
      _StepInfo(
        DiagnosisStep.assembling,
        'Assemble report',
        Icons.fact_check_rounded,
        true,
      ),
    ];

    return SettingsSurface(
      padding: const EdgeInsets.fromLTRB(18, 20, 18, 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              settingsPastelIcon(Icons.troubleshoot_rounded, 'violet'),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      state.isFailed ? 'Diagnosis stopped' : 'Diagnosing…',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w800,
                        color: ink,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      state.progressText.isEmpty
                          ? 'Starting…'
                          : state.progressText,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 13, color: muted),
                    ),
                  ],
                ),
              ),
              if (elapsedLabel != null)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    elapsedLabel,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: muted,
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 18),
          for (final step in steps)
            _StepRow(
              label: step.label,
              icon: step.icon,
              status: _statusFor(state, step.step, step.enabled),
            ),
          if (state.isFailed) ...[
            const SizedBox(height: 12),
            Text(
              state.error ?? 'Something went wrong.',
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: Color(0xFFE85D75),
              ),
            ),
            const SizedBox(height: 14),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton(
                onPressed: onRetry,
                child: const Text('Try again'),
              ),
            ),
          ] else if (state.isRunning) ...[
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: onCancel,
                icon: const Icon(Icons.close_rounded),
                label: const Text('Cancel'),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _StepRow extends StatelessWidget {
  const _StepRow({
    required this.label,
    required this.icon,
    required this.status,
  });

  final String label;
  final IconData icon;
  final _RowStatus status;

  @override
  Widget build(BuildContext context) {
    final ink = AmlTheme.inkOf(context);
    final muted = AmlTheme.mutedOf(context);
    Color textColor = ink;
    Widget leading;
    switch (status) {
      case _RowStatus.done:
        leading = _StatusDot(color: AmlTheme.mint, icon: Icons.check_rounded);
      case _RowStatus.active:
        leading = const BirdLoader(size: 22);
      case _RowStatus.error:
        leading = _StatusDot(color: AmlTheme.pink, icon: Icons.close_rounded);
        textColor = AmlTheme.pink;
      case _RowStatus.skipped:
        leading = Icon(icon, size: 18, color: muted.withValues(alpha: 0.5));
        textColor = muted;
      case _RowStatus.pending:
        leading = Icon(icon, size: 18, color: muted.withValues(alpha: 0.5));
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          SizedBox(width: 26, child: Center(child: leading)),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                fontSize: 14.5,
                fontWeight: status == _RowStatus.active
                    ? FontWeight.w800
                    : FontWeight.w600,
                color: textColor,
              ),
            ),
          ),
          if (status == _RowStatus.skipped)
            Text(
              'skipped',
              style: TextStyle(
                fontSize: 12,
                color: muted,
                fontWeight: FontWeight.w600,
              ),
            ),
        ],
      ),
    );
  }
}

class _StatusDot extends StatelessWidget {
  const _StatusDot({required this.color, required this.icon});

  final Color color;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 22,
      height: 22,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.85),
        shape: BoxShape.circle,
      ),
      child: Icon(icon, size: 14, color: Colors.white),
    );
  }
}

class _ReportView extends StatelessWidget {
  const _ReportView({
    required this.state,
    required this.exporting,
    required this.exportMessage,
    required this.onExport,
    required this.onOpenPerfetto,
    required this.onRunAgain,
  });

  final DiagnosisState state;
  final bool exporting;
  final String? exportMessage;
  final void Function(bool asJson) onExport;
  final VoidCallback onOpenPerfetto;
  final VoidCallback onRunAgain;

  @override
  Widget build(BuildContext context) {
    final report = state.report;
    if (report == null) return const SizedBox.shrink();
    final ink = AmlTheme.inkOf(context);
    final muted = AmlTheme.mutedOf(context);
    final elapsed = state.elapsed;
    final pssMb = report.mem?.totalPssKb == null
        ? null
        : report.mem!.totalPssKb! / 1024;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SettingsSurface(
          padding: const EdgeInsets.fromLTRB(18, 18, 18, 18),
          child: Row(
            children: [
              settingsPastelIcon(
                Icons.fact_check_rounded,
                'mint',
                iconColor: AmlTheme.mint,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Diagnosis complete',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w800,
                        color: ink,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      [
                        state.serial ?? '',
                        state.packageName ?? 'no package',
                        if (elapsed != null) '${elapsed.inSeconds}s',
                      ].where((s) => s.isNotEmpty).join(' · '),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 12, color: muted),
                    ),
                  ],
                ),
              ),
              IconButton(
                tooltip: 'Run again',
                onPressed: onRunAgain,
                icon: const Icon(Icons.refresh_rounded),
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),
        GridView.count(
          crossAxisCount: 2,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          mainAxisSpacing: 12,
          crossAxisSpacing: 12,
          childAspectRatio: 1.45,
          children: [
            _StatCard(
              icon: Icons.warning_amber_rounded,
              pastelKey: 'pink',
              accent: AmlTheme.pink,
              label: 'ANR events',
              value: '${state.anrCount}',
            ),
            _StatCard(
              icon: Icons.speed_rounded,
              pastelKey: 'amber',
              accent: AmlTheme.amber,
              label: 'Janky frames',
              value: report.gfx?.jankyFrames == null
                  ? '—'
                  : '${report.gfx!.jankyFrames}',
              subtitle: report.gfx?.jankyPercent == null
                  ? null
                  : '${report.gfx!.jankyPercent!.toStringAsFixed(1)}%',
            ),
            _StatCard(
              icon: Icons.memory_rounded,
              pastelKey: 'sky',
              accent: AmlTheme.sky,
              label: 'Total PSS',
              value: pssMb == null ? '—' : '${pssMb.toStringAsFixed(0)} MB',
            ),
            _StatCard(
              icon: Icons.priority_high_rounded,
              pastelKey: 'violet',
              accent: AmlTheme.violet,
              label: 'Top finding',
              value: state.topFinding,
              valueFontSize: 13,
              valueMaxLines: 3,
            ),
          ],
        ),
        const SizedBox(height: 14),
        _AnrStackViewer(report: report),
        const SizedBox(height: 14),
        _PerfettoSection(
          report: report,
          tracePath: state.perfettoResult?.traceFile.path,
          onOpen: onOpenPerfetto,
        ),
        const SizedBox(height: 14),
        SettingsSurface(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  settingsPastelIcon(
                    Icons.save_alt_rounded,
                    'mint',
                    iconColor: AmlTheme.mint,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      'Save report',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w800,
                        color: ink,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Text(
                'Writes to your Documents folder under diagnostic-reports.',
                style: TextStyle(fontSize: 12, color: muted),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: exporting ? null : () => onExport(false),
                      icon: const Icon(Icons.description_outlined),
                      label: const Text('Export .md'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: exporting ? null : () => onExport(true),
                      icon: const Icon(Icons.data_object_rounded),
                      label: const Text('Export .json'),
                    ),
                  ),
                ],
              ),
              if (exporting) ...[
                const SizedBox(height: 14),
                const Center(
                  child: BirdLoader(size: 60, semanticsLabel: 'Saving report'),
                ),
              ],
              if (exportMessage != null) ...[
                const SizedBox(height: 10),
                SelectableText(
                  exportMessage!,
                  style: TextStyle(fontSize: 12, color: muted),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 14),
        AiDiagnosisPanel(report: report),
      ],
    );
  }
}

class _StatCard extends StatelessWidget {
  const _StatCard({
    required this.icon,
    required this.pastelKey,
    required this.label,
    required this.value,
    this.accent,
    this.subtitle,
    this.valueFontSize = 20,
    this.valueMaxLines = 1,
  });

  final IconData icon;
  final String pastelKey;
  final String label;
  final String value;
  final Color? accent;
  final String? subtitle;
  final double valueFontSize;
  final int valueMaxLines;

  @override
  Widget build(BuildContext context) {
    final ink = AmlTheme.inkOf(context);
    final muted = AmlTheme.mutedOf(context);
    return SettingsSurface(
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
      borderRadius: 22,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          settingsPastelIcon(icon, pastelKey, iconColor: accent),
          const SizedBox(height: 10),
          Text(
            value,
            maxLines: valueMaxLines,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: valueFontSize,
              fontWeight: FontWeight.w800,
              color: ink,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: muted,
            ),
          ),
          if (subtitle != null) ...[
            const SizedBox(height: 2),
            Text(
              subtitle!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 11, color: muted),
            ),
          ],
        ],
      ),
    );
  }
}

class _AnrStackViewer extends StatefulWidget {
  const _AnrStackViewer({required this.report});

  final DiagnosisReport report;

  @override
  State<_AnrStackViewer> createState() => _AnrStackViewerState();
}

class _AnrStackViewerState extends State<_AnrStackViewer> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final report = widget.report;
    final ink = AmlTheme.inkOf(context);
    final muted = AmlTheme.mutedOf(context);
    final hasFrames = report.mainThreadFrames.isNotEmpty;

    return SettingsSurface(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: hasFrames
                ? () => setState(() => _expanded = !_expanded)
                : null,
            borderRadius: BorderRadius.circular(14),
            child: Row(
              children: [
                settingsPastelIcon(Icons.dns_rounded, 'violet'),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Main thread stack',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w800,
                          color: ink,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        hasFrames
                            ? '${report.mainThreadName ?? 'main'} · '
                                  '${report.mainThreadState ?? 'unknown'} · '
                                  '${report.mainThreadFrames.length} frames'
                            : 'No main-thread frames captured.',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 12, color: muted),
                      ),
                    ],
                  ),
                ),
                if (hasFrames)
                  Icon(
                    _expanded
                        ? Icons.expand_less_rounded
                        : Icons.expand_more_rounded,
                    color: muted,
                  ),
              ],
            ),
          ),
          if (_expanded && hasFrames) ...[
            const SizedBox(height: 12),
            _MonospaceBlock(lines: report.mainThreadFrames),
            if (report.lockedStacks.isNotEmpty) ...[
              const SizedBox(height: 12),
              Text(
                'Locked / waiting',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: ink,
                ),
              ),
              const SizedBox(height: 6),
              _MonospaceBlock(lines: report.lockedStacks),
            ],
          ],
        ],
      ),
    );
  }
}

class _MonospaceBlock extends StatelessWidget {
  const _MonospaceBlock({required this.lines});

  final List<String> lines;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: AmlTheme.fieldOf(context),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AmlTheme.strokeOf(context)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: SelectableText(
          lines.join('\n'),
          style: const TextStyle(
            fontSize: 12,
            fontFamily: 'monospace',
            height: 1.4,
          ),
        ),
      ),
    );
  }
}

class _PerfettoSection extends StatelessWidget {
  const _PerfettoSection({
    required this.report,
    required this.tracePath,
    required this.onOpen,
  });

  final DiagnosisReport report;
  final String? tracePath;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final ink = AmlTheme.inkOf(context);
    final muted = AmlTheme.mutedOf(context);
    return SettingsSurface(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              settingsPastelIcon(Icons.timeline_rounded, 'sky'),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  'Perfetto findings',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w800,
                    color: ink,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          if (report.perfettoFindings.isEmpty)
            Text(
              report.processorNote ?? 'No Perfetto trace captured.',
              style: TextStyle(fontSize: 13, color: muted),
            )
          else
            for (final finding in report.perfettoFindings) ...[
              _FindingRow(finding: finding),
              const SizedBox(height: 8),
            ],
          if (tracePath != null && tracePath!.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              'Local trace file',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: muted,
              ),
            ),
            const SizedBox(height: 4),
            SelectableText(
              tracePath!,
              style: TextStyle(fontSize: 12, color: muted),
            ),
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: onOpen,
                icon: const Icon(Icons.open_in_new_rounded),
                label: const Text('Open in Perfetto UI'),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _FindingRow extends StatelessWidget {
  const _FindingRow({required this.finding});

  final PerfettoFinding finding;

  @override
  Widget build(BuildContext context) {
    final color = switch (finding.severity) {
      PerfettoSeverity.severe => AmlTheme.pink,
      PerfettoSeverity.warning => AmlTheme.amber,
      PerfettoSeverity.info => AmlTheme.sky,
    };
    final ink = AmlTheme.inkOf(context);
    final muted = AmlTheme.mutedOf(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                finding.title,
                style: TextStyle(
                  fontSize: 13.5,
                  fontWeight: FontWeight.w700,
                  color: ink,
                ),
              ),
              Text(
                finding.detail,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12, color: muted),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
