import 'package:aml_ui/aml_ui.dart';
import 'package:flutter/material.dart';

import '../core/logcat/logcat_parser.dart';
import '../theme/desktop_theme.dart';

/// Dense Logcat row used on desktop Watch and phone Watch.
class LogcatRow extends StatelessWidget {
  const LogcatRow({
    super.key,
    required this.line,
    required this.zebra,
    this.dimmed = false,
    this.stacked = false,
  });

  final LogcatLine line;
  final bool zebra;
  final bool dimmed;

  /// Phone layout: time · type · tag on the first line, wrapping message below.
  final bool stacked;

  @override
  Widget build(BuildContext context) {
    final accent = Desk.levelColor(line.level);
    final fade = dimmed ? 0.45 : 1.0;
    final ink = AmlTheme.inkOf(context).withValues(alpha: fade);
    final muted = AmlTheme.mutedOf(context).withValues(alpha: 0.85 * fade);
    final message = line.message.isEmpty ? line.raw : line.message;
    final tagStyle = Desk.mono(
      size: 11,
      weight: FontWeight.w700,
      color: accent.withValues(alpha: fade),
    );

    return Container(
      color: zebra ? Desk.zebra(context) : null,
      padding: EdgeInsets.symmetric(
        horizontal: 8,
        vertical: stacked ? 6 : 0,
      ),
      alignment: Alignment.centerLeft,
      child: stacked
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      formatLogcatTime(line.timestamp),
                      maxLines: 1,
                      style: Desk.mono(size: 10.5, color: muted),
                    ),
                    const SizedBox(width: 8),
                    LogcatLevelMarker(
                      level: line.level,
                      color: accent,
                      fade: fade,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        line.tag,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: tagStyle,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 3),
                Text(
                  message,
                  style: Desk.mono(size: 11.5, color: ink, height: 1.35),
                ),
              ],
            )
          : Row(
              children: [
                SizedBox(
                  width: 72,
                  child: Text(
                    formatLogcatTime(line.timestamp),
                    maxLines: 1,
                    style: Desk.mono(size: 10.5, color: muted),
                  ),
                ),
                LogcatLevelMarker(level: line.level, color: accent, fade: fade),
                const SizedBox(width: 8),
                SizedBox(
                  width: 132,
                  child: Text(
                    line.tag,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: tagStyle,
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

class LogcatLevelMarker extends StatelessWidget {
  const LogcatLevelMarker({
    super.key,
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

String formatLogcatTime(DateTime? stamp) {
  if (stamp == null) return '';
  final h = stamp.hour.toString().padLeft(2, '0');
  final m = stamp.minute.toString().padLeft(2, '0');
  final s = stamp.second.toString().padLeft(2, '0');
  final ms = stamp.millisecond.toString().padLeft(3, '0');
  return '$h:$m:$s.$ms';
}
