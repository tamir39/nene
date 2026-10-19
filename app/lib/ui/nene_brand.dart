import 'package:flutter/material.dart';

/// The user-approved light palette. Logo teal is not a small-text color.
abstract final class NeneColors {
  static const brand = Color(0xFF4C929E);
  static const apricot = Color(0xFFF6C9A5);
  static const ivory = Color(0xFFF8F7F2);
  static const action = Color(0xFF286E78);
  static const ink = Color(0xFF172F38);
  static const muted = Color(0xFF4D626B);
  static const pale = Color(0xFFEFF7F5);
  static const border = Color(0xFFD7DFDF);
}

ThemeData neneTheme() {
  final scheme =
      ColorScheme.fromSeed(
        seedColor: NeneColors.action,
        brightness: Brightness.light,
      ).copyWith(
        primary: NeneColors.action,
        onPrimary: Colors.white,
        surface: NeneColors.ivory,
        onSurface: NeneColors.ink,
        onSurfaceVariant: NeneColors.muted,
        primaryContainer: NeneColors.pale,
        onPrimaryContainer: NeneColors.ink,
        error: const Color(0xFF9B3434),
      );
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: NeneColors.ivory,
    appBarTheme: const AppBarTheme(
      backgroundColor: NeneColors.ivory,
      foregroundColor: NeneColors.ink,
      surfaceTintColor: Colors.transparent,
      centerTitle: false,
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: Colors.white,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 18),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: Color(0xFF71828A)),
      ),
      errorMaxLines: 3,
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(48, 54),
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
      ),
    ),
    cardTheme: CardThemeData(
      color: Colors.white,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: const BorderSide(color: NeneColors.border),
      ),
    ),
  );
}

/// Open pocket paths match docs/ui/open-pocket-study.svg. No raster scaling
/// or third-party rendering dependency is needed for the three simple paths.
class NeneLogo extends StatelessWidget {
  const NeneLogo({super.key, this.size = 44, this.wordmark = true});
  final double size;
  final bool wordmark;

  @override
  Widget build(BuildContext context) => Semantics(
    label: 'Nene',
    image: true,
    child: ExcludeSemantics(
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          CustomPaint(size: Size.square(size), painter: const _PocketPainter()),
          if (wordmark) ...[
            const SizedBox(width: 10),
            Flexible(
              child: Text(
                'nene',
                style: TextStyle(
                  fontSize: size * .95,
                  fontWeight: FontWeight.w700,
                  letterSpacing: -1.5,
                  color: NeneColors.brand,
                ),
              ),
            ),
          ],
        ],
      ),
    ),
  );
}

class _PocketPainter extends CustomPainter {
  const _PocketPainter();

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / 320, size.height / 320);
    final back = Path()
      ..moveTo(8, 92)
      ..quadraticBezierTo(8, 68, 34, 61)
      ..lineTo(239, 7)
      ..quadraticBezierTo(278, -3, 278, 39)
      ..lineTo(278, 78)
      ..lineTo(155, 118)
      ..quadraticBezierTo(55, 86, 8, 92)
      ..close();
    final insert = Path()
      ..moveTo(168, 125)
      ..lineTo(282, 86)
      ..quadraticBezierTo(306, 78, 306, 102)
      ..lineTo(306, 145)
      ..quadraticBezierTo(236, 143, 168, 125)
      ..close();
    final front = Path()
      ..moveTo(4, 120)
      ..quadraticBezierTo(4, 102, 25, 107)
      ..cubicTo(98, 115, 173, 156, 302, 159)
      ..quadraticBezierTo(320, 159, 320, 181)
      ..lineTo(320, 267)
      ..quadraticBezierTo(320, 320, 269, 320)
      ..lineTo(55, 320)
      ..quadraticBezierTo(4, 320, 4, 269)
      ..close();
    canvas.drawPath(back, Paint()..color = NeneColors.brand);
    canvas.drawPath(insert, Paint()..color = NeneColors.apricot);
    canvas.drawPath(front, Paint()..color = NeneColors.brand);
    canvas.restore();
  }

  @override
  bool shouldRepaint(_PocketPainter oldDelegate) => false;
}
