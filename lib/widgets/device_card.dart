import 'package:aml_ui/aml_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/adb/adb_client.dart';
import '../core/adb/device_details.dart';
import '../state/adb_providers.dart';
import '../state/device_names_provider.dart';
import '../theme/desktop_theme.dart';
import 'desktop_chrome.dart';

/// Fancy rounded device card for the home grid.
class DeviceCard extends ConsumerStatefulWidget {
  const DeviceCard({
    super.key,
    required this.device,
    required this.selected,
    required this.watching,
    required this.anrCount,
    required this.onSelect,
    required this.onWatchToggle,
    required this.onPickApp,
    required this.onRename,
  });

  final AdbDevice device;
  final bool selected;
  final bool watching;
  final int anrCount;
  final VoidCallback onSelect;
  final VoidCallback onWatchToggle;
  final VoidCallback onPickApp;
  final VoidCallback onRename;

  @override
  ConsumerState<DeviceCard> createState() => _DeviceCardState();
}

class _DeviceCardState extends ConsumerState<DeviceCard> {
  var _hovering = false;

  @override
  Widget build(BuildContext context) {
    final device = widget.device;
    final detailsAsync = ref.watch(deviceDetailsProvider(device));
    final details =
        detailsAsync.valueOrNull ?? AdbDeviceDetails.fallback(device);
    final names = ref.watch(deviceNamesProvider);
    final nickname = names[device.serial]?.trim();
    final renamed = nickname != null && nickname.isNotEmpty;

    final accent = switch (device.state) {
      AdbDeviceState.device => AmlTheme.mint,
      AdbDeviceState.unauthorized => AmlTheme.amber,
      AdbDeviceState.offline => AmlTheme.pink,
      AdbDeviceState.unknown => AmlTheme.sky,
    };

    final ink = AmlTheme.inkOf(context);
    final muted = AmlTheme.mutedOf(context);
    final dark = AmlTheme.isDark(context);

    final headline = renamed ? nickname : details.displayModel;
    final manufacturer = details.displayManufacturer;
    final subtitleParts = <String>[
      if (renamed) details.displayModel,
      if (details.androidLabel != null) details.androidLabel!,
      device.serial,
    ];

    return MouseRegion(
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: widget.onSelect,
          borderRadius: BorderRadius.circular(20),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOut,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(20),
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: dark
                    ? [
                        Color.lerp(AmlTheme.darkSurface, accent, 0.14)!,
                        AmlTheme.darkSurface,
                      ]
                    : [
                        Colors.white,
                        Color.lerp(Colors.white, accent, 0.10)!,
                      ],
              ),
              border: Border.all(
                color: widget.selected
                    ? AmlTheme.violet.withValues(alpha: 0.72)
                    : accent.withValues(alpha: dark ? 0.34 : 0.28),
                width: widget.selected ? 1.6 : 1,
              ),
              boxShadow: [
                BoxShadow(
                  color: accent.withValues(alpha: dark ? 0.18 : 0.14),
                  blurRadius: widget.selected ? 22 : 16,
                  offset: const Offset(0, 10),
                ),
                if (!dark)
                  BoxShadow(
                    color: AmlTheme.violet.withValues(alpha: 0.05),
                    blurRadius: 8,
                    offset: const Offset(0, 2),
                  ),
              ],
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(20),
              child: Stack(
                children: [
                  Positioned(
                    right: -18,
                    top: -24,
                    child: IgnorePointer(
                      child: Container(
                        width: 120,
                        height: 120,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          gradient: RadialGradient(
                            colors: [
                              accent.withValues(alpha: dark ? 0.28 : 0.22),
                              accent.withValues(alpha: 0),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                  if (widget.selected)
                    Positioned(
                      left: 0,
                      top: 14,
                      bottom: 14,
                      child: Container(
                        width: 4,
                        decoration: const BoxDecoration(
                          color: AmlTheme.violet,
                          borderRadius: BorderRadius.horizontal(
                            right: Radius.circular(4),
                          ),
                        ),
                      ),
                    ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 14, 14, 12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            _PhonePictogram(
                              accent: accent,
                              isTablet: details.isTablet,
                            ),
                            const SizedBox(width: 14),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    manufacturer.toUpperCase(),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontSize: 10.5,
                                      fontWeight: FontWeight.w800,
                                      letterSpacing: 0.9,
                                      color: accent.withValues(alpha: 0.95),
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  Row(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.center,
                                    children: [
                                      Flexible(
                                        child: Text(
                                          headline,
                                          maxLines: 2,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                            fontSize: 16.5,
                                            fontWeight: FontWeight.w800,
                                            height: 1.15,
                                            letterSpacing: -0.2,
                                            color: ink,
                                          ),
                                        ),
                                      ),
                                      AnimatedOpacity(
                                        opacity: _hovering ? 1 : 0,
                                        duration: const Duration(
                                          milliseconds: 140,
                                        ),
                                        child: IgnorePointer(
                                          ignoring: !_hovering,
                                          child: IconButton(
                                            tooltip: 'Rename device',
                                            onPressed: widget.onRename,
                                            visualDensity:
                                                VisualDensity.compact,
                                            padding: const EdgeInsets.all(4),
                                            constraints: const BoxConstraints(
                                              minWidth: 28,
                                              minHeight: 28,
                                            ),
                                            iconSize: 16,
                                            style: IconButton.styleFrom(
                                              foregroundColor: muted,
                                              hoverColor: AmlTheme.violet
                                                  .withValues(alpha: 0.12),
                                            ),
                                            icon: const Icon(
                                              Icons
                                                  .drive_file_rename_outline_rounded,
                                            ),
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 6),
                                  Text(
                                    subtitleParts.join(' · '),
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: Desk.mono(size: 11, color: muted),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                        const Spacer(),
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            if (widget.watching)
                              DesktopTag(
                                label: widget.anrCount > 0
                                    ? '${widget.anrCount} ANR'
                                    : 'watching',
                                color: widget.anrCount > 0
                                    ? AmlTheme.pink
                                    : AmlTheme.violet,
                              )
                            else if (detailsAsync.isLoading)
                              SizedBox(
                                width: 12,
                                height: 12,
                                child: CircularProgressIndicator(
                                  strokeWidth: 1.6,
                                  color: muted.withValues(alpha: 0.7),
                                ),
                              ),
                            const Spacer(),
                            _LabeledCardAction(
                              glyph: _WatchGlyph(
                                watching: widget.watching,
                                color: widget.watching
                                    ? AmlTheme.pink
                                    : AmlTheme.violet,
                                enabled: device.isReady || widget.watching,
                              ),
                              label: widget.watching ? 'Stop' : 'Watch',
                              onPressed: device.isReady || widget.watching
                                  ? widget.onWatchToggle
                                  : null,
                            ),
                            const SizedBox(width: 2),
                            _LabeledCardAction(
                              glyph: _AppsGlyph(
                                color: AmlTheme.violet,
                                enabled: device.isReady,
                              ),
                              label: 'Apps',
                              onPressed: device.isReady
                                  ? widget.onPickApp
                                  : null,
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Bottom-corner card action: glass pictogram with a tiny centered label.
class _LabeledCardAction extends StatelessWidget {
  const _LabeledCardAction({
    required this.glyph,
    required this.label,
    required this.onPressed,
  });

  final Widget glyph;
  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final muted = AmlTheme.mutedOf(context);
    final enabled = onPressed != null;

    return Tooltip(
      message: label,
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(8, 2, 8, 2),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Opacity(opacity: enabled ? 1 : 0.38, child: glyph),
              const SizedBox(height: 3),
              Text(
                label,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 9.5,
                  fontWeight: FontWeight.w700,
                  height: 1,
                  letterSpacing: 0.1,
                  color: enabled
                      ? muted.withValues(alpha: 0.92)
                      : muted.withValues(alpha: 0.35),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Pulse / stop mark — thin glass, not a fat Material heart monitor.
class _WatchGlyph extends StatelessWidget {
  const _WatchGlyph({
    required this.watching,
    required this.color,
    required this.enabled,
  });

  final bool watching;
  final Color color;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 30,
      height: 30,
      child: CustomPaint(
        painter: _WatchGlyphPainter(
          color: color,
          watching: watching,
          dark: AmlTheme.isDark(context),
          muted: !enabled,
        ),
      ),
    );
  }
}

class _WatchGlyphPainter extends CustomPainter {
  const _WatchGlyphPainter({
    required this.color,
    required this.watching,
    required this.dark,
    required this.muted,
  });

  final Color color;
  final bool watching;
  final bool dark;
  final bool muted;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = RRect.fromRectAndRadius(
      Rect.fromLTWH(1.2, 3.5, size.width - 2.4, size.height - 7),
      const Radius.circular(9),
    );
    canvas.drawRRect(
      rect,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            color.withValues(alpha: dark ? 0.28 : 0.16),
            (dark ? const Color(0xFF1A1430) : Colors.white)
                .withValues(alpha: 0.92),
          ],
        ).createShader(rect.outerRect),
    );
    canvas.drawRRect(
      rect,
      Paint()
        ..color = color.withValues(alpha: 0.55)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.15,
    );
    // Upper-left glass sheen.
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(3, 5, size.width * 0.42, 6),
        const Radius.circular(6),
      ),
      Paint()..color = Colors.white.withValues(alpha: dark ? 0.12 : 0.55),
    );

    if (watching) {
      final stop = RRect.fromRectAndRadius(
        Rect.fromCenter(
          center: Offset(size.width / 2, size.height / 2),
          width: 9,
          height: 9,
        ),
        const Radius.circular(2.4),
      );
      canvas.drawRRect(stop, Paint()..color = color);
      return;
    }

    final midY = size.height / 2 + 0.4;
    final path = Path()
      ..moveTo(4.5, midY)
      ..lineTo(8.2, midY)
      ..lineTo(10.4, midY - 5.4)
      ..lineTo(12.8, midY + 6.2)
      ..lineTo(15.4, midY - 3.6)
      ..lineTo(17.6, midY)
      ..lineTo(25.4, midY);
    canvas.drawPath(
      path,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.35
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );
  }

  @override
  bool shouldRepaint(covariant _WatchGlyphPainter oldDelegate) =>
      oldDelegate.color != color ||
      oldDelegate.watching != watching ||
      oldDelegate.dark != dark ||
      oldDelegate.muted != muted;
}

/// Four pearl app tiles — a tiny shelf, not the fat Material grid.
class _AppsGlyph extends StatelessWidget {
  const _AppsGlyph({required this.color, required this.enabled});

  final Color color;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 30,
      height: 30,
      child: CustomPaint(
        painter: _AppsGlyphPainter(
          color: color,
          dark: AmlTheme.isDark(context),
          muted: !enabled,
        ),
      ),
    );
  }
}

class _AppsGlyphPainter extends CustomPainter {
  const _AppsGlyphPainter({
    required this.color,
    required this.dark,
    required this.muted,
  });

  final Color color;
  final bool dark;
  final bool muted;

  @override
  void paint(Canvas canvas, Size size) {
    const tiles = <Color>[
      AmlTheme.violet,
      AmlTheme.mint,
      AmlTheme.sky,
      AmlTheme.pink,
    ];
    const gap = 2.4;
    const tile = 10.2;
    final origin = Offset(
      (size.width - tile * 2 - gap) / 2,
      (size.height - tile * 2 - gap) / 2,
    );
    for (var i = 0; i < 4; i++) {
      final col = i % 2;
      final row = i ~/ 2;
      final rrect = RRect.fromRectAndRadius(
        Rect.fromLTWH(
          origin.dx + col * (tile + gap),
          origin.dy + row * (tile + gap),
          tile,
          tile,
        ),
        const Radius.circular(3.6),
      );
      final fill = tiles[i];
      canvas.drawRRect(
        rrect,
        Paint()
          ..shader = LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              Color.lerp(Colors.white, fill, dark ? 0.35 : 0.22)!,
              fill.withValues(alpha: dark ? 0.92 : 0.88),
            ],
          ).createShader(rrect.outerRect),
      );
      canvas.drawRRect(
        rrect,
        Paint()
          ..color = Colors.white.withValues(alpha: dark ? 0.22 : 0.55)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 0.7,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _AppsGlyphPainter oldDelegate) =>
      oldDelegate.color != color ||
      oldDelegate.dark != dark ||
      oldDelegate.muted != muted;
}

/// Compact phone / tablet glass — frame and screen only, no fat Material glyph.
class _PhonePictogram extends StatelessWidget {
  const _PhonePictogram({required this.accent, required this.isTablet});

  final Color accent;
  final bool isTablet;

  @override
  Widget build(BuildContext context) {
    final dark = AmlTheme.isDark(context);
    final w = isTablet ? 54.0 : 40.0;
    final h = isTablet ? 40.0 : 66.0;
    final radius = isTablet ? 11.0 : 13.0;

    return SizedBox(
      width: 68,
      height: 74,
      child: Center(
        child: Container(
          width: w,
          height: h,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(radius),
            border: Border.all(
              color: accent.withValues(alpha: 0.48),
              width: 1.35,
            ),
            boxShadow: [
              BoxShadow(
                color: accent.withValues(alpha: 0.18),
                blurRadius: 12,
                offset: const Offset(0, 7),
              ),
            ],
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                accent.withValues(alpha: dark ? 0.26 : 0.16),
                (dark ? AmlTheme.darkBg : Colors.white).withValues(alpha: 0.94),
              ],
            ),
          ),
          child: Stack(
            children: [
              Positioned(
                left: 6,
                top: 5,
                child: Container(
                  width: w * 0.38,
                  height: 7,
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: dark ? 0.14 : 0.7),
                    borderRadius: BorderRadius.circular(6),
                  ),
                ),
              ),
              Positioned(
                top: isTablet ? 6 : 8,
                left: 0,
                right: 0,
                child: Center(
                  child: Container(
                    width: isTablet ? 12 : 9,
                    height: 3,
                    decoration: BoxDecoration(
                      color: accent.withValues(alpha: 0.38),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
              ),
              Positioned(
                left: w * 0.22,
                right: w * 0.22,
                bottom: isTablet ? 6 : 8,
                child: Container(
                  height: 2.4,
                  decoration: BoxDecoration(
                    color: accent.withValues(alpha: 0.28),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
