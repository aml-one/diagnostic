import 'dart:async';

import 'package:aml_ui/aml_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/logcat/anr_detector.dart';
import '../core/logcat/logcat_parser.dart';
import '../core/logcat/logcat_session.dart';
import '../state/logcat_providers.dart';
import '../state/package_providers.dart';
import '../theme/desktop_theme.dart';
import '../widgets/desktop_chrome.dart';
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
    await ref
        .read(appSessionProvider.notifier)
        .startAndWatch(
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
    final muted = AmlTheme.mutedOf(context);
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
          toolbarHeight: 48,
          titleSpacing: 8,
          title: Row(
            children: [
              Flexible(
                child: Text(
                  widget.packageName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -0.1,
                    color: ink,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              DesktopTag(
                label: pid == null ? 'PID …' : 'PID $pid',
                color: AmlTheme.sky,
                mono: true,
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
                padding: const EdgeInsets.only(right: 8),
                child: Center(
                  child: DesktopTag(
                    label: '${logcat.anrCount} ANR',
                    color: AmlTheme.pink,
                    icon: Icons.warning_amber_rounded,
                  ),
                ),
              ),
            Center(
              child: OutlinedButton.icon(
                onPressed: _stop,
                icon: const Icon(Icons.stop_rounded, size: 16),
                label: const Text('Stop'),
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size(0, Desk.smallButtonHeight),
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  foregroundColor: AmlTheme.pink,
                  side: BorderSide(
                    color: AmlTheme.pink.withValues(alpha: 0.42),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 12),
          ],
        ),
        body: launching
            ? const Center(
                child: BirdLoader(size: 72, semanticsLabel: 'Starting app'),
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
                    padding: const EdgeInsets.fromLTRB(12, 2, 12, 8),
                    child: _LogToolbar(
                      pid: pid,
                      showAll: showAll || pid == null,
                      lineCount: visible.length,
                      onChanged: pid == null
                          ? null
                          : (value) => ref
                                .read(appSessionProvider.notifier)
                                .setShowAllLogs(value),
                    ),
                  ),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      child: _LogPane(
                        lines: visible,
                        controller: _scroll,
                        starting:
                            logcat.connection ==
                                LogcatConnectionState.starting &&
                            visible.isEmpty,
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            'Diagnose pulls a bugreport, parses ANR traces and '
                            'records a short Perfetto trace.',
                            maxLines: 2,
                            style: TextStyle(
                              fontSize: 11.5,
                              height: 1.35,
                              color: muted,
                            ),
                          ),
                        ),
                        const SizedBox(width: 16),
                        SizedBox(
                          height: 40,
                          child: FilledButton.icon(
                            onPressed: () => _openDiagnose(event: anr),
                            icon: const Icon(
                              Icons.troubleshoot_rounded,
                              size: 18,
                            ),
                            label: const Text('Diagnose'),
                            style: FilledButton.styleFrom(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 22,
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

/// One compact toolbar row: PID filter switch, its hint, and the line count.
class _LogToolbar extends StatelessWidget {
  const _LogToolbar({
    required this.pid,
    required this.showAll,
    required this.lineCount,
    required this.onChanged,
  });

  final int? pid;
  final bool showAll;
  final int lineCount;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    final ink = AmlTheme.inkOf(context);
    final muted = AmlTheme.mutedOf(context);
    return DesktopPanel(
      padding: const EdgeInsets.symmetric(horizontal: 10),
      child: SizedBox(
        height: Desk.toolbarHeight,
        child: Row(
          children: [
            SizedBox(
              width: 40,
              height: 24,
              child: FittedBox(
                fit: BoxFit.contain,
                child: Switch(
                  value: showAll,
                  onChanged: onChanged,
                  activeTrackColor: AmlTheme.violet,
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
              ),
            ),
            const SizedBox(width: 10),
            Text(
              'Show all logs',
              style: TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w700,
                color: ink,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                pid == null
                    ? 'PID not known yet — showing every line'
                    : 'Dim lines that are not PID $pid',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 11.5, color: muted),
              ),
            ),
            const SizedBox(width: 10),
            DesktopTag(
              label: '$lineCount lines',
              color: AmlTheme.sky,
              mono: true,
            ),
          ],
        ),
      ),
    );
  }
}

/// Dense, flat, selectable monospace log pane (Android Studio Logcat style).
class _LogPane extends StatelessWidget {
  const _LogPane({
    required this.lines,
    required this.controller,
    required this.starting,
  });

  final List<_VisibleLine> lines;
  final ScrollController controller;
  final bool starting;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Desk.logSurface(context),
        borderRadius: BorderRadius.circular(Desk.row),
        border: Border.all(color: Desk.hairline(context)),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(Desk.row),
        child: starting
            ? const Center(
                child: BirdLoader(size: 64, semanticsLabel: 'Starting logcat'),
              )
            : SelectionArea(
                child: Scrollbar(
                  controller: controller,
                  child: ListView.builder(
                    controller: controller,
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    itemExtent: Desk.logRowHeight,
                    itemCount: lines.length,
                    itemBuilder: (context, index) {
                      final row = lines[index];
                      return _LogRow(
                        line: row.line,
                        dimmed: row.dimmed,
                        zebra: index.isOdd,
                      );
                    },
                  ),
                ),
              ),
      ),
    );
  }
}

class _LogRow extends StatelessWidget {
  const _LogRow({
    required this.line,
    required this.dimmed,
    required this.zebra,
  });

  final LogcatLine line;
  final bool dimmed;
  final bool zebra;

  @override
  Widget build(BuildContext context) {
    final accent = Desk.levelColor(line.level);
    final fade = dimmed ? 0.45 : 1.0;
    final ink = AmlTheme.inkOf(context).withValues(alpha: fade);
    final muted = AmlTheme.mutedOf(context).withValues(alpha: 0.85 * fade);
    final message = line.message.isEmpty ? line.raw : line.message;

    return Container(
      color: zebra ? Desk.zebra(context) : null,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      alignment: Alignment.centerLeft,
      child: Row(
        children: [
          SizedBox(
            width: 72,
            child: Text(
              _timeLabel(line.timestamp),
              maxLines: 1,
              style: Desk.mono(size: 10.5, color: muted),
            ),
          ),
          _LevelMarker(level: line.level, color: accent, fade: fade),
          const SizedBox(width: 8),
          SizedBox(
            width: 132,
            child: Text(
              line.tag,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Desk.mono(
                size: 11,
                weight: FontWeight.w700,
                color: accent.withValues(alpha: fade),
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Desk.mono(size: 11.5, color: ink),
            ),
          ),
        ],
      ),
    );
  }
}

class _LevelMarker extends StatelessWidget {
  const _LevelMarker({
    required this.level,
    required this.color,
    required this.fade,
  });

  final String level;
  final Color color;
  final double fade;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 15,
      height: 15,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.18 * fade),
        borderRadius: BorderRadius.circular(Desk.tag),
        border: Border.all(color: color.withValues(alpha: 0.34 * fade)),
      ),
      alignment: Alignment.center,
      child: Text(
        level.isEmpty ? '·' : level,
        style: Desk.mono(
          size: 9.5,
          weight: FontWeight.w800,
          height: 1,
          color: color.withValues(alpha: fade),
        ),
      ),
    );
  }
}

String _timeLabel(DateTime? stamp) {
  if (stamp == null) return '';
  final h = stamp.hour.toString().padLeft(2, '0');
  final m = stamp.minute.toString().padLeft(2, '0');
  final s = stamp.second.toString().padLeft(2, '0');
  final ms = stamp.millisecond.toString().padLeft(3, '0');
  return '$h:$m:$s.$ms';
}

class _AnrBanner extends StatelessWidget {
  const _AnrBanner({required this.event, required this.onDiagnose});

  final AnrEvent event;
  final VoidCallback onDiagnose;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 2, 12, 6),
      child: DesktopPanel(
        tint: AmlTheme.pink,
        padding: const EdgeInsets.fromLTRB(10, 8, 8, 8),
        child: Row(
          children: [
            const DesktopMiniIcon(
              icon: Icons.warning_amber_rounded,
              color: AmlTheme.pink,
              size: 24,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    event.reason,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w800,
                      height: 1.25,
                      color: AmlTheme.pink,
                    ),
                  ),
                  if (event.packageHint.isNotEmpty)
                    Text(
                      event.packageHint,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Desk.mono(
                        size: 11,
                        color: AmlTheme.mutedOf(context),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            TextButton(
              onPressed: onDiagnose,
              style: TextButton.styleFrom(foregroundColor: AmlTheme.pink),
              child: const Text('Diagnose'),
            ),
          ],
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
      padding: const EdgeInsets.fromLTRB(12, 2, 12, 6),
      child: DesktopPanel(
        tint: Desk.danger,
        padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
        child: Row(
          children: [
            const DesktopMiniIcon(
              icon: Icons.error_outline_rounded,
              color: Desk.danger,
              size: 24,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: SelectableText(
                message,
                maxLines: 2,
                style: const TextStyle(
                  fontSize: 12.5,
                  height: 1.35,
                  fontWeight: FontWeight.w600,
                  color: Desk.danger,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
