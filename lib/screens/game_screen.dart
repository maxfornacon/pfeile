import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../game/game_controller.dart';
import '../models/arrow.dart';

const double cellSize = 32.0;

/// Same corner rounding as [_ArrowsPainter] stroke — used for removal sampling.
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

/// [shift] matches removal / blocked-slide sampling (grid units along the spine).
bool _cellDotSuppressedByPathShift(
  int col,
  int row,
  List<Offset> cells,
  double shift,
) {
  for (int i = 0; i < cells.length; i++) {
    final c = cells[i];
    if (c.dx.round() == col && c.dy.round() == row) {
      return shift < i + 1;
    }
  }
  return false;
}

/// While an arrow slides off, keep dots hidden on cells its tail has not yet
/// passed.
bool _cellDotSuppressedByActiveRemoval(
  int col,
  int row,
  Map<int, _RemovalFlight> activeFlights,
  DateTime now,
) {
  for (final flight in activeFlights.values) {
    final shift = flight.distanceCells * flight.progress(now);
    if (_cellDotSuppressedByPathShift(col, row, flight.cells, shift)) {
      return true;
    }
  }
  return false;
}

/// Static occupancy hides dots, except cells vacated by a blocked arrow's tail
/// (still in [occupancy] but no longer covered by the sliding stroke).
bool _occupancySuppressesDot(
  int col,
  int row,
  Map<String, List<int>> occupancy,
  Map<int, _BlockedSlideFlight> blockedFlights,
  DateTime now,
) {
  final ids = occupancy['$col:$row'];
  if (ids == null || ids.isEmpty) return false;
  for (final id in ids) {
    final blocked = blockedFlights[id];
    if (blocked != null) {
      if (_cellDotSuppressedByPathShift(
            col,
            row,
            blocked.cells,
            blocked.shiftAt(now),
          )) {
        return true;
      }
    } else {
      return true;
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
  static const Duration _blockedForwardDuration = Duration(milliseconds: 320);
  static const Duration _blockedImpactPause = Duration(milliseconds: 50);
  static const Duration _blockedReturnDuration = Duration(milliseconds: 340);
  static const Duration _shakeDuration = Duration(milliseconds: 380);
  static const Duration _damageFlashDuration = Duration(milliseconds: 900);
  static const double _offBoardMarginCells = 1.0;

  late final Ticker _ticker;
  late final TransformationController _viewerController;
  final Map<int, _RemovalFlight> _activeFlights = <int, _RemovalFlight>{};
  final Map<int, _BlockedSlideFlight> _blockedFlights =
      <int, _BlockedSlideFlight>{};
  final Set<int> _knownRemoved = <int>{};
  final Set<int> _blockedImpactDone = <int>{};
  DateTime? _shakeStartedAt;
  DateTime? _damageFlashStartedAt;

  static const int _maxHelpLineUses = 3;
  int _helpLineUsesLeft = _maxHelpLineUses;
  bool _showHelpLines = false;

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
    final now = DateTime.now();

    if (_activeFlights.isNotEmpty) {
      final completed = <int>[];
      _activeFlights.forEach((index, flight) {
        if (flight.progress(now) >= 1.0) completed.add(index);
      });
      for (final index in completed) {
        _activeFlights.remove(index);
      }
    }

    if (_blockedFlights.isNotEmpty) {
      final blockedDone = <int>[];
      _blockedFlights.forEach((index, flight) {
        if (!_blockedImpactDone.contains(index) &&
            flight.forwardEnded(now)) {
          _blockedImpactDone.add(index);
          _shakeStartedAt = now;
          _damageFlashStartedAt = now;
          HapticFeedback.heavyImpact();
        }
        if (flight.isComplete(now)) blockedDone.add(index);
      });
      for (final index in blockedDone) {
        _blockedFlights.remove(index);
        _blockedImpactDone.remove(index);
      }
    }

    final shakeActive = _shakeOffset(now) != Offset.zero;
    final damageActive = _damageFlashStrength(now) > 0.001;
    final needsTicks = _activeFlights.isNotEmpty ||
        _blockedFlights.isNotEmpty ||
        shakeActive ||
        damageActive;
    if (!needsTicks) _ticker.stop();
    setState(() {});
  }

  void _syncRemovalFlights(GameController controller, List<Arrow> arrows) {
    final anyRemovedInState = arrows.any((a) => a.removed);
    if (!anyRemovedInState &&
        (_knownRemoved.isNotEmpty ||
            _activeFlights.isNotEmpty ||
            _blockedFlights.isNotEmpty)) {
      _knownRemoved.clear();
      _activeFlights.clear();
      _blockedFlights.clear();
      _blockedImpactDone.clear();
      _shakeStartedAt = null;
      _damageFlashStartedAt = null;
      if (_ticker.isActive) _ticker.stop();
    }

    if (arrows.length < _knownRemoved.length) {
      _knownRemoved.clear();
      _activeFlights.clear();
      _blockedFlights.clear();
      _blockedImpactDone.clear();
      _shakeStartedAt = null;
      _damageFlashStartedAt = null;
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

    final hasActive = _activeFlights.isNotEmpty || _blockedFlights.isNotEmpty;
    if (hasActive && !_ticker.isActive) _ticker.start();
  }

  double _maxShiftBeforeCollision(
    int index,
    List<Offset> cells,
    Offset unitDir,
    GameController controller,
  ) {
    final occupancy = controller.occupancyMap();
    const step = 0.05;
    var shift = 0.0;
    var lastGood = 0.0;
    final maxTravel =
        cells.length + GameController.rows + GameController.cols + 4.0;

    while (shift <= maxTravel) {
      final moved = _straighteningCells(cells, unitDir, shift);
      var collides = false;
      for (final p in moved) {
        final col = p.dx.round();
        final row = p.dy.round();
        final key = '$col:$row';
        final ids = occupancy[key];
        if (ids != null && ids.any((id) => id != index)) {
          collides = true;
          break;
        }
      }
      if (collides) break;
      lastGood = shift;
      shift += step;
    }
    return lastGood;
  }

  void _startBlockedSlide(int index, GameController controller) {
    if (_blockedFlights.containsKey(index)) return;
    final arrow = ref.read(gameProvider).arrows[index];
    if (arrow.removed) return;

    final cells = controller.cellsForArrow(arrow);
    if (cells.length < 2) return;

    final head = cells.last;
    final beforeHead = cells[cells.length - 2];
    final direction = head - beforeHead;
    final norm = direction.distance;
    if (norm <= 0) return;

    final unitDir = Offset(direction.dx / norm, direction.dy / norm);
    final maxShift = _maxShiftBeforeCollision(index, cells, unitDir, controller);

    _blockedFlights[index] = _BlockedSlideFlight(
      cells: cells,
      direction: unitDir,
      maxShiftCells: maxShift,
      startedAt: DateTime.now(),
      forwardDuration: _blockedForwardDuration,
      impactPause: _blockedImpactPause,
      returnDuration: _blockedReturnDuration,
    );
    if (!_ticker.isActive) _ticker.start();
    setState(() {});
  }

  Offset _shakeOffset(DateTime now) {
    final start = _shakeStartedAt;
    if (start == null) return Offset.zero;
    final elapsedMs = now.difference(start).inMilliseconds;
    if (elapsedMs < 0 || elapsedMs >= _shakeDuration.inMilliseconds) {
      return Offset.zero;
    }
    final t = elapsedMs / _shakeDuration.inMilliseconds;
    final damp = 1.0 - Curves.easeOut.transform(t);
    final w = 38.0;
    final secs = elapsedMs / 1000.0;
    return Offset(
      math.sin(secs * w) * 7 * damp,
      math.cos(secs * w * 1.17) * 6 * damp,
    );
  }

  /// 1 at impact, eases to 0 — drives the red edge damage vignette.
  double _damageFlashStrength(DateTime now) {
    final start = _damageFlashStartedAt;
    if (start == null) return 0;
    final elapsedMs = now.difference(start).inMilliseconds;
    if (elapsedMs < 0 || elapsedMs >= _damageFlashDuration.inMilliseconds) {
      return 0;
    }
    final t = elapsedMs / _damageFlashDuration.inMilliseconds;
    return 1.0 - Curves.easeOutCubic.transform(t);
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
    ref.listen(gameProvider.select((s) => s.levelId), (prev, next) {
      if (prev != null && prev != next) {
        setState(() {
          _helpLineUsesLeft = _maxHelpLineUses;
          _showHelpLines = false;
        });
      }
    });
    final controller = ref.read(gameProvider.notifier);
    _syncRemovalFlights(controller, state.arrows);

    final occupancy = controller.occupancyMap();
    final arrowCells = <int, List<Offset>>{};

    for (int i = 0; i < state.arrows.length; i++) {
      arrowCells[i] = controller.cellsForArrow(state.arrows[i]);
    }

    final boardWidth = GameController.cols * cellSize;
    final boardHeight = GameController.rows * cellSize;
    final statusText = controller.isWin
        ? 'Level Cleared'
        : 'Tap free arrow heads to clear';

    final damageStrength = _damageFlashStrength(DateTime.now());

    return Scaffold(
      backgroundColor: Colors.white,
      floatingActionButton: FloatingActionButton(
        tooltip: _showHelpLines
            ? 'Hide guide lines'
            : 'Show guide lines ($_helpLineUsesLeft/3)',
        onPressed: _showHelpLines
            ? () => setState(() => _showHelpLines = false)
            : _helpLineUsesLeft <= 0
                ? null
                : () => setState(() {
                      _helpLineUsesLeft -= 1;
                      _showHelpLines = true;
                    }),
        backgroundColor: Colors.white,
        foregroundColor: Colors.black54,
        elevation: 2,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.lightbulb_outline),
            Text(
              '$_helpLineUsesLeft/3',
              style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w600),
            ),
          ],
        ),
      ),
      body: Stack(
        children: [
          Column(
            children: [
              Expanded(
                child: Transform.translate(
                  offset: _shakeOffset(DateTime.now()),
                  child: ClipRect(
                    child: LayoutBuilder(
                      builder: (context, constraints) {
                        final vp = constraints.biggest;
                        final ox = (vp.width - boardWidth) / 2;
                        final oy = (vp.height - boardHeight) / 2;
                        final boardOrigin = Offset(ox, oy);
                        return InteractiveViewer(
                          transformationController: _viewerController,
                          constrained: true,
                          clipBehavior: Clip.none,
                          boundaryMargin: const EdgeInsets.all(400),
                          minScale: 0.5,
                          maxScale: 4.0,
                          panEnabled: true,
                          scaleEnabled: true,
                          child: SizedBox(
                            width: vp.width,
                            height: vp.height,
                            child: Stack(
                              clipBehavior: Clip.none,
                              children: [
                                Positioned(
                                  left: ox,
                                  top: oy,
                                  width: boardWidth,
                                  height: boardHeight,
                                  child: CustomPaint(
                                    painter: _GridPainter(
                                      rows: GameController.rows,
                                      cols: GameController.cols,
                                      cellSize: cellSize,
                                      occupancy: occupancy,
                                      activeFlights: _activeFlights,
                                      blockedFlights: _blockedFlights,
                                    ),
                                  ),
                                ),
                                if (_showHelpLines)
                                  Positioned.fill(
                                    child: IgnorePointer(
                                      child: CustomPaint(
                                        painter: _GuideLinesPainter(
                                          cellSize: cellSize,
                                          arrows: state.arrows,
                                          arrowCells: arrowCells,
                                          activeFlights: _activeFlights,
                                          blockedFlights: _blockedFlights,
                                          boardOrigin: boardOrigin,
                                        ),
                                      ),
                                    ),
                                  ),
                                Positioned(
                                  left: ox,
                                  top: oy,
                                  width: boardWidth,
                                  height: boardHeight,
                                  child: GestureDetector(
                                    behavior: HitTestBehavior.opaque,
                                    onTapUp: (details) {
                                      final boardLocal = details.localPosition;

                                      final col =
                                          (boardLocal.dx / cellSize).floor();
                                      final row =
                                          (boardLocal.dy / cellSize).floor();
                                      final tappedIndex = controller
                                          .topArrowIndexAtCell(col, row);
                                      if (tappedIndex == null) return;

                                      if (_showHelpLines) {
                                        setState(() => _showHelpLines = false);
                                      }

                                      if (controller.tapCell(col, row)) {
                                        HapticFeedback.mediumImpact();
                                        return;
                                      }
                                      _startBlockedSlide(
                                          tappedIndex, controller);
                                    },
                                    child: CustomPaint(
                                      painter: _ArrowsPainter(
                                        rows: GameController.rows,
                                        cols: GameController.cols,
                                        cellSize: cellSize,
                                        arrows: state.arrows,
                                        arrowCells: arrowCells,
                                        activeFlights: _activeFlights,
                                        blockedFlights: _blockedFlights,
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        );
                      },
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
          if (damageStrength > 0.001)
            Positioned.fill(
              child: IgnorePointer(
                child: CustomPaint(
                  painter: _DamageEdgeFlashPainter(strength: damageStrength),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Red vignette + soft border, strongest at screen edges (blocked-arrow impact).
class _DamageEdgeFlashPainter extends CustomPainter {
  final double strength;

  const _DamageEdgeFlashPainter({required this.strength});

  static const Color _redDeep = Color(0xFFB71C1C);
  static const Color _redMid = Color(0xFFE53935);

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
          _redMid.withValues(alpha: 0.14 * strength),
          _redDeep.withValues(alpha: 0.42 * strength),
        ],
        stops: const [0.0, 0.52, 0.8, 1.0],
      ).createShader(rect);
    canvas.drawRect(rect, vignette);

    final glow = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 14
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 12)
      ..color = _redDeep.withValues(alpha: 0.28 * strength);
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect.deflate(10), const Radius.circular(6)),
      glow,
    );
  }

  @override
  bool shouldRepaint(covariant _DamageEdgeFlashPainter oldDelegate) {
    return oldDelegate.strength != strength;
  }
}

/// White fill + corner dots beneath guide lines and arrow strokes.
class _GridPainter extends CustomPainter {
  final int rows;
  final int cols;
  final double cellSize;
  final Map<String, List<int>> occupancy;
  final Map<int, _RemovalFlight> activeFlights;
  final Map<int, _BlockedSlideFlight> blockedFlights;

  const _GridPainter({
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
        if (_occupancySuppressesDot(col, row, occupancy, blockedFlights, now)) {
          continue;
        }
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
  }

  @override
  bool shouldRepaint(covariant _GridPainter oldDelegate) {
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

class _ArrowsPainter extends CustomPainter {
  final int rows;
  final int cols;
  final double cellSize;
  final List<Arrow> arrows;
  final Map<int, List<Offset>> arrowCells;
  final Map<int, _RemovalFlight> activeFlights;
  final Map<int, _BlockedSlideFlight> blockedFlights;

  const _ArrowsPainter({
    required this.rows,
    required this.cols,
    required this.cellSize,
    required this.arrows,
    required this.arrowCells,
    required this.activeFlights,
    required this.blockedFlights,
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
      final pixelSamples = _removalPolylinePixelSamples(
        flight.cells,
        flight.direction,
        shiftCells,
      );
      _drawRemovalArrow(canvas: canvas, pixelSamples: pixelSamples, color: color);
    }

    for (final entry in blockedFlights.entries) {
      final index = entry.key;
      final flight = entry.value;
      final color = _palette[index % _palette.length];
      final shiftCells = flight.shiftAt(now);
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
  bool shouldRepaint(covariant _ArrowsPainter oldDelegate) {
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

/// Straight guide rays in viewport space so they can reach the visible area edges.
class _GuideLinesPainter extends CustomPainter {
  final double cellSize;
  final List<Arrow> arrows;
  final Map<int, List<Offset>> arrowCells;
  final Map<int, _RemovalFlight> activeFlights;
  final Map<int, _BlockedSlideFlight> blockedFlights;
  final Offset boardOrigin;

  const _GuideLinesPainter({
    required this.cellSize,
    required this.arrows,
    required this.arrowCells,
    required this.activeFlights,
    required this.blockedFlights,
    required this.boardOrigin,
  });

  static const Color _lineColor = Color(0xFFCFD8DC);

  Offset _cellCenter(double col, double row) {
    return Offset((col + 0.5) * cellSize, (row + 0.5) * cellSize);
  }

  @override
  void paint(Canvas canvas, Size size) {
    final now = DateTime.now();
    // Long enough to cross the whole viewport from any interior start; avoids
    // ray/rect edge cases. Parent ClipRect still bounds what is actually visible.
    final lineExtent = size.longestSide * 2.5;
    final helpPaint = Paint()
      ..color = _lineColor
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
        final samples = _removalPolylinePixelSamples(
          blocked.cells,
          blocked.direction,
          shift,
        );
        if (samples.isEmpty) continue;
        if (samples.length == 1) {
          unitDir = blocked.direction;
          startTipBoard =
              samples.first + unitDir * (cellSize * 0.33);
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
  bool shouldRepaint(covariant _GuideLinesPainter oldDelegate) {
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

class _BlockedSlideFlight {
  final List<Offset> cells;
  final Offset direction;
  final double maxShiftCells;
  final DateTime startedAt;
  final Duration forwardDuration;
  final Duration impactPause;
  final Duration returnDuration;

  const _BlockedSlideFlight({
    required this.cells,
    required this.direction,
    required this.maxShiftCells,
    required this.startedAt,
    required this.forwardDuration,
    required this.impactPause,
    required this.returnDuration,
  });

  DateTime get _forwardEnd => startedAt.add(forwardDuration);

  DateTime get _returnStart => _forwardEnd.add(impactPause);

  DateTime get _returnEnd => _returnStart.add(returnDuration);

  bool forwardEnded(DateTime now) => !now.isBefore(_forwardEnd);

  double shiftAt(DateTime now) {
    if (now.isBefore(_forwardEnd)) {
      final ms = now.difference(startedAt).inMilliseconds;
      final p = (ms / forwardDuration.inMilliseconds).clamp(0.0, 1.0);
      return maxShiftCells * Curves.easeInOut.transform(p);
    }
    if (now.isBefore(_returnStart)) {
      return maxShiftCells;
    }
    if (now.isBefore(_returnEnd)) {
      final ms = now.difference(_returnStart).inMilliseconds;
      final p = (ms / returnDuration.inMilliseconds).clamp(0.0, 1.0);
      return maxShiftCells * (1 - Curves.easeInOut.transform(p));
    }
    return 0;
  }

  bool isComplete(DateTime now) => !now.isBefore(_returnEnd);
}
