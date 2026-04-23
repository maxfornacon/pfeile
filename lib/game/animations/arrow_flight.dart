import 'package:flutter/material.dart';

/// Exit animation for an arrow that was successfully removed.
class RemovalFlight {
  final List<Offset> cells;
  final Offset direction;
  final double distanceCells;
  final DateTime startedAt;
  final Duration duration;

  const RemovalFlight({
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

/// Forward / bounce animation when the player taps a blocked arrow head.
class BlockedSlideFlight {
  final List<Offset> cells;
  final Offset direction;
  final double maxShiftCells;
  final DateTime startedAt;
  final Duration forwardDuration;
  final Duration impactPause;
  final Duration returnDuration;

  const BlockedSlideFlight({
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
