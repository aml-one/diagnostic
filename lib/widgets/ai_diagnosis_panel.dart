import 'package:aml_ui/aml_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/diagnosis/diagnosis_report.dart';
import '../screens/settings_screen.dart';
import '../state/deepseek_providers.dart';

/// Ask DeepSeek card for Diagnose. Orchestrator can drop this on the report.
class AiDiagnosisPanel extends ConsumerStatefulWidget {
  const AiDiagnosisPanel({
    super.key,
    required this.report,
  });

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
    await ref
        .read(deepSeekDiagnosisControllerProvider.notifier)
        .followUp(text);
  }

  void _openSettings() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => const SettingsScreen()),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ink = AmlTheme.inkOf(context);
    final muted = AmlTheme.mutedOf(context);
    final hasKey = ref.watch(hasDeepSeekApiKeyProvider);
    final view = ref.watch(deepSeekDiagnosisControllerProvider);

    return SettingsSurface(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              settingsPastelIcon(Icons.auto_awesome_rounded, 'violet'),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  'AI diagnosis',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w800,
                    color: ink,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            'Sends a capped ANR evidence bundle to DeepSeek. '
            'This uses your key and is not automatic.',
            style: TextStyle(fontSize: 13, height: 1.35, color: muted),
          ),
          const SizedBox(height: 14),
          if (!hasKey)
            SizedBox(
              width: double.infinity,
              child: OutlinedButton(
                onPressed: _openSettings,
                child: const Text('Add DeepSeek API key'),
              ),
            )
          else
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: view.busy || !widget.report.hasEvidence
                    ? null
                    : _ask,
                child: Text(
                  view.hasReply ? 'Ask DeepSeek again' : 'Ask DeepSeek',
                ),
              ),
            ),
          if (hasKey && !widget.report.hasEvidence) ...[
            const SizedBox(height: 8),
            Text(
              'No ANR evidence yet. Capture a trace first.',
              style: TextStyle(fontSize: 13, color: muted),
            ),
          ],
          if (view.busy) ...[
            const SizedBox(height: 20),
            const Center(
              child: BirdLoader(
                size: 88,
                semanticsLabel: 'Asking DeepSeek',
              ),
            ),
            const SizedBox(height: 8),
            Center(
              child: Text(
                'DeepSeek is reading the traces…',
                style: TextStyle(fontSize: 13, color: muted),
              ),
            ),
          ],
          if (view.error != null) ...[
            const SizedBox(height: 12),
            Text(
              view.error!,
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: Color(0xFFE85D75),
              ),
            ),
          ],
          if (view.diagnosis != null) ...[
            const SizedBox(height: 16),
            _ReplyCard(text: view.diagnosis!),
          ],
          for (final turn in view.followUps) ...[
            const SizedBox(height: 12),
            if (turn.role == 'user')
              Align(
                alignment: Alignment.centerRight,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 520),
                  child: Text(
                    turn.content,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                      color: ink,
                    ),
                  ),
                ),
              )
            else
              _ReplyCard(text: turn.content),
          ],
          if (view.hasReply && !view.busy) ...[
            const SizedBox(height: 14),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _followUp,
                    textInputAction: TextInputAction.send,
                    onSubmitted: (_) => _sendFollowUp(),
                    decoration: const InputDecoration(
                      labelText: 'Follow-up',
                      hintText: 'Ask about a frame or lock…',
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton.filled(
                  tooltip: 'Send',
                  onPressed: _sendFollowUp,
                  icon: const Icon(Icons.send_rounded),
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
    return Material(
      color: AmlTheme.panelOf(context),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: AmlTheme.strokeOf(context)),
      ),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
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
    var size = 14.0;
    if (line.startsWith('### ')) {
      line = line.substring(4);
      weight = FontWeight.w800;
      size = 15;
    } else if (line.startsWith('## ')) {
      line = line.substring(3);
      weight = FontWeight.w800;
      size = 16;
    } else if (line.startsWith('# ')) {
      line = line.substring(2);
      weight = FontWeight.w800;
      size = 17;
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
