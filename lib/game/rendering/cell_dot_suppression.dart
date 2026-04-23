import 'dart:ui';

import '../animations/arrow_flight.dart';

/// [shift] matches removal / blocked-slide sampling (grid units along the spine).
bool cellDotSuppressedByPathShift(
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
bool cellDotSuppressedByActiveRemoval(
  int col,
  int row,
  Map<int, RemovalFlight> activeFlights,
  DateTime now,
) {
  for (final flight in activeFlights.values) {
    final shift = flight.distanceCells * flight.progress(now);
    if (cellDotSuppressedByPathShift(col, row, flight.cells, shift)) {
      return true;
    }
  }
  return false;
}

/// Static occupancy hides dots, except cells vacated by a blocked arrow's tail
/// (still in [occupancy] but no longer covered by the sliding stroke).
bool occupancySuppressesDot(
  int col,
  int row,
  Map<String, List<int>> occupancy,
  Map<int, BlockedSlideFlight> blockedFlights,
  DateTime now,
) {
  final ids = occupancy['$col:$row'];
  if (ids == null || ids.isEmpty) return false;
  for (final id in ids) {
    final blocked = blockedFlights[id];
    if (blocked != null) {
      if (cellDotSuppressedByPathShift(
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
