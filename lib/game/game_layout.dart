/// Shared layout constants for the board and hit targets.
abstract final class GameLayout {
  static const double cellSize = 32;

  /// Padding around the board so edge cells stay hittable when zoomed.
  static const double boardTouchPad = cellSize;
}
