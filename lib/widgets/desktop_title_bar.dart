import 'dart:io';

import 'package:aml_ui/aml_ui.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import '../screens/settings_screen.dart';

/// Custom Flutter title strip on Windows / macOS (native bar is hidden).
bool get kDesktopCustomTitleBar =>
    !kIsWeb && (Platform.isWindows || Platform.isMacOS);

/// Windows stays compact; macOS needs a taller strip so traffic lights and
/// title content don't feel jammed into the top edge.
double get kDesktopTitleBarHeight => Platform.isMacOS ? 52 : 40;

/// Clearance past the native macOS traffic lights before Flutter chrome.
const double _kMacTrafficLightInset = 92;

final diagnosticNavigatorKey = GlobalKey<NavigatorState>();

/// Bumped on every navigator stack change; [DesktopAppFrame] listens.
final diagnosticNavStackTick = ValueNotifier<int>(0);

/// Keeps the custom title-bar back chevron in sync with the real stack.
/// [NavigationNotification] alone can flicker `canHandlePop` during route
/// transitions, which made the chevron ignore clicks until it settled.
class DiagnosticNavigatorObserver extends NavigatorObserver {
  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      diagnosticNavStackTick.value++;

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      diagnosticNavStackTick.value++;

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      diagnosticNavStackTick.value++;

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) =>
      diagnosticNavStackTick.value++;
}

final diagnosticNavObserver = DiagnosticNavigatorObserver();

/// Optional page title / trailing actions published into [DesktopTitleBar].
class DesktopTitleChrome {
  const DesktopTitleChrome({
    this.owner,
    this.title,
    this.actions = const [],
  });

  final Object? owner;
  final String? title;
  final List<DesktopTitleAction> actions;
}

class DesktopTitleAction {
  const DesktopTitleAction({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;
}

final desktopTitleChrome = ValueNotifier<DesktopTitleChrome>(
  const DesktopTitleChrome(),
);

/// While mounted, drives the window title bar title + trailing actions.
class DesktopTitleChromeBinder extends StatefulWidget {
  const DesktopTitleChromeBinder({
    super.key,
    required this.title,
    required this.child,
    this.actions = const [],
  });

  final String title;
  final List<DesktopTitleAction> actions;
  final Widget child;

  @override
  State<DesktopTitleChromeBinder> createState() =>
      _DesktopTitleChromeBinderState();
}

class _DesktopTitleChromeBinderState extends State<DesktopTitleChromeBinder> {
  static final _stack = <_DesktopTitleChromeBinderState>[];
  final _owner = Object();

  void _applyTop() {
    if (_stack.isEmpty) {
      desktopTitleChrome.value = const DesktopTitleChrome();
      return;
    }
    final top = _stack.last;
    desktopTitleChrome.value = DesktopTitleChrome(
      owner: top._owner,
      title: top.widget.title,
      actions: top.widget.actions,
    );
  }

  @override
  void initState() {
    super.initState();
    _stack.add(this);
    _applyTop();
  }

  @override
  void didUpdateWidget(covariant DesktopTitleChromeBinder oldWidget) {
    super.didUpdateWidget(oldWidget);
    _applyTop();
  }

  @override
  void dispose() {
    _stack.remove(this);
    _applyTop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// App chrome: drag region, leading app icon / back, settings, window buttons.
///
/// Windows: settings sits immediately left of minimize.
/// macOS: settings is flush right (traffic lights stay native on the left).
class DesktopTitleBar extends StatefulWidget {
  const DesktopTitleBar({
    super.key,
    required this.canPop,
    required this.onBack,
    required this.onSettings,
    this.title = 'AOW Diagnostic tool for Android',
  });

  final bool canPop;
  final VoidCallback onBack;
  final VoidCallback onSettings;
  final String title;

  @override
  State<DesktopTitleBar> createState() => _DesktopTitleBarState();
}

class _DesktopTitleBarState extends State<DesktopTitleBar> with WindowListener {
  var _maximized = false;

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    desktopTitleChrome.addListener(_onChromeChanged);
    windowManager.isMaximized().then((v) {
      if (mounted) setState(() => _maximized = v);
    });
  }

  @override
  void dispose() {
    desktopTitleChrome.removeListener(_onChromeChanged);
    windowManager.removeListener(this);
    super.dispose();
  }

  void _onChromeChanged() {
    if (!mounted) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void onWindowMaximize() => setState(() => _maximized = true);

  @override
  void onWindowUnmaximize() => setState(() => _maximized = false);

  @override
  Widget build(BuildContext context) {
    final ink = AmlTheme.inkOf(context);
    final muted = AmlTheme.mutedOf(context);
    final isMac = Platform.isMacOS;
    final barH = kDesktopTitleBarHeight;
    final chrome = desktopTitleChrome.value;
    final pageTitle = chrome.title?.trim();
    final hasPageTitle = pageTitle != null && pageTitle.isNotEmpty;

    final settingsBtn = _ChromeIconButton(
      icon: Icons.settings_rounded,
      tooltip: 'Settings',
      color: muted,
      barHeight: barH,
      onPressed: widget.canPop ? null : widget.onSettings,
    );

    // Page chrome (e.g. Pick an app) wins; else product name.
    final title = hasPageTitle
        ? pageTitle
        : (isMac ? 'AOW Diagnostic' : widget.title);

    final titleStyle = TextStyle(
      inherit: false,
      fontSize: isMac ? 13 : 12.5,
      fontWeight: isMac ? FontWeight.w600 : FontWeight.w700,
      letterSpacing: isMac ? -0.2 : -0.1,
      // Segoe is Windows; on macOS leave null so Flutter uses SF.
      fontFamily: isMac ? null : 'Segoe UI',
      color: ink.withValues(alpha: isMac ? 0.78 : 0.88),
      decoration: TextDecoration.none,
    );

    final trailing = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final action in chrome.actions)
          _ChromeIconButton(
            icon: action.icon,
            tooltip: action.tooltip,
            color: muted,
            barHeight: barH,
            onPressed: action.onPressed,
          ),
        settingsBtn,
        if (isMac)
          const SizedBox(width: 14)
        else ...[
          _WinButton(
            icon: Icons.remove,
            onTap: () => windowManager.minimize(),
          ),
          _WinButton(
            icon: _maximized
                ? Icons.filter_none_rounded
                : Icons.crop_square_rounded,
            iconSize: _maximized ? 13 : 15,
            onTap: () async {
              if (await windowManager.isMaximized()) {
                await windowManager.unmaximize();
              } else {
                await windowManager.maximize();
              }
            },
          ),
          _WinButton(
            icon: Icons.close_rounded,
            hoverColor: const Color(0xFFE53935),
            hoverIconColor: Colors.white,
            onTap: () => windowManager.close(),
          ),
        ],
      ],
    );

    // Transparent Material only — gives Text a proper DefaultTextStyle so
    // Flutter does not paint the yellow "missing Material" underline. The
    // opaque fill still lives in [DesktopAppFrame] (no seam under chrome).
    //
    // LayoutBuilder uses the parent’s max width (the window). Caption
    // buttons are Positioned(right: 0) so they stay on the window edge
    // even if a Row above them shrink-wraps.
    return Material(
      type: MaterialType.transparency,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final width = constraints.maxWidth.isFinite
              ? constraints.maxWidth
              : MediaQuery.sizeOf(context).width;
          return SizedBox(
            height: barH,
            width: width,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                Row(
                  children: [
                    SizedBox(width: isMac ? _kMacTrafficLightInset : 10),
                    _LeadingSlot(
                      canPop: widget.canPop,
                      onBack: widget.onBack,
                      ink: ink,
                      barHeight: barH,
                      compact: isMac,
                    ),
                    SizedBox(width: isMac ? 10 : 8),
                    Expanded(
                      child: GestureDetector(
                        behavior: HitTestBehavior.translucent,
                        onDoubleTap: isMac
                            ? null
                            : () async {
                                if (await windowManager.isMaximized()) {
                                  await windowManager.unmaximize();
                                } else {
                                  await windowManager.maximize();
                                }
                              },
                        child: DragToMoveArea(
                          child: Align(
                            alignment: Alignment.centerLeft,
                            child: Padding(
                              padding: const EdgeInsets.only(right: 12),
                              child: Text(
                                title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: titleStyle,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                    IgnorePointer(child: Opacity(opacity: 0, child: trailing)),
                  ],
                ),
                Positioned(
                  right: 0,
                  top: 0,
                  bottom: 0,
                  child: trailing,
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _LeadingSlot extends StatelessWidget {
  const _LeadingSlot({
    required this.canPop,
    required this.onBack,
    required this.ink,
    required this.barHeight,
    this.compact = false,
  });

  final bool canPop;
  final VoidCallback onBack;
  final Color ink;
  final double barHeight;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    if (canPop) {
      return _ChromeIconButton(
        icon: Icons.arrow_back_ios_new_rounded,
        tooltip: 'Back',
        color: ink,
        iconSize: compact ? 14 : 15,
        barHeight: barHeight,
        onPressed: onBack,
      );
    }
    final dark = AmlTheme.isDark(context);
    final size = compact ? 20.0 : 18.0;
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: compact ? 2 : 6),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(compact ? 6 : 5),
        child: Image.asset(
          dark
              ? 'assets/branding/app_icon_dark.png'
              : 'assets/branding/app_icon_light.png',
          width: size,
          height: size,
          filterQuality: FilterQuality.medium,
          errorBuilder: (_, _, _) =>
              Icon(Icons.monitor_heart_rounded, size: size, color: ink),
        ),
      ),
    );
  }
}

class _ChromeIconButton extends StatelessWidget {
  const _ChromeIconButton({
    required this.icon,
    required this.tooltip,
    required this.color,
    required this.barHeight,
    this.onPressed,
    this.iconSize = 17,
  });

  final IconData icon;
  final String tooltip;
  final Color color;
  final VoidCallback? onPressed;
  final double iconSize;
  final double barHeight;

  @override
  Widget build(BuildContext context) {
    // Opaque hit target — sparse IconButton splash + title-bar drag siblings
    // used to eat single clicks on the back chevron.
    return Tooltip(
      message: tooltip,
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          onTap: onPressed,
          customBorder: const CircleBorder(),
          child: SizedBox(
            width: 40,
            height: barHeight,
            child: Icon(
              icon,
              size: iconSize,
              color: onPressed == null
                  ? color.withValues(alpha: 0.28)
                  : color,
            ),
          ),
        ),
      ),
    );
  }
}

class _WinButton extends StatefulWidget {
  const _WinButton({
    required this.icon,
    required this.onTap,
    this.iconSize = 16,
    this.hoverColor,
    this.hoverIconColor,
  });

  final IconData icon;
  final VoidCallback onTap;
  final double iconSize;
  final Color? hoverColor;
  final Color? hoverIconColor;

  @override
  State<_WinButton> createState() => _WinButtonState();
}

class _WinButtonState extends State<_WinButton> {
  var _hover = false;

  @override
  Widget build(BuildContext context) {
    final idle = AmlTheme.mutedOf(context);
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Container(
          width: 46,
          height: kDesktopTitleBarHeight,
          color: _hover
              ? (widget.hoverColor ??
                    (AmlTheme.isDark(context)
                        ? Colors.white.withValues(alpha: 0.08)
                        : const Color(0xFFEDEAF6)))
              : Colors.transparent,
          child: Icon(
            widget.icon,
            size: widget.iconSize,
            color: _hover
                ? (widget.hoverIconColor ?? AmlTheme.inkOf(context))
                : idle,
          ),
        ),
      ),
    );
  }
}

/// Wraps the [MaterialApp] navigator with the desktop title strip.
class DesktopAppFrame extends StatefulWidget {
  const DesktopAppFrame({super.key, required this.child});

  final Widget child;

  @override
  State<DesktopAppFrame> createState() => _DesktopAppFrameState();
}

class _DesktopAppFrameState extends State<DesktopAppFrame> {
  var _canPop = false;

  void _syncCanPop() {
    final next = diagnosticNavigatorKey.currentState?.canPop() ?? false;
    if (!mounted || next == _canPop) return;
    setState(() => _canPop = next);
  }

  void _handleBack() {
    final nav = diagnosticNavigatorKey.currentState;
    if (nav != null && nav.canPop()) {
      nav.pop();
    }
  }

  void _openSettings() {
    diagnosticNavigatorKey.currentState?.push(
      MaterialPageRoute<void>(builder: (_) => const SettingsScreen()),
    );
  }

  @override
  void initState() {
    super.initState();
    diagnosticNavStackTick.addListener(_syncCanPop);
    WidgetsBinding.instance.addPostFrameCallback((_) => _syncCanPop());
  }

  @override
  void dispose() {
    diagnosticNavStackTick.removeListener(_syncCanPop);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!kDesktopCustomTitleBar) {
      return widget.child;
    }

    final dark = AmlTheme.isDark(context);
    final shell = dark ? AmlTheme.darkBg : kSettingsPageBackground;
    final baseTheme = Theme.of(context);

    // Title-bar Tooltips sit outside the Navigator Overlay. Overlay.wrap
    // sizes its child to the window (unlike a raw OverlayEntry, whose
    // builder is ignored on rebuild and can shrink-wrap).
    //
    // Ambient wash sits behind the *whole* frame so the title strip and
    // the page share one gradient (no solid bar under the chrome).
    return Overlay.wrap(
      child: NotificationListener<NavigationNotification>(
        onNotification: (notification) {
          WidgetsBinding.instance.addPostFrameCallback((_) => _syncCanPop());
          return false;
        },
        child: ColoredBox(
          color: shell,
          child: Stack(
            fit: StackFit.expand,
            children: [
              const SettingsAmbientBackground(),
              Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  DesktopTitleBar(
                    canPop: _canPop,
                    onBack: _handleBack,
                    onSettings: _openSettings,
                  ),
                  Expanded(
                    child: Theme(
                      data: baseTheme.copyWith(
                        scaffoldBackgroundColor: Colors.transparent,
                        canvasColor: Colors.transparent,
                      ),
                      child: widget.child,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
