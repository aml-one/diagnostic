import 'package:aml_ui/aml_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/diagnosis/diagnosis_report.dart';
import '../screens/settings_screen.dart';
import '../state/deepseek_providers.dart';
import '../theme/desktop_theme.dart';
import 'desktop_chrome.dart';

/// Ask DeepSeek card for Diagnose. Orchestrator can drop this on the report.
class AiDiagnosisPanel extends ConsumerStatefulWidget {
  const AiDiagnosisPanel({super.key, required this.report});

  final DiagnosisReport report;

  @override
  ConsumerState<AiDiagnosisPanel> createState() => _AiDiagnosisPanelState();
}

class _AiDiagnosisPanelState extends ConsumerState<AiDiagnosisPanel> {
  final _followUp = TextEditingController();

  @override
  void initState() {
    super.initState();
    Future<void>.microtask(() {
      if (!mounted) return;
      ref.read(deepSeekDiagnosisControllerProvider.notifier).reset();
    });
  }

  @override
  void dispose() {
    _followUp.dispose();
    super.dispose();
  }

  Future<void> _ask() {
    return ref
        .read(deepSeekDiagnosisControllerProvider.notifier)
        .ask(widget.report);
  }

  Future<void> _sendFollowUp() async {
    final text = _followUp.text;
    _followUp.clear();
    await ref.read(deepSeekDiagnosisControllerProvider.notifier).followUp(text);
  }

  void _openSettings() {
    Navigator.of(
      context,
    ).push(MaterialPageRoute<void>(builder: (_) => const SettingsScreen()));
  }

  @override
  Widget build(BuildContext context) {
    final ink = AmlTheme.inkOf(context);
    final muted = AmlTheme.mutedOf(context);
    final hasKey = ref.watch(hasDeepSeekApiKeyProvider);
    final view = ref.watch(deepSeekDiagnosisControllerProvider);

    return DesktopPanel(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const DesktopPanelHeader(
            icon: Icons.auto_awesome_rounded,
            accent: AmlTheme.violet,
            title: 'AI diagnosis',
            subtitle:
                'Sends a capped ANR evidence bundle to DeepSeek. '
                'This uses your key and is not automatic.',
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              if (!hasKey)
                OutlinedButton.icon(
                  onPressed: _openSettings,
                  icon: const Icon(Icons.key_rounded, size: 16),
                  label: const Text('Add DeepSeek API key'),
                )
              else
                FilledButton.icon(
                  onPressed: view.busy || !widget.report.hasEvidence
                      ? null
                      : _ask,
                  icon: const Icon(Icons.auto_awesome_rounded, size: 16),
                  label: Text(
                    view.hasReply ? 'Ask DeepSeek again' : 'Ask DeepSeek',
                  ),
                ),
              if (view.busy) ...[
                const SizedBox(width: 12),
                const BirdLoader(size: 28, semanticsLabel: 'Asking DeepSeek'),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'DeepSeek is reading the traces…',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12, color: muted),
                  ),
                ),
              ] else if (hasKey && !widget.report.hasEvidence) ...[
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'No ANR evidence yet. Capture a trace first.',
                    maxLines: 2,
                    style: TextStyle(fontSize: 12, height: 1.3, color: muted),
                  ),
                ),
              ],
            ],
          ),
          if (view.error != null) ...[
            const SizedBox(height: 10),
            Text(
              view.error!,
              style: const TextStyle(
                fontSize: 12.5,
                height: 1.35,
                fontWeight: FontWeight.w600,
                color: Desk.danger,
              ),
            ),
          ],
          if (view.diagnosis != null) ...[
            const SizedBox(height: 12),
            _ReplyCard(text: view.diagnosis!),
          ],
          for (final turn in view.followUps) ...[
            const SizedBox(height: 10),
            if (turn.role == 'user')
              Align(
                alignment: Alignment.centerRight,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 520),
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: AmlTheme.violet.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(Desk.row),
                      border: Border.all(
                        color: AmlTheme.violet.withValues(alpha: 0.28),
                      ),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(10, 7, 10, 7),
                      child: Text(
                        turn.content,
                        style: TextStyle(
                          fontSize: 13,
                          height: 1.35,
                          fontWeight: FontWeight.w700,
                          color: ink,
                        ),
                      ),
                    ),
                  ),
                ),
              )
            else
              _ReplyCard(text: turn.content),
          ],
          if (view.hasReply && !view.busy) ...[
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: SizedBox(
                    height: Desk.buttonHeight,
                    child: TextField(
                      controller: _followUp,
                      textInputAction: TextInputAction.send,
                      style: const TextStyle(fontSize: 13),
                      onSubmitted: (_) => _sendFollowUp(),
                      decoration: const InputDecoration(
                        hintText: 'Ask about a frame or lock…',
                        contentPadding: EdgeInsets.symmetric(horizontal: 10),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                SizedBox(
                  height: Desk.buttonHeight,
                  child: FilledButton.icon(
                    onPressed: _sendFollowUp,
                    icon: const Icon(Icons.send_rounded, size: 16),
                    label: const Text('Send'),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _ReplyCard extends StatelessWidget {
  const _ReplyCard({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final ink = AmlTheme.inkOf(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Desk.logSurface(context),
        borderRadius: BorderRadius.circular(Desk.row),
        border: Border.all(color: Desk.hairline(context)),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
        child: SelectableText.rich(
          TextSpan(children: _markdownIshSpans(text, ink)),
        ),
      ),
    );
  }
}

List<InlineSpan> _markdownIshSpans(String text, Color ink) {
  final spans = <InlineSpan>[];
  final lines = text.split('\n');
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i];
    var weight = FontWeight.w500;
    var size = 13.0;
    if (line.startsWith('### ')) {
      line = line.substring(4);
      weight = FontWeight.w800;
      size = 14;
    } else if (line.startsWith('## ')) {
      line = line.substring(3);
      weight = FontWeight.w800;
      size = 14.5;
    } else if (line.startsWith('# ')) {
      line = line.substring(2);
      weight = FontWeight.w800;
      size = 15.5;
    } else if (line.startsWith('- ') || line.startsWith('* ')) {
      line = '• ${line.substring(2)}';
    }
    spans.addAll(_boldSpans(line, ink, weight, size));
    if (i != lines.length - 1) {
      spans.add(const TextSpan(text: '\n'));
    }
  }
  return spans;
}

List<InlineSpan> _boldSpans(
  String line,
  Color ink,
  FontWeight weight,
  double size,
) {
  final spans = <InlineSpan>[];
  final pattern = RegExp(r'\*\*(.+?)\*\*');
  var start = 0;
  for (final match in pattern.allMatches(line)) {
    if (match.start > start) {
      spans.add(
        TextSpan(
          text: line.substring(start, match.start),
          style: TextStyle(
            fontSize: size,
            height: 1.4,
            fontWeight: weight,
            color: ink,
          ),
        ),
      );
    }
    spans.add(
      TextSpan(
        text: match.group(1),
        style: TextStyle(
          fontSize: size,
          height: 1.4,
          fontWeight: FontWeight.w800,
          color: ink,
        ),
      ),
    );
    start = match.end;
  }
  if (start < line.length || spans.isEmpty) {
    spans.add(
      TextSpan(
        text: line.substring(start),
        style: TextStyle(
          fontSize: size,
          height: 1.4,
          fontWeight: weight,
          color: ink,
        ),
      ),
    );
  }
  return spans;
}
