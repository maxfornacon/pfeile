import 'package:flutter/material.dart';

import '../../../theme/app_colors.dart';

/// Red vignette + soft border, strongest at screen edges (blocked-arrow impact).
class DamageEdgeFlashPainter extends CustomPainter {
  final double strength;

  const DamageEdgeFlashPainter({required this.strength});

  @override
  void paint(Canvas canvas, Size size) {
    if (strength <= 0) return;
    final rect = Offset.zero & size;

    final vignette = Paint()
      ..shader = RadialGradient(
        center: Alignment.center,
        radius: 1.05,
        colors: [
          Colors.transparent,
          Colors.transparent,
          AppColors.damageRedMid.withValues(alpha: 0.14 * strength),
          AppColors.damageRedDeep.withValues(alpha: 0.42 * strength),
        ],
        stops: const [0.0, 0.52, 0.8, 1.0],
      ).createShader(rect);
    canvas.drawRect(rect, vignette);

    final glow = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 14
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 12)
      ..color = AppColors.damageRedDeep.withValues(alpha: 0.28 * strength);
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect.deflate(10), const Radius.circular(6)),
      glow,
    );
  }

  @override
  bool shouldRepaint(covariant DamageEdgeFlashPainter oldDelegate) {
    return oldDelegate.strength != strength;
  }
}
