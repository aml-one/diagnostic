import 'package:aml_ui/aml_ui.dart';
import 'package:flutter/material.dart';

import '../theme/desktop_theme.dart';

/// Left-aligned page content with a readable max width. Desktop windows are
/// wide; a centred 560px column reads as a phone app in a frame.
class DesktopContent extends StatelessWidget {
  const DesktopContent({
    super.key,
    required this.child,
    this.maxWidth = Desk.contentWidth,
  });

  final Widget child;
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.topLeft,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: SizedBox(width: double.infinity, child: child),
      ),
    );
  }
}

/// Flat 12px panel with a hairline border — the base surface of every screen.
class DesktopPanel extends StatelessWidget {
  const DesktopPanel({
    super.key,
    required this.child,
    this.padding = EdgeInsets.zero,
    this.radius = Desk.panel,
    this.tint,
    this.clip = true,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final double radius;

  /// Optional accent wash (ANR banner, error banner).
  final Color? tint;

  final bool clip;

  @override
  Widget build(BuildContext context) {
    final accent = tint;
    return SizedBox(
      width: double.infinity,
      child: Material(
        color: accent == null
            ? Desk.panelFill(context)
            : accent.withValues(alpha: AmlTheme.isDark(context) ? 0.18 : 0.13),
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radius),
          side: BorderSide(
            color: accent == null
                ? Desk.hairline(context)
                : accent.withValues(alpha: 0.38),
          ),
        ),
        clipBehavior: clip ? Clip.antiAlias : Clip.none,
        child: Padding(padding: padding, child: child),
      ),
    );
  }
}

/// Small caps label above a panel, with optional trailing controls.
class DesktopSectionLabel extends StatelessWidget {
  const DesktopSectionLabel({super.key, required this.label, this.trailing});

  final String label;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 24,
      child: Row(
        children: [
          Text(label.toUpperCase(), style: Desk.sectionLabel(context)),
          const Spacer(),
          ?trailing,
        ],
      ),
    );
  }
}

/// 6px status tag. Never a stadium pill.
class DesktopTag extends StatelessWidget {
  const DesktopTag({
    super.key,
    required this.label,
    required this.color,
    this.icon,
    this.mono = false,
  });

  final String label;
  final Color color;
  final IconData? icon;
  final bool mono;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(Desk.tag),
        border: Border.all(color: color.withValues(alpha: 0.32)),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2.5),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[
              Icon(icon, size: 12, color: color),
              const SizedBox(width: 4),
            ],
            Text(
              label,
              style: mono
                  ? Desk.mono(size: 11, weight: FontWeight.w700, color: color)
                  : TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      height: 1.3,
                      color: color,
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 10px state dot with a soft halo — replaces the 46px pastel icon badge in
/// repeated rows.
class DesktopStatusDot extends StatelessWidget {
  const DesktopStatusDot({super.key, required this.color, this.size = 10});

  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        border: Border.all(color: color.withValues(alpha: 0.35), width: 3),
      ),
    );
  }
}

/// Small tinted square icon (26px) for row leadings and panel headers.
class DesktopMiniIcon extends StatelessWidget {
  const DesktopMiniIcon({
    super.key,
    required this.icon,
    required this.color,
    this.size = 26,
  });

  final IconData icon;
  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(Desk.tag),
        border: Border.all(color: color.withValues(alpha: 0.26)),
      ),
      alignment: Alignment.center,
      child: Icon(icon, size: size * 0.56, color: color),
    );
  }
}

/// Icon-only row action with a hover tooltip.
class DesktopIconAction extends StatelessWidget {
  const DesktopIconAction({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.color,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: tooltip,
      onPressed: onPressed,
      icon: Icon(icon, size: 17),
      style: IconButton.styleFrom(foregroundColor: color),
    );
  }
}

/// Panel header: mini icon + title + optional subtitle and trailing widget.
class DesktopPanelHeader extends StatelessWidget {
  const DesktopPanelHeader({
    super.key,
    required this.icon,
    required this.accent,
    required this.title,
    this.subtitle,
    this.trailing,
  });

  final IconData icon;
  final Color accent;
  final String title;
  final String? subtitle;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        DesktopMiniIcon(icon: icon, color: accent),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  height: 1.2,
                  color: AmlTheme.inkOf(context),
                ),
              ),
              if (subtitle != null)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(
                    subtitle!,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      height: 1.3,
                      color: AmlTheme.mutedOf(context),
                    ),
                  ),
                ),
            ],
          ),
        ),
        if (trailing != null) ...[const SizedBox(width: 8), trailing!],
      ],
    );
  }
}

/// Slim inline status strip (adb state, empty states, pipeline notes).
class DesktopStatusStrip extends StatelessWidget {
  const DesktopStatusStrip({
    super.key,
    required this.icon,
    required this.accent,
    required this.title,
    this.detail,
    this.trailing,
    this.leading,
  });

  final IconData icon;
  final Color accent;
  final String title;
  final String? detail;
  final Widget? trailing;

  /// Replaces the mini icon (a [DesktopStatusDot] or a small [BirdLoader]).
  final Widget? leading;

  @override
  Widget build(BuildContext context) {
    return DesktopPanel(
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
      child: Row(
        children: [
          leading ?? DesktopMiniIcon(icon: icon, color: accent, size: 24),
          const SizedBox(width: 10),
          Text(
            title,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              color: AmlTheme.inkOf(context),
            ),
          ),
          if (detail != null) ...[
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                detail!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12,
                  color: AmlTheme.mutedOf(context),
                ),
              ),
            ),
          ] else
            const Spacer(),
          if (trailing != null) ...[const SizedBox(width: 8), trailing!],
        ],
      ),
    );
  }
}

/// Hairline between compact rows inside a panel.
class DesktopHairline extends StatelessWidget {
  const DesktopHairline({super.key, this.indent = 0});

  final double indent;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(left: indent),
      child: Container(height: 1, color: Desk.hairline(context)),
    );
  }
}

/// Flat monospace block for stacks, trace paths and log excerpts.
class DesktopMonoBlock extends StatelessWidget {
  const DesktopMonoBlock({super.key, required this.text, this.maxHeight = 320});

  final String text;
  final double maxHeight;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Desk.logSurface(context),
        borderRadius: BorderRadius.circular(Desk.row),
        border: Border.all(color: Desk.hairline(context)),
      ),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxHeight),
        child: Scrollbar(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
            child: SelectableText(
              text,
              style: Desk.mono(
                size: 11.5,
                height: 1.45,
                color: AmlTheme.inkOf(context),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
