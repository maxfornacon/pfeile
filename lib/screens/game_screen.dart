import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/scheduler.dart';

import '../game/game_controller.dart';
import '../models/arrow.dart';

const double cellSize = 32.0;

/// Same corner rounding as [_BoardPainter] stroke — used for removal sampling.
Path _buildRoundedArrowPath(List<Offset> points, double cornerRadius) {
  final path = Path();
  if (points.isEmpty) return path;
  if (points.length == 1) {
    path.moveTo(points.first.dx, points.first.dy);
    return path;
  }

  path.moveTo(points.first.dx, points.first.dy);
  for (int i = 1; i < points.length - 1; i++) {
    final prev = points[i - 1];
    final curr = points[i];
    final next = points[i + 1];

    final inVec = curr - prev;
    final outVec = next - curr;
    final inLen = inVec.distance;
    final outLen = outVec.distance;

    if (inLen == 0 || outLen == 0) {
      path.lineTo(curr.dx, curr.dy);
      continue;
    }

    final radius = cornerRadius < (inLen / 2) ? cornerRadius : (inLen / 2);
    final clampedRadius = radius < (outLen / 2) ? radius : (outLen / 2);

    final inDir = Offset(inVec.dx / inLen, inVec.dy / inLen);
    final outDir = Offset(outVec.dx / outLen, outVec.dy / outLen);

    final cornerStart = Offset(
      curr.dx - (inDir.dx * clampedRadius),
      curr.dy - (inDir.dy * clampedRadius),
    );
    final cornerEnd = Offset(
      curr.dx + (outDir.dx * clampedRadius),
      curr.dy + (outDir.dy * clampedRadius),
    );

    path.lineTo(cornerStart.dx, cornerStart.dy);
    path.quadraticBezierTo(curr.dx, curr.dy, cornerEnd.dx, cornerEnd.dy);
  }

  path.lineTo(points.last.dx, points.last.dy);
  return path;
}

List<double> _vertexDistancesAlongRoundedPath(
  PathMetric metric,
  List<Offset> centers,
) {
  final n = centers.length;
  final result = List<double>.filled(n, 0);
  if (n == 0) return result;
  result[0] = 0;
  final len = metric.length;
  if (len <= 0) return result;

  const samples = 256;
  for (int i = 1; i < n; i++) {
    final target = centers[i];
    var bestD = 0.0;
    var bestDist = double.infinity;
    for (int s = 0; s <= samples; s++) {
      final d = len * s / samples;
      final pos = metric.getTangentForOffset(d)?.position;
      if (pos == null) continue;
      final dist = (pos - target).distance;
      if (dist < bestDist) {
        bestDist = dist;
        bestD = d;
      }
    }
    result[i] = bestD < result[i - 1] ? result[i - 1] : bestD;
  }
  return result;
}

Offset _pointOnExtendedRoundedPathPixel(
  List<Offset> cells,
  Offset direction,
  double cellSize,
  double position,
  PathMetric metric,
  List<double> vertexDistances,
) {
  if (cells.isEmpty) return Offset.zero;

  final centers = cells
      .map(
        (c) => Offset((c.dx + 0.5) * cellSize, (c.dy + 0.5) * cellSize),
      )
      .toList();

  if (cells.length == 1) {
    return centers.first +
        Offset(direction.dx * position * cellSize, direction.dy * position * cellSize);
  }

  final lastIndex = cells.length - 1;

  if (position <= 0) return centers.first;

  if (position <= lastIndex) {
    final lower = position.floor();
    final upper = (lower + 1).clamp(0, lastIndex);
    final t = position - lower;
    final d0 = vertexDistances[lower];
    final d1 = vertexDistances[upper];
    final dist = d0 + (d1 - d0) * t;
    final clamped = dist.clamp(0.0, metric.length);
    return metric.getTangentForOffset(clamped)!.position;
  }

  final extra = position - lastIndex;
  final endPos = metric.getTangentForOffset(metric.length)!.position;
  return endPos +
      Offset(direction.dx * extra * cellSize, direction.dy * extra * cellSize);
}

/// Grid coordinates along the same spine as the rounded on-screen stroke (for exit checks).
Offset _pointOnExtendedRoundedPathGrid(
  List<Offset> cells,
  Offset direction,
  double cellSize,
  double position,
  PathMetric metric,
  List<double> vertexDistances,
) {
  final p = _pointOnExtendedRoundedPathPixel(
    cells,
    direction,
    cellSize,
    position,
    metric,
    vertexDistances,
  );
  return Offset(p.dx / cellSize - 0.5, p.dy / cellSize - 0.5);
}

List<Offset> _straighteningCells(
  List<Offset> cells,
  Offset direction,
  double shift,
) {
  if (cells.isEmpty) return const <Offset>[];
  const cornerRadius = cellSize * 0.26;

  if (cells.length == 1) {
    return [
      cells.first +
          Offset(direction.dx * shift, direction.dy * shift),
    ];
  }

  final pixelCenters = cells
      .map(
        (c) => Offset((c.dx + 0.5) * cellSize, (c.dy + 0.5) * cellSize),
      )
      .toList();
  final path = _buildRoundedArrowPath(pixelCenters, cornerRadius);
  final metric = path.computeMetrics().first;
  final vertexDistances = _vertexDistancesAlongRoundedPath(metric, pixelCenters);

  return List<Offset>.generate(cells.length, (i) {
    return _pointOnExtendedRoundedPathGrid(
      cells,
      direction,
      cellSize,
      i + shift,
      metric,
      vertexDistances,
    );
  });
}

List<Offset> _removalPolylinePixelSamples(
  List<Offset> cells,
  Offset direction,
  double shift, {
  double spacing = 0.18,
}) {
  if (cells.isEmpty) return const <Offset>[];
  const cornerRadius = cellSize * 0.26;

  if (cells.length == 1) {
    final center = Offset(
      (cells.first.dx + 0.5) * cellSize,
      (cells.first.dy + 0.5) * cellSize,
    );
    return <Offset>[
      center +
          Offset(direction.dx * shift * cellSize, direction.dy * shift * cellSize),
    ];
  }

  final pixelCenters = cells
      .map(
        (c) => Offset((c.dx + 0.5) * cellSize, (c.dy + 0.5) * cellSize),
      )
      .toList();
  final path = _buildRoundedArrowPath(pixelCenters, cornerRadius);
  final metric = path.computeMetrics().first;
  final vertexDistances = _vertexDistancesAlongRoundedPath(metric, pixelCenters);

  final bodyLength = (cells.length - 1).toDouble();
  final segments = (bodyLength / spacing).ceil();
  final sampleCount = segments < 1 ? 2 : segments + 1;
  final points = <Offset>[];
  for (int i = 0; i < sampleCount; i++) {
    final t = sampleCount > 1 ? i / (sampleCount - 1) : 0.0;
    final pos = shift + (bodyLength * t);
    points.add(
      _pointOnExtendedRoundedPathPixel(
        cells,
        direction,
        cellSize,
        pos,
        metric,
        vertexDistances,
      ),
    );
  }
  return points;
}

/// While an arrow slides off, keep dots hidden on cells its tail has not yet
/// passed. [shift] matches removal sampling (grid units along the spine).
bool _cellDotSuppressedByActiveRemoval(
  int col,
  int row,
  Map<int, _RemovalFlight> activeFlights,
  DateTime now,
) {
  for (final flight in activeFlights.values) {
    final shift = flight.distanceCells * flight.progress(now);
    final cells = flight.cells;
    for (int i = 0; i < cells.length; i++) {
      final c = cells[i];
      if (c.dx.round() == col && c.dy.round() == row) {
        if (shift < i + 1) {
          return true;
        }
        break;
      }
    }
  }
  return false;
}

class GameScreen extends ConsumerStatefulWidget {
  const GameScreen({super.key});

  @override
  ConsumerState<GameScreen> createState() => _GameScreenState();
}

class _GameScreenState extends ConsumerState<GameScreen>
    with SingleTickerProviderStateMixin {
  static const Duration _removalDuration = Duration(milliseconds: 420);
  static const double _offBoardMarginCells = 1.0;

  late final Ticker _ticker;
  late final TransformationController _viewerController;
  final Map<int, _RemovalFlight> _activeFlights = <int, _RemovalFlight>{};
  final Set<int> _knownRemoved = <int>{};

  @override
  void initState() {
    super.initState();
    _ticker = createTicker((_) => _tickFlights());
    _viewerController = TransformationController();
  }

  @override
  void dispose() {
    _ticker.dispose();
    _viewerController.dispose();
    super.dispose();
  }

  void _tickFlights() {
    if (_activeFlights.isEmpty) {
      _ticker.stop();
      return;
    }

    final now = DateTime.now();
    final completed = <int>[];
    _activeFlights.forEach((index, flight) {
      if (flight.progress(now) >= 1.0) completed.add(index);
    });
    for (final index in completed) {
      _activeFlights.remove(index);
    }

    if (_activeFlights.isEmpty) _ticker.stop();
    setState(() {});
  }

  void _syncRemovalFlights(GameController controller, List<Arrow> arrows) {
    final anyRemovedInState = arrows.any((a) => a.removed);
    if (!anyRemovedInState &&
        (_knownRemoved.isNotEmpty || _activeFlights.isNotEmpty)) {
      _knownRemoved.clear();
      _activeFlights.clear();
      if (_ticker.isActive) _ticker.stop();
    }

    if (arrows.length < _knownRemoved.length) {
      _knownRemoved.clear();
      _activeFlights.clear();
    }

    for (int i = 0; i < arrows.length; i++) {
      final arrow = arrows[i];
      if (!arrow.removed) continue;
      if (_knownRemoved.contains(i)) continue;

      final cells = controller.cellsForArrow(arrow);
      if (cells.length >= 2) {
        final head = cells.last;
        final beforeHead = cells[cells.length - 2];
        final direction = head - beforeHead;
        final norm = direction.distance;
        if (norm > 0) {
          final unitDir = Offset(direction.dx / norm, direction.dy / norm);
          final distanceCells = _distanceToFullyExit(cells, unitDir);
          _activeFlights[i] = _RemovalFlight(
            cells: cells,
            direction: unitDir,
            distanceCells: distanceCells,
            startedAt: DateTime.now(),
            duration: _removalDuration,
          );
        }
      }
      _knownRemoved.add(i);
    }

    final hasActive = _activeFlights.isNotEmpty;
    if (hasActive && !_ticker.isActive) _ticker.start();
    if (!hasActive && _ticker.isActive) _ticker.stop();
  }

  double _distanceToFullyExit(List<Offset> cells, Offset direction) {
    final maxTravel =
        cells.length + GameController.rows + GameController.cols + 4.0;
    const step = 0.1;
    var travel = 0.0;

    while (travel <= maxTravel) {
      final moved = _straighteningCells(cells, direction, travel);
      final allOutside = moved.every((point) {
        return point.dx < -_offBoardMarginCells ||
            point.dy < -_offBoardMarginCells ||
            point.dx > (GameController.cols - 1 + _offBoardMarginCells) ||
            point.dy > (GameController.rows - 1 + _offBoardMarginCells);
      });

      if (allOutside) {
        return travel;
      }
      travel += step;
    }

    return maxTravel;
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(gameProvider);
    final controller = ref.read(gameProvider.notifier);
    _syncRemovalFlights(controller, state.arrows);

    final occupancy = controller.occupancyMap();
    final occupiedKeys = occupancy.keys.toSet();
    final arrowCells = <int, List<Offset>>{};

    for (int i = 0; i < state.arrows.length; i++) {
      arrowCells[i] = controller.cellsForArrow(state.arrows[i]);
    }

    final boardWidth = GameController.cols * cellSize;
    final boardHeight = GameController.rows * cellSize;
    final statusText = controller.isWin
        ? 'Level Cleared'
        : 'Tap free arrow heads to clear';

    return Scaffold(
      appBar: AppBar(title: const Text('Pfeile')),
      body: Column(
        children: [
          Expanded(
            child: ClipRect(
              child: InteractiveViewer(
                transformationController: _viewerController,
                constrained: false,
                boundaryMargin: const EdgeInsets.all(400),
                minScale: 0.5,
                maxScale: 4.0,
                panEnabled: true,
                scaleEnabled: true,
                child: GestureDetector(
                  onTapUp: (details) {
                    final boardLocal = details.localPosition;

                    if (boardLocal.dx < 0 ||
                        boardLocal.dy < 0 ||
                        boardLocal.dx >= boardWidth ||
                        boardLocal.dy >= boardHeight) {
                      return;
                    }

                    final col = (boardLocal.dx / cellSize).floor();
                    final row = (boardLocal.dy / cellSize).floor();
                    controller.tapCell(col, row);
                  },
                  child: SizedBox(
                    width: boardWidth,
                    height: boardHeight,
                    child: CustomPaint(
                      painter: _BoardPainter(
                        rows: GameController.rows,
                        cols: GameController.cols,
                        cellSize: cellSize,
                        arrows: state.arrows,
                        arrowCells: arrowCells,
                        occupiedKeys: occupiedKeys,
                        activeFlights: _activeFlights,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 12),
          Text(statusText, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          FilledButton(
            onPressed: controller.newGame,
            child: const Text('New Game'),
          ),
          const SizedBox(height: 12),
        ],
      ),
    );
  }
}

class _BoardPainter extends CustomPainter {
  final int rows;
  final int cols;
  final double cellSize;
  final List<Arrow> arrows;
  final Map<int, List<Offset>> arrowCells;
  final Set<String> occupiedKeys;
  final Map<int, _RemovalFlight> activeFlights;

  const _BoardPainter({
    required this.rows,
    required this.cols,
    required this.cellSize,
    required this.arrows,
    required this.arrowCells,
    required this.occupiedKeys,
    required this.activeFlights,
  });

  static const List<Color> _palette = <Color>[
    Colors.blue,
    Colors.teal,
    Colors.deepOrange,
    Colors.purple,
    Colors.brown,
    Colors.indigo,
  ];

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
        if (occupiedKeys.contains('$col:$row')) continue;
        if (_cellDotSuppressedByActiveRemoval(col, row, activeFlights, now)) {
          continue;
        }
        canvas.drawCircle(
          _cellCenter(col.toDouble(), row.toDouble()),
          2.3,
          dotPaint,
        );
      }
    }

    for (int index = 0; index < arrows.length; index++) {
      final arrow = arrows[index];
      if (arrow.removed) continue;

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
      final pixelSamples = _removalPolylinePixelSamples(
        flight.cells,
        flight.direction,
        shiftCells,
      );
      _drawRemovalArrow(canvas: canvas, pixelSamples: pixelSamples, color: color);
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
    final path = _buildRoundedArrowPath(centers, cellSize * 0.26);
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
    required List<Offset> pixelSamples,
    required Color color,
  }) {
    if (pixelSamples.isEmpty) return;
    if (pixelSamples.length == 1) {
      final singlePaint = Paint()..color = color;
      canvas.drawCircle(pixelSamples.first, cellSize * 0.18, singlePaint);
      return;
    }

    final strokePaint = Paint()
      ..color = color
      ..strokeWidth = cellSize * 0.14
      ..style = PaintingStyle.stroke
      ..strokeJoin = StrokeJoin.round
      ..strokeCap = StrokeCap.round;

    final path = Path()..moveTo(pixelSamples.first.dx, pixelSamples.first.dy);
    for (int i = 1; i < pixelSamples.length; i++) {
      path.lineTo(pixelSamples[i].dx, pixelSamples[i].dy);
    }
    canvas.drawPath(path, strokePaint);

    final head = pixelSamples.last;
    final beforeHead = pixelSamples[pixelSamples.length - 2];
    final direction = head - beforeHead;
    _drawArrowHead(
      canvas: canvas,
      tipCenter: head,
      direction: direction,
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
  bool shouldRepaint(covariant _BoardPainter oldDelegate) {
    if (activeFlights.isNotEmpty || oldDelegate.activeFlights.isNotEmpty) {
      return true;
    }
    return oldDelegate.arrows != arrows ||
        oldDelegate.occupiedKeys != occupiedKeys ||
        oldDelegate.arrowCells != arrowCells ||
        oldDelegate.activeFlights != activeFlights;
  }
}

class _RemovalFlight {
  final List<Offset> cells;
  final Offset direction;
  final double distanceCells;
  final DateTime startedAt;
  final Duration duration;

  const _RemovalFlight({
    required this.cells,
    required this.direction,
    required this.distanceCells,
    required this.startedAt,
    required this.duration,
  });

  double progress(DateTime now) {
    final elapsedMs = now.difference(startedAt).inMilliseconds;
    if (elapsedMs <= 0) return 0;
    final p = elapsedMs / duration.inMilliseconds;
    if (p >= 1) return 1;
    return Curves.easeIn.transform(p);
  }
}
