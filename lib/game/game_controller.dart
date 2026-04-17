import 'dart:math';
import 'dart:ui';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/arrow.dart';
import 'game_state.dart';

final gameProvider = NotifierProvider<GameController, GameState>(
  GameController.new,
);

/// Controls the game state and the lifecycle of a level.
///
/// Generation is delegated to [_BoardGenerator], which produces a board that
/// is solvable by construction (see the class docs for the algorithm).
class GameController extends Notifier<GameState> {
  static const int rows = 50;
  static const int cols = 50;

  // Generation parameters. Adjusting these is safe: the generator works for
  // arbitrarily large boards in linear time.
  static const int _minArrowLen = 3;
  static const int _maxArrowLen = 3;
  static const int _maxBendsPerArrow = 5;
  static const double _bendProbability = 0.22;

  final Random _random = Random();

  @override
  GameState build() {
    return GameState(arrows: _createLevel());
  }

  // ---------------------------------------------------------------------------
  // Level creation
  // ---------------------------------------------------------------------------
  List<Arrow> _createLevel() {
    final generator = _BoardGenerator(
      rows: rows,
      cols: cols,
      minLen: _minArrowLen,
      maxLen: _maxArrowLen,
      maxBends: _maxBendsPerArrow,
      bendProbability: _bendProbability,
      random: _random,
    );
    final paths = generator.generate();
    return [
      for (final path in paths)
        Arrow(points: _compressSegmentToPolyline(path)),
    ];
  }

  // ---------------------------------------------------------------------------
  // Tap handling
  // ---------------------------------------------------------------------------
  void tapCell(int col, int row) {
    final index = topArrowIndexAtCell(col, row);
    if (index == null) return;
    tapArrow(index);
  }

  void tapArrow(int index) {
    final arrows = [...state.arrows];
    final arrow = arrows[index];
    if (arrow.removed) return;
    if (!isArrowTappable(index)) return;
    arrows[index] = arrow.copyWith(removed: true);
    state = state.copyWith(arrows: arrows);
  }

  void newGame() {
    state = GameState(arrows: _createLevel());
  }

  // ---------------------------------------------------------------------------
  // Rules & derived state
  // ---------------------------------------------------------------------------
  bool isArrowTappable(int index) {
    final arrow = state.arrows[index];
    if (arrow.removed) return false;

    final cells = cellsForArrow(arrow);
    if (cells.length < 2) return true;

    final head = cells.last;
    final beforeHead = cells[cells.length - 2];
    final direction = head - beforeHead;

    final occupancy = occupancyMap();
    final stepX = direction.dx.toInt();
    final stepY = direction.dy.toInt();
    var x = head.dx.toInt() + stepX;
    var y = head.dy.toInt() + stepY;

    while (x >= 0 && y >= 0 && x < cols && y < rows) {
      final key = _cellKey(x, y);
      final occupiedBy = occupancy[key] ?? const <int>[];
      if (occupiedBy.any((other) => other != index)) {
        return false;
      }
      x += stepX;
      y += stepY;
    }
    return true;
  }

  Map<String, List<int>> occupancyMap() {
    final map = <String, List<int>>{};
    for (int i = 0; i < state.arrows.length; i++) {
      final arrow = state.arrows[i];
      if (arrow.removed) continue;
      for (final cell in cellsForArrow(arrow)) {
        final key = _cellKey(cell.dx.toInt(), cell.dy.toInt());
        map.putIfAbsent(key, () => <int>[]).add(i);
      }
    }
    return map;
  }

  int? topArrowIndexAtCell(int col, int row) {
    final indexes = occupancyMap()[_cellKey(col, row)];
    if (indexes == null || indexes.isEmpty) return null;
    return indexes.last;
  }

  List<Offset> cellsForArrow(Arrow arrow) {
    final cells = <Offset>[];
    if (arrow.points.isEmpty) return cells;

    if (arrow.points.length == 1) {
      return [
        Offset(
          arrow.points.first.dx.roundToDouble(),
          arrow.points.first.dy.roundToDouble(),
        ),
      ];
    }

    for (int i = 0; i < arrow.points.length - 1; i++) {
      final from = arrow.points[i];
      final to = arrow.points[i + 1];

      final startX = from.dx.round();
      final startY = from.dy.round();
      final endX = to.dx.round();
      final endY = to.dy.round();

      final deltaX = endX - startX;
      final deltaY = endY - startY;
      final stepX = deltaX == 0 ? 0 : deltaX ~/ deltaX.abs();
      final stepY = deltaY == 0 ? 0 : deltaY ~/ deltaY.abs();
      final steps = deltaX.abs() > deltaY.abs() ? deltaX.abs() : deltaY.abs();

      for (int step = 0; step <= steps; step++) {
        if (i > 0 && step == 0) continue;
        final x = startX + (stepX * step);
        final y = startY + (stepY * step);
        cells.add(Offset(x.toDouble(), y.toDouble()));
      }
    }
    return cells;
  }

  bool get isWin => state.arrows.every((a) => a.removed);

  // ---------------------------------------------------------------------------
  // Internals
  // ---------------------------------------------------------------------------
  String _cellKey(int col, int row) => '$col:$row';

  /// Reduces a full cell path to its polyline corners (start, bends, end).
  List<Offset> _compressSegmentToPolyline(List<Offset> segment) {
    if (segment.length <= 2) return [...segment];

    final points = <Offset>[segment.first];
    Offset lastDir = segment[1] - segment[0];

    for (int i = 1; i < segment.length - 1; i++) {
      final nextDir = segment[i + 1] - segment[i];
      if (nextDir != lastDir) {
        points.add(segment[i]);
      }
      lastDir = nextDir;
    }

    points.add(segment.last);
    return points;
  }
}

// =============================================================================
// Board generator
// =============================================================================

/// Generates a solvable arrow board using **reverse construction**.
///
/// An arrow is tappable in the solve iff no other still-present arrow occupies
/// a cell in its head's forward ray to the board edge. If we build the board
/// in the *opposite* order of the solve (last-tapped first), each new arrow
/// only needs its head-forward ray to be clear of the *already placed*
/// arrows — those are exactly the ones that will still exist at the moment
/// this arrow is removed in the solve. So the board is solvable by
/// construction; no backtracking search or post-hoc check is needed.
///
/// The "no two arrows facing in opposing directions" rule is enforced
/// implicitly: two arrows pointing *toward* each other would each have the
/// other's body in its head-forward ray, and reverse construction rejects
/// that on placement. Two arrows pointing *away* from each other in the same
/// row/column are harmless and we deliberately allow them — forbidding them
/// would strictly reduce coverage for no gameplay benefit.
///
/// Generation runs three stages:
///   1. Primary fill — long, varied arrows (random walks with up to
///      [maxBends] turns, tried in both orientations).
///   2. Cleanup fill — tiny (length 2–3) arrows into small pockets, seeded
///      from the most-constrained free cells first.
///   3. Endpoint absorption — swallow remaining free cells into a
///      neighboring arrow by prepending at the tail or appending at the
///      head. Head-extension re-validates the new ray against earlier
///      arrows.
///
/// Any cells that none of the stages can absorb are left empty; the painter
/// renders them as the usual faint background dots.
///
/// Complexity: each arrow does O(maxLen + rows + cols) work, so the whole
/// generator is O(cells) — suitable for very large boards.
class _BoardGenerator {
  _BoardGenerator({
    required this.rows,
    required this.cols,
    required this.minLen,
    required this.maxLen,
    required this.maxBends,
    required this.bendProbability,
    required this.random,
  });

  final int rows;
  final int cols;
  final int minLen;
  final int maxLen;
  final int maxBends;
  final double bendProbability;
  final Random random;

  static const List<Offset> _directions = <Offset>[
    Offset(1, 0),
    Offset(-1, 0),
    Offset(0, 1),
    Offset(0, -1),
  ];

  // Cells that are still unoccupied by any arrow.
  final Set<int> _free = <int>{};
  // Cells belonging to any already-placed arrow.
  final Set<int> _placed = <int>{};
  // For each placed cell, the index (into [_arrows]) of the arrow owning it.
  // Used to check ray clearance against arrows placed earlier than a given
  // index without rescanning every body.
  final Map<int, int> _placedBy = <int, int>{};
  // Committed arrows, each as a full cell path from tail to head.
  final List<List<Offset>> _arrows = <List<Offset>>[];
  // The head-forward ray (set of cell keys from the cell after the head all
  // the way to the board edge) for each committed arrow, parallel to
  // [_arrows]. Precomputed on commit and refreshed when the head changes.
  final List<Set<int>> _arrowRays = <Set<int>>[];

  List<List<Offset>> generate() {
    _free.clear();
    _placed.clear();
    _placedBy.clear();
    _arrows.clear();
    _arrowRays.clear();

    for (int row = 0; row < rows; row++) {
      for (int col = 0; col < cols; col++) {
        _free.add(_keyFor(col, row));
      }
    }

    // Primary pass: long, varied arrows, random order.
    _fillPass(
      minLen: minLen,
      maxLen: maxLen,
      walkAttemptsPerStart: 6,
      preferConstrainedStarts: false,
    );

    // Cleanup pass: tiny arrows into the remaining pockets. Seeding from the
    // most-constrained free cells first gives the best chance of not
    // stranding their neighbors.
    if (_free.isNotEmpty) {
      _fillPass(
        minLen: 2,
        maxLen: 3,
        walkAttemptsPerStart: 4,
        preferConstrainedStarts: true,
      );
    }

    // Endpoint absorption: absorb stragglers into neighboring arrows, either
    // at the tail (cheap) or at the head (re-validates the new ray).
    if (_free.isNotEmpty) {
      _extensionPass();
    }

    return _arrows;
  }

  /// Repeatedly sweeps through free cells, trying to grow an arrow from each.
  /// Stops when a full sweep places nothing new. Bounded to a handful of
  /// sweeps to keep generation fast even on huge boards.
  void _fillPass({
    required int minLen,
    required int maxLen,
    required int walkAttemptsPerStart,
    required bool preferConstrainedStarts,
  }) {
    const maxSweeps = 4;
    for (int sweep = 0; sweep < maxSweeps; sweep++) {
      if (_free.isEmpty) return;
      final startKeys = _orderedStartKeys(preferConstrainedStarts);
      var progressed = false;
      for (final startKey in startKeys) {
        if (!_free.contains(startKey)) continue;
        final arrow = _tryBuildArrow(
          startKey: startKey,
          minLen: minLen,
          maxLen: maxLen,
          attempts: walkAttemptsPerStart,
        );
        if (arrow != null) {
          _commit(arrow);
          progressed = true;
        }
      }
      if (!progressed) return;
    }
  }

  /// Returns free cell keys in the order the sweep should try them. When
  /// [preferConstrained] is true, cells with fewer free neighbors come first
  /// (Warnsdorff-like heuristic) with random tiebreak.
  List<int> _orderedStartKeys(bool preferConstrained) {
    final keys = _free.toList();
    if (!preferConstrained) {
      keys.shuffle(random);
      return keys;
    }
    keys.shuffle(random);
    keys.sort((a, b) => _freeNeighborCount(a) - _freeNeighborCount(b));
    return keys;
  }

  int _freeNeighborCount(int key) {
    final col = key % cols;
    final row = key ~/ cols;
    var count = 0;
    for (final dir in _directions) {
      final nc = col + dir.dx.toInt();
      final nr = row + dir.dy.toInt();
      if (nc < 0 || nr < 0 || nc >= cols || nr >= rows) continue;
      if (_free.contains(_keyFor(nc, nr))) count++;
    }
    return count;
  }

  /// Tries to produce a valid arrow starting at [startKey]. Returns null if
  /// every attempted random walk (and both orientations of each) fails the
  /// placement rules.
  List<Offset>? _tryBuildArrow({
    required int startKey,
    required int minLen,
    required int maxLen,
    required int attempts,
  }) {
    final start = Offset(
      (startKey % cols).toDouble(),
      (startKey ~/ cols).toDouble(),
    );
    for (int attempt = 0; attempt < attempts; attempt++) {
      final targetLen = minLen + random.nextInt(maxLen - minLen + 1);
      final walk = _randomWalk(start: start, targetLen: targetLen);
      if (walk.length < minLen) continue;

      final orientations = <List<Offset>>[
        walk,
        walk.reversed.toList(),
      ]..shuffle(random);
      for (final oriented in orientations) {
        if (_validate(oriented)) return oriented;
      }
    }
    return null;
  }

  /// Grows a random walk over free cells. Prefers to keep direction; turns
  /// with probability [bendProbability], up to [maxBends] turns. Never
  /// revisits a cell and never reverses direction.
  List<Offset> _randomWalk({
    required Offset start,
    required int targetLen,
  }) {
    final path = <Offset>[start];
    final used = <int>{_keyFor(start.dx.toInt(), start.dy.toInt())};
    Offset? lastDir;
    int bends = 0;

    while (path.length < targetLen) {
      final current = path.last;
      final options = <_WalkOption>[];

      for (final dir in _directions) {
        if (lastDir != null && dir == -lastDir) continue;
        final next = current + dir;
        if (!_isInside(next)) continue;
        final nextKey = _keyFor(next.dx.toInt(), next.dy.toInt());
        if (!_free.contains(nextKey) || used.contains(nextKey)) continue;

        final double weight;
        if (lastDir == null) {
          weight = 1.0;
        } else if (dir == lastDir) {
          weight = 1.0 - bendProbability;
        } else {
          if (bends >= maxBends) continue;
          weight = bendProbability / 2.0;
        }
        if (weight <= 0) continue;
        options.add(_WalkOption(cell: next, dir: dir, weight: weight));
      }

      if (options.isEmpty) break;
      final chosen = _weightedPick(options);
      if (lastDir != null && chosen.dir != lastDir) bends++;
      path.add(chosen.cell);
      used.add(_keyFor(chosen.cell.dx.toInt(), chosen.cell.dy.toInt()));
      lastDir = chosen.dir;
    }
    return path;
  }

  _WalkOption _weightedPick(List<_WalkOption> options) {
    double total = 0;
    for (final option in options) {
      total += option.weight;
    }
    var pick = random.nextDouble() * total;
    for (final option in options) {
      pick -= option.weight;
      if (pick <= 0) return option;
    }
    return options.last;
  }

  /// Placement rule check for a fully oriented arrow path (tail → head).
  ///
  /// Walks the head-forward ray to the board edge: it must not cross any of
  /// this arrow's own cells (self-bite) nor any previously placed cell
  /// (solvability). Two arrows facing *toward* each other are automatically
  /// rejected by this check — each sees the other in its ray. Arrows facing
  /// *away* in the same row/column are allowed on purpose.
  bool _validate(List<Offset> path) {
    if (path.length < 2) return true;

    final head = path.last;
    final beforeHead = path[path.length - 2];
    final dx = head.dx.toInt() - beforeHead.dx.toInt();
    final dy = head.dy.toInt() - beforeHead.dy.toInt();

    final pathKeys = <int>{
      for (final cell in path) _keyFor(cell.dx.toInt(), cell.dy.toInt()),
    };
    var x = head.dx.toInt() + dx;
    var y = head.dy.toInt() + dy;
    while (x >= 0 && y >= 0 && x < cols && y < rows) {
      final key = _keyFor(x, y);
      if (pathKeys.contains(key)) return false;
      if (_placed.contains(key)) return false;
      x += dx;
      y += dy;
    }
    return true;
  }

  void _commit(List<Offset> path) {
    final index = _arrows.length;
    _arrows.add(path);
    _arrowRays.add(_computeHeadRay(path));
    for (final cell in path) {
      final key = _keyFor(cell.dx.toInt(), cell.dy.toInt());
      _free.remove(key);
      _placed.add(key);
      _placedBy[key] = index;
    }
  }

  /// Returns the set of cell keys strictly in front of the head, out to the
  /// board edge, in the head's direction. Empty for length-1 paths.
  Set<int> _computeHeadRay(List<Offset> path) {
    final ray = <int>{};
    if (path.length < 2) return ray;
    final head = path.last;
    final beforeHead = path[path.length - 2];
    final dx = head.dx.toInt() - beforeHead.dx.toInt();
    final dy = head.dy.toInt() - beforeHead.dy.toInt();
    var x = head.dx.toInt() + dx;
    var y = head.dy.toInt() + dy;
    while (x >= 0 && y >= 0 && x < cols && y < rows) {
      ray.add(_keyFor(x, y));
      x += dx;
      y += dy;
    }
    return ray;
  }

  /// Endpoint-absorption mop-up: absorb remaining free cells into neighboring
  /// arrows at either end.
  ///
  /// Tail extension keeps the head and ray fixed; head extension rebuilds the
  /// ray and re-validates it. Both are subject to the same invariant for
  /// other arrows: the new cell cannot land in the head-forward ray of any
  /// arrow placed *after* this one, since those are still present when this
  /// arrow is tapped in the solve.
  void _extensionPass() {
    if (_free.isEmpty) return;
    var progressed = true;
    while (progressed && _free.isNotEmpty) {
      progressed = false;
      final freeKeys = _free.toList()..shuffle(random);
      for (final cellKey in freeKeys) {
        if (!_free.contains(cellKey)) continue;
        if (_tryAbsorbIntoNeighbor(cellKey)) progressed = true;
      }
    }
  }

  bool _tryAbsorbIntoNeighbor(int cellKey) {
    final cell = Offset(
      (cellKey % cols).toDouble(),
      (cellKey ~/ cols).toDouble(),
    );

    final order = List<int>.generate(_arrows.length, (i) => i)
      ..shuffle(random);

    for (final i in order) {
      final arrow = _arrows[i];

      // Tail extension: prepend when the cell touches the tail.
      if (_isOrthogonallyAdjacent(arrow.first, cell) &&
          _tryTailExtend(i, cell, cellKey)) {
        return true;
      }

      // Head extension: append when the cell touches the head. For length-1
      // arrows `first == last`, so this branch gives the opposite-orientation
      // alternative to the tail branch above.
      if (_isOrthogonallyAdjacent(arrow.last, cell) &&
          _tryHeadExtend(i, cell, cellKey)) {
        return true;
      }
    }
    return false;
  }

  bool _tryTailExtend(int i, Offset cell, int cellKey) {
    // Self-bite: the added cell can't lie in this arrow's own forward ray.
    if (_arrowRays[i].contains(cellKey)) return false;
    // Can't block a later-placed arrow's forward ray.
    if (_isBlockedByLaterRay(i, cellKey)) return false;

    _arrows[i] = [cell, ..._arrows[i]];
    _free.remove(cellKey);
    _placed.add(cellKey);
    _placedBy[cellKey] = i;
    // Head and direction unchanged → _arrowRays[i] stays valid.
    return true;
  }

  bool _tryHeadExtend(int i, Offset cell, int cellKey) {
    // Can't block a later-placed arrow's forward ray.
    if (_isBlockedByLaterRay(i, cellKey)) return false;

    final arrow = _arrows[i];
    final oldHead = arrow.last;
    final newDx = cell.dx.toInt() - oldHead.dx.toInt();
    final newDy = cell.dy.toInt() - oldHead.dy.toInt();

    // Build the set of cells belonging to the *extended* arrow so we can
    // detect self-bite into the body (including back into the old head).
    final bodyKeys = <int>{cellKey};
    for (final c in arrow) {
      bodyKeys.add(_keyFor(c.dx.toInt(), c.dy.toInt()));
    }

    // Walk the new head-forward ray and check:
    //   - no self-bite (ray doesn't cross any of our own cells)
    //   - no block by an arrow placed *before* this one (those are still
    //     present when this arrow is tapped in the solve)
    final newRay = <int>{};
    var x = cell.dx.toInt() + newDx;
    var y = cell.dy.toInt() + newDy;
    while (x >= 0 && y >= 0 && x < cols && y < rows) {
      final k = _keyFor(x, y);
      if (bodyKeys.contains(k)) return false;
      final owner = _placedBy[k];
      if (owner != null && owner < i) return false;
      newRay.add(k);
      x += newDx;
      y += newDy;
    }

    _arrows[i] = [...arrow, cell];
    _arrowRays[i] = newRay;
    _free.remove(cellKey);
    _placed.add(cellKey);
    _placedBy[cellKey] = i;
    return true;
  }

  bool _isBlockedByLaterRay(int i, int cellKey) {
    for (int j = i + 1; j < _arrows.length; j++) {
      if (_arrowRays[j].contains(cellKey)) return true;
    }
    return false;
  }

  bool _isOrthogonallyAdjacent(Offset a, Offset b) {
    final dx = (a.dx - b.dx).abs();
    final dy = (a.dy - b.dy).abs();
    return (dx == 1 && dy == 0) || (dx == 0 && dy == 1);
  }

  bool _isInside(Offset cell) =>
      cell.dx >= 0 && cell.dy >= 0 && cell.dx < cols && cell.dy < rows;

  int _keyFor(int col, int row) => row * cols + col;
}

class _WalkOption {
  const _WalkOption({
    required this.cell,
    required this.dir,
    required this.weight,
  });
  final Offset cell;
  final Offset dir;
  final double weight;
}
