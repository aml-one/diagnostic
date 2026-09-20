import 'dart:async';
import 'dart:io';

import 'package:aml_ui/aml_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/diagnosis/diagnosis_report.dart';
import '../core/diagnosis/diagnosis_report_export.dart';
import '../core/upload/field_report_client.dart';
import '../core/logcat/anr_detector.dart';
import '../core/logcat/logcat_parser.dart';
import '../core/mobile/device_bridge.dart';
import '../core/mobile/phone_diagnostic.dart';
import '../core/perfetto/perfetto_models.dart';
import '../core/perfetto/perfetto_service.dart';
import '../screens/android/mdx_share_sheet.dart';
import '../state/device_names_provider.dart';
import '../state/diagnosis_controller.dart';
import '../theme/desktop_theme.dart';
import '../widgets/ai_diagnosis_panel.dart';
import '../widgets/desktop_chrome.dart';
import '../widgets/desktop_title_bar.dart';

String _diagnoseAppLabel({
  String? appLabel,
  String? packageName,
  String empty = 'Whole device',
}) {
  final name = appLabel?.trim();
  if (name != null && name.isNotEmpty) return name;
  final pkg = packageName?.trim();
  if (pkg != null && pkg.isNotEmpty) return pkg;
  return empty;
}

/// Diagnose host: runs [DiagnosisController]'s pipeline for [serial] /
/// [packageName] (seeded by [event] when opened from an ANR banner), shows
/// step-by-step progress, then the assembled report with stat cards, an
/// expandable ANR stack, Perfetto findings, export, and [AiDiagnosisPanel].
class DiagnoseScreen extends ConsumerStatefulWidget {
  const DiagnoseScreen({
    super.key,
    required this.serial,
    this.packageName,
    this.appLabel,
    this.event,
    this.logLines,
    this.onDevice = false,
  });

  final String serial;
  final String? packageName;

  /// Launcher name (e.g. MessageMe). Shown in the app bar and complete header.
  final String? appLabel;
  final AnrEvent? event;
  final List<LogcatLine>? logLines;
  final bool onDevice;

  @override
  ConsumerState<DiagnoseScreen> createState() => _DiagnoseScreenState();
}

class _DiagnoseScreenState extends ConsumerState<DiagnoseScreen> {
  Timer? _tick;
  bool _exporting = false;
  bool _sendingToAppBuilder = false;
  String? _exportMessage;
  final _fieldReports = FieldReportClient();

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
    // Stop in-flight adb / parse work when the user leaves this route.
    ref.read(diagnosisControllerProvider.notifier).cancel();
    super.dispose();
  }

  void _start() {
    final notifier = ref.read(diagnosisControllerProvider.notifier);
    if (widget.onDevice) {
      notifier.runOnDevice(
        packageName: widget.packageName,
        lines: widget.logLines ?? const [],
      );
      return;
    }
    notifier.run(
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

  Future<File> _writeMdxdFile() async {
    final state = ref.read(diagnosisControllerProvider);
    final report = state.report;
    if (report == null) {
      throw StateError('No diagnosis report');
    }
    Map<String, String> identity = const {};
    Directory? dir;
    if (widget.onDevice) {
      identity = await deviceBridge.deviceIdentity();
      final mdx = await deviceBridge.mdxDirectory();
      if (mdx.isNotEmpty) dir = Directory(mdx);
    }
    return DiagnosisReportExport.writeMdxd(
      report: report,
      serial: state.serial ?? widget.serial,
      packageName: state.packageName ?? widget.packageName,
      appLabel: widget.appLabel,
      brand: identity['brand'] ?? '',
      model: identity['model'] ?? '',
      deviceName: identity['deviceName'] ?? '',
      manufacturer: identity['manufacturer'] ?? '',
      anrEvents: state.anrEvents,
      startedAt: state.startedAt,
      finishedAt: state.finishedAt,
      bugreportZipPath: state.bugreportResult?.zipPath,
      bugreportExtractDir: state.bugreportResult?.extractDir,
      perfettoTracePath: state.perfettoResult?.traceFile.path,
      perfettoProcessorNote: state.perfettoResult?.processorNote,
      directory: dir,
    );
  }

  Future<void> _exportMdxd() async {
    final report = ref.read(diagnosisControllerProvider).report;
    if (report == null) return;
    setState(() {
      _exporting = true;
      _exportMessage = null;
    });
    try {
      final file = await _writeMdxdFile();
      if (!mounted) return;
      setState(() {
        _exporting = false;
        _exportMessage = 'Saved ${file.path}';
      });
      if (widget.onDevice) {
        await offerMdxActions(
          context,
          path: file.path,
          applicationId: widget.packageName ?? kDiagnosticAndroidPackage,
          source: 'diagnose',
        );
      }
    } catch (err) {
      if (!mounted) return;
      setState(() {
        _exporting = false;
        _exportMessage = 'Could not save .mdxd: $err';
      });
    }
  }

  Future<void> _sendToAppBuilder() async {
    final state = ref.read(diagnosisControllerProvider);
    final report = state.report;
    if (report == null) return;

    final packageName = state.packageName ?? widget.packageName;
    if (packageName == null || packageName.trim().isEmpty) {
      if (!mounted) return;
      setState(() {
        _exportMessage = 'No package name — cannot send to App Builder.';
      });
      return;
    }

    setState(() {
      _sendingToAppBuilder = true;
      _exportMessage = null;
    });

    try {
      final serial = state.serial ?? widget.serial;
      final payload = DiagnosisReportExport.buildPayloadMap(
        report: report,
        serial: serial,
        packageName: packageName,
        anrEvents: state.anrEvents,
        startedAt: state.startedAt,
        finishedAt: state.finishedAt,
        bugreportZipPath: state.bugreportResult?.zipPath,
        bugreportExtractDir: state.bugreportResult?.extractDir,
        perfettoTracePath: state.perfettoResult?.traceFile.path,
        perfettoProcessorNote: state.perfettoResult?.processorNote,
      );
      final markdown = DiagnosisReportExport.buildMarkdown(
        report: report,
        serial: serial,
        packageName: packageName,
        anrEvents: state.anrEvents,
        startedAt: state.startedAt,
        finishedAt: state.finishedAt,
        bugreportZipPath: state.bugreportResult?.zipPath,
        bugreportExtractDir: state.bugreportResult?.extractDir,
        perfettoTracePath: state.perfettoResult?.traceFile.path,
        perfettoProcessorNote: state.perfettoResult?.processorNote,
      );

      File? attachment;
      try {
        attachment = await _writeMdxdFile();
      } catch (_) {
        attachment = null;
      }
      if (attachment == null) {
        final zipPath = state.bugreportResult?.zipPath;
        if (zipPath != null && zipPath.isNotEmpty) {
          final file = File(zipPath);
          if (await file.exists()) attachment = file;
        }
      }

      final result = await _fieldReports.upload(
        applicationId: packageName,
        kind: FieldReportKinds.diagnosis,
        title: topFindingFor(report),
        deviceSerial: serial,
        textBody: markdown,
        payloadJson: {
          ...payload,
          'format': 'mdxd',
          'magic': kMdxdMagic,
        },
        attachment: attachment,
      );

      if (!mounted) return;
      setState(() {
        _sendingToAppBuilder = false;
        _exportMessage = 'Sent to App Builder (report ${result.id}).';
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Sent to App Builder (${result.id}).'),
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 3),
        ),
      );
    } on FieldReportUploadException catch (err) {
      if (!mounted) return;
      final message = fieldReportUserMessage(err);
      setState(() {
        _sendingToAppBuilder = false;
        _exportMessage = message;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(message),
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 5),
        ),
      );
    } catch (err) {
      if (!mounted) return;
      final message = 'Could not reach App Builder ($err).';
      setState(() {
        _sendingToAppBuilder = false;
        _exportMessage = message;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(message),
          behavior: SnackBarBehavior.floating,
        ),
      );
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

  String get _pageTitle {
    final name = widget.appLabel?.trim();
    if (name == null || name.isEmpty) return 'Diagnose';
    return 'Diagnose · $name';
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(diagnosisControllerProvider);
    // Progress stays a centered mid-window card. The finished report needs the
    // full width for its stat grid, so it keeps edge-to-edge DesktopContent.
    if (!state.isDone) {
      // Narrow centered card — not a full-bleed strip. Cap well below
      // Desk.formWidth so a maximized Windows window still shows clear
      // empty margin on both sides.
      return SettingsPageScaffold(
        title: _pageTitle,
        showBackButton: !kDesktopCustomTitleBar,
        embedInParentAmbient: kDesktopCustomTitleBar,
        body: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520),
              child: SizedBox(
                width: double.infinity,
                child: _ProgressPanel(
                  state: state,
                  fallbackSerial: widget.serial,
                  fallbackPackageName: widget.packageName,
                  fallbackAppLabel: widget.appLabel,
                  onDevice: widget.onDevice,
                  onCancel: () {
                    ref.read(diagnosisControllerProvider.notifier).cancel();
                    if (context.mounted) Navigator.of(context).maybePop();
                  },
                  onRetry: _start,
                ),
              ),
            ),
          ),
        ),
      );
    }
    return SettingsPageScaffold(
      title: _pageTitle,
      showBackButton: !kDesktopCustomTitleBar,
      embedInParentAmbient: kDesktopCustomTitleBar,
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
        children: [
          DesktopContent(
            child: _ReportView(
              state: state,
              fallbackSerial: widget.serial,
              fallbackPackageName: widget.packageName,
              fallbackAppLabel: widget.appLabel,
              onDevice: widget.onDevice,
              exporting: _exporting,
              sendingToAppBuilder: _sendingToAppBuilder,
              exportMessage: _exportMessage,
              onExport: _export,
              onExportMdxd: _exportMdxd,
              onSendToAppBuilder: _sendToAppBuilder,
              onOpenPerfetto: _openInPerfetto,
              onRunAgain: _start,
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

class _ProgressPanel extends ConsumerWidget {
  const _ProgressPanel({
    required this.state,
    required this.fallbackSerial,
    required this.fallbackPackageName,
    required this.onCancel,
    required this.onRetry,
    this.fallbackAppLabel,
    this.onDevice = false,
  });

  final DiagnosisState state;
  final String fallbackSerial;
  final String? fallbackPackageName;
  final String? fallbackAppLabel;
  final VoidCallback onCancel;
  final VoidCallback onRetry;
  final bool onDevice;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final names = ref.watch(deviceNamesProvider);
    final serial = state.serial ?? fallbackSerial;
    final packageName = state.packageName ?? fallbackPackageName;
    final deviceLabel = resolveSerialLabel(names, serial);
    final packageLabel = _diagnoseAppLabel(
      appLabel: fallbackAppLabel,
      packageName: packageName,
    );
    final elapsed = state.elapsed;
    final elapsedLabel = elapsed == null
        ? null
        : '${elapsed.inMinutes}:'
              '${(elapsed.inSeconds % 60).toString().padLeft(2, '0')}';

    final steps = <_StepInfo>[
      _StepInfo(
        DiagnosisStep.scanningLogcat,
        onDevice ? 'Dump live logcat' : 'Scan logcat for ANRs',
        Icons.subject_rounded,
        true,
      ),
      _StepInfo(
        DiagnosisStep.dumpsys,
        'Dumpsys gfx / mem / cpu',
        Icons.speed_rounded,
        state.includeDumpsys,
      ),
      _StepInfo(
        DiagnosisStep.bugreport,
        'Pull bugreport',
        Icons.description_rounded,
        state.includeBugreport,
      ),
      _StepInfo(
        DiagnosisStep.parsing,
        'Parse ANR traces',
        Icons.manage_search_rounded,
        state.includeBugreport,
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
              _DiagnosisTarget(
                deviceLabel: deviceLabel,
                serial: serial,
                packageLabel: packageLabel,
              ),
              const SizedBox(height: 12),
              _PipelineProgressBar(
                statuses: [
                  for (final step in steps)
                    _statusFor(state, step.step, step.enabled),
                ],
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



class _DiagnosisTarget extends StatelessWidget {
  const _DiagnosisTarget({
    required this.deviceLabel,
    required this.serial,
    required this.packageLabel,
  });

  final String deviceLabel;
  final String serial;
  final String packageLabel;

  @override
  Widget build(BuildContext context) {
    final muted = AmlTheme.mutedOf(context);
    final showSerial = deviceLabel != serial;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
      decoration: BoxDecoration(
        color: AmlTheme.violet.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(Desk.row),
        border: Border.all(
          color: AmlTheme.violet.withValues(alpha: 0.18),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'TARGET',
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w800,
              letterSpacing: 0.6,
              color: muted,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            packageLabel,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: 13.5,
              fontWeight: FontWeight.w800,
              height: 1.25,
              letterSpacing: -0.1,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            showSerial ? '$deviceLabel · $serial' : deviceLabel,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 11.5,
              fontWeight: FontWeight.w600,
              color: muted,
            ),
          ),
        ],
      ),
    );
  }
}

class _PipelineProgressBar extends StatelessWidget {
  const _PipelineProgressBar({required this.statuses});

  final List<_RowStatus> statuses;

  @override
  Widget build(BuildContext context) {
    final track = AmlTheme.isDark(context)
        ? Colors.white.withValues(alpha: 0.08)
        : const Color(0xFFE6E1F4);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            for (var i = 0; i < statuses.length; i++) ...[
              if (i > 0) const SizedBox(width: 4),
              Expanded(child: _seg(statuses[i], track)),
            ],
          ],
        ),
        const SizedBox(height: 6),
        Text(
          _caption(statuses),
          style: TextStyle(
            fontSize: 11.5,
            fontWeight: FontWeight.w600,
            color: AmlTheme.mutedOf(context),
          ),
        ),
      ],
    );
  }

  static Widget _seg(_RowStatus status, Color track) {
    final Color fill;
    switch (status) {
      case _RowStatus.done:
        fill = AmlTheme.mint;
      case _RowStatus.active:
        fill = AmlTheme.violet;
      case _RowStatus.error:
        fill = Desk.danger;
      case _RowStatus.skipped:
        fill = track;
      case _RowStatus.pending:
        fill = track;
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(99),
      child: SizedBox(
        height: 6,
        child: ColoredBox(color: fill),
      ),
    );
  }

  static String _caption(List<_RowStatus> statuses) {
    final total = statuses.where((s) => s != _RowStatus.skipped).length;
    final done = statuses.where((s) => s == _RowStatus.done).length;
    final active = statuses.indexWhere((s) => s == _RowStatus.active);
    final failed = statuses.indexWhere((s) => s == _RowStatus.error);
    if (failed >= 0) {
      return 'Stopped at step ${failed + 1} of ${statuses.length}';
    }
    if (done >= total && total > 0) {
      return 'All $total steps complete';
    }
    if (active >= 0) {
      return 'Step ${active + 1} of ${statuses.length}';
    }
    return 'Step $done of $total';
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
        leading = SizedBox(
          width: 16,
          height: 16,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            color: AmlTheme.violet,
          ),
        );
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
    required this.fallbackPackageName,
    required this.exporting,
    required this.sendingToAppBuilder,
    required this.exportMessage,
    required this.onExport,
    required this.onExportMdxd,
    required this.onSendToAppBuilder,
    required this.onOpenPerfetto,
    required this.onRunAgain,
    this.fallbackAppLabel,
    this.onDevice = false,
  });

  final DiagnosisState state;
  final String fallbackSerial;
  final String? fallbackPackageName;
  final String? fallbackAppLabel;
  final bool exporting;
  final bool sendingToAppBuilder;
  final String? exportMessage;
  final void Function(bool asJson) onExport;
  final VoidCallback onExportMdxd;
  final VoidCallback onSendToAppBuilder;
  final VoidCallback onOpenPerfetto;
  final VoidCallback onRunAgain;
  final bool onDevice;

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
    final packageName = state.packageName ?? fallbackPackageName;
    final canSendToAppBuilder =
        packageName != null && packageName.trim().isNotEmpty;

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
              _diagnoseAppLabel(
                appLabel: fallbackAppLabel,
                packageName: packageName,
                empty: 'no package',
              ),
              if (elapsed != null) formatDiagnosisElapsed(elapsed),
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
            final maxW = constraints.maxWidth.isFinite
                ? constraints.maxWidth
                : 400.0;
            final columns = maxW >= 680 ? 4 : 2;
            const gap = 10.0;
            final cards = <Widget>[
              if (onDevice) ...[
                _StatCard(
                  icon: Icons.error_outline_rounded,
                  accent: AmlTheme.pink,
                  label: 'Errors',
                  value: '${report.errorLines}',
                ),
                _StatCard(
                  icon: Icons.warning_amber_rounded,
                  accent: AmlTheme.amber,
                  label: 'Warnings',
                  value: '${report.warningLines}',
                ),
                _StatCard(
                  icon: Icons.subject_rounded,
                  accent: AmlTheme.sky,
                  label: 'Lines scanned',
                  value: '${report.scannedLines}',
                ),
              ] else ...[
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
                  value: pssMb == null
                      ? '—'
                      : '${pssMb.toStringAsFixed(0)} MB',
                ),
              ],
              _StatCard(
                icon: Icons.priority_high_rounded,
                accent: AmlTheme.violet,
                label: 'Top finding',
                value: state.topFinding,
                valueFontSize: 12.5,
                valueMaxLines: 3,
              ),
            ];
            return Column(
              children: [
                for (var i = 0; i < cards.length; i += columns) ...[
                  if (i > 0) const SizedBox(height: gap),
                  IntrinsicHeight(
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        for (var j = 0;
                            j < columns && i + j < cards.length;
                            j++) ...[
                          if (j > 0) const SizedBox(width: gap),
                          Expanded(child: cards[i + j]),
                        ],
                      ],
                    ),
                  ),
                ],
              ],
            );
          },
        ),
        const SizedBox(height: 10),
        if (onDevice) _WatchHighlights(report: report),
        if (!onDevice || report.mainThreadFrames.isNotEmpty) ...[
          if (onDevice) const SizedBox(height: 10),
          _AnrStackViewer(report: report),
        ],
        if (!onDevice) ...[
          const SizedBox(height: 10),
          _PerfettoSection(
            report: report,
            tracePath: state.perfettoResult?.traceFile.path,
            onOpen: onOpenPerfetto,
          ),
        ],
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
                    'Writes a .mdxd capture you can send in MessageMe or App Builder.',
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  FilledButton.icon(
                    onPressed: exporting ? null : onExportMdxd,
                    icon: const Icon(Icons.troubleshoot_rounded, size: 16),
                    label: const Text('Export .mdxd'),
                  ),
                  OutlinedButton.icon(
                    onPressed: exporting ? null : () => onExport(false),
                    icon: const Icon(Icons.description_outlined, size: 16),
                    label: const Text('Export .md'),
                  ),
                  OutlinedButton.icon(
                    onPressed: exporting ? null : () => onExport(true),
                    icon: const Icon(Icons.data_object_rounded, size: 16),
                    label: const Text('Export .json'),
                  ),
                  OutlinedButton.icon(
                    onPressed: (exporting ||
                            sendingToAppBuilder ||
                            !canSendToAppBuilder)
                        ? null
                        : onSendToAppBuilder,
                    icon: const Icon(Icons.cloud_upload_outlined, size: 16),
                    label: const Text('Send to App Builder'),
                  ),
                  if (exporting || sendingToAppBuilder)
                    const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
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
        if (!onDevice) ...[
          const SizedBox(height: 10),
          AiDiagnosisPanel(report: report),
        ],
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
    return Container(
      alignment: Alignment.topLeft,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: Desk.panelFill(context),
        borderRadius: BorderRadius.circular(Desk.panel),
        border: Border.all(color: Desk.hairline(context)),
      ),
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
          const SizedBox(height: 8),
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

class _WatchHighlights extends StatelessWidget {
  const _WatchHighlights({required this.report});

  final DiagnosisReport report;

  @override
  Widget build(BuildContext context) {
    final muted = AmlTheme.mutedOf(context);
    final lines = report.logcatContext;
    final extra = report.logFindings.length > 1
        ? report.logFindings.skip(1).toList()
        : const <String>[];
    return DesktopPanel(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          DesktopPanelHeader(
            icon: Icons.manage_search_rounded,
            accent: AmlTheme.violet,
            title: 'Log highlights',
            subtitle: lines.isEmpty
                ? 'Nothing noisy in this Watch buffer.'
                : '${lines.length} recent error or warning line'
                    '${lines.length == 1 ? '' : 's'}',
          ),
          if (extra.isNotEmpty) ...[
            const SizedBox(height: 10),
            for (final finding in extra)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text(
                  finding,
                  style: TextStyle(
                    fontSize: 12.5,
                    height: 1.35,
                    fontWeight: FontWeight.w600,
                    color: muted,
                  ),
                ),
              ),
          ],
          if (lines.isNotEmpty) ...[
            const SizedBox(height: 10),
            SelectableText(
              lines.join('\n'),
              style: Desk.mono(size: 11.5, color: AmlTheme.inkOf(context)),
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
