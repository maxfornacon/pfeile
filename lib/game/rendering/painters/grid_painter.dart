import 'package:flutter/material.dart';

import '../../animations/arrow_flight.dart';
import '../cell_dot_suppression.dart';

/// White fill + corner dots beneath guide lines and arrow strokes.
class GridPainter extends CustomPainter {
  final int rows;
  final int cols;
  final double cellSize;
  final Map<String, List<int>> occupancy;
  final Map<int, RemovalFlight> activeFlights;
  final Map<int, BlockedSlideFlight> blockedFlights;

  const GridPainter({
    required this.rows,
    required this.cols,
    required this.cellSize,
    required this.occupancy,
    required this.activeFlights,
    required this.blockedFlights,
  });

  Offset _cellCenter(double col, double row) {
    return Offset((col + 0.5) * cellSize, (row + 0.5) * cellSize);
  }

  @override
  void paint(Canvas canvas, Size size) {
    final now = DateTime.now();
    final boardRect = Rect.fromLTWH(0, 0, cols * cellSize, rows * cellSize);
    final bgPaint = Paint()..color = Colors.white;
    canvas.drawRect(boardRect, bgPaint);

    final dotPaint = Paint()
      ..color = Colors.black26
      ..style = PaintingStyle.fill;
    for (int row = 0; row < rows; row++) {
      for (int col = 0; col < cols; col++) {
        if (occupancySuppressesDot(col, row, occupancy, blockedFlights, now)) {
          continue;
        }
        if (cellDotSuppressedByActiveRemoval(col, row, activeFlights, now)) {
          continue;
        }
        canvas.drawCircle(
          _cellCenter(col.toDouble(), row.toDouble()),
          2.3,
          dotPaint,
        );
      }
    }
  }

  @override
  bool shouldRepaint(covariant GridPainter oldDelegate) {
    if (activeFlights.isNotEmpty || oldDelegate.activeFlights.isNotEmpty) {
      return true;
    }
    if (blockedFlights.isNotEmpty || oldDelegate.blockedFlights.isNotEmpty) {
      return true;
    }
    return oldDelegate.occupancy != occupancy ||
        oldDelegate.activeFlights != activeFlights ||
        oldDelegate.blockedFlights != blockedFlights;
  }
}
