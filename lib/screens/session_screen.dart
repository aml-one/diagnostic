import 'dart:async';

import 'package:aml_ui/aml_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/logcat/anr_detector.dart';
import '../core/logcat/logcat_parser.dart';
import '../core/logcat/logcat_session.dart';
import '../state/logcat_providers.dart';
import '../state/package_providers.dart';
import 'diagnose_screen.dart';

class SessionScreen extends ConsumerStatefulWidget {
  const SessionScreen({
    super.key,
    required this.serial,
    required this.packageName,
  });

  final String serial;
  final String packageName;

  @override
  ConsumerState<SessionScreen> createState() => _SessionScreenState();
}

class _SessionScreenState extends ConsumerState<SessionScreen> {
  final _lines = <LogcatLine>[];
  final _scroll = ScrollController();
  StreamSubscription<LogcatLine>? _sub;
  Timer? _tick;
  var _dirty = false;
  var _started = false;
  var _pinToBottom = true;

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(milliseconds: 100), (_) => _flush());
    _scroll.addListener(_onScroll);
    WidgetsBinding.instance.addPostFrameCallback((_) => _begin());
  }

  @override
  void dispose() {
    _tick?.cancel();
    _sub?.cancel();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _begin() async {
    if (_started || !mounted) return;
    _started = true;
    await ref.read(appSessionProvider.notifier).startAndWatch(
          serial: widget.serial,
          packageName: widget.packageName,
          onWatching: () {
            unawaited(_sub?.cancel() ?? Future<void>.value());
            if (!mounted) return;
            final session = ref.read(logcatSessionProvider.notifier).session;
            _sub = session?.lines.listen(_onLine);
          },
        );
  }

  void _onLine(LogcatLine line) {
    _lines.add(line);
    if (_lines.length > 3000) {
      _lines.removeRange(0, _lines.length - 3000);
    }
    _dirty = true;
  }

  void _onScroll() {
    if (!_scroll.hasClients) return;
    final distance = _scroll.position.maxScrollExtent - _scroll.position.pixels;
    _pinToBottom = distance < 80;
  }

  void _flush() {
    if (!_dirty || !mounted) return;
    _dirty = false;
    setState(() {});
    if (!_pinToBottom || !_scroll.hasClients) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      _scroll.jumpTo(_scroll.position.maxScrollExtent);
    });
  }

  Future<void> _stop() async {
    await ref.read(appSessionProvider.notifier).stop();
    if (mounted) Navigator.of(context).maybePop();
  }

  void _openDiagnose({AnrEvent? event}) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => DiagnoseScreen(
          serial: widget.serial,
          packageName: widget.packageName,
          event: event,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(appSessionProvider);
    final logcat = ref.watch(logcatSessionProvider);
    final ink = AmlTheme.inkOf(context);
    final pid = session.pid;
    final showAll = session.showAllLogs;
    final launching = session.launching;
    final anr = logcat.recentAnrs.isEmpty ? null : logcat.recentAnrs.last;
    final visible = _visibleLines(pid: pid, showAll: showAll);

    return PopScope(
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) {
          unawaited(ref.read(appSessionProvider.notifier).stop());
        }
      },
      child: Scaffold(
        backgroundColor: AmlTheme.isDark(context)
            ? AmlTheme.darkBg
            : kSettingsPageBackground,
        appBar: AppBar(
          title: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                widget.packageName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w800,
                  color: ink,
                ),
              ),
              Text(
                pid == null ? 'PID …' : 'PID $pid',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: AmlTheme.mutedOf(context),
                ),
              ),
            ],
          ),
          backgroundColor: Colors.transparent,
          foregroundColor: ink,
          surfaceTintColor: Colors.transparent,
          elevation: 0,
          actions: [
            if (logcat.anrCount > 0)
              Padding(
                padding: const EdgeInsets.only(right: 4),
                child: Center(child: _AnrBadge(count: logcat.anrCount)),
              ),
            TextButton(
              onPressed: _stop,
              child: const Text('Stop'),
            ),
          ],
        ),
        body: Stack(
          children: [
            const Positioned.fill(child: SettingsAmbientBackground()),
            Positioned.fill(
              child: launching
                  ? const Center(
                      child: BirdLoader(
                        size: 120,
                        semanticsLabel: 'Starting app',
                      ),
                    )
                  : Column(
                      children: [
                        if (session.errorMessage != null)
                          _ErrorBanner(message: session.errorMessage!)
                        else if (anr != null)
                          _AnrBanner(
                            event: anr,
                            onDiagnose: () => _openDiagnose(event: anr),
                          ),
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                          child: SettingsSurface(
                            padding: const EdgeInsets.symmetric(horizontal: 4),
                            child: SwitchListTile.adaptive(
                              contentPadding: const EdgeInsets.symmetric(
                                horizontal: 12,
                              ),
                              title: const Text(
                                'Show all logs',
                                style: TextStyle(fontWeight: FontWeight.w700),
                              ),
                              subtitle: Text(
                                pid == null
                                    ? 'PID not known yet — showing every line'
                                    : 'Dim lines that are not PID $pid',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: AmlTheme.mutedOf(context),
                                ),
                              ),
                              value: showAll || pid == null,
                              onChanged: pid == null
                                  ? null
                                  : (value) => ref
                                        .read(appSessionProvider.notifier)
                                        .setShowAllLogs(value),
                            ),
                          ),
                        ),
                        Expanded(
                          child: logcat.connection ==
                                      LogcatConnectionState.starting &&
                                  visible.isEmpty
                              ? const Center(
                                  child: BirdLoader(
                                    size: 96,
                                    semanticsLabel: 'Starting logcat',
                                  ),
                                )
                              : ListView.builder(
                                  controller: _scroll,
                                  padding: const EdgeInsets.fromLTRB(
                                    16,
                                    0,
                                    16,
                                    8,
                                  ),
                                  itemCount: visible.length,
                                  itemBuilder: (context, index) {
                                    final row = visible[index];
                                    return _LogLineTile(
                                      line: row.line,
                                      dimmed: row.dimmed,
                                    );
                                  },
                                ),
                        ),
                        SafeArea(
                          top: false,
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                            child: SizedBox(
                              width: double.infinity,
                              height: 52,
                              child: FilledButton.icon(
                                onPressed: () => _openDiagnose(event: anr),
                                icon: const Icon(Icons.troubleshoot_rounded),
                                label: const Text('Diagnose'),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }

  List<_VisibleLine> _visibleLines({required int? pid, required bool showAll}) {
    if (pid == null || showAll) {
      return [
        for (final line in _lines)
          _VisibleLine(line: line, dimmed: pid != null && line.pid != pid),
      ];
    }
    final out = <_VisibleLine>[];
    var includeUnparsed = false;
    for (final line in _lines) {
      if (!line.isParsed) {
        if (includeUnparsed) out.add(_VisibleLine(line: line, dimmed: false));
        continue;
      }
      final match = line.pid == pid;
      includeUnparsed = match;
      if (match) out.add(_VisibleLine(line: line, dimmed: false));
    }
    return out;
  }
}

class _VisibleLine {
  const _VisibleLine({required this.line, required this.dimmed});

  final LogcatLine line;
  final bool dimmed;
}

class _LogLineTile extends StatelessWidget {
  const _LogLineTile({required this.line, required this.dimmed});

  final LogcatLine line;
  final bool dimmed;

  @override
  Widget build(BuildContext context) {
    final accent = _levelColor(line.level);
    final ink = AmlTheme.inkOf(context);
    return Opacity(
      opacity: dimmed ? 0.38 : 1,
      child: Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: AmlTheme.panelOf(context).withValues(alpha: 0.92),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: AmlTheme.strokeOf(context)),
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
            child: Text.rich(
              TextSpan(
                children: [
                  TextSpan(
                    text: line.level.isEmpty ? '  ' : '${line.level} ',
                    style: TextStyle(
                      fontWeight: FontWeight.w800,
                      color: accent,
                    ),
                  ),
                  if (line.tag.isNotEmpty)
                    TextSpan(
                      text: '${line.tag}  ',
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        color: ink,
                      ),
                    ),
                  TextSpan(
                    text: line.message.isEmpty ? line.raw : line.message,
                    style: TextStyle(color: AmlTheme.mutedOf(context)),
                  ),
                ],
              ),
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12.5, height: 1.3),
            ),
          ),
        ),
      ),
    );
  }
}

Color _levelColor(String level) {
  switch (level) {
    case 'F':
    case 'E':
      return AmlTheme.pink;
    case 'W':
      return AmlTheme.amber;
    case 'I':
      return AmlTheme.sky;
    default:
      return AmlTheme.violet;
  }
}

class _AnrBadge extends StatelessWidget {
  const _AnrBadge({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: AmlTheme.pink.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: AmlTheme.pink.withValues(alpha: 0.35)),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        child: Text(
          '$count ANR',
          style: const TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w800,
            color: AmlTheme.pink,
          ),
        ),
      ),
    );
  }
}

class _AnrBanner extends StatelessWidget {
  const _AnrBanner({required this.event, required this.onDiagnose});

  final AnrEvent event;
  final VoidCallback onDiagnose;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: Material(
        color: AmlTheme.pink.withValues(alpha: 0.16),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18),
          side: BorderSide(color: AmlTheme.pink.withValues(alpha: 0.4)),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onDiagnose,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
            child: Row(
              children: [
                settingsPastelIcon(
                  Icons.warning_amber_rounded,
                  'pink',
                  iconColor: AmlTheme.pink,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        event.reason,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontWeight: FontWeight.w800,
                          color: AmlTheme.pink,
                        ),
                      ),
                      if (event.packageHint.isNotEmpty)
                        Text(
                          event.packageHint,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 12,
                            color: AmlTheme.mutedOf(context),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: SettingsSurface(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        child: Text(
          message,
          style: const TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: Color(0xFFE85D75),
          ),
        ),
      ),
    );
  }
}
