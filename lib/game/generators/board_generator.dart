import 'dart:math';
import 'dart:ui';

import 'interior_first_generator.dart';
import 'tiled_generator.dart';

/// Identifier for one of the bundled board generation algorithms.
///
/// Adding a new algorithm is a three-step change:
///   1. Add a new case here.
///   2. Extend [label] and [create] to handle it.
///   3. Implement a [BoardGenerator] subclass in its own file under
///      `lib/game/generators/`.
enum BoardGenerationAlgorithm {
  interiorFirst,
  tiled;

  /// Short human-readable name, suitable for a picker UI.
  String get label {
    switch (this) {
      case BoardGenerationAlgorithm.interiorFirst:
        return 'Interior-first';
      case BoardGenerationAlgorithm.tiled:
        return 'Tiled (divide & conquer)';
    }
  }

  /// Builds a fresh generator for a `rows × cols` board using [random] as
  /// its randomness source. Each call returns a new instance; generators
  /// are not reusable across calls to `generate()`.
  BoardGenerator create({
    required int rows,
    required int cols,
    required Random random,
  }) {
    switch (this) {
      case BoardGenerationAlgorithm.interiorFirst:
        return InteriorFirstGenerator(
          rows: rows,
          cols: cols,
          random: random,
        );
      case BoardGenerationAlgorithm.tiled:
        return TiledGenerator(
          rows: rows,
          cols: cols,
          random: random,
        );
    }
  }
}

/// Produces an initial board layout: a list of arrow paths, each encoded
/// as a tail-to-head polyline of grid cell centers.
///
/// Implementations must guarantee *solvability*: the player must be able
/// to remove every arrow by following the tap-in-head-ray rule in some
/// order. Beyond that, choice of shape, density, and aesthetic is up to
/// the implementation.
///
/// Generators are single-use scratchpads — call [generate] once per
/// instance. Reuse is undefined.
abstract class BoardGenerator {
  BoardGenerator({required this.rows, required this.cols});

  final int rows;
  final int cols;

  /// Returns the generated arrows as cell paths in tail→head order.
  List<List<Offset>> generate();
}
