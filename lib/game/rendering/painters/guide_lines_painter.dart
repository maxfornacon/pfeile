import 'package:flutter/material.dart';

import '../../../models/arrow.dart';
import '../../../theme/app_colors.dart';
import '../../animations/arrow_flight.dart';
import '../arrow_geometry.dart';

/// Straight guide rays in viewport space so they can reach the visible area edges.
class GuideLinesPainter extends CustomPainter {
  final double cellSize;
  final List<Arrow> arrows;
  final Map<int, List<Offset>> arrowCells;
  final Map<int, RemovalFlight> activeFlights;
  final Map<int, BlockedSlideFlight> blockedFlights;
  final Offset boardOrigin;

  const GuideLinesPainter({
    required this.cellSize,
    required this.arrows,
    required this.arrowCells,
    required this.activeFlights,
    required this.blockedFlights,
    required this.boardOrigin,
  });

  Offset _cellCenter(double col, double row) {
    return Offset((col + 0.5) * cellSize, (row + 0.5) * cellSize);
  }

  @override
  void paint(Canvas canvas, Size size) {
    final now = DateTime.now();
    final lineExtent = size.longestSide * 2.5;
    final helpPaint = Paint()
      ..color = AppColors.guideLine
      ..strokeWidth = cellSize * 0.08 + 1.0
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;

    for (int index = 0; index < arrows.length; index++) {
      final arrow = arrows[index];
      if (arrow.removed) continue;
      if (activeFlights.containsKey(index)) continue;

      final Offset? startTipBoard;
      final Offset unitDir;

      final blocked = blockedFlights[index];
      if (blocked != null) {
        final shift = blocked.shiftAt(now);
        final samples = removalPolylinePixelSamples(
          blocked.cells,
          blocked.direction,
          shift,
          cellSize,
        );
        if (samples.isEmpty) continue;
        if (samples.length == 1) {
          unitDir = blocked.direction;
          startTipBoard = samples.first + unitDir * (cellSize * 0.33);
        } else {
          unitDir = blocked.direction;
          startTipBoard = samples.last + unitDir * (cellSize * 0.33);
        }
      } else {
        final cells = arrowCells[index] ?? const <Offset>[];
        if (cells.isEmpty) continue;
        if (cells.length >= 2) {
          final centers = cells.map((c) => _cellCenter(c.dx, c.dy)).toList();
          final head = centers.last;
          final beforeHead = centers[centers.length - 2];
          final d = head - beforeHead;
          final len = d.distance;
          if (len < 1e-9) continue;
          unitDir = Offset(d.dx / len, d.dy / len);
          startTipBoard = head + unitDir * (cellSize * 0.33);
        } else if (arrow.points.length >= 2) {
          final a = arrow.points[arrow.points.length - 2];
          final b = arrow.points.last;
          final raw = b - a;
          final len = raw.distance;
          if (len < 1e-9) continue;
          unitDir = Offset(raw.dx / len, raw.dy / len);
          final head = _cellCenter(cells.first.dx, cells.first.dy);
          startTipBoard = head + unitDir * (cellSize * 0.33);
        } else {
          continue;
        }
      }

      final startInView = boardOrigin + startTipBoard;
      if (startInView.dx.isNaN || startInView.dy.isNaN) continue;
      canvas.drawLine(
        startInView,
        startInView + unitDir * lineExtent,
        helpPaint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant GuideLinesPainter oldDelegate) {
    if (activeFlights.isNotEmpty || oldDelegate.activeFlights.isNotEmpty) {
      return true;
    }
    if (blockedFlights.isNotEmpty || oldDelegate.blockedFlights.isNotEmpty) {
      return true;
    }
    return oldDelegate.arrows != arrows ||
        oldDelegate.arrowCells != arrowCells ||
        oldDelegate.activeFlights != activeFlights ||
        oldDelegate.blockedFlights != blockedFlights ||
        oldDelegate.boardOrigin != boardOrigin;
  }
}
