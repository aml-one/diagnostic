import 'dart:async';

import 'package:aml_ui/aml_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/diagnosis/diagnosis_report.dart';
import '../core/diagnosis/diagnosis_report_export.dart';
import '../core/logcat/anr_detector.dart';
import '../core/perfetto/perfetto_models.dart';
import '../core/perfetto/perfetto_service.dart';
import '../state/device_names_provider.dart';
import '../state/diagnosis_controller.dart';
import '../theme/desktop_theme.dart';
import '../widgets/ai_diagnosis_panel.dart';
import '../widgets/desktop_chrome.dart';

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
    ref
        .read(diagnosisControllerProvider.notifier)
        .run(
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
    final trace = ref
        .read(diagnosisControllerProvider)
        .perfettoResult
        ?.traceFile;
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
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
        children: [
          DesktopContent(
            child: state.isDone
                ? _ReportView(
                    state: state,
                    fallbackSerial: widget.serial,
                    exporting: _exporting,
                    exportMessage: _exportMessage,
                    onExport: _export,
                    onOpenPerfetto: _openInPerfetto,
                    onRunAgain: _start,
                  )
                : _ProgressPanel(
                    state: state,
                    onCancel: () =>
                        ref.read(diagnosisControllerProvider.notifier).cancel(),
                    onRetry: _start,
                  ),
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

class _ProgressPanel extends StatelessWidget {
  const _ProgressPanel({
    required this.state,
    required this.onCancel,
    required this.onRetry,
  });

  final DiagnosisState state;
  final VoidCallback onCancel;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final elapsed = state.elapsed;
    final elapsedLabel = elapsed == null
        ? null
        : '${elapsed.inMinutes}:'
              '${(elapsed.inSeconds % 60).toString().padLeft(2, '0')}';

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

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        DesktopSectionLabel(
          label: 'Pipeline',
          trailing: elapsedLabel == null
              ? null
              : DesktopTag(
                  label: elapsedLabel,
                  color: AmlTheme.sky,
                  mono: true,
                  icon: Icons.timer_outlined,
                ),
        ),
        const SizedBox(height: 6),
        DesktopPanel(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              DesktopPanelHeader(
                icon: state.isFailed
                    ? Icons.error_outline_rounded
                    : Icons.troubleshoot_rounded,
                accent: state.isFailed ? Desk.danger : AmlTheme.violet,
                title: state.isFailed ? 'Diagnosis stopped' : 'Diagnosing…',
                subtitle: state.progressText.isEmpty
                    ? 'Starting…'
                    : state.progressText,
              ),
              const SizedBox(height: 10),
              const DesktopHairline(),
              const SizedBox(height: 4),
              for (final step in steps)
                _StepRow(
                  label: step.label,
                  icon: step.icon,
                  status: _statusFor(state, step.step, step.enabled),
                ),
              if (state.isFailed) ...[
                const SizedBox(height: 8),
                Text(
                  state.error ?? 'Something went wrong.',
                  style: const TextStyle(
                    fontSize: 12.5,
                    height: 1.35,
                    fontWeight: FontWeight.w600,
                    color: Desk.danger,
                  ),
                ),
                const SizedBox(height: 12),
                Align(
                  alignment: Alignment.centerLeft,
                  child: FilledButton.icon(
                    onPressed: onRetry,
                    icon: const Icon(Icons.refresh_rounded, size: 16),
                    label: const Text('Try again'),
                  ),
                ),
              ] else if (state.isRunning) ...[
                const SizedBox(height: 12),
                Align(
                  alignment: Alignment.centerLeft,
                  child: OutlinedButton.icon(
                    onPressed: onCancel,
                    icon: const Icon(Icons.close_rounded, size: 16),
                    label: const Text('Cancel'),
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
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
        leading = const _StepMark(
          color: AmlTheme.mint,
          icon: Icons.check_rounded,
        );
      case _RowStatus.active:
        leading = const BirdLoader(size: 20);
      case _RowStatus.error:
        leading = const _StepMark(
          color: Desk.danger,
          icon: Icons.close_rounded,
        );
        textColor = Desk.danger;
      case _RowStatus.skipped:
        leading = Icon(icon, size: 16, color: muted.withValues(alpha: 0.5));
        textColor = muted;
      case _RowStatus.pending:
        leading = Icon(icon, size: 16, color: muted.withValues(alpha: 0.5));
    }

    return SizedBox(
      height: 30,
      child: Row(
        children: [
          SizedBox(width: 22, child: Center(child: leading)),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 13,
                fontWeight: status == _RowStatus.active
                    ? FontWeight.w800
                    : FontWeight.w600,
                color: textColor,
              ),
            ),
          ),
          if (status == _RowStatus.skipped)
            DesktopTag(label: 'skipped', color: muted),
        ],
      ),
    );
  }
}

class _StepMark extends StatelessWidget {
  const _StepMark({required this.color, required this.icon});

  final Color color;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 18,
      height: 18,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.9),
        borderRadius: BorderRadius.circular(Desk.tag),
      ),
      alignment: Alignment.center,
      child: Icon(icon, size: 12, color: Colors.white),
    );
  }
}

class _ReportView extends ConsumerWidget {
  const _ReportView({
    required this.state,
    required this.fallbackSerial,
    required this.exporting,
    required this.exportMessage,
    required this.onExport,
    required this.onOpenPerfetto,
    required this.onRunAgain,
  });

  final DiagnosisState state;
  final String fallbackSerial;
  final bool exporting;
  final String? exportMessage;
  final void Function(bool asJson) onExport;
  final VoidCallback onOpenPerfetto;
  final VoidCallback onRunAgain;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final report = state.report;
    if (report == null) return const SizedBox.shrink();
    final muted = AmlTheme.mutedOf(context);
    final elapsed = state.elapsed;
    final pssMb = report.mem?.totalPssKb == null
        ? null
        : report.mem!.totalPssKb! / 1024;
    final names = ref.watch(deviceNamesProvider);
    final serial = state.serial ?? fallbackSerial;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        DesktopPanel(
          padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
          child: DesktopPanelHeader(
            icon: Icons.fact_check_rounded,
            accent: AmlTheme.mint,
            title: 'Diagnosis complete',
            subtitle: [
              resolveSerialLabel(names, serial),
              state.packageName ?? 'no package',
              if (elapsed != null) '${elapsed.inSeconds}s',
            ].where((s) => s.isNotEmpty).join('  ·  '),
            trailing: DesktopIconAction(
              tooltip: 'Run again',
              onPressed: onRunAgain,
              icon: Icons.refresh_rounded,
            ),
          ),
        ),
        const SizedBox(height: 10),
        LayoutBuilder(
          builder: (context, constraints) {
            final columns = constraints.maxWidth >= 680 ? 4 : 2;
            return GridView.count(
              crossAxisCount: columns,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              mainAxisSpacing: 10,
              crossAxisSpacing: 10,
              childAspectRatio: columns == 4 ? 1.55 : 1.9,
              children: [
                _StatCard(
                  icon: Icons.warning_amber_rounded,
                  accent: AmlTheme.pink,
                  label: 'ANR events',
                  value: '${state.anrCount}',
                ),
                _StatCard(
                  icon: Icons.speed_rounded,
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
                  accent: AmlTheme.sky,
                  label: 'Total PSS',
                  value: pssMb == null ? '—' : '${pssMb.toStringAsFixed(0)} MB',
                ),
                _StatCard(
                  icon: Icons.priority_high_rounded,
                  accent: AmlTheme.violet,
                  label: 'Top finding',
                  value: state.topFinding,
                  valueFontSize: 12.5,
                  valueMaxLines: 3,
                ),
              ],
            );
          },
        ),
        const SizedBox(height: 10),
        _AnrStackViewer(report: report),
        const SizedBox(height: 10),
        _PerfettoSection(
          report: report,
          tracePath: state.perfettoResult?.traceFile.path,
          onOpen: onOpenPerfetto,
        ),
        const SizedBox(height: 10),
        DesktopPanel(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const DesktopPanelHeader(
                icon: Icons.save_alt_rounded,
                accent: AmlTheme.mint,
                title: 'Save report',
                subtitle:
                    'Writes to your Documents folder under diagnostic-reports.',
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  OutlinedButton.icon(
                    onPressed: exporting ? null : () => onExport(false),
                    icon: const Icon(Icons.description_outlined, size: 16),
                    label: const Text('Export .md'),
                  ),
                  const SizedBox(width: 8),
                  OutlinedButton.icon(
                    onPressed: exporting ? null : () => onExport(true),
                    icon: const Icon(Icons.data_object_rounded, size: 16),
                    label: const Text('Export .json'),
                  ),
                  if (exporting) ...[
                    const SizedBox(width: 12),
                    const BirdLoader(size: 28, semanticsLabel: 'Saving report'),
                  ],
                ],
              ),
              if (exportMessage != null) ...[
                const SizedBox(height: 10),
                SelectableText(
                  exportMessage!,
                  style: Desk.mono(size: 11.5, color: muted),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 10),
        AiDiagnosisPanel(report: report),
      ],
    );
  }
}

class _StatCard extends StatelessWidget {
  const _StatCard({
    required this.icon,
    required this.accent,
    required this.label,
    required this.value,
    this.subtitle,
    this.valueFontSize = 20,
    this.valueMaxLines = 1,
  });

  final IconData icon;
  final Color accent;
  final String label;
  final String value;
  final String? subtitle;
  final double valueFontSize;
  final int valueMaxLines;

  @override
  Widget build(BuildContext context) {
    final ink = AmlTheme.inkOf(context);
    final muted = AmlTheme.mutedOf(context);
    return DesktopPanel(
      padding: const EdgeInsets.fromLTRB(10, 10, 10, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              DesktopMiniIcon(icon: icon, color: accent, size: 22),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  label.toUpperCase(),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Desk.sectionLabel(context),
                ),
              ),
            ],
          ),
          const Spacer(),
          Text(
            value,
            maxLines: valueMaxLines,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: valueFontSize,
              fontWeight: FontWeight.w800,
              height: 1.2,
              color: ink,
            ),
          ),
          if (subtitle != null)
            Text(
              subtitle!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 11, color: muted),
            ),
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

    return DesktopPanel(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: hasFrames
                ? () => setState(() => _expanded = !_expanded)
                : null,
            borderRadius: BorderRadius.circular(Desk.row),
            child: Row(
              children: [
                const DesktopMiniIcon(
                  icon: Icons.dns_rounded,
                  color: AmlTheme.violet,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        'Main thread stack',
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                          height: 1.2,
                          color: ink,
                        ),
                      ),
                      Text(
                        hasFrames
                            ? '${report.mainThreadName ?? 'main'} · '
                                  '${report.mainThreadState ?? 'unknown'} · '
                                  '${report.mainThreadFrames.length} frames'
                            : 'No main-thread frames captured.',
                        maxLines: 1,
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
                    size: 20,
                    color: muted,
                  ),
              ],
            ),
          ),
          if (_expanded && hasFrames) ...[
            const SizedBox(height: 10),
            DesktopMonoBlock(text: report.mainThreadFrames.join('\n')),
            if (report.lockedStacks.isNotEmpty) ...[
              const SizedBox(height: 10),
              Text('Locked / waiting', style: Desk.sectionLabel(context)),
              const SizedBox(height: 6),
              DesktopMonoBlock(
                text: report.lockedStacks.join('\n'),
                maxHeight: 220,
              ),
            ],
          ],
        ],
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
    final muted = AmlTheme.mutedOf(context);
    final hasTrace = tracePath != null && tracePath!.isNotEmpty;
    return DesktopPanel(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          DesktopPanelHeader(
            icon: Icons.timeline_rounded,
            accent: AmlTheme.sky,
            title: 'Perfetto findings',
            trailing: report.perfettoFindings.isEmpty
                ? null
                : DesktopTag(
                    label: '${report.perfettoFindings.length}',
                    color: AmlTheme.sky,
                    mono: true,
                  ),
          ),
          const SizedBox(height: 10),
          if (report.perfettoFindings.isEmpty)
            Text(
              report.processorNote ?? 'No Perfetto trace captured.',
              style: TextStyle(fontSize: 12.5, height: 1.35, color: muted),
            )
          else
            for (final finding in report.perfettoFindings) ...[
              _FindingRow(finding: finding),
              const SizedBox(height: 6),
            ],
          if (hasTrace) ...[
            const SizedBox(height: 6),
            Text('Local trace file', style: Desk.sectionLabel(context)),
            const SizedBox(height: 4),
            SelectableText(
              tracePath!,
              style: Desk.mono(size: 11.5, color: muted),
            ),
            const SizedBox(height: 10),
            Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton.icon(
                onPressed: onOpen,
                icon: const Icon(Icons.open_in_new_rounded, size: 16),
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
          padding: const EdgeInsets.only(top: 3),
          child: Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(2),
            ),
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
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  height: 1.25,
                  color: ink,
                ),
              ),
              Text(
                finding.detail,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12, height: 1.3, color: muted),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
