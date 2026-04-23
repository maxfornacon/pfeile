import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/arrow.dart';
import 'animations/arrow_flight.dart';
import 'game_controller.dart';
import 'game_layout.dart';
import 'rendering/arrow_geometry.dart';

/// Animation timings, penalties, and flight state for a level. Kept separate from
/// [GameController] so board rules stay testable without the ticker.
class GamePlaySession {
  static const Duration removalDuration = Duration(milliseconds: 420);
  static const Duration blockedForwardDuration = Duration(milliseconds: 320);
  static const Duration blockedImpactPause = Duration(milliseconds: 50);
  static const Duration blockedReturnDuration = Duration(milliseconds: 340);
  static const Duration shakeDuration = Duration(milliseconds: 380);
  static const Duration damageFlashDuration = Duration(milliseconds: 900);
  static const Duration penaltyLabelDuration = Duration(milliseconds: 1100);
  static const double offBoardMarginCells = 1;
  static const int maxHelpLineUses = 3;

  final Map<int, RemovalFlight> activeFlights = {};
  final Map<int, BlockedSlideFlight> blockedFlights = {};
  final Set<int> knownRemoved = {};
  final Set<int> blockedImpactDone = {};

  DateTime? shakeStartedAt;
  DateTime? damageFlashStartedAt;
  DateTime? levelClockStartedAt;
  int? finishedElapsedMs;
  int timePenaltyMs = 0;
  DateTime? penaltyIndicatorStartedAt;
  int? syncedLevelId;

  int helpLineUsesLeft = maxHelpLineUses;
  bool showHelpLines = false;

  void onNewLevelLoaded({required bool hadPreviousLevel}) {
    if (hadPreviousLevel) {
      helpLineUsesLeft = maxHelpLineUses;
      showHelpLines = false;
      levelClockStartedAt = null;
      finishedElapsedMs = null;
      timePenaltyMs = 0;
      penaltyIndicatorStartedAt = null;
      knownRemoved.clear();
      activeFlights.clear();
      blockedFlights.clear();
      blockedImpactDone.clear();
      shakeStartedAt = null;
      damageFlashStartedAt = null;
    }
  }

  void syncRemovalFlights(GameController controller, List<Arrow> arrows) {
    final anyRemovedInState = arrows.any((a) => a.removed);
    if (!anyRemovedInState &&
        (knownRemoved.isNotEmpty || activeFlights.isNotEmpty)) {
      knownRemoved.clear();
      activeFlights.clear();
      blockedFlights.clear();
      blockedImpactDone.clear();
      shakeStartedAt = null;
      damageFlashStartedAt = null;
    }

    if (arrows.length < knownRemoved.length) {
      knownRemoved.clear();
      activeFlights.clear();
      blockedFlights.clear();
      blockedImpactDone.clear();
      shakeStartedAt = null;
      damageFlashStartedAt = null;
    }

    for (int i = 0; i < arrows.length; i++) {
      final arrow = arrows[i];
      if (!arrow.removed) continue;
      if (knownRemoved.contains(i)) continue;

      final cells = controller.cellsForArrow(arrow);
      if (cells.length >= 2) {
        final head = cells.last;
        final beforeHead = cells[cells.length - 2];
        final direction = head - beforeHead;
        final norm = direction.distance;
        if (norm > 0) {
          final unitDir = Offset(direction.dx / norm, direction.dy / norm);
          final distanceCells = distanceToFullyExit(cells, unitDir);
          activeFlights[i] = RemovalFlight(
            cells: cells,
            direction: unitDir,
            distanceCells: distanceCells,
            startedAt: DateTime.now(),
            duration: removalDuration,
          );
        }
      }
      knownRemoved.add(i);
    }
  }

  /// Returns whether the ticker should stay running.
  bool tick(GameController controller) {
    final now = DateTime.now();

    if (activeFlights.isNotEmpty) {
      final completed = <int>[];
      activeFlights.forEach((index, flight) {
        if (flight.progress(now) >= 1.0) completed.add(index);
      });
      for (final index in completed) {
        activeFlights.remove(index);
      }
    }

    if (blockedFlights.isNotEmpty) {
      final blockedDone = <int>[];
      blockedFlights.forEach((index, flight) {
        if (!blockedImpactDone.contains(index) && flight.forwardEnded(now)) {
          blockedImpactDone.add(index);
          shakeStartedAt = now;
          damageFlashStartedAt = now;
          timePenaltyMs += 5000;
          penaltyIndicatorStartedAt = now;
          HapticFeedback.heavyImpact();
        }
        if (flight.isComplete(now)) blockedDone.add(index);
      });
      for (final index in blockedDone) {
        blockedFlights.remove(index);
        blockedImpactDone.remove(index);
      }
    }

    final shakeActive = shakeOffset(now) != Offset.zero;
    final damageActive = damageFlashStrength(now) > 0.001;
    final penaltyLabelActive = penaltyLabelStrength(now) > 0.001;
    final isWin = controller.isWin;
    final needsTicks = activeFlights.isNotEmpty ||
        blockedFlights.isNotEmpty ||
        shakeActive ||
        damageActive ||
        penaltyLabelActive ||
        !isWin;
    if (isWin &&
        activeFlights.isEmpty &&
        blockedFlights.isEmpty &&
        finishedElapsedMs == null) {
      finishedElapsedMs = displayElapsedMs(now);
      HapticFeedback.lightImpact();
    }

    return needsTicks;
  }

  double maxShiftBeforeCollision(
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
    final cs = GameLayout.cellSize;

    while (shift <= maxTravel) {
      final moved = straighteningCells(cells, unitDir, shift, cs);
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

  void startBlockedSlide(int index, GameController controller, Arrow arrow) {
    if (blockedFlights.containsKey(index)) return;
    if (arrow.removed) return;

    final cells = controller.cellsForArrow(arrow);
    if (cells.length < 2) return;

    final head = cells.last;
    final beforeHead = cells[cells.length - 2];
    final direction = head - beforeHead;
    final norm = direction.distance;
    if (norm <= 0) return;

    final unitDir = Offset(direction.dx / norm, direction.dy / norm);
    final maxShift = maxShiftBeforeCollision(index, cells, unitDir, controller);

    blockedFlights[index] = BlockedSlideFlight(
      cells: cells,
      direction: unitDir,
      maxShiftCells: maxShift,
      startedAt: DateTime.now(),
      forwardDuration: blockedForwardDuration,
      impactPause: blockedImpactPause,
      returnDuration: blockedReturnDuration,
    );
  }

  Offset shakeOffset(DateTime now) {
    final start = shakeStartedAt;
    if (start == null) return Offset.zero;
    final elapsedMs = now.difference(start).inMilliseconds;
    if (elapsedMs < 0 || elapsedMs >= shakeDuration.inMilliseconds) {
      return Offset.zero;
    }
    final t = elapsedMs / shakeDuration.inMilliseconds;
    final damp = 1.0 - Curves.easeOut.transform(t);
    const w = 38.0;
    final secs = elapsedMs / 1000.0;
    return Offset(
      math.sin(secs * w) * 7 * damp,
      math.cos(secs * w * 1.17) * 6 * damp,
    );
  }

  double damageFlashStrength(DateTime now) {
    final start = damageFlashStartedAt;
    if (start == null) return 0;
    final elapsedMs = now.difference(start).inMilliseconds;
    if (elapsedMs < 0 || elapsedMs >= damageFlashDuration.inMilliseconds) {
      return 0;
    }
    final t = elapsedMs / damageFlashDuration.inMilliseconds;
    return 1.0 - Curves.easeOutCubic.transform(t);
  }

  double penaltyLabelStrength(DateTime now) {
    final start = penaltyIndicatorStartedAt;
    if (start == null) return 0;
    final elapsedMs = now.difference(start).inMilliseconds;
    if (elapsedMs < 0 || elapsedMs >= penaltyLabelDuration.inMilliseconds) {
      return 0;
    }
    final t = elapsedMs / penaltyLabelDuration.inMilliseconds;
    return 1.0 - Curves.easeOutCubic.transform(t);
  }

  int displayElapsedMs(DateTime now) {
    final start = levelClockStartedAt;
    if (start == null) return 0;
    return now.difference(start).inMilliseconds + timePenaltyMs;
  }

  static String formatStopwatch(int totalMs) {
    var ms = totalMs;
    if (ms < 0) ms = 0;
    final m = ms ~/ 60000;
    final s = (ms % 60000) ~/ 1000;
    final frac = ms % 1000;
    return '${m.toString().padLeft(2, '0')}:'
        '${s.toString().padLeft(2, '0')}.'
        '${frac.toString().padLeft(3, '0')}';
  }

  double distanceToFullyExit(List<Offset> cells, Offset direction) {
    final maxTravel =
        cells.length + GameController.rows + GameController.cols + 4.0;
    const step = 0.1;
    var travel = 0.0;
    final cs = GameLayout.cellSize;

    while (travel <= maxTravel) {
      final moved = straighteningCells(cells, direction, travel, cs);
      final allOutside = moved.every((point) {
        return point.dx < -offBoardMarginCells ||
            point.dy < -offBoardMarginCells ||
            point.dx > (GameController.cols - 1 + offBoardMarginCells) ||
            point.dy > (GameController.rows - 1 + offBoardMarginCells);
      });

      if (allOutside) {
        return travel;
      }
      travel += step;
    }

    return maxTravel;
  }

  void hideHelpLines() => showHelpLines = false;

  void tryShowHelpLines() {
    if (helpLineUsesLeft <= 0) return;
    helpLineUsesLeft -= 1;
    showHelpLines = true;
  }
}
