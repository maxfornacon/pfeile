import 'package:flutter/material.dart';

import '../../../models/arrow.dart';
import '../../../theme/app_colors.dart';
import '../../animations/arrow_flight.dart';
import '../arrow_geometry.dart';

class ArrowsPainter extends CustomPainter {
  final double cellSize;
  final List<Arrow> arrows;
  final Map<int, List<Offset>> arrowCells;
  final Map<int, RemovalFlight> activeFlights;
  final Map<int, BlockedSlideFlight> blockedFlights;

  const ArrowsPainter({
    required this.cellSize,
    required this.arrows,
    required this.arrowCells,
    required this.activeFlights,
    required this.blockedFlights,
  });

  List<Color> get _palette => AppColors.arrowPalette;

  @override
  void paint(Canvas canvas, Size size) {
    final now = DateTime.now();
    for (int index = 0; index < arrows.length; index++) {
      final arrow = arrows[index];
      if (arrow.removed) continue;
      if (blockedFlights.containsKey(index)) continue;

      final cells = arrowCells[index] ?? const <Offset>[];
      if (cells.isEmpty) continue;

      final color = _palette[index % _palette.length];
      _drawArrow(canvas: canvas, cells: cells, color: color);
    }

    for (final entry in activeFlights.entries) {
      final index = entry.key;
      final flight = entry.value;
      final color = _palette[index % _palette.length];
      final progress = flight.progress(now);
      final shiftCells = flight.distanceCells * progress;
      _drawRemovalArrow(
        canvas: canvas,
        cells: flight.cells,
        direction: flight.direction,
        shiftCells: shiftCells,
        color: color,
      );
    }

    for (final entry in blockedFlights.entries) {
      final index = entry.key;
      final flight = entry.value;
      final color = _palette[index % _palette.length];
      final shiftCells = flight.shiftAt(now);
      _drawRemovalArrow(
        canvas: canvas,
        cells: flight.cells,
        direction: flight.direction,
        shiftCells: shiftCells,
        color: color,
      );
    }
  }

  void _drawArrow({
    required Canvas canvas,
    required List<Offset> cells,
    required Color color,
  }) {
    if (cells.length == 1) {
      final singlePaint = Paint()..color = color;
      final center = _cellCenter(cells.first.dx, cells.first.dy);
      canvas.drawCircle(center, cellSize * 0.18, singlePaint);
      return;
    }

    final strokePaint = Paint()
      ..color = color
      ..strokeWidth = cellSize * 0.14
      ..style = PaintingStyle.stroke
      ..strokeJoin = StrokeJoin.round
      ..strokeCap = StrokeCap.round;

    final centers = cells.map((cell) => _cellCenter(cell.dx, cell.dy)).toList();
    final path = buildRoundedArrowPath(centers, cellSize * 0.26);
    canvas.drawPath(path, strokePaint);

    final head = centers.last;
    final beforeHead = centers[centers.length - 2];
    final direction = head - beforeHead;
    _drawArrowHead(
      canvas: canvas,
      tipCenter: head,
      direction: direction,
      color: color,
    );
  }

  void _drawRemovalArrow({
    required Canvas canvas,
    required List<Offset> cells,
    required Offset direction,
    required double shiftCells,
    required Color color,
  }) {
    if (cells.isEmpty) return;
    if (cells.length == 1) {
      final center = Offset(
        (cells.first.dx + 0.5) * cellSize,
        (cells.first.dy + 0.5) * cellSize,
      ) +
          Offset(
            direction.dx * shiftCells * cellSize,
            direction.dy * shiftCells * cellSize,
          );
      final singlePaint = Paint()..color = color;
      canvas.drawCircle(center, cellSize * 0.18, singlePaint);
      return;
    }

    final strokePaint = Paint()
      ..color = color
      ..strokeWidth = cellSize * 0.14
      ..style = PaintingStyle.stroke
      ..strokeJoin = StrokeJoin.round
      ..strokeCap = StrokeCap.round;

    final (bodyPath, tip, headDirection) = removalArrowStrokeGeometry(
      cells,
      direction,
      shiftCells,
      cellSize,
    );
    canvas.drawPath(bodyPath, strokePaint);

    _drawArrowHead(
      canvas: canvas,
      tipCenter: tip,
      direction: headDirection,
      color: color,
    );
  }

  Offset _cellCenter(double col, double row) {
    return Offset((col + 0.5) * cellSize, (row + 0.5) * cellSize);
  }

  void _drawArrowHead({
    required Canvas canvas,
    required Offset tipCenter,
    required Offset direction,
    required Color color,
  }) {
    final len = direction.distance;
    if (len == 0) return;
    final dir = Offset(direction.dx / len, direction.dy / len);
    final normal = Offset(-dir.dy, dir.dx);

    final tip =
        tipCenter + Offset(dir.dx * cellSize * 0.33, dir.dy * cellSize * 0.33);
    final baseCenter =
        tipCenter - Offset(dir.dx * cellSize * 0.02, dir.dy * cellSize * 0.02);
    final wing = cellSize * 0.17;

    final left = baseCenter + Offset(normal.dx * wing, normal.dy * wing);
    final right = baseCenter - Offset(normal.dx * wing, normal.dy * wing);

    final headPath = Path()
      ..moveTo(tip.dx, tip.dy)
      ..lineTo(left.dx, left.dy)
      ..lineTo(right.dx, right.dy)
      ..close();

    final headPaint = Paint()
      ..color = color
      ..style = PaintingStyle.fill;
    canvas.drawPath(headPath, headPaint);

    final headOutlinePaint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = cellSize * 0.08
      ..strokeJoin = StrokeJoin.round
      ..strokeCap = StrokeCap.round;
    canvas.drawPath(headPath, headOutlinePaint);
  }

  @override
  bool shouldRepaint(covariant ArrowsPainter oldDelegate) {
    if (activeFlights.isNotEmpty || oldDelegate.activeFlights.isNotEmpty) {
      return true;
    }
    if (blockedFlights.isNotEmpty || oldDelegate.blockedFlights.isNotEmpty) {
      return true;
    }
    return oldDelegate.arrows != arrows ||
        oldDelegate.arrowCells != arrowCells ||
        oldDelegate.activeFlights != activeFlights ||
        oldDelegate.blockedFlights != blockedFlights;
  }
}
