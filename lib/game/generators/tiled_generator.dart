import 'dart:math';
import 'dart:ui';

import 'board_generator.dart';

/// Divide-and-conquer board generator that grows arrows as
/// independent random self-avoiding walks.
///
/// The board is partitioned into rectangular tiles by a randomised
/// binary space partition (BSP): tile sides live in `[minTileSide,
/// maxTileSide]`, so tile shapes and sizes vary across the board.
/// Tiling is strictly a performance trick — every arrow's body stays
/// inside the tile it was grown in, but its head ray still runs all
/// the way across the board, so dependencies and ray crossings weave
/// freely through the whole grid.
///
/// Per tile, arrows are placed one at a time and each one is an
/// independent random walk:
///
///   1. **Seed.** Pick a free cell inside the tile with the fewest
///      remaining free neighbours (Warnsdorff-style, but on the
///      *free* subgraph — not a Hamiltonian construction). Breaking
///      ties at random. This fills corners and awkward leftovers
///      first, which dramatically cuts the odds of a tiny
///      unreachable pocket at the end.
///   2. **Target length.** Uniform in `[minLen, maxLen]`. Uniform
///      gives you the mix of very short and very long arrows that
///      makes some arrows visually end up swallowed by others.
///   3. **Growth.** Random self-avoiding walk through still-free
///      cells. Each step:
///        * With probability [spiralBias] pick a next cell weighted
///          toward neighbours that touch multiple already-laid body
///          cells — i.e. curl back onto the arrow's own tail. This
///          is where the spirals / C-shapes / tight coils come from.
///        * Otherwise pick uniformly at random, which produces the
///          long sprawling snakes.
///      Growth stops when the target length is reached or no free
///      neighbour remains; if the walk is still below [minLen] we
///      abandon it and try a different seed.
///   4. **Orient + commit.** Try both walk orientations; an
///      orientation is accepted iff it doesn't self-bite and doesn't
///      close a cycle in the running dependency DAG (see below).
///      Zero-ray orientations (head on the global board edge
///      pointing off-board) are tried as a fallback — an empty ray
///      is trivially tappable and contributes no outgoing DAG edges,
///      so it can never cycle.
///
/// Dependency DAG (controls solvability):
///
///   * `dependsOn(seg)` — existing arrows whose bodies sit in
///     `seg`'s head-forward ray. Those must be tapped before `seg`,
///     adding `seg → A` for each such A.
///   * `dependedBy(seg)` — existing arrows whose head rays already
///     cover any cell of `seg`'s body. `seg` must be tapped before
///     them, adding `B → seg` for each such B.
///
///   A new segment is accepted iff the added edges don't close a
///   cycle — a BFS out of `dependsOn` following existing "depends
///   on" edges short-circuits on any path to `dependedBy`.
///
/// If a tile can't be fully filled in a given pass (e.g. a random
/// seeding order stranded one cell between rejected orientations)
/// we roll the whole tile back and try again with fresh random
/// choices. If a tile truly refuses (very rare) the whole board is
/// regenerated from scratch.
class TiledGenerator extends BoardGenerator {
  TiledGenerator({
    required super.rows,
    required super.cols,
    required this.random,
    this.minTileSide = 4,
    this.maxTileSide = 10,
    this.minLen = 2,
    this.maxLen = 20,
    this.spiralBias = 0.6,
    this.arrowRetries = 80,
    this.tileRetries = 12,
    this.generationRetries = 8,
  }) : assert(minTileSide >= 2),
       assert(maxTileSide >= minTileSide),
       assert(minLen >= 2, 'length-1 arrows are never produced'),
       assert(maxLen >= minLen),
       assert(spiralBias >= 0 && spiralBias <= 1);

  /// Minimum side length (in cells) of a leaf tile.
  final int minTileSide;

  /// Soft upper bound on a leaf tile's side length. The BSP may stop
  /// splitting early for rectangles already below this.
  final int maxTileSide;

  /// Shortest arrow the generator will produce. Must be >= 2 — no
  /// length-1 "dot" arrows are ever emitted.
  final int minLen;

  /// Longest arrow the generator will produce.
  final int maxLen;

  /// Probability (0..1) that a walk's next-cell choice is biased
  /// toward cells adjacent to the walk's own body, producing
  /// spirals, curls and compact coils. `0` gives pure random walks
  /// (long sprawling snakes); `1` curls every chance it gets.
  final double spiralBias;

  /// Tries per arrow placement — each try picks a fresh seed, target
  /// length, grown walk and orientation, so the effective search
  /// width per arrow is quite large even if the first few fail.
  final int arrowRetries;

  /// How many times a tile retries from scratch (all its arrows
  /// rolled back) before it gives up and asks for a full board
  /// regeneration.
  final int tileRetries;

  /// How many times the whole board is regenerated if a tile gives
  /// up. Essentially never triggers on normal parameters.
  final int generationRetries;

  final Random random;

  static const List<Offset> _directions = <Offset>[
    Offset(1, 0),
    Offset(-1, 0),
    Offset(0, 1),
    Offset(0, -1),
  ];

  // ---------------------------------------------------------------------------
  // Board state. Reset at the top of every `generate()` attempt.
  // ---------------------------------------------------------------------------

  final Set<int> _free = <int>{};
  final Map<int, int> _placedBy = <int, int>{};
  final List<List<Offset>> _arrows = <List<Offset>>[];
  final List<Set<int>> _arrowRays = <Set<int>>[];
  // Outgoing dependency edges of arrow `i`: indices of arrows that
  // must be tapped before `i`.
  final List<Set<int>> _deps = <Set<int>>[];
  // Reverse spatial index: cell key -> indices of arrows whose head
  // rays cover that cell. Used for `dependedBy` in O(body length).
  final Map<int, Set<int>> _cellInRays = <int, Set<int>>{};

  // ---------------------------------------------------------------------------
  // Public API
  // ---------------------------------------------------------------------------

  @override
  List<List<Offset>> generate() {
    for (int attempt = 0; attempt < generationRetries; attempt++) {
      _resetState();
      final tiles = _buildTiles();
      // Random tile order; bigger tiles first reduces cycle
      // rejections on dense late-stage DAGs.
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
    // Last-resort fall-through: return whatever survived. Length-1
    // arrows are still impossible because no commit path produces
    // them.
    return _arrows;
  }

  void _resetState() {
    _free.clear();
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
  // BSP tiles
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
    final canV = w >= minTileSide * 2;
    final canH = h >= minTileSide * 2;
    if (!canV && !canH) {
      tiles.add(_Tile(x: x, y: y, w: w, h: h));
      return;
    }
    final mustSplit = w > maxTileSide || h > maxTileSide;
    if (!mustSplit) {
      final larger = w > h ? w : h;
      final headroom = (maxTileSide - larger + 1) / (maxTileSide + 1);
      final stopProb = 0.4 + headroom.clamp(0.0, 1.0) * 0.5;
      if (random.nextDouble() < stopProb) {
        tiles.add(_Tile(x: x, y: y, w: w, h: h));
        return;
      }
    }
    final bool vertical;
    if (canV && !canH) {
      vertical = true;
    } else if (!canV && canH) {
      vertical = false;
    } else if (w > h) {
      vertical = true;
    } else if (h > w) {
      vertical = false;
    } else {
      vertical = random.nextBool();
    }
    if (vertical) {
      final lo = minTileSide;
      final hi = w - minTileSide;
      final at = lo + random.nextInt(hi - lo + 1);
      _splitRect(x: x, y: y, w: at, h: h, tiles: tiles);
      _splitRect(x: x + at, y: y, w: w - at, h: h, tiles: tiles);
    } else {
      final lo = minTileSide;
      final hi = h - minTileSide;
      final at = lo + random.nextInt(hi - lo + 1);
      _splitRect(x: x, y: y, w: w, h: at, tiles: tiles);
      _splitRect(x: x, y: y + at, w: w, h: h - at, tiles: tiles);
    }
  }

  // ---------------------------------------------------------------------------
  // Per-tile fill
  // ---------------------------------------------------------------------------

  bool _fillTile(_Tile tile) {
    for (int attempt = 0; attempt < tileRetries; attempt++) {
      final checkpoint = _arrows.length;
      final tileFree = _tileCellSet(tile);
      var stuck = false;
      while (tileFree.isNotEmpty) {
        if (!_placeOneArrow(tile, tileFree)) {
          stuck = true;
          break;
        }
      }
      if (!stuck) return true;
      _rollbackTo(checkpoint);
    }
    return false;
  }

  Set<int> _tileCellSet(_Tile tile) {
    final s = <int>{};
    for (int row = tile.y; row < tile.y + tile.h; row++) {
      for (int col = tile.x; col < tile.x + tile.w; col++) {
        s.add(_keyFor(col, row));
      }
    }
    return s;
  }

  bool _placeOneArrow(_Tile tile, Set<int> tileFree) {
    for (int trial = 0; trial < arrowRetries; trial++) {
      final seed = _pickSeed(tileFree, tile);
      final target = minLen + random.nextInt(maxLen - minLen + 1);
      final walk = _growWalk(seed, target, tileFree, tile);
      if (walk == null || walk.length < minLen) continue;
      if (_commitSegment(walk)) {
        for (final c in walk) {
          tileFree.remove(_keyForCell(c));
        }
        return true;
      }
    }
    return false;
  }

  /// Warnsdorff-style seed pick over `tileFree`: lowest free-neighbour
  /// count wins, ties random. Crucially, this is run on the shrinking
  /// *free* subgraph (not a Hamilton construction), so it's just a
  /// way to tackle awkward pockets first.
  Offset _pickSeed(Set<int> tileFree, _Tile tile) {
    var minNeighbors = 5;
    final mins = <int>[];
    for (final k in tileFree) {
      final col = k % cols;
      final row = k ~/ cols;
      var count = 0;
      for (final dir in _directions) {
        final nx = col + dir.dx.toInt();
        final ny = row + dir.dy.toInt();
        if (nx < tile.x ||
            ny < tile.y ||
            nx >= tile.x + tile.w ||
            ny >= tile.y + tile.h) {
          continue;
        }
        if (tileFree.contains(_keyFor(nx, ny))) count++;
      }
      if (count < minNeighbors) {
        minNeighbors = count;
        mins
          ..clear()
          ..add(k);
      } else if (count == minNeighbors) {
        mins.add(k);
      }
    }
    final k = mins[random.nextInt(mins.length)];
    return Offset((k % cols).toDouble(), (k ~/ cols).toDouble());
  }

  /// Grows a random self-avoiding walk starting at [seed], staying
  /// inside [tile] and inside the still-free cells of [tileFree].
  /// Returns the walk or null if it couldn't reach [minLen].
  List<Offset>? _growWalk(
    Offset seed,
    int target,
    Set<int> tileFree,
    _Tile tile,
  ) {
    final walk = <Offset>[seed];
    final walkCells = <int>{_keyForCell(seed)};
    while (walk.length < target) {
      final current = walk.last;
      final candidates = <Offset>[];
      for (final dir in _directions) {
        final next = current + dir;
        if (!_isInsideTile(next, tile)) continue;
        final k = _keyForCell(next);
        if (!tileFree.contains(k)) continue;
        if (walkCells.contains(k)) continue;
        candidates.add(next);
      }
      if (candidates.isEmpty) break;
      final next = random.nextDouble() < spiralBias
          ? _spiralPick(candidates, walkCells)
          : candidates[random.nextInt(candidates.length)];
      walk.add(next);
      walkCells.add(_keyForCell(next));
    }
    if (walk.length < minLen) return null;
    return walk;
  }

  /// Weighted pick among [candidates] that prefers cells touching
  /// more already-laid body cells — the mechanism that produces
  /// spirals and tight curls.
  Offset _spiralPick(List<Offset> candidates, Set<int> walkCells) {
    final weights = <double>[];
    var total = 0.0;
    for (final c in candidates) {
      var adj = 0;
      for (final dir in _directions) {
        final n = c + dir;
        if (walkCells.contains(_keyForCell(n))) adj++;
      }
      // The walk's current head is always adjacent to any legal
      // candidate — subtract it out so the weight measures "extra
      // tail contact".
      adj = (adj - 1).clamp(0, 3);
      final w = 1.0 + 2.5 * adj;
      weights.add(w);
      total += w;
    }
    var pick = random.nextDouble() * total;
    for (var i = 0; i < candidates.length; i++) {
      pick -= weights[i];
      if (pick <= 0) return candidates[i];
    }
    return candidates.last;
  }

  // ---------------------------------------------------------------------------
  // Orientation + DAG commit
  // ---------------------------------------------------------------------------

  bool _commitSegment(List<Offset> seg) {
    final orientations = <List<Offset>>[seg, seg.reversed.toList()]
      ..shuffle(random);
    // Prefer orientations whose head-forward ray stays on the board.
    for (final o in orientations) {
      if (_rayLength(o) == 0) continue;
      if (_tryCommit(o)) return true;
    }
    // Zero-ray fallback — always safe (no outgoing DAG edges).
    for (final o in orientations) {
      if (_rayLength(o) != 0) continue;
      if (_tryCommit(o)) return true;
    }
    return false;
  }

  bool _tryCommit(List<Offset> oriented) {
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
    final before = path[path.length - 2];
    final dx = head.dx.toInt() - before.dx.toInt();
    final dy = head.dy.toInt() - before.dy.toInt();
    final bodyKeys = <int>{
      for (final cell in path) _keyForCell(cell),
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
    final before = path[path.length - 2];
    final dx = head.dx.toInt() - before.dx.toInt();
    final dy = head.dy.toInt() - before.dy.toInt();
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
      final owners = _cellInRays[_keyForCell(cell)];
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
      final key = _keyForCell(cell);
      _free.remove(key);
      _placedBy[key] = index;
    }
    for (final j in dependedBy) {
      _deps[j].add(index);
    }
    for (final rayKey in ray) {
      _cellInRays.putIfAbsent(rayKey, () => <int>{}).add(index);
    }
  }

  void _rollbackTo(int checkpoint) {
    while (_arrows.length > checkpoint) {
      final idx = _arrows.length - 1;
      final path = _arrows.removeLast();
      final ray = _arrowRays.removeLast();
      _deps.removeLast();
      for (final cell in path) {
        final key = _keyForCell(cell);
        _free.add(key);
        _placedBy.remove(key);
      }
      for (final rayKey in ray) {
        final set = _cellInRays[rayKey];
        if (set == null) continue;
        set.remove(idx);
        if (set.isEmpty) _cellInRays.remove(rayKey);
      }
      for (var j = 0; j < _deps.length; j++) {
        _deps[j].remove(idx);
      }
    }
  }

  // ---------------------------------------------------------------------------
  // Geometry helpers
  // ---------------------------------------------------------------------------

  Set<int> _computeHeadRay(List<Offset> path) {
    final ray = <int>{};
    if (path.length < 2) return ray;
    final head = path.last;
    final before = path[path.length - 2];
    final dx = head.dx.toInt() - before.dx.toInt();
    final dy = head.dy.toInt() - before.dy.toInt();
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
    final before = path[path.length - 2];
    final dx = head.dx.toInt() - before.dx.toInt();
    final dy = head.dy.toInt() - before.dy.toInt();
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
  int _keyForCell(Offset c) => c.dy.toInt() * cols + c.dx.toInt();
}

class _Tile {
  const _Tile({
    required this.x,
    required this.y,
    required this.w,
    required this.h,
  });
  final int x;
  final int y;
  final int w;
  final int h;
}
