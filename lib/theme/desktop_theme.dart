import 'package:aml_ui/aml_ui.dart';
import 'package:flutter/material.dart';

/// Desktop chrome tokens for AmL Diagnostic.
///
/// The shared `aml_ui` package keeps its phone-sized radii and paddings for
/// the other AmL products (MessageMe, OneAuth, …). This tool is a Windows-only
/// utility, so the tighter geometry lives here and is applied through
/// [diagnosticLightTheme] / [diagnosticDarkTheme] plus the widgets in
/// `lib/widgets/desktop_chrome.dart`.
abstract final class Desk {
  /// Cards, banners, panels.
  static const double panel = 12;

  /// Compact list rows, log pane, mono blocks.
  static const double row = 8;

  /// Filled / outlined / icon buttons.
  static const double button = 8;

  /// Status tags, level markers, badges.
  static const double tag = 6;

  static const double dialog = 14;

  static const double buttonHeight = 36;
  static const double smallButtonHeight = 30;

  /// Readable cap for left-aligned page content.
  static const double contentWidth = 960;
  static const double formWidth = 720;

  static const double deviceRowHeight = 54;
  static const double packageRowHeight = 48;
  static const double logRowHeight = 22;
  static const double toolbarHeight = 40;

  static const String monoFamily = 'Consolas';
  static const List<String> monoFallback = <String>[
    'Cascadia Mono',
    'Courier New',
    'monospace',
  ];

  /// Flat panel fill: lets the pastel ambient background breathe through
  /// without the heavy gradient + shadow of the shared `SettingsSurface`.
  static Color panelFill(BuildContext context) => AmlTheme.isDark(context)
      ? AmlTheme.darkSurface.withValues(alpha: 0.88)
      : Colors.white.withValues(alpha: 0.86);

  static Color hairline(BuildContext context) => AmlTheme.isDark(context)
      ? const Color(0x33C9BEDC)
      : const Color(0xFFEBE7F6);

  /// Log pane background — deeper than a panel so the mono text reads.
  static Color logSurface(BuildContext context) => AmlTheme.isDark(context)
      ? const Color(0xFF201C2A)
      : const Color(0xFFFCFBFE);

  /// Alternate log row wash (zebra), intentionally very low contrast.
  static Color zebra(BuildContext context) => AmlTheme.isDark(context)
      ? Colors.white.withValues(alpha: 0.022)
      : AmlTheme.violet.withValues(alpha: 0.028);

  /// Row highlight for the selected device.
  static Color selectedRowFill(BuildContext context) =>
      AmlTheme.violet.withValues(alpha: AmlTheme.isDark(context) ? 0.16 : 0.08);

  static const Color danger = Color(0xFFE85D75);

  /// Pastel accent per logcat level (V/D/I/W/E/F).
  static Color levelColor(String level) {
    switch (level) {
      case 'F':
      case 'E':
        return AmlTheme.pink;
      case 'W':
        return AmlTheme.amber;
      case 'I':
        return AmlTheme.mint;
      case 'D':
        return AmlTheme.sky;
      default:
        return AmlTheme.violet;
    }
  }

  static TextStyle mono({
    double size = 12,
    FontWeight weight = FontWeight.w400,
    Color? color,
    double height = 1.3,
  }) {
    return TextStyle(
      fontFamily: monoFamily,
      fontFamilyFallback: monoFallback,
      fontSize: size,
      fontWeight: weight,
      height: height,
      color: color,
    );
  }

  /// Small caps section label ("DEVICES", "LOGCAT").
  static TextStyle sectionLabel(BuildContext context) => TextStyle(
    fontSize: 11,
    fontWeight: FontWeight.w800,
    letterSpacing: 0.7,
    color: AmlTheme.mutedOf(context),
  );
}

ThemeData diagnosticLightTheme() => _desktop(AmlTheme.light());

ThemeData diagnosticDarkTheme() => _desktop(AmlTheme.dark());

/// Tightens the shared AmL theme for a native-feeling Windows utility:
/// smaller radii, 36px buttons, dense inputs and rows, hover tooltips.
ThemeData _desktop(ThemeData base) {
  final dark = base.brightness == Brightness.dark;
  final ink = dark ? AmlTheme.darkInk : AmlTheme.ink;
  final muted = dark ? AmlTheme.darkMuted : AmlTheme.muted;
  final stroke = dark ? AmlTheme.darkStroke : AmlTheme.stroke;
  final field = dark ? AmlTheme.darkField : AmlTheme.field;

  final buttonShape = RoundedRectangleBorder(
    borderRadius: BorderRadius.circular(Desk.button),
  );
  const buttonPadding = EdgeInsets.symmetric(horizontal: 16);
  const buttonText = TextStyle(
    fontSize: 13,
    fontWeight: FontWeight.w700,
    letterSpacing: 0.1,
  );
  final inputBorder = OutlineInputBorder(
    borderRadius: BorderRadius.circular(Desk.button),
    borderSide: BorderSide(color: stroke),
  );

  return base.copyWith(
    visualDensity: VisualDensity.compact,
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        shape: buttonShape,
        padding: buttonPadding,
        minimumSize: const Size(0, Desk.buttonHeight),
        textStyle: buttonText,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        shape: buttonShape,
        padding: buttonPadding,
        minimumSize: const Size(0, Desk.buttonHeight),
        textStyle: buttonText,
        side: BorderSide(color: stroke),
        foregroundColor: ink,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        shape: buttonShape,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        minimumSize: const Size(0, Desk.smallButtonHeight),
        textStyle: buttonText,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(
        shape: buttonShape,
        iconSize: 17,
        minimumSize: const Size(30, 30),
        padding: EdgeInsets.zero,
        foregroundColor: muted,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
    ),
    cardTheme: base.cardTheme.copyWith(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Desk.panel),
      ),
    ),
    dialogTheme: base.dialogTheme.copyWith(
      elevation: 8,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Desk.dialog),
      ),
      insetPadding: const EdgeInsets.symmetric(horizontal: 40, vertical: 24),
      titleTextStyle: base.dialogTheme.titleTextStyle?.copyWith(fontSize: 16),
      contentTextStyle: base.dialogTheme.contentTextStyle?.copyWith(
        fontSize: 13,
      ),
      actionsPadding: const EdgeInsets.fromLTRB(14, 4, 14, 12),
    ),
    inputDecorationTheme: InputDecorationTheme(
      isDense: true,
      filled: true,
      fillColor: field,
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      border: inputBorder,
      enabledBorder: inputBorder,
      disabledBorder: inputBorder,
      focusedBorder: inputBorder.copyWith(
        borderSide: BorderSide(color: AmlTheme.violet, width: 1.4),
      ),
      labelStyle: TextStyle(fontSize: 13, color: muted),
      floatingLabelStyle: const TextStyle(
        fontSize: 12,
        color: AmlTheme.violet,
        fontWeight: FontWeight.w700,
      ),
      hintStyle: TextStyle(fontSize: 13, color: muted.withValues(alpha: 0.72)),
    ),
    chipTheme: base.chipTheme.copyWith(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Desk.tag),
      ),
      labelStyle: TextStyle(
        fontSize: 11.5,
        fontWeight: FontWeight.w700,
        color: ink,
      ),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
    ),
    listTileTheme: base.listTileTheme.copyWith(
      dense: true,
      minVerticalPadding: 8,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Desk.row),
      ),
    ),
    dividerTheme: DividerThemeData(color: stroke, thickness: 1, space: 1),
    snackBarTheme: base.snackBarTheme.copyWith(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Desk.button),
      ),
    ),
    switchTheme: base.switchTheme.copyWith(
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
    ),
    scrollbarTheme: ScrollbarThemeData(
      thickness: const WidgetStatePropertyAll<double>(8),
      radius: const Radius.circular(4),
      thumbColor: WidgetStatePropertyAll<Color>(
        (dark ? AmlTheme.darkMuted : AmlTheme.muted).withValues(alpha: 0.35),
      ),
    ),
    // Icon-only row actions need hover hints on a desktop; the shared theme
    // disables tooltips for touch products.
    tooltipTheme: TooltipThemeData(
      waitDuration: const Duration(milliseconds: 380),
      showDuration: const Duration(seconds: 4),
      decoration: BoxDecoration(
        color: dark ? const Color(0xFF3A3546) : const Color(0xFF2A2440),
        borderRadius: BorderRadius.circular(Desk.tag),
      ),
      textStyle: const TextStyle(
        fontSize: 11.5,
        fontWeight: FontWeight.w600,
        color: Colors.white,
      ),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
    ),
  );
}
