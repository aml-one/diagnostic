import 'package:aml_ui/aml_ui.dart';
import 'package:flutter/material.dart';

import '../../core/logcat/logcat_collapse.dart';
import '../../core/mobile/phone_diagnostic.dart';
import '../../core/mobile/self_check.dart';
import '../../widgets/logcat_row.dart';
import 'mdx_share_sheet.dart';

/// Review leftover Diagnostic crash and error logcat. Uploads automatically.
class AndroidSelfCheckScreen extends StatefulWidget {
  const AndroidSelfCheckScreen({super.key, required this.check});

  final DiagnosticSelfCheck check;

  static const _previewCap = 400;

  @override
  State<AndroidSelfCheckScreen> createState() => _AndroidSelfCheckScreenState();
}

class _AndroidSelfCheckScreenState extends State<AndroidSelfCheckScreen> {
  DiagnosticSelfCheck get check => widget.check;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final path = check.path;
      if (!mounted || path == null || path.isEmpty) return;
      offerMdxActions(
        context,
        path: path,
        applicationId: kDiagnosticAndroidPackage,
        source: 'self-check',
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final dark = AmlTheme.isDark(context);
    final ink = AmlTheme.inkOf(context);
    final muted = AmlTheme.mutedOf(context);
    final lines = check.lines;
    final previewCap = AndroidSelfCheckScreen._previewCap;
    final previewSource = lines.length <= previewCap
        ? lines
        : lines.sublist(lines.length - previewCap);
    final preview = collapseLogcatLines(previewSource);
    final skipped = lines.length - previewSource.length;
    return Scaffold(
      backgroundColor: dark ? AmlTheme.darkBg : kSettingsPageBackground,
      body: Stack(
        fit: StackFit.expand,
        children: [
          const Positioned.fill(child: SettingsAmbientBackground()),
          SafeArea(
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(4, 0, 12, 8),
                  child: Row(
                    children: [
                      IconButton(
                        tooltip: 'Back',
                        onPressed: () => Navigator.of(context).maybePop(),
                        icon: const Icon(Icons.arrow_back_rounded),
                      ),
                      const SizedBox(width: 4),
                      settingsPastelIcon(
                        Icons.monitor_heart_rounded,
                        'diagnostic',
                        dimension: 40,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Diagnostic',
                              style: TextStyle(
                                fontSize: 18,
                                height: 1.1,
                                fontWeight: FontWeight.w800,
                                color: ink,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              'Self-check · ${check.lines.length} lines'
                              '${check.fatalCount > 0 ? ' · ${check.fatalCount} fatal' : ''}'
                              '${check.errorCount > 0 ? ' · ${check.errorCount} errors' : ''}',
                              style: TextStyle(
                                fontSize: 12.5,
                                height: 1.2,
                                fontWeight: FontWeight.w600,
                                color: muted,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: Text(
                    'Leftover crash and error logcat from this app. It uploads to the server automatically. Hide the tile until something new shows up.',
                    style: TextStyle(
                      fontSize: 13,
                      height: 1.35,
                      fontWeight: FontWeight.w600,
                      color: muted,
                    ),
                  ),
                ),
                Expanded(
                  child: Material(
                    color: (dark ? AmlTheme.darkSurface : Colors.white)
                        .withValues(alpha: dark ? 0.72 : 0.9),
                    child: ListView.builder(
                      padding: const EdgeInsets.fromLTRB(8, 8, 8, 16),
                      itemCount: preview.length + (skipped > 0 ? 1 : 0),
                      itemBuilder: (context, index) {
                        if (skipped > 0 && index == 0) {
                          return Padding(
                            padding: const EdgeInsets.fromLTRB(8, 4, 8, 10),
                            child: Text(
                              'Showing the last ${preview.length} of ${lines.length} lines.',
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w700,
                                color: muted,
                              ),
                            ),
                          );
                        }
                        final row = preview[index - (skipped > 0 ? 1 : 0)];
                        return LogcatRow(
                          line: row.line,
                          zebra: index.isOdd,
                          stacked: true,
                          repeatCount: row.count,
                        );
                      },
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
                  child: Row(
                    children: [
                      Expanded(
                        child: OutlinedButton(
                          onPressed: () => _dismiss(context),
                          child: const Text('Hide'),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: FilledButton(
                          onPressed: check.path == null || check.path!.isEmpty
                              ? null
                              : () => _send(context),
                          child: const Text('Done'),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _dismiss(BuildContext context) async {
    await dismissDiagnosticSelfCheck(check);
    if (!context.mounted) return;
    Navigator.of(context).pop(true);
  }

  Future<void> _send(BuildContext context) async {
    final path = check.path;
    if (path == null || path.isEmpty) return;
    await offerMdxActions(
      context,
      path: path,
      applicationId: kDiagnosticAndroidPackage,
      source: 'self-check',
    );
    await dismissDiagnosticSelfCheck(check);
    if (!context.mounted) return;
    Navigator.of(context).pop(true);
  }
}
