import 'dart:ui';
import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'game_state.dart';
import '../models/arrow.dart';

final gameProvider = NotifierProvider<GameController, GameState>(
  GameController.new,
);

class GameController extends Notifier<GameState> {
  static const int rows = 8;
  static const int cols = 8;
  static const int _minArrowLen = 2;
  static const int _maxArrowLen = 6;
  final Random _random = Random();

  @override
  GameState build() {
    return GameState(arrows: _createLevel());
  }

  // -----------------------------
  // 🎮 LEVEL
  // -----------------------------
  List<Arrow> _createLevel() {
    const maxAttempts = 300;

    for (int attempt = 0; attempt < maxAttempts; attempt++) {
      final candidate = _generateArrowCellPaths();
      if (_passesOppositeFacingRule(candidate) &&
          _passesNoSelfBiteRule(candidate) &&
          _isBoardSolvable(candidate)) {
        return candidate
            .map((cells) => Arrow(points: _compressSegmentToPolyline(cells)))
            .toList();
      }
    }

    // Safe fallback: always solvable by construction.
    return _buildGuaranteedSolvablePaths()
        .map((cells) => Arrow(points: _compressSegmentToPolyline(cells)))
        .toList();
  }

  // -----------------------------
  // 🎯 TAP
  // -----------------------------
  void tapCell(int col, int row) {
    final index = topArrowIndexAtCell(col, row);
    if (index == null) return;
    tapArrow(index);
  }

  void tapArrow(int index) {
    final arrows = [...state.arrows];
    final arrow = arrows[index];

    if (arrow.removed) return;

    if (!isArrowTappable(index)) {
      return;
    }

    arrows[index] = arrow.copyWith(removed: true);

    state = state.copyWith(arrows: arrows);
  }

  void newGame() {
    state = GameState(arrows: _createLevel());
  }

  // -----------------------------
  // ✔ RULES
  // -----------------------------
  bool isArrowTappable(int index) {
    final arrow = state.arrows[index];
    if (arrow.removed) return false;

    final cells = cellsForArrow(arrow);
    if (cells.length < 2) return true;

    final head = cells.last;
    final beforeHead = cells[cells.length - 2];
    final direction = head - beforeHead;
    final ahead = Offset(head.dx + direction.dx, head.dy + direction.dy);

    if (!_isInside(ahead)) return true;

    final occupancy = occupancyMap();
    var x = ahead.dx.toInt();
    var y = ahead.dy.toInt();
    final stepX = direction.dx.toInt();
    final stepY = direction.dy.toInt();

    while (x >= 0 && y >= 0 && x < cols && y < rows) {
      final key = _cellKey(x, y);
      final occupiedBy = occupancy[key] ?? const <int>[];
      if (occupiedBy.where((other) => other != index).isNotEmpty) {
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

  bool _isInside(Offset cell) {
    return cell.dx >= 0 && cell.dy >= 0 && cell.dx < cols && cell.dy < rows;
  }

  String _cellKey(int col, int row) {
    return '$col:$row';
  }

  List<List<Offset>> _generateArrowCellPaths() {
    final free = <int>{};
    for (int row = 0; row < rows; row++) {
      for (int col = 0; col < cols; col++) {
        free.add(_cellKeyInt(col, row));
      }
    }

    final paths = <List<Offset>>[];

    while (free.isNotEmpty) {
      final start = _pickStartCell(free);
      final targetLen = _chooseArrowLength(free.length);
      final path = <Offset>[start];
      free.remove(_cellKeyInt(start.dx.toInt(), start.dy.toInt()));

      while (path.length < targetLen) {
        final next = _pickNextCell(path, free);
        if (next == null) {
          break;
        }
        path.add(next);
        free.remove(_cellKeyInt(next.dx.toInt(), next.dy.toInt()));
      }

      paths.add(path);
    }

    return _mergeSingletons(paths);
  }

  bool _passesOppositeFacingRule(List<List<Offset>> paths) {
    final horizontalDirectionsByRow = <int, Set<int>>{};
    final verticalDirectionsByCol = <int, Set<int>>{};

    for (final path in paths) {
      if (path.length < 2) continue;

      final head = path.last;
      final beforeHead = path[path.length - 2];
      final dx = head.dx.toInt() - beforeHead.dx.toInt();
      final dy = head.dy.toInt() - beforeHead.dy.toInt();

      if (dx != 0) {
        final row = head.dy.toInt();
        final dir = dx > 0 ? 1 : -1;
        horizontalDirectionsByRow.putIfAbsent(row, () => <int>{}).add(dir);
        if (horizontalDirectionsByRow[row]!.length > 1) {
          return false;
        }
      } else if (dy != 0) {
        final col = head.dx.toInt();
        final dir = dy > 0 ? 1 : -1;
        verticalDirectionsByCol.putIfAbsent(col, () => <int>{}).add(dir);
        if (verticalDirectionsByCol[col]!.length > 1) {
          return false;
        }
      }
    }

    return true;
  }

  bool _passesNoSelfBiteRule(List<List<Offset>> paths) {
    for (final cells in paths) {
      if (_hasSelfBite(cells)) {
        return false;
      }
    }
    return true;
  }

  bool _hasSelfBite(List<Offset> cells) {
    if (cells.length < 2) return false;

    final head = cells.last;
    final beforeHead = cells[cells.length - 2];
    final direction = head - beforeHead;
    final stepX = direction.dx.toInt();
    final stepY = direction.dy.toInt();

    final ownCells = <int>{};
    for (final cell in cells) {
      ownCells.add(_cellKeyInt(cell.dx.toInt(), cell.dy.toInt()));
    }

    var x = head.dx.toInt() + stepX;
    var y = head.dy.toInt() + stepY;

    while (x >= 0 && y >= 0 && x < cols && y < rows) {
      if (ownCells.contains(_cellKeyInt(x, y))) {
        return true;
      }
      x += stepX;
      y += stepY;
    }

    return false;
  }

  bool _isBoardSolvable(List<List<Offset>> paths) {
    final removed = <int>{};

    while (removed.length < paths.length) {
      final occupancy = _buildPathOccupancy(paths, removed);
      var progressed = false;

      for (int i = 0; i < paths.length; i++) {
        if (removed.contains(i)) continue;
        if (_isPathTappable(i, paths, removed, occupancy)) {
          removed.add(i);
          progressed = true;
        }
      }

      if (!progressed) return false;
    }

    return true;
  }

  Map<int, List<int>> _buildPathOccupancy(
    List<List<Offset>> paths,
    Set<int> removed,
  ) {
    final occupancy = <int, List<int>>{};
    for (int i = 0; i < paths.length; i++) {
      if (removed.contains(i)) continue;
      for (final cell in paths[i]) {
        final key = _cellKeyInt(cell.dx.toInt(), cell.dy.toInt());
        occupancy.putIfAbsent(key, () => <int>[]).add(i);
      }
    }
    return occupancy;
  }

  bool _isPathTappable(
    int index,
    List<List<Offset>> paths,
    Set<int> removed,
    Map<int, List<int>> occupancy,
  ) {
    if (removed.contains(index)) return false;
    final cells = paths[index];
    if (cells.length < 2) return true;

    final head = cells.last;
    final beforeHead = cells[cells.length - 2];
    final direction = head - beforeHead;
    var x = head.dx.toInt() + direction.dx.toInt();
    var y = head.dy.toInt() + direction.dy.toInt();
    final stepX = direction.dx.toInt();
    final stepY = direction.dy.toInt();

    while (x >= 0 && y >= 0 && x < cols && y < rows) {
      final key = _cellKeyInt(x, y);
      final occupiedBy = occupancy[key] ?? const <int>[];
      if (occupiedBy.any(
        (other) => other != index && !removed.contains(other),
      )) {
        return false;
      }
      x += stepX;
      y += stepY;
    }
    return true;
  }

  List<List<Offset>> _buildGuaranteedSolvablePaths() {
    final paths = <List<Offset>>[];
    for (int row = 0; row < rows; row++) {
      final line = <Offset>[];
      for (int col = 0; col < cols; col++) {
        line.add(Offset(col.toDouble(), row.toDouble()));
      }
      paths.add(line);
    }
    return paths;
  }

  int _chooseArrowLength(int remaining) {
    if (remaining <= _maxArrowLen) return remaining;

    final minLen = _minArrowLen;
    final maxLen = _maxArrowLen;
    var length = minLen + _random.nextInt(maxLen - minLen + 1);

    // Avoid leaving exactly one cell to reduce one-cell arrows.
    if (remaining - length == 1) {
      if (length > minLen) {
        length -= 1;
      } else {
        length += 1;
      }
    }
    return length;
  }

  Offset _pickStartCell(Set<int> free) {
    var bestScore = 999;

    for (final key in free) {
      final col = key % cols;
      final row = key ~/ cols;
      final degree = _availableNeighbors(
        Offset(col.toDouble(), row.toDouble()),
        free,
      ).length;
      if (degree < bestScore) {
        bestScore = degree;
      }
    }

    final candidates = <int>[];
    for (final key in free) {
      final col = key % cols;
      final row = key ~/ cols;
      final degree = _availableNeighbors(
        Offset(col.toDouble(), row.toDouble()),
        free,
      ).length;
      if (degree <= bestScore + 1) {
        candidates.add(key);
      }
    }

    final picked = candidates[_random.nextInt(candidates.length)];
    return Offset((picked % cols).toDouble(), (picked ~/ cols).toDouble());
  }

  Offset? _pickNextCell(List<Offset> path, Set<int> free) {
    final current = path.last;
    final neighbors = _availableNeighbors(current, free);
    if (neighbors.isEmpty) return null;

    final prev = path.length > 1 ? path[path.length - 2] : null;
    final weighted = <_WeightedCell>[];

    for (final candidate in neighbors) {
      var score = 1.0;

      final candidateDegree = _availableNeighbors(candidate, free).length;
      score += (4 - candidateDegree) * 0.35;

      if (prev != null) {
        final lastDir = current - prev;
        final nextDir = candidate - current;
        final isTurn = nextDir != lastDir;
        score += isTurn ? 1.4 : 0.2;
      }

      score += _random.nextDouble() * 0.25;
      weighted.add(
        _WeightedCell(cell: candidate, score: score < 0.05 ? 0.05 : score),
      );
    }

    final total = weighted.fold<double>(0, (sum, w) => sum + w.score);
    var pick = _random.nextDouble() * total;
    for (final item in weighted) {
      pick -= item.score;
      if (pick <= 0) return item.cell;
    }
    return weighted.last.cell;
  }

  List<Offset> _availableNeighbors(Offset cell, Set<int> free) {
    final col = cell.dx.toInt();
    final row = cell.dy.toInt();
    final result = <Offset>[];
    const deltas = <Offset>[
      Offset(1, 0),
      Offset(-1, 0),
      Offset(0, 1),
      Offset(0, -1),
    ];

    for (final delta in deltas) {
      final nextCol = col + delta.dx.toInt();
      final nextRow = row + delta.dy.toInt();
      if (nextCol < 0 || nextRow < 0 || nextCol >= cols || nextRow >= rows) {
        continue;
      }
      final key = _cellKeyInt(nextCol, nextRow);
      if (free.contains(key)) {
        result.add(Offset(nextCol.toDouble(), nextRow.toDouble()));
      }
    }
    return result;
  }

  List<List<Offset>> _mergeSingletons(List<List<Offset>> paths) {
    final result = <List<Offset>>[];

    for (final path in paths) {
      if (path.length != 1 || result.isEmpty) {
        result.add(path);
        continue;
      }

      final single = path.first;
      var merged = false;
      for (int i = 0; i < result.length; i++) {
        final candidate = result[i];
        final start = candidate.first;
        final end = candidate.last;

        if (_isAdjacent(single, end)) {
          result[i] = [...candidate, single];
          merged = true;
          break;
        }
        if (_isAdjacent(single, start)) {
          result[i] = [single, ...candidate];
          merged = true;
          break;
        }
      }

      if (!merged) {
        result.add(path);
      }
    }

    return result;
  }

  bool _isAdjacent(Offset a, Offset b) {
    final dx = (a.dx - b.dx).abs();
    final dy = (a.dy - b.dy).abs();
    return (dx == 1 && dy == 0) || (dx == 0 && dy == 1);
  }

  int _cellKeyInt(int col, int row) {
    return row * cols + col;
  }

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

  // -----------------------------
  // 🏁 WIN
  // -----------------------------
  bool get isWin => state.arrows.every((a) => a.removed);
}

class _WeightedCell {
  final Offset cell;
  final double score;

  const _WeightedCell({required this.cell, required this.score});
}
