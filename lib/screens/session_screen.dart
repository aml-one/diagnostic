import 'dart:async';
import 'dart:io';

import 'package:aml_ui/aml_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../core/adb/adb_client.dart';
import '../core/adb/device_details.dart';
import '../core/logcat/anr_detector.dart';
import '../core/logcat/logcat_parser.dart';
import '../core/logcat/logcat_session.dart';
import '../core/onedrop/onedrop_watch.dart';
import '../core/upload/field_report_client.dart';
import '../state/adb_providers.dart';
import '../state/device_names_provider.dart';
import '../state/logcat_providers.dart';
import '../state/package_providers.dart';
import '../theme/desktop_theme.dart';
import '../widgets/desktop_chrome.dart';
import '../widgets/desktop_title_bar.dart';
import '../widgets/logcat_row.dart';
import '../widgets/onedrop_watch_panel.dart';
import 'diagnose_screen.dart';

class SessionScreen extends ConsumerStatefulWidget {
  const SessionScreen({
    super.key,
    required this.serial,
    this.packageName,
    this.device,
  });

  final String serial;

  /// When null, Watch is device-wide (all logcat) and no app is launched.
  final String? packageName;

  /// Home / picker already know this phone — used for the window title.
  final AdbDevice? device;

  @override
  ConsumerState<SessionScreen> createState() => _SessionScreenState();
}

class _SessionScreenState extends ConsumerState<SessionScreen> {
  /// Raw device logcat (export / full-session send).
  final _lines = <LogcatLine>[];

  /// Filtered rows shown in the list. Updated only on the UI tick.
  final _visible = <_VisibleLine>[];

  /// Bumps when [_visible] changes so the log pane rebuilds without
  /// rebuilding the whole session chrome on every log line.
  final _logTick = ValueNotifier<int>(0);

  /// OneDrop USB Watch summary — independent of log pin-to-bottom.
  final _dropTick = ValueNotifier<int>(0);
  OneDropWatchTracker? _dropWatch;
  var _dropShownGen = -1;

  final _scroll = ScrollController();
  StreamSubscription<LogcatLine>? _sub;
  Timer? _tick;
  var _dirty = false;
  var _started = false;
  var _pinToBottom = true;
  var _uploading = false;
  final _fieldReports = FieldReportClient();

  /// Incremental filter cursor into [_lines].
  var _filterFrom = 0;
  int? _filterPid;
  var _filterShowAll = true;
  var _filterHideSpam = true;
  var _filterLevelsKey = 'VDIWEF';
  var _filterIncludeUnparsed = false;
  var _lastLevelShown = false;

  /// IME inset tags (InsetsSource, ImeTracker, …). On by default.
  var _hideSpam = true;

  /// V/D/I/W/E/F — all on until the user taps a badge off.
  final _enabledLevels = allLogcatLevels();

  static const _bufferCap = 5000;
  static const _displayCap = 2000;

  /// Stay glued to live lines only when the viewport is on the tail.
  static const _pinThreshold = 24.0;

  @override
  void initState() {
    super.initState();
    if (isOneDropWatchPackage(widget.packageName)) {
      _dropWatch = OneDropWatchTracker();
    }
    // ~5 UI refreshes/sec — enough to feel live, cheap enough for macOS.
    _tick = Timer.periodic(const Duration(milliseconds: 200), (_) {
      _flushDrop();
      _flush();
    });
    _scroll.addListener(_onScroll);
    WidgetsBinding.instance.addPostFrameCallback((_) => _begin());
  }

  @override
  void dispose() {
    _tick?.cancel();
    _sub?.cancel();
    _scroll.dispose();
    _logTick.dispose();
    _dropTick.dispose();
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
    // Append only here — never trim/scan/setState on the hot adb stream.
    _lines.add(line);
    _dropWatch?.ingest(line);
    _dirty = true;
    if (!_pinToBottom && _lines.length > _bufferCap * 4) {
      final drop = _lines.length - _bufferCap * 4;
      _lines.removeRange(0, drop);
      _filterFrom = (_filterFrom - drop).clamp(0, _lines.length);
    }
  }

  void _flushDrop() {
    final watch = _dropWatch;
    if (watch == null || !mounted) return;
    if (watch.generation == _dropShownGen) return;
    _dropShownGen = watch.generation;
    _dropTick.value++;
  }

  /// Keep a rolling window of device logcat, but never let other PIDs shove
  /// the watched app's lines out of the buffer.
  ///
  /// Logcat is device-wide (needed for ANR / system lines). With "Show all
  /// logs" off we only *display* the focus PID — if we trimmed FIFO, a busy
  /// phone would slowly erase every matching line until the pane hit 0.
  ///
  /// Called from [_flush] only (not per line).
  void _trimBuffer() {
    if (_lines.length <= _bufferCap) return;
    final focusPid = ref.read(appSessionProvider).pid;
    if (focusPid == null) {
      final drop = _lines.length - _bufferCap;
      _lines.removeRange(0, drop);
      _resetFilter();
      return;
    }
    final overflow = _lines.length - _bufferCap;
    var dropped = 0;
    final kept = <LogcatLine>[];
    for (final line in _lines) {
      final noise =
          line.isParsed && line.pid != null && line.pid != focusPid;
      if (noise && dropped < overflow) {
        dropped++;
        continue;
      }
      kept.add(line);
    }
    if (kept.length > _bufferCap) {
      kept.removeRange(0, kept.length - _bufferCap);
    }
    _lines
      ..clear()
      ..addAll(kept);
    _resetFilter();
  }

  void _resetFilter() {
    _filterFrom = 0;
    _visible.clear();
    _filterIncludeUnparsed = false;
    _lastLevelShown = false;
  }

  bool _isPinnedToBottom() {
    if (!_scroll.hasClients) return _pinToBottom;
    return _scroll.position.maxScrollExtent - _scroll.position.pixels <=
        _pinThreshold;
  }

  void _onScroll() {
    if (!_scroll.hasClients) return;
    final wasPinned = _pinToBottom;
    _pinToBottom = _isPinnedToBottom();
    if (_pinToBottom && !wasPinned) {
      // Catch up as soon as they return to the live tail.
      _flush();
    }
  }

  /// Wheel / drag toward older lines must freeze immediately — a post-frame
  /// jumpTo from the previous live flush used to yank the list back down.
  bool _onUserScroll(UserScrollNotification notification) {
    if (notification.depth != 0) return false;
    if (notification.direction == ScrollDirection.idle) return false;
    if (notification.direction == ScrollDirection.forward) {
      _pinToBottom = false;
      return false;
    }
    _pinToBottom = _isPinnedToBottom();
    if (_pinToBottom) _flush();
    return false;
  }

  void _flush() {
    if (!_dirty || !mounted) return;
    // Scrolled up to read: keep the snapshot still. New lines stay in
    // [_lines] and apply when they return to the bottom.
    if (!_pinToBottom) return;
    _dirty = false;
    _trimBuffer();
    final session = ref.read(appSessionProvider);
    _syncVisible(
      pid: session.pid,
      showAll: session.showAllLogs,
      hideSpam: _hideSpam,
      levels: _enabledLevels,
    );
    _logTick.value++;
    if (!_scroll.hasClients) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_pinToBottom || !_scroll.hasClients) return;
      final max = _scroll.position.maxScrollExtent;
      if ((_scroll.position.pixels - max).abs() < 1) return;
      _scroll.jumpTo(max);
    });
  }

  /// Incrementally append filtered rows; full rebuild only when the filter
  /// mode changes or the source buffer was trimmed.
  void _syncVisible({
    required int? pid,
    required bool showAll,
    required bool hideSpam,
    required Set<String> levels,
  }) {
    final levelsKey = logcatLevelsKey(levels);
    if (pid != _filterPid ||
        showAll != _filterShowAll ||
        hideSpam != _filterHideSpam ||
        levelsKey != _filterLevelsKey) {
      _filterPid = pid;
      _filterShowAll = showAll;
      _filterHideSpam = hideSpam;
      _filterLevelsKey = levelsKey;
      _resetFilter();
    }
    if (_filterFrom > _lines.length) {
      _resetFilter();
    }

    for (var i = _filterFrom; i < _lines.length; i++) {
      final line = _lines[i];
      if (hideSpam && isLogcatDisplayNoise(line)) continue;
      if (pid == null || showAll) {
        if (!_passesLevel(line, levels)) continue;
        _visible.add(
          _VisibleLine(line: line, dimmed: pid != null && line.pid != pid),
        );
        continue;
      }
      if (!line.isParsed) {
        if (_filterIncludeUnparsed && _lastLevelShown) {
          _visible.add(_VisibleLine(line: line, dimmed: false));
        }
        continue;
      }
      final match = line.pid == pid;
      _filterIncludeUnparsed = match;
      if (!match) continue;
      if (!_passesLevel(line, levels)) continue;
      _visible.add(_VisibleLine(line: line, dimmed: false));
    }
    _filterFrom = _lines.length;

    if (_visible.length > _displayCap) {
      _visible.removeRange(0, _visible.length - _displayCap);
    }
  }

  bool _passesLevel(LogcatLine line, Set<String> levels) {
    if (!line.isParsed) return _lastLevelShown;
    final ok = passesLogcatLevelFilter(line, levels);
    _lastLevelShown = ok;
    return ok;
  }

  void _toggleLevel(String level) {
    setState(() {
      if (!_enabledLevels.remove(level)) {
        _enabledLevels.add(level);
      }
    });
    final session = ref.read(appSessionProvider);
    _syncVisible(
      pid: session.pid,
      showAll: session.showAllLogs,
      hideSpam: _hideSpam,
      levels: _enabledLevels,
    );
    _logTick.value++;
  }

  Future<void> _stop() async {
    await ref.read(appSessionProvider.notifier).stop();
    if (mounted) Navigator.of(context).maybePop();
  }

  void _openDiagnose({AnrEvent? event}) {
    // Banner Diagnose must target the ANR's package (e.g. MessageMe), not the
    // package currently being watched in this session.
    final hint = event?.packageHint.trim();
    final package = (hint != null && hint.isNotEmpty)
        ? hint
        : widget.packageName;
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => DiagnoseScreen(
          serial: widget.serial,
          packageName: package,
          event: event,
        ),
      ),
    );
  }

  /// Exact text currently shown in the log pane (respects the PID filter).
  String _visibleLogText(List<_VisibleLine> visible) {
    if (visible.isEmpty) return '';
    final buf = StringBuffer();
    for (final row in visible) {
      buf.writeln(row.line.raw);
    }
    return buf.toString();
  }

  String _fullSessionLogText() {
    if (_lines.isEmpty) return '';
    final buf = StringBuffer();
    for (final line in _lines) {
      buf.writeln(line.raw);
    }
    return buf.toString();
  }

  void _showUploadSnack(String message, {bool error = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        behavior: SnackBarBehavior.floating,
        duration: Duration(seconds: error ? 5 : 3),
      ),
    );
  }

  Future<void> _sendLogToAppBuilder({
    required FieldReportKind kind,
    required String textBody,
    required String title,
  }) async {
    if (_uploading || textBody.isEmpty) return;
    setState(() => _uploading = true);
    try {
      final result = await _fieldReports.upload(
        applicationId: widget.packageName ?? 'device-logcat',
        kind: kind,
        title: title,
        deviceSerial: widget.serial,
        textBody: textBody,
      );
      _showUploadSnack('Sent to App Builder (${result.id}).');
    } on FieldReportUploadException catch (err) {
      _showUploadSnack(fieldReportUserMessage(err), error: true);
    } catch (err) {
      _showUploadSnack('Could not reach App Builder ($err).', error: true);
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  Future<void> _sendVisibleToAppBuilder(List<_VisibleLine> visible) async {
    await _sendLogToAppBuilder(
      kind: FieldReportKinds.logcatExcerpt,
      textBody: _visibleLogText(visible),
      title: 'Logcat excerpt (${visible.length} lines)',
    );
  }

  Future<void> _sendFullSessionToAppBuilder() async {
    await _sendLogToAppBuilder(
      kind: FieldReportKinds.sessionLog,
      textBody: _fullSessionLogText(),
      title: 'Session log (${_lines.length} lines)',
    );
  }

  Future<void> _copyVisible(List<_VisibleLine> visible) async {
    final text = _visibleLogText(visible);
    if (text.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Copied ${visible.length} lines.'),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 2),
      ),
    );
  }

  Future<void> _saveVisible(List<_VisibleLine> visible) async {
    final text = _visibleLogText(visible);
    if (text.isEmpty) return;
    try {
      final docs = await getApplicationDocumentsDirectory();
      final dir = Directory(p.join(docs.path, 'diagnostic-reports', 'session-logs'));
      await dir.create(recursive: true);
      final safePkg = (widget.packageName ?? 'logcat')
          .replaceAll(RegExp(r'[^a-zA-Z0-9._-]'), '_');
      final now = DateTime.now();
      String two(int v) => v.toString().padLeft(2, '0');
      final stamp =
          '${now.year}${two(now.month)}${two(now.day)}-'
          '${two(now.hour)}${two(now.minute)}${two(now.second)}';
      final file = File(p.join(dir.path, '${safePkg}_$stamp.log'));
      await file.writeAsString(text);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Saved ${visible.length} lines to ${file.path}'),
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 4),
        ),
      );
    } catch (err) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Could not save log: $err'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  String _sessionDeviceTitle(
    WidgetRef ref,
    String serial,
    Map<String, String> names,
  ) {
    final devices =
        ref.watch(devicesProvider).valueOrNull ?? const <AdbDevice>[];
    AdbDevice? device = widget.device;
    if (device == null || device.serial != serial) {
      for (final item in devices) {
        if (item.serial == serial) {
          device = item;
          break;
        }
      }
    }
    if (device == null) {
      final selected = ref.watch(selectedDeviceProvider);
      if (selected != null && selected.serial == serial) device = selected;
    }
    final details = device == null
        ? AdbDeviceDetails(serial: serial)
        : (ref.watch(deviceDetailsProvider(device)).valueOrNull ??
            AdbDeviceDetails.fallback(device));
    return details.titleWithSerial(nickname: names[serial]);
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
    final names = ref.watch(deviceNamesProvider);
    final deviceTitle = _sessionDeviceTitle(ref, widget.serial, names);
    final hideNavChrome = kDesktopCustomTitleBar;
    final packageTitle = widget.packageName;

    // Keep the filter in sync when PID / show-all changes without waiting
    // for the next log line.
    ref.listen<({int? pid, bool showAll})>(
      appSessionProvider.select(
        (s) => (pid: s.pid, showAll: s.showAllLogs),
      ),
      (prev, next) {
        if (prev?.pid == next.pid && prev?.showAll == next.showAll) return;
        _syncVisible(
          pid: next.pid,
          showAll: next.showAll,
          hideSpam: _hideSpam,
          levels: _enabledLevels,
        );
        _logTick.value++;
      },
    );

    return PopScope(
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) {
          unawaited(ref.read(appSessionProvider.notifier).stop());
        }
      },
      child: DesktopTitleChromeBinder(
        title: deviceTitle,
        child: Scaffold(
        backgroundColor: kDesktopCustomTitleBar
            ? Colors.transparent
            : (AmlTheme.isDark(context)
                  ? AmlTheme.darkBg
                  : kSettingsPageBackground),
        appBar: AppBar(
          toolbarHeight: 48,
          titleSpacing: hideNavChrome ? 12 : 8,
          automaticallyImplyLeading: !hideNavChrome,
          title: packageTitle == null
              ? (hideNavChrome
                    ? null
                    : Text(
                        deviceTitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w800,
                          letterSpacing: -0.1,
                          color: ink,
                        ),
                      ))
              : Row(
            children: [
              Flexible(
                child: Text(
                  packageTitle,
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
            Center(
              child: Padding(
                padding: const EdgeInsets.only(right: 12),
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: _LevelFilterBar(
                    enabled: _enabledLevels,
                    onToggle: _toggleLevel,
                  ),
                ),
              ),
            ),
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
                  if (_dropWatch != null)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
                      child: ValueListenableBuilder<int>(
                        valueListenable: _dropTick,
                        builder: (context, _, __) {
                          return OneDropWatchPanel(
                            snapshot: _dropWatch!.snapshot(),
                          );
                        },
                      ),
                    ),
                  Expanded(
                    child: ValueListenableBuilder<int>(
                      valueListenable: _logTick,
                      builder: (context, _, __) {
                        final visible = _visible;
                        return Column(
                          children: [
                            Padding(
                              padding: const EdgeInsets.fromLTRB(12, 2, 12, 8),
                              child: _LogToolbar(
                                pid: pid,
                                showAll: showAll || pid == null,
                                hideSpam: _hideSpam,
                                lineCount: visible.length,
                                uploading: _uploading,
                                onChanged: pid == null
                                    ? null
                                    : (value) {
                                        ref
                                            .read(appSessionProvider.notifier)
                                            .setShowAllLogs(value);
                                        _syncVisible(
                                          pid: pid,
                                          showAll: value,
                                          hideSpam: _hideSpam,
                                          levels: _enabledLevels,
                                        );
                                        _logTick.value++;
                                      },
                                onHideSpamChanged: (value) {
                                  _hideSpam = value;
                                  _syncVisible(
                                    pid: pid,
                                    showAll: showAll,
                                    hideSpam: value,
                                    levels: _enabledLevels,
                                  );
                                  _logTick.value++;
                                },
                                onCopy: visible.isEmpty
                                    ? null
                                    : () => unawaited(_copyVisible(visible)),
                                onDownload: visible.isEmpty
                                    ? null
                                    : () => unawaited(_saveVisible(visible)),
                                onSendVisible:
                                    visible.isEmpty || _uploading
                                    ? null
                                    : () => unawaited(
                                          _sendVisibleToAppBuilder(visible),
                                        ),
                                onSendFullSession:
                                    _lines.isEmpty || _uploading
                                    ? null
                                    : () => unawaited(
                                          _sendFullSessionToAppBuilder(),
                                        ),
                              ),
                            ),
                            Expanded(
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 12,
                                ),
                                child: NotificationListener<UserScrollNotification>(
                                  onNotification: _onUserScroll,
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
                            ),
                          ],
                        );
                      },
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
      ),
    );
  }

}

class _VisibleLine {
  const _VisibleLine({required this.line, required this.dimmed});

  final LogcatLine line;
  final bool dimmed;
}

/// One compact toolbar row: PID filter switch, its hint, line count, and
/// copy / save actions for whatever is currently visible.
class _LogToolbar extends StatelessWidget {
  const _LogToolbar({
    required this.pid,
    required this.showAll,
    required this.hideSpam,
    required this.lineCount,
    required this.uploading,
    required this.onChanged,
    required this.onHideSpamChanged,
    required this.onCopy,
    required this.onDownload,
    required this.onSendVisible,
    required this.onSendFullSession,
  });

  final int? pid;
  final bool showAll;
  final bool hideSpam;
  final int lineCount;
  final bool uploading;
  final ValueChanged<bool>? onChanged;
  final ValueChanged<bool> onHideSpamChanged;
  final VoidCallback? onCopy;
  final VoidCallback? onDownload;
  final VoidCallback? onSendVisible;
  final VoidCallback? onSendFullSession;

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
            if (pid != null) ...[
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
              const SizedBox(width: 8),
            ],
            Tooltip(
              message:
                  'Hide IME inset spam (InsetsSource, ImeTracker, and friends)',
              child: InkWell(
                onTap: () => onHideSpamChanged(!hideSpam),
                borderRadius: BorderRadius.circular(Desk.row),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SizedBox(
                        width: 22,
                        height: 22,
                        child: Checkbox(
                          value: hideSpam,
                          onChanged: (value) {
                            if (value == null) return;
                            onHideSpamChanged(value);
                          },
                          materialTapTargetSize:
                              MaterialTapTargetSize.shrinkWrap,
                          visualDensity: VisualDensity.compact,
                          side: BorderSide(
                            color: muted.withValues(alpha: 0.7),
                          ),
                          activeColor: AmlTheme.violet,
                        ),
                      ),
                      const SizedBox(width: 4),
                      Text(
                        'Hide spam',
                        style: TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w700,
                          color: ink,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: pid == null
                  ? const SizedBox.shrink()
                  : Text(
                      showAll
                          ? 'Dim lines that are not PID $pid'
                          : 'Only lines from PID $pid',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 11.5, color: muted),
                    ),
            ),
            const SizedBox(width: 8),
            DesktopTag(
              label: '$lineCount lines',
              color: AmlTheme.sky,
              mono: true,
            ),
            const SizedBox(width: 4),
            DesktopIconAction(
              icon: Icons.copy_rounded,
              tooltip: 'Copy to clipboard',
              onPressed: onCopy,
            ),
            DesktopIconAction(
              icon: Icons.download_rounded,
              tooltip: 'Save as .log',
              onPressed: onDownload,
            ),
            DesktopIconAction(
              icon: Icons.cloud_upload_outlined,
              tooltip: 'Send visible to App Builder',
              onPressed: onSendVisible,
            ),
            DesktopIconAction(
              icon: Icons.upload_file_rounded,
              tooltip: 'Send full session to App Builder',
              onPressed: onSendFullSession,
            ),
            if (uploading) ...[
              const SizedBox(width: 6),
              const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ],
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
            // No SelectionArea — wrapping a hot ListView in it tanks macOS
            // (layout + semantics every tick). Copy/save use the toolbar.
            : Scrollbar(
                controller: controller,
                child: ListView.builder(
                  controller: controller,
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  itemExtent: Desk.logRowHeight,
                  itemCount: lines.length,
                  addAutomaticKeepAlives: false,
                  addRepaintBoundaries: false,
                  cacheExtent: 240,
                  itemBuilder: (context, index) {
                    final row = lines[index];
                    return LogcatRow(
                      line: row.line,
                      dimmed: row.dimmed,
                      zebra: index.isOdd,
                    );
                  },
                ),
              ),
      ),
    );
  }
}

class _LevelFilterBar extends StatelessWidget {
  const _LevelFilterBar({
    required this.enabled,
    required this.onToggle,
  });

  final Set<String> enabled;
  final ValueChanged<String> onToggle;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final level in kLogcatLevels)
          _LevelFilterChip(
            level: level,
            label: kLogcatLevelLabels[level]!,
            selected: enabled.contains(level),
            onTap: () => onToggle(level),
          ),
      ],
    );
  }
}

class _LevelFilterChip extends StatelessWidget {
  const _LevelFilterChip({
    required this.level,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String level;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = Desk.levelColor(level);
    final fade = selected ? 1.0 : 0.32;
    return Tooltip(
      message: selected ? 'Hide $label' : 'Show $label',
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(Desk.row),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              LogcatLevelMarker(level: level, color: color, fade: fade),
              const SizedBox(width: 5),
              Text(
                label,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: color.withValues(alpha: fade),
                ),
              ),
            ],
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
