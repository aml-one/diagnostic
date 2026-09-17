import 'package:aml_ui/aml_ui.dart';
import 'package:flutter/material.dart';

/// Fun empty state: an upright phone with a literal USB cable that curls
/// and loops before ending in a recognizable USB-A connector, similar to a
/// classic "cable" icon. Meant to sit centered in whatever space the parent
/// gives it (e.g. inside an `Expanded` + `Center`).
class ConnectDevicePictogram extends StatelessWidget {
  const ConnectDevicePictogram({super.key});

  @override
  Widget build(BuildContext context) {
    final dark = AmlTheme.isDark(context);
    final ink = AmlTheme.inkOf(context);
    final muted = AmlTheme.mutedOf(context);
    final cableColor = AmlTheme.amber.withValues(alpha: dark ? 0.85 : 0.75);

    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 236,
            height: 196,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                // Soft pastel backdrop blob, behind the phone.
                Positioned(
                  right: 6,
                  top: 4,
                  child: Container(
                    width: 172,
                    height: 172,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: RadialGradient(
                        colors: [
                          AmlTheme.sky.withValues(alpha: dark ? 0.22 : 0.16),
                          AmlTheme.violet.withValues(
                            alpha: dark ? 0.10 : 0.05,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                // Sparkle accents.
                const Positioned(
                  top: 2,
                  right: 30,
                  child: _Spark(color: AmlTheme.pink, size: 10),
                ),
                const Positioned(
                  top: 56,
                  right: 4,
                  child: _Spark(color: AmlTheme.violet, size: 7),
                ),
                // The USB cable: loops from the connector head up to the
                // phone's charging port. Drawn before the phone and the
                // connector so both visually sit on top of it.
                Positioned.fill(
                  child: CustomPaint(painter: _UsbCablePainter(cableColor)),
                ),
                // Phone, upright — the cable's port nub sits at its base.
                Positioned(
                  right: 34,
                  top: 8,
                  child: Container(
                    width: 68,
                    height: 122,
                    decoration: BoxDecoration(
                      color: dark ? AmlTheme.darkBg : Colors.white,
                      borderRadius: BorderRadius.circular(18),
                      border: Border.all(
                        color: AmlTheme.sky.withValues(alpha: 0.5),
                        width: 2.5,
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: AmlTheme.sky.withValues(alpha: 0.2),
                          blurRadius: 20,
                          offset: const Offset(0, 12),
                        ),
                      ],
                    ),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          Icons.phone_android_rounded,
                          size: 30,
                          color: AmlTheme.mint,
                        ),
                        const SizedBox(height: 10),
                        Container(
                          width: 22,
                          height: 3.5,
                          decoration: BoxDecoration(
                            color: muted.withValues(alpha: 0.3),
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                // The little charging-port nub on the phone's bottom edge,
                // where the cable visually plugs in.
                const Positioned(right: 58, top: 126, child: _PortNub()),
                // The USB-A connector head — the cable's free end, the
                // part that would plug into a computer.
                const Positioned(
                  left: 6,
                  bottom: 6,
                  child: _UsbConnector(color: AmlTheme.amber),
                ),
              ],
            ),
          ),
          const SizedBox(height: 22),
          Text(
            'Connect a device',
            style: TextStyle(
              fontSize: 21,
              fontWeight: FontWeight.w800,
              letterSpacing: -0.2,
              color: ink,
            ),
          ),
          const SizedBox(height: 8),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 320),
            child: Text(
              'Plug in a phone with USB debugging, unlock it, and allow '
              'this PC.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 14.5, height: 1.45, color: muted),
            ),
          ),
        ],
      ),
    );
  }
}

class _Spark extends StatelessWidget {
  const _Spark({required this.color, required this.size});

  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Icon(
      Icons.auto_awesome_rounded,
      size: size,
      color: color.withValues(alpha: 0.75),
    );
  }
}

/// The dark little notch on the phone's bottom edge that the cable
/// visually plugs into.
class _PortNub extends StatelessWidget {
  const _PortNub();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 16,
      height: 8,
      decoration: BoxDecoration(
        color: AmlTheme.amber,
        borderRadius: BorderRadius.circular(2.5),
      ),
    );
  }
}

/// Paints the cable inside the pictogram's [Stack]: it leaves the phone's
/// port nub, sweeps down and to the left, curls into a single loop (like a
/// coiled cable resting on a desk), then continues to the USB-A connector.
class _UsbCablePainter extends CustomPainter {
  const _UsbCablePainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    // Anchor points: where the cable meets the phone's port nub, and
    // where it meets the base of the USB-A connector glyph.
    final top = Offset(size.width - 74, size.height * 0.675);
    final bottom = Offset(17, size.height - 8);

    final path = Path()
      ..moveTo(top.dx, top.dy)
      // Sweep down and to the left, out toward the loop.
      ..cubicTo(
        top.dx - 6,
        top.dy + 34,
        top.dx - 58,
        top.dy + 10,
        top.dx - 52,
        top.dy + 46,
      )
      // The loop itself: swings out and curls back across the incoming
      // line, so the cable reads as coiled rather than a single arc.
      ..cubicTo(
        top.dx - 46,
        top.dy + 80,
        top.dx - 98,
        top.dy + 78,
        top.dx - 96,
        top.dy + 46,
      )
      ..cubicTo(
        top.dx - 94,
        top.dy + 18,
        top.dx - 60,
        top.dy + 14,
        top.dx - 60,
        top.dy + 44,
      )
      // Continue on down to the connector's back.
      ..cubicTo(
        top.dx - 60,
        top.dy + 78,
        bottom.dx + 10,
        bottom.dy - 30,
        bottom.dx,
        bottom.dy,
      );

    canvas.drawPath(
      path,
      Paint()
        ..color = color
        ..strokeWidth = 5
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );
  }

  @override
  bool shouldRepaint(covariant _UsbCablePainter oldDelegate) =>
      oldDelegate.color != color;
}

/// The cable's free end — a literal USB-A plug: a narrow metal contact
/// tip and a slightly wider plastic body, separated by a thin seam. Same
/// silhouette as a real connector, resting at a casual lean.
class _UsbConnector extends StatelessWidget {
  const _UsbConnector({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) {
    return Transform.rotate(
      angle: -0.12,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Metal contact tip — narrow, pokes out from the body.
          Container(
            width: 16,
            height: 11,
            decoration: BoxDecoration(
              color: color,
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(2),
              ),
            ),
          ),
          // Seam between the tip and the body.
          Container(width: 22, height: 2.5, color: Colors.white),
          // Plastic body — where the cable attaches underneath.
          Container(
            width: 22,
            height: 22,
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(3),
              boxShadow: [
                BoxShadow(
                  color: color.withValues(alpha: 0.45),
                  blurRadius: 8,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
