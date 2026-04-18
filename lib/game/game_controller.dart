import 'dart:math';
import 'dart:ui';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/arrow.dart';
import 'game_state.dart';
import 'generators/board_generator.dart';

final gameProvider = NotifierProvider<GameController, GameState>(
  GameController.new,
);

/// Controls the game state and the lifecycle of a level.
///
/// Board layouts are produced by a [BoardGenerator] selected via
/// [BoardGenerationAlgorithm]. The controller itself is algorithm-agnostic;
/// swapping generators is a matter of changing [_algorithm] and calling
/// [newGame].
class GameController extends Notifier<GameState> {
  static const int rows = 50;
  static const int cols = 40;
  static const BoardGenerationAlgorithm _defaultAlgorithm =
      BoardGenerationAlgorithm.tiled;

  final Random _random = Random();
  BoardGenerationAlgorithm _algorithm = _defaultAlgorithm;

  /// The generation algorithm that will be used on the next [newGame] (or
  /// the current one, if no new game has started since).
  BoardGenerationAlgorithm get algorithm => _algorithm;

  @override
  GameState build() {
    return GameState(arrows: _createLevel());
  }

  // ---------------------------------------------------------------------------
  // Level creation
  // ---------------------------------------------------------------------------
  List<Arrow> _createLevel() {
    final generator = _algorithm.create(
      rows: rows,
      cols: cols,
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

  /// Starts a fresh level. If [algorithm] is provided, the controller
  /// switches to that algorithm first; otherwise the currently-selected
  /// one is used.
  void newGame({BoardGenerationAlgorithm? algorithm}) {
    if (algorithm != null) _algorithm = algorithm;
    state = GameState(arrows: _createLevel());
  }

  /// Switches the active generation algorithm without starting a new
  /// game. The change takes effect on the next [newGame] call.
  void setAlgorithm(BoardGenerationAlgorithm algorithm) {
    _algorithm = algorithm;
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
