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
    return GameState(arrows: _createLevel(), lives: 3);
  }

  // -----------------------------
  // 🎮 LEVEL
  // -----------------------------
  List<Arrow> _createLevel() {
    final fullPath = _buildSerpentinePath();
    final arrows = <Arrow>[];
    int cursor = 0;

    while (cursor < fullPath.length) {
      final remaining = fullPath.length - cursor;
      final length = _chooseArrowLength(remaining);
      final segment = fullPath.sublist(cursor, cursor + length);
      arrows.add(Arrow(points: _compressSegmentToPolyline(segment)));
      cursor += length;
    }

    return arrows;
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
      state = state.copyWith(lives: (state.lives - 1).clamp(0, 999));
      return;
    }

    arrows[index] = arrow.copyWith(removed: true);

    state = state.copyWith(arrows: arrows);
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

  List<Offset> _buildSerpentinePath() {
    final path = <Offset>[];
    for (int row = 0; row < rows; row++) {
      if (row.isEven) {
        for (int col = 0; col < cols; col++) {
          path.add(Offset(col.toDouble(), row.toDouble()));
        }
      } else {
        for (int col = cols - 1; col >= 0; col--) {
          path.add(Offset(col.toDouble(), row.toDouble()));
        }
      }
    }
    return path;
  }

  int _chooseArrowLength(int remaining) {
    if (remaining <= _maxArrowLen) {
      if (remaining == 1) return 1;
      return remaining;
    }

    final maxLen = min(_maxArrowLen, remaining - _minArrowLen);
    final minLen = _minArrowLen;
    return minLen + _random.nextInt(maxLen - minLen + 1);
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

  // -----------------------------
  // 💀 GAME OVER
  // -----------------------------
  bool get isGameOver => state.lives <= 0;
}
