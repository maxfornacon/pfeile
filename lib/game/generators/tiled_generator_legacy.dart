import 'dart:math';
import 'dart:ui';

import 'board_generator.dart';

/// Divide-and-conquer board generator built on per-tile Hamiltonian
/// walks plus an explicit dependency DAG.
///
/// The board is split into rectangular tiles by a randomised binary
/// space partition: each rectangle splits along its longer axis at a
/// random position (both halves at least [minTileSide] cells thick),
/// and rectangles already within [maxTileSide] may stop splitting
/// early. Tile sizes vary across the board, so the result shows no
/// regular grid lines.
///
/// Fill per tile (three stages):
///
///   1. **Hamiltonian walk.** A DFS that starts from a random corner
///      visits every cell in the tile exactly once, using a randomised
///      direction order plus Warnsdorff's rule (prefer moves to cells
///      with the fewest unvisited neighbours) to succeed in O(tile
///      area) with effectively no backtracking on the tile sizes this
///      generator produces. Rectangular grids always admit a
///      Hamiltonian path from any corner, so this stage is total.
///   2. **Segmentation.** The walk is cut into contiguous chunks whose
///      lengths are drawn independently from `[minLen, maxLen]`. The
///      segmenter never leaves a sub-[minLen] tail, so every resulting
///      arrow has at least `minLen` cells — no length-1 "dot" arrows
///      ever get produced, and no cell in the tile is left empty.
///      Independent per-segment length draws give natural length
///      diversity across a tile.
///   3. **Orientation pick.** Each segment has two candidate
///      orientations; zero-ray orientations (head on the global board
///      edge pointing off-board) are kept in reserve as a fallback
///      because they're trivially tappable — an empty ray cannot
///      contain any other arrow, and they have no outgoing edges in
///      the dependency graph so they can never close a cycle. For
///      non-zero-ray orientations we consult the running dependency
///      DAG:
///
///        * `dependsOn(seg)` — existing arrows whose bodies sit in
///          `seg`'s head ray. Those arrows must be tapped before
///          `seg`, so the graph gains `seg → A` for each such A.
///        * `dependedBy(seg)` — existing arrows whose head rays cover
///          any cell of `seg`'s body. `seg` must be tapped before
///          them, so the graph gains `B → seg` for each such B.
///
///      We accept the orientation iff those edges don't close a cycle
///      — a DFS from `dependsOn`, following "depends on" edges in the
///      current DAG, detects any path to `dependedBy` and short
///      circuits on it. Two arrows pointing straight at each other
///      would form a 2-cycle and are rejected automatically; that's
///      the only pairwise rule the original game cared about, so no
///      separate "opposing directions" check is needed.
///
/// If some segment in a tile has no valid orientation the whole tile
/// is rolled back (committed arrows for the tile removed, placed cells
/// restored to the free pool, dependency edges unwound) and a fresh
/// Hamiltonian walk is tried. If every per-tile retry fails, the
/// generator restarts from an empty board — a safety net that
/// essentially never fires in practice but keeps the "no empty cells"
/// invariant strict.
///
/// Bends: Hamiltonian walks have to turn repeatedly to visit every
/// cell, and Warnsdorff's rule pushes the walker toward the tile's
/// edges and corners early. Both biases naturally produce many 90°
/// turns per segment, so short segments bend occasionally and long
/// ones almost always bend at least once or twice.
class TiledGeneratorLegacy extends BoardGenerator {
  TiledGeneratorLegacy({
    required super.rows,
    required super.cols,
    required this.random,
    this.minTileSide = 5,
    this.maxTileSide = 15,
    this.minLen = 2,
    this.maxLen = 8,
    this.tileRetries = 16,
    this.segmentationsPerWalk = 8,
    this.generationRetries = 8,
    this.hamiltonStepLimit = 200000,
  }) : assert(minTileSide >= 2),
        assert(maxTileSide >= minTileSide),
        assert(minLen >= 2, 'length-1 arrows are never produced'),
        assert(maxLen >= minLen);

  /// Minimum side length (cells) for a leaf tile.
  final int minTileSide;

  /// Soft upper bound on a leaf tile's side length (cells).
  final int maxTileSide;

  /// Shortest arrow the generator will produce. Must be >= 2 so no
  /// "dot" arrows are ever emitted.
  final int minLen;

  /// Longest arrow the generator will produce.
  final int maxLen;

  /// How many Hamiltonian walks are attempted per tile before the
  /// generator gives up on it and asks for a full restart.
  final int tileRetries;

  /// How many fresh random segmentations are tried on each walk before
  /// the walk itself is discarded. Retrying segmentation is much
  /// cheaper than finding a new Hamiltonian path, so most bad
  /// orientation combos get fixed at this level without rerunning the
  /// DFS.
  final int segmentationsPerWalk;

  /// How many times the whole board is regenerated from scratch if a
  /// tile fill bottoms out on [tileRetries]. This essentially never
  /// happens in practice; the value is a safety net.
  final int generationRetries;

  /// Upper bound on recursive DFS steps per Hamiltonian walk attempt,
  /// in case Warnsdorff's rule hits a pathological dead end on a
  /// larger tile. Exceeding the budget aborts that walk and we simply
  /// try another corner / another walk.
  final int hamiltonStepLimit;

  final Random random;

  static const List<Offset> _directions = <Offset>[
    Offset(1, 0),
    Offset(-1, 0),
    Offset(0, 1),
    Offset(0, -1),
  ];

  final Set<int> _free = <int>{};
  final Set<int> _placed = <int>{};
  final Map<int, int> _placedBy = <int, int>{};
  final List<List<Offset>> _arrows = <List<Offset>>[];
  final List<Set<int>> _arrowRays = <Set<int>>[];
  // `_deps[i]` is the set of arrow indices arrow `i` must be tapped
  // *after* (outgoing edges from `i` in the dependency graph).
  final List<Set<int>> _deps = <Set<int>>[];
  // Reverse spatial index: cell key → arrow indices whose head ray
  // covers that cell. Lets us compute `dependedBy` for a new candidate
  // in O(body length) without rescanning every ray.
  final Map<int, Set<int>> _cellInRays = <int, Set<int>>{};

  // Budget counter for the current Hamiltonian walk attempt — reset
  // at the top of every `_hamiltonianWalk` call.
  int _hamiltonSteps = 0;

  @override
  List<List<Offset>> generate() {
    for (int attempt = 0; attempt < generationRetries; attempt++) {
      _resetState();
      final tiles = _buildTiles();
      // Shuffle first for randomness, then sort by area descending so
      // the tiles with the most segments run while the DAG is still
      // sparse. This dramatically reduces cycle-rejection failures on
      // large boards, where a late-filled big tile facing a dense DAG
      // is the dominant failure mode.
      tiles.shuffle(random);
      tiles.sort((a, b) => (b.w * b.h).compareTo(a.w * a.h));
      var ok = true;
      for (final tile in tiles) {
        if (!_fillTile(tile)) {
          ok = false;
          break;
        }
      }
      if (ok && _free.isEmpty) return _arrows;
    }
    // Last-resort return of whatever we have; should be unreachable in
    // practice. Length-1 dots are still avoided because we never
    // commit them anywhere in this generator.
    return _arrows;
  }

  void _resetState() {
    _free.clear();
    _placed.clear();
    _placedBy.clear();
    _arrows.clear();
    _arrowRays.clear();
    _deps.clear();
    _cellInRays.clear();
    for (int row = 0; row < rows; row++) {
      for (int col = 0; col < cols; col++) {
        _free.add(_keyFor(col, row));
      }
    }
  }

  // ---------------------------------------------------------------------------
  // Tile partition (randomised BSP)
  // ---------------------------------------------------------------------------

  List<_Tile> _buildTiles() {
    final tiles = <_Tile>[];
    _splitRect(x: 0, y: 0, w: cols, h: rows, tiles: tiles);
    return tiles;
  }

  void _splitRect({
    required int x,
    required int y,
    required int w,
    required int h,
    required List<_Tile> tiles,
  }) {
    final canSplitV = w >= minTileSide * 2;
    final canSplitH = h >= minTileSide * 2;

    if (!canSplitV && !canSplitH) {
      tiles.add(_Tile(x: x, y: y, w: w, h: h));
      return;
    }

    final mustSplit = w > maxTileSide || h > maxTileSide;
    if (!mustSplit) {
      final largerSide = w > h ? w : h;
      final headroom = (maxTileSide - largerSide + 1) / (maxTileSide + 1);
      final stopProb = 0.45 + (headroom.clamp(0.0, 1.0) * 0.5);
      if (random.nextDouble() < stopProb) {
        tiles.add(_Tile(x: x, y: y, w: w, h: h));
        return;
      }
    }

    final bool splitVertical;
    if (canSplitV && !canSplitH) {
      splitVertical = true;
    } else if (!canSplitV && canSplitH) {
      splitVertical = false;
    } else if (w > h) {
      splitVertical = true;
    } else if (h > w) {
      splitVertical = false;
    } else {
      splitVertical = random.nextBool();
    }

    if (splitVertical) {
      final lo = minTileSide;
      final hi = w - minTileSide;
      final splitAt = lo + random.nextInt(hi - lo + 1);
      _splitRect(x: x, y: y, w: splitAt, h: h, tiles: tiles);
      _splitRect(x: x + splitAt, y: y, w: w - splitAt, h: h, tiles: tiles);
    } else {
      final lo = minTileSide;
      final hi = h - minTileSide;
      final splitAt = lo + random.nextInt(hi - lo + 1);
      _splitRect(x: x, y: y, w: w, h: splitAt, tiles: tiles);
      _splitRect(x: x, y: y + splitAt, w: w, h: h - splitAt, tiles: tiles);
    }
  }

  // ---------------------------------------------------------------------------
  // Per-tile fill: Hamiltonian walk → segments → orient & commit
  // ---------------------------------------------------------------------------

  bool _fillTile(_Tile tile) {
    final checkpoint = _arrows.length;
    for (int walkAttempt = 0; walkAttempt < tileRetries; walkAttempt++) {
      final walk = _hamiltonianWalk(tile);
      if (walk == null) continue;
      for (int segAttempt = 0; segAttempt < segmentationsPerWalk; segAttempt++) {
        final segments = _segmentWalk(walk);
        if (_commitSegments(segments)) return true;
        _rollbackTo(checkpoint);
      }
    }
    return false;
  }

  /// Finds a Hamiltonian path through [tile] starting at one of its
  /// corners (tried in random order). DFS uses a randomised direction
  /// order and Warnsdorff's rule to almost always succeed without
  /// backtracking at the tile sizes we produce.
  List<Offset>? _hamiltonianWalk(_Tile tile) {
    final total = tile.w * tile.h;
    if (total < minLen) return null;

    final corners = <Offset>[
      Offset(tile.x.toDouble(), tile.y.toDouble()),
      Offset((tile.x + tile.w - 1).toDouble(), tile.y.toDouble()),
      Offset(tile.x.toDouble(), (tile.y + tile.h - 1).toDouble()),
      Offset((tile.x + tile.w - 1).toDouble(), (tile.y + tile.h - 1).toDouble()),
    ]..shuffle(random);

    for (final start in corners) {
      _hamiltonSteps = 0;
      final path = <Offset>[];
      final visited = <int>{};
      if (_dfsHamilton(start, path, visited, tile, total)) return path;
    }
    return null;
  }

  bool _dfsHamilton(
      Offset cell,
      List<Offset> path,
      Set<int> visited,
      _Tile tile,
      int total,
      ) {
    if (++_hamiltonSteps > hamiltonStepLimit) return false;
    path.add(cell);
    visited.add(_keyFor(cell.dx.toInt(), cell.dy.toInt()));
    if (path.length == total) return true;

    final options = <_HamiltonMove>[];
    for (final dir in _directions) {
      final next = cell + dir;
      if (!_isInsideTile(next, tile)) continue;
      final nextKey = _keyFor(next.dx.toInt(), next.dy.toInt());
      if (visited.contains(nextKey)) continue;

      // Warnsdorff degree: unvisited neighbours of `next`. Lower
      // degree = fewer forward options later, so we visit it first to
      // avoid orphaning it.
      var degree = 0;
      for (final d2 in _directions) {
        final nn = next + d2;
        if (!_isInsideTile(nn, tile)) continue;
        final nnKey = _keyFor(nn.dx.toInt(), nn.dy.toInt());
        if (!visited.contains(nnKey)) degree++;
      }
      options.add(_HamiltonMove(
        cell: next,
        degree: degree,
        tieBreak: random.nextDouble(),
      ));
    }
    options.sort((a, b) {
      final d = a.degree.compareTo(b.degree);
      if (d != 0) return d;
      return a.tieBreak.compareTo(b.tieBreak);
    });
    for (final opt in options) {
      if (_dfsHamilton(opt.cell, path, visited, tile, total)) return true;
    }
    path.removeLast();
    visited.remove(_keyFor(cell.dx.toInt(), cell.dy.toInt()));
    return false;
  }

  /// Cuts a Hamiltonian walk into segments of length in
  /// `[minLen, maxLen]`. Invariant: every emitted segment has at least
  /// [minLen] cells, and every cell of [walk] ends up in exactly one
  /// segment — so the tile is fully covered and no length-1 "dot"
  /// arrow is possible.
  List<List<Offset>> _segmentWalk(List<Offset> walk) {
    final segments = <List<Offset>>[];
    int i = 0;
    final n = walk.length;
    while (i < n) {
      final remaining = n - i;
      // Short-tail case: whatever's left becomes the final segment if
      // it's still above the minimum. Tails smaller than minLen are
      // impossible because the previous iteration would have forced a
      // segment length that leaves at least `minLen` cells behind.
      if (remaining <= maxLen) {
        assert(remaining >= minLen);
        segments.add(walk.sublist(i, n));
        return segments;
      }
      // Otherwise pick a random length, but clip the upper end so the
      // tail stays at least `minLen` cells long.
      final upper = remaining - minLen < maxLen ? remaining - minLen : maxLen;
      if (upper < minLen) {
        // Tight parameter edge case (maxLen < 2 * minLen − 1): the
        // remaining length is too awkward to split while keeping both
        // halves ≥ minLen. Emit the whole remainder as one segment —
        // it exceeds maxLen slightly, but keeping the "no empty
        // cells, no length-1 arrows" invariant matters more.
        segments.add(walk.sublist(i, n));
        return segments;
      }
      final len = minLen + random.nextInt(upper - minLen + 1);
      segments.add(walk.sublist(i, i + len));
      i += len;
    }
    return segments;
  }

  bool _commitSegments(List<List<Offset>> segments) {
    for (final seg in segments) {
      if (seg.length < minLen) return false;
      if (!_commitSegment(seg)) return false;
    }
    return true;
  }

  bool _commitSegment(List<Offset> seg) {
    final orientations = <List<Offset>>[seg, seg.reversed.toList()]
      ..shuffle(random);

    // Pass 1: prefer orientations whose head-forward ray stays on the
    // board (non-zero ray length). These look nicer and are the common
    // case.
    for (final oriented in orientations) {
      if (_rayLength(oriented) == 0) continue;
      if (_tryCommitOrientation(oriented)) return true;
    }
    // Pass 2: fall back to zero-ray orientations — head on the global
    // board edge with its direction pointing off-board. The tap rule
    // is satisfied trivially (empty ray cannot contain any "other
    // still-present arrow"), and zero-ray arrows have empty
    // `dependsOn`, so they have no outgoing edges in the DAG and
    // therefore cannot close a cycle. This is what lets every
    // Hamiltonian walk fit — corner tiles whose walks end at a board
    // corner always have at least one orientation in this bucket.
    for (final oriented in orientations) {
      if (_rayLength(oriented) != 0) continue;
      if (_tryCommitOrientation(oriented)) return true;
    }
    return false;
  }

  bool _tryCommitOrientation(List<Offset> oriented) {
    if (!_noSelfBite(oriented)) return false;
    final dependsOn = _computeDependsOn(oriented);
    final dependedBy = _computeDependedBy(oriented);
    if (_wouldCreateCycle(dependsOn, dependedBy)) return false;
    _commit(oriented, dependsOn, dependedBy);
    return true;
  }

  // ---------------------------------------------------------------------------
  // Dependency / cycle machinery
  // ---------------------------------------------------------------------------

  bool _noSelfBite(List<Offset> path) {
    if (path.length < 2) return true;
    final head = path.last;
    final beforeHead = path[path.length - 2];
    final dx = head.dx.toInt() - beforeHead.dx.toInt();
    final dy = head.dy.toInt() - beforeHead.dy.toInt();
    final bodyKeys = <int>{
      for (final cell in path) _keyFor(cell.dx.toInt(), cell.dy.toInt()),
    };
    var x = head.dx.toInt() + dx;
    var y = head.dy.toInt() + dy;
    while (x >= 0 && y >= 0 && x < cols && y < rows) {
      if (bodyKeys.contains(_keyFor(x, y))) return false;
      x += dx;
      y += dy;
    }
    return true;
  }

  Set<int> _computeDependsOn(List<Offset> path) {
    final deps = <int>{};
    if (path.length < 2) return deps;
    final head = path.last;
    final beforeHead = path[path.length - 2];
    final dx = head.dx.toInt() - beforeHead.dx.toInt();
    final dy = head.dy.toInt() - beforeHead.dy.toInt();
    var x = head.dx.toInt() + dx;
    var y = head.dy.toInt() + dy;
    while (x >= 0 && y >= 0 && x < cols && y < rows) {
      final owner = _placedBy[_keyFor(x, y)];
      if (owner != null) deps.add(owner);
      x += dx;
      y += dy;
    }
    return deps;
  }

  Set<int> _computeDependedBy(List<Offset> path) {
    final deps = <int>{};
    for (final cell in path) {
      final owners = _cellInRays[_keyFor(cell.dx.toInt(), cell.dy.toInt())];
      if (owners != null) deps.addAll(owners);
    }
    return deps;
  }

  bool _wouldCreateCycle(Set<int> dependsOn, Set<int> dependedBy) {
    if (dependsOn.isEmpty || dependedBy.isEmpty) return false;
    final visited = <int>{};
    final stack = <int>[...dependsOn];
    while (stack.isNotEmpty) {
      final n = stack.removeLast();
      if (!visited.add(n)) continue;
      if (dependedBy.contains(n)) return true;
      stack.addAll(_deps[n]);
    }
    return false;
  }

  // ---------------------------------------------------------------------------
  // Commit / rollback
  // ---------------------------------------------------------------------------

  void _commit(List<Offset> path, Set<int> dependsOn, Set<int> dependedBy) {
    final index = _arrows.length;
    _arrows.add(path);
    final ray = _computeHeadRay(path);
    _arrowRays.add(ray);
    _deps.add(<int>{...dependsOn});

    for (final cell in path) {
      final key = _keyFor(cell.dx.toInt(), cell.dy.toInt());
      _free.remove(key);
      _placed.add(key);
      _placedBy[key] = index;
    }
    for (final j in dependedBy) {
      _deps[j].add(index);
    }
    for (final rayKey in ray) {
      _cellInRays.putIfAbsent(rayKey, () => <int>{}).add(index);
    }
  }

  /// Unwinds every commit newer than [checkpoint], restoring the
  /// generator's state exactly to how it was before the current tile
  /// started filling. Removes cells from [_placed]/[_placedBy] back
  /// into [_free], drops ray entries from [_cellInRays], and strips
  /// references to the unwound arrow indices from every surviving
  /// entry of [_deps].
  void _rollbackTo(int checkpoint) {
    while (_arrows.length > checkpoint) {
      final idx = _arrows.length - 1;
      final path = _arrows.removeLast();
      final ray = _arrowRays.removeLast();
      _deps.removeLast();
      for (final cell in path) {
        final key = _keyFor(cell.dx.toInt(), cell.dy.toInt());
        _free.add(key);
        _placed.remove(key);
        _placedBy.remove(key);
      }
      for (final rayKey in ray) {
        final set = _cellInRays[rayKey];
        if (set == null) continue;
        set.remove(idx);
        if (set.isEmpty) _cellInRays.remove(rayKey);
      }
      for (int j = 0; j < _deps.length; j++) {
        _deps[j].remove(idx);
      }
    }
  }

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

  int _rayLength(List<Offset> path) {
    if (path.length < 2) return 0;
    final head = path.last;
    final beforeHead = path[path.length - 2];
    final dx = head.dx.toInt() - beforeHead.dx.toInt();
    final dy = head.dy.toInt() - beforeHead.dy.toInt();
    var x = head.dx.toInt() + dx;
    var y = head.dy.toInt() + dy;
    var count = 0;
    while (x >= 0 && y >= 0 && x < cols && y < rows) {
      count++;
      x += dx;
      y += dy;
    }
    return count;
  }

  bool _isInsideTile(Offset cell, _Tile t) {
    final x = cell.dx.toInt();
    final y = cell.dy.toInt();
    return x >= t.x && y >= t.y && x < t.x + t.w && y < t.y + t.h;
  }

  int _keyFor(int col, int row) => row * cols + col;
}

class _Tile {
  const _Tile({required this.x, required this.y, required this.w, required this.h});
  final int x;
  final int y;
  final int w;
  final int h;
}

class _HamiltonMove {
  const _HamiltonMove({
    required this.cell,
    required this.degree,
    required this.tieBreak,
  });
  final Offset cell;
  final int degree;
  final double tieBreak;
}