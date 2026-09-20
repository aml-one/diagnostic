import 'dart:async';

import 'package:aml_ui/aml_ui.dart';
import 'package:flutter/material.dart';

import '../../core/logcat/logcat_collapse.dart';
import '../../core/logcat/logcat_parser.dart';
import '../../core/logcat/watch_line_keep.dart';
import '../../core/mobile/device_bridge.dart';
import '../../core/mobile/phone_diagnostic.dart';
import '../../core/mobile/watch_follow.dart';
import '../../core/onedrop/onedrop_watch.dart';
import '../../theme/desktop_theme.dart';
import '../../widgets/logcat_row.dart';
import '../../widgets/onedrop_watch_panel.dart';
import '../diagnose_screen.dart';
import 'mdx_share_sheet.dart';

String _levelTitle(String level) {
  final raw = kLogcatLevelLabels[level] ?? level;
  if (raw.isEmpty) return level;
  return '${raw[0].toUpperCase()}${raw.substring(1)}';
}

class AndroidWatchScreen extends StatefulWidget {
  const AndroidWatchScreen({super.key, this.app});

  final PhoneInstalledApp? app;

  @override
  State<AndroidWatchScreen> createState() => _AndroidWatchScreenState();
}

class _AndroidWatchScreenState extends State<AndroidWatchScreen> {
  static const _maxLines = 400;
  static const _uiCoalesce = Duration(milliseconds: 200);

  final _lines = <CollapsedLogcatLine>[];
  final _levels = allLogcatLevels();
  final _scroll = ScrollController();
  final _pidGate = LogcatPidGate();
  var _hideSpam = true;
  var _recording = false;
  var _paused = false;
  var _overlay = false;
  var _followTail = true;
  var _pendingNew = 0;
  var _pinningLive = false;
  var _fingerDrag = false;
  var _uiDirty = false;
  String? _error;
  int? _pid;
  StreamSubscription<Map<Object?, Object?>>? _sub;
  Timer? _pidTimer;
  Timer? _uiTimer;
  OneDropWatchTracker? _dropWatch;

  String get _packageName => widget.app?.packageName ?? '';

  String get _title {
    final app = widget.app;
    if (app == null) return 'Whole device';
    return app.label.isNotEmpty ? app.label : app.packageName;
  }

  @override
  void initState() {
    super.initState();
    if (isOneDropWatchPackage(_packageName)) {
      _dropWatch = OneDropWatchTracker();
    }
    _start();
  }

  @override
  void dispose() {
    _pidTimer?.cancel();
    _uiTimer?.cancel();
    _sub?.cancel();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    _sub = deviceBridge.events.listen(_onEvent, onError: (Object err) {
      if (!mounted) return;
      setState(() => _error = '$err');
    });
    try {
      if (_packageName.isNotEmpty) {
        _pid = await deviceBridge.pidOf(_packageName);
        _pidGate.pid = _pid;
      }
      await deviceBridge.startWatch(
        packageName: _packageName.isEmpty ? null : _packageName,
        pid: _pid,
        levels: logcatLevelsKey(_levels),
        hideSpam: _hideSpam,
      );
      _pidTimer = Timer.periodic(const Duration(seconds: 4), (_) => _refreshPid());
    } catch (err) {
      if (!mounted) return;
      setState(() => _error = '$err');
    }
  }

  Future<void> _refreshPid() async {
    if (_packageName.isEmpty) return;
    final pid = await deviceBridge.pidOf(_packageName);
    if (!mounted || pid == _pid) return;
    _pid = pid;
    _pidGate.pid = pid;
    await deviceBridge.setFilter(
      packageName: _packageName,
      pid: pid,
      levels: logcatLevelsKey(_levels),
      hideSpam: _hideSpam,
    );
    setState(() {});
  }

  Future<void> _pushFilter() {
    return deviceBridge.setFilter(
      packageName: _packageName.isEmpty ? null : _packageName,
      pid: _pid,
      levels: logcatLevelsKey(_levels),
      hideSpam: _hideSpam,
    );
  }

  void _pauseFollow() {
    if (!_followTail) return;
    _followTail = false;
    setState(() {});
  }

  void _resumeLiveIfNeeded() {
    if (_followTail) return;
    _followTail = true;
    _pendingNew = 0;
    if (_lines.length > _maxLines) {
      _lines.removeRange(0, _lines.length - _maxLines);
    }
    setState(() {});
    _pinLive();
  }

  bool _onLogScroll(ScrollNotification notification) {
    if (notification.depth != 0 || _pinningLive) return false;
    if (notification is ScrollStartNotification &&
        notification.dragDetails != null) {
      _fingerDrag = true;
    }
    if (notification is ScrollEndNotification) {
      _fingerDrag = false;
      if (_scroll.hasClients &&
          WatchFollow.shouldResume(
            pixels: _scroll.position.pixels,
            following: _followTail,
          )) {
        _resumeLiveIfNeeded();
      }
      return false;
    }
    if (notification is ScrollUpdateNotification) {
      final user = _fingerDrag || notification.dragDetails != null;
      if (!user || !_scroll.hasClients) return false;
      if (WatchFollow.shouldPause(
        pixels: notification.metrics.pixels,
        userDrag: true,
      )) {
        _pauseFollow();
      }
    }
    return false;
  }

  void _resumeLive() {
    _followTail = true;
    _pendingNew = 0;
    if (_lines.length > _maxLines) {
      _lines.removeRange(0, _lines.length - _maxLines);
    }
    setState(() {});
    _pinLive();
  }

  void _pinLive() {
    if (_fingerDrag) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_followTail || _fingerDrag || !_scroll.hasClients) {
        return;
      }
      if (_scroll.position.pixels.abs() < 0.5) return;
      _pinningLive = true;
      _scroll.jumpTo(0);
      _pinningLive = false;
    });
  }

  void _onEvent(Map<Object?, Object?> event) {
    final type = event['type'];
    if (type == 'error') {
      setState(() => _error = '${event['message'] ?? 'logcat failed'}');
      return;
    }
    if (type == 'mdxReady') {
      final path = '${event['path'] ?? ''}';
      if (path.isEmpty || !mounted) return;
      offerMdxActions(
        context,
        path: path,
        applicationId: _packageName.isEmpty
            ? kDiagnosticAndroidPackage
            : _packageName,
        source: 'watch',
      );
      return;
    }
    if (type == 'overlay') {
      if (!mounted) return;
      setState(() => _overlay = event['showing'] == true);
      return;
    }
    if (type == 'state') {
      setState(() {
        _recording = event['recording'] == true;
        _paused = event['paused'] == true;
      });
      return;
    }
    if (type != 'batch') return;
    final rawLines = event['lines'];
    if (rawLines is! List) return;
    var added = 0;
    var collapsed = false;
    var dropDirty = false;
    for (final item in rawLines) {
      final parsed = LogcatParser.parse('$item');
      if (!shouldKeepWatchLine(
        parsed,
        pids: {
          if (_pid != null) _pid!,
        },
        packageName: _packageName.isEmpty ? null : _packageName,
        levelsKey: logcatLevelsKey(_levels),
        hideSpam: _hideSpam,
        uidScoped: _packageName.isNotEmpty &&
            !isOneDropWatchPackage(_packageName),
      )) {
        continue;
      }
      // Native already filtered. Pid gate only keeps stack-frame continuations
      // so ColorOS `at …` floods cannot ANR Watch again.
      if (!parsed.isParsed) {
        if (!_pidGate.accept(parsed)) continue;
      } else {
        _pidGate.accept(parsed);
      }
      if (_dropWatch?.ingest(parsed) == true) dropDirty = true;
      if (!passesLogcatLevelFilter(parsed, _levels)) continue;
      if (_hideSpam && isLogcatDisplayNoise(parsed)) continue;
      if (appendCollapsed(_lines, parsed)) {
        added++;
      } else {
        collapsed = true;
      }
    }
    if (added == 0 && !collapsed && !dropDirty) return;
    if (added > 0 && !_followTail) {
      _pendingNew += added;
    }
    _scheduleUi();
  }

  void _scheduleUi() {
    _uiDirty = true;
    if (_uiTimer != null) return;
    _uiTimer = Timer(_uiCoalesce, () {
      _uiTimer = null;
      if (!mounted || !_uiDirty) return;
      _uiDirty = false;
      if (_followTail && _lines.length > _maxLines) {
        _lines.removeRange(0, _lines.length - _maxLines);
      }
      setState(() {});
      if (_followTail) _pinLive();
    });
  }

  Future<void> _toggleRecord() async {
    if (_recording) {
      await deviceBridge.stopRecord();
      return;
    }
    await deviceBridge.startRecord(appLabel: widget.app?.label);
  }

  Future<void> _toggleOverlay() async {
    if (_overlay) {
      await deviceBridge.hideOverlay();
      setState(() => _overlay = false);
      return;
    }
    final shown = await deviceBridge.showOverlay();
    if (!mounted) return;
    setState(() => _overlay = shown);
    if (!shown) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Allow display over other apps in Permissions first.'),
        ),
      );
    }
  }

  void _openDiagnose() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => DiagnoseScreen(
          serial: kOnDeviceSerial,
          packageName: _packageName.isEmpty ? null : _packageName,
          appLabel: _title,
          onDevice: true,
          logLines: [for (final row in _lines) row.toDiagnoseLine()],
        ),
      ),
    );
  }

  void _toggleLevel(String level, bool on) {
    setState(() {
      if (on) {
        _levels.add(level);
      } else if (_levels.length > 1) {
        _levels.remove(level);
      }
    });
    _pushFilter();
  }

  @override
  Widget build(BuildContext context) {
    final ink = AmlTheme.inkOf(context);
    final muted = AmlTheme.mutedOf(context);
    final dark = AmlTheme.isDark(context);
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
                  padding: const EdgeInsets.fromLTRB(4, 0, 12, 0),
                  child: Row(
                    children: [
                      IconButton(
                        tooltip: 'Back',
                        onPressed: () => Navigator.maybePop(context),
                        iconSize: 22,
                        style: IconButton.styleFrom(
                          minimumSize: const Size(48, 48),
                          tapTargetSize: MaterialTapTargetSize.padded,
                          padding: const EdgeInsets.all(10),
                        ),
                        icon: Icon(Icons.arrow_back_ios_new_rounded, color: ink),
                      ),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              _title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 20,
                                fontWeight: FontWeight.w800,
                                letterSpacing: -0.4,
                                color: ink,
                              ),
                            ),
                            if (_packageName.isNotEmpty)
                              Text(
                                _pid != null
                                    ? '$_packageName · pid $_pid'
                                    : _packageName,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                  color: muted,
                                ),
                              ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      _OverlayToggle(
                        on: _overlay,
                        onPressed: _toggleOverlay,
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 10),
                  child: _WatchToolbar(
                    levels: _levels,
                    hideSpam: _hideSpam,
                    recording: _recording,
                    paused: _paused,
                    followTail: _followTail,
                    pendingNew: _pendingNew,
                    lineCount: _lines.length,
                    error: _error,
                    onToggleLevel: _toggleLevel,
                    onHideSpam: (on) {
                      setState(() => _hideSpam = on);
                      _pushFilter();
                    },
                    onRecord: _toggleRecord,
                    onDiagnose: _openDiagnose,
                    onResumeLive: _resumeLive,
                  ),
                ),
                if (_dropWatch != null)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
                    child: OneDropWatchPanel(
                      snapshot: _dropWatch!.snapshot(),
                    ),
                  ),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                    child: _WatchLogPane(
                      lines: _followTail
                          ? _lines
                          : (_lines.length <= _pendingNew
                              ? _lines
                              : _lines.sublist(0, _lines.length - _pendingNew)),
                      empty: _lines.isEmpty,
                      muted: muted,
                      controller: _scroll,
                      onScroll: _onLogScroll,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _WatchToolbar extends StatelessWidget {
  const _WatchToolbar({
    required this.levels,
    required this.hideSpam,
    required this.recording,
    required this.paused,
    required this.followTail,
    required this.pendingNew,
    required this.lineCount,
    required this.onToggleLevel,
    required this.onHideSpam,
    required this.onRecord,
    required this.onDiagnose,
    required this.onResumeLive,
    this.error,
  });

  final Set<String> levels;
  final bool hideSpam;
  final bool recording;
  final bool paused;
  final bool followTail;
  final int pendingNew;
  final int lineCount;
  final String? error;
  final void Function(String level, bool on) onToggleLevel;
  final ValueChanged<bool> onHideSpam;
  final VoidCallback onRecord;
  final VoidCallback onDiagnose;
  final VoidCallback onResumeLive;

  static const _radius = BorderRadius.all(Radius.circular(26));
  static const _countersHeight = 28.0;

  @override
  Widget build(BuildContext context) {
    final dark = AmlTheme.isDark(context);
    final pills = <Widget>[
      for (final level in kLogcatLevels)
        _FilterPill(
          label: _levelTitle(level),
          accent: Desk.levelColor(level),
          selected: levels.contains(level),
          onTap: () => onToggleLevel(level, !levels.contains(level)),
        ),
      _FilterPill(
        label: 'Hide spam',
        accent: AmlTheme.violet,
        selected: hideSpam,
        onTap: () => onHideSpam(!hideSpam),
      ),
    ];
    final counters = <Widget>[
      _MetricChip(
        accent: AmlTheme.sky,
        label: '$lineCount lines',
      ),
      if (!followTail)
        GestureDetector(
          onTap: onResumeLive,
          child: _MetricChip(
            accent: AmlTheme.amber,
            label: pendingNew > 0
                ? 'Paused · $pendingNew new'
                : 'Paused · live',
          ),
        )
      else
        const _MetricChip(
          accent: AmlTheme.mint,
          label: 'Live',
        ),
      if (recording)
        _MetricChip(
          accent: Desk.danger,
          label: paused ? 'Paused rec' : 'Recording',
        ),
    ];
    return ClipRRect(
      borderRadius: _radius,
      child: Stack(
        children: [
          const Positioned.fill(
            child: AmlMeshAtmosphere(
              tessellation: 8,
              borderRadius: _radius,
            ),
          ),
          DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: _radius,
              border: Border.all(
                color: dark
                    ? Colors.white.withValues(alpha: 0.12)
                    : const Color(0x66FFFFFF),
              ),
            ),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
              child: Column(
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        flex: 4,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Wrap(
                              spacing: 5,
                              runSpacing: 5,
                              children: pills,
                            ),
                            const SizedBox(height: 8),
                            SizedBox(
                              height: _countersHeight,
                              child: ListView.separated(
                                scrollDirection: Axis.horizontal,
                                itemCount: counters.length,
                                separatorBuilder: (context, index) =>
                                    const SizedBox(width: 6),
                                itemBuilder: (context, index) {
                                  return Center(child: counters[index]);
                                },
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        flex: 1,
                        child: Column(
                          children: [
                            _RecordButton(
                              recording: recording,
                              onPressed: onRecord,
                            ),
                            const SizedBox(height: 8),
                            _DiagnoseButton(onPressed: onDiagnose),
                          ],
                        ),
                      ),
                    ],
                  ),
                  if (error != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          error!,
                          style: TextStyle(color: Desk.danger, fontSize: 12.5),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _FilterPill extends StatelessWidget {
  const _FilterPill({
    required this.label,
    required this.accent,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final Color accent;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final paint = selected
        ? accent
        : HSVColor.fromColor(accent).withSaturation(0).toColor();
    final fill = Color.alphaBlend(
      paint.withValues(alpha: selected ? 0.30 : 0.14),
      const Color(0xFFFFFFFF),
    );
    return Semantics(
      button: true,
      selected: selected,
      label: label,
      child: Material(
        color: fill,
        shape: const StadiumBorder(),
        child: InkWell(
          onTap: onTap,
          customBorder: const StadiumBorder(),
          child: DecoratedBox(
            decoration: ShapeDecoration(
              shape: StadiumBorder(
                side: BorderSide(
                  color: paint.withValues(alpha: selected ? 0.55 : 0.28),
                ),
              ),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 12.5,
                  height: 1,
                  fontWeight: FontWeight.w800,
                  color: paint,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _MetricChip extends StatelessWidget {
  const _MetricChip({required this.accent, required this.label});

  final Color accent;
  final String label;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: ShapeDecoration(
        color: Color.alphaBlend(
          accent.withValues(alpha: 0.22),
          const Color(0xFFFFFFFF),
        ),
        shape: StadiumBorder(
          side: BorderSide(color: accent.withValues(alpha: 0.42)),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 11,
            height: 1,
            fontWeight: FontWeight.w700,
            color: accent,
          ),
        ),
      ),
    );
  }
}

class _OverlayToggle extends StatelessWidget {
  const _OverlayToggle({required this.on, required this.onPressed});

  final bool on;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final muted = AmlTheme.mutedOf(context);
    const mint = AmlTheme.mint;
    final fill = on
        ? Color.alphaBlend(
            mint.withValues(alpha: 0.32),
            Colors.white.withValues(alpha: 0.9),
          )
        : Colors.white.withValues(alpha: 0.78);
    final ink = on ? mint : muted;
    return Semantics(
      button: true,
      toggled: on,
      label: on ? 'Hide overlay' : 'Show overlay',
      child: Material(
        color: fill,
        shape: CircleBorder(
          side: BorderSide(
            color: on
                ? mint.withValues(alpha: 0.72)
                : Colors.white.withValues(alpha: 0.55),
            width: on ? 1.6 : 1,
          ),
        ),
        child: InkWell(
          onTap: onPressed,
          customBorder: const CircleBorder(),
          child: SizedBox(
            width: 44,
            height: 44,
            child: Center(
              child: _FlyingWindowGlyph(color: ink, filled: on),
            ),
          ),
        ),
      ),
    );
  }
}

class _FlyingWindowGlyph extends StatelessWidget {
  const _FlyingWindowGlyph({required this.color, required this.filled});

  final Color color;
  final bool filled;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 20,
      height: 16,
      child: Stack(
        children: [
          Positioned(
            left: 0,
            top: 0,
            child: Container(
              width: 13,
              height: 10,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(3),
                border: Border.all(
                  color: color.withValues(alpha: 0.42),
                  width: 1.4,
                ),
              ),
            ),
          ),
          Positioned(
            right: 0,
            bottom: 0,
            child: Container(
              width: 14,
              height: 11,
              decoration: BoxDecoration(
                color: filled ? color : color.withValues(alpha: 0.16),
                borderRadius: BorderRadius.circular(3.5),
                border: Border.all(color: color, width: 1.5),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _RecordButton extends StatelessWidget {
  const _RecordButton({
    required this.recording,
    required this.onPressed,
  });

  final bool recording;
  final VoidCallback onPressed;

  static const _red = Color(0xFFE53935);

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: recording ? 'Stop recording' : 'Record',
      child: Material(
        color: Colors.white.withValues(alpha: 0.72),
        shape: const CircleBorder(),
        child: InkWell(
          onTap: onPressed,
          customBorder: const CircleBorder(),
          child: SizedBox(
            width: 44,
            height: 44,
            child: Center(
              child: recording
                  ? Container(
                      width: 9,
                      height: 9,
                      decoration: BoxDecoration(
                        color: _red,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    )
                  : Container(
                      width: 18,
                      height: 18,
                      decoration: const BoxDecoration(
                        color: _red,
                        shape: BoxShape.circle,
                      ),
                    ),
            ),
          ),
        ),
      ),
    );
  }
}

class _DiagnoseButton extends StatelessWidget {
  const _DiagnoseButton({required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    const accent = AmlTheme.violet;
    return Semantics(
      button: true,
      label: 'Diagnose',
      child: Material(
        color: Color.alphaBlend(
          accent.withValues(alpha: 0.18),
          Colors.white.withValues(alpha: 0.88),
        ),
        shape: const CircleBorder(
          side: BorderSide(color: Color(0x527C6FF0)),
        ),
        child: InkWell(
          onTap: onPressed,
          customBorder: const CircleBorder(),
          child: const SizedBox(
            width: 44,
            height: 44,
            child: Icon(Icons.troubleshoot_rounded, size: 22, color: accent),
          ),
        ),
      ),
    );
  }
}

class _WatchLogPane extends StatelessWidget {
  const _WatchLogPane({
    required this.lines,
    required this.empty,
    required this.muted,
    required this.controller,
    required this.onScroll,
  });

  final List<CollapsedLogcatLine> lines;
  final bool empty;
  final Color muted;
  final ScrollController controller;
  final bool Function(ScrollNotification notification) onScroll;

  static const _radius = BorderRadius.all(Radius.circular(22));

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Desk.logSurface(context),
        borderRadius: _radius,
        border: Border.all(color: Desk.hairline(context)),
      ),
      child: ClipRRect(
        borderRadius: _radius,
        child: empty
            ? Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const BirdLoader(
                      size: 56,
                      semanticsLabel: 'Waiting for logcat',
                    ),
                    const SizedBox(height: 10),
                    Text(
                      'Waiting for logcat…',
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        color: muted,
                      ),
                    ),
                  ],
                ),
              )
            : NotificationListener<ScrollNotification>(
                onNotification: onScroll,
                child: ListView.builder(
                  controller: controller,
                  reverse: true,
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  itemCount: lines.length,
                  cacheExtent: 240,
                  itemBuilder: (context, index) {
                    final lineIndex = lines.length - 1 - index;
                    final row = lines[lineIndex];
                    return LogcatRow(
                      line: row.line,
                      zebra: lineIndex.isOdd,
                      stacked: true,
                      repeatCount: row.count,
                    );
                  },
                ),
              ),
      ),
    );
  }
}
