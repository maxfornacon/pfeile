import 'dart:math';
import 'dart:ui';

import 'board_generator.dart';

/// Generates a solvable arrow board using **reverse construction**.
///
/// An arrow is tappable in the solve iff no other still-present arrow
/// occupies a cell in its head's forward ray to the board edge. If we
/// build the board in the *opposite* order of the solve (last-tapped
/// first), each new arrow only needs its head-forward ray to be clear of
/// the *already placed* arrows — those are exactly the ones that will
/// still exist at the moment this arrow is removed in the solve. So the
/// board is solvable by construction; no backtracking search or post-hoc
/// check is needed.
///
/// The "no two arrows facing in opposing directions" rule is enforced
/// implicitly: two arrows pointing *toward* each other would each have
/// the other's body in its head-forward ray, and reverse construction
/// rejects that on placement. Two arrows pointing *away* from each other
/// in the same row/column are harmless and we deliberately allow them —
/// forbidding them would strictly reduce coverage for no gameplay
/// benefit.
///
/// Generation runs four stages:
///   1. Boundary-seed pass — before any other placement, plant arrows on
///      a random ~50% of boundary cells. Seeds go through the same
///      bend-biased walk machinery as the main fill, but with *random*
///      orientation (not longer-ray-preferred) so parallel-to-edge heads
///      get an even chance against perpendicular-inward heads. Because
///      the board is empty when seeds are placed, their forward rays are
///      trivially clear regardless of orientation.
///   2. Fill — a single pass that iterates remaining free cells sorted
///      interior-first (distance from the nearest edge, descending) with
///      random tiebreak. Early placements happen on a mostly-empty board
///      and face the larger open region; unseeded edge cells come last
///      and often cannot be placed at all.
///   3. Reshape/infill — alternating body-detour and front-of-head
///      passes. *Body detours* reroute a non-final body edge of an
///      existing arrow through a 2-cell free pocket on one side:
///      `p[j] → p[j+1]` becomes `p[j] → a → b → p[j+1]`. Since the last
///      segment is untouched the head direction and ray stay identical,
///      so the modified arrow inherits the original's solvability
///      without re-validation. *Front-of-head* placements commit a fresh
///      straight arrow inside the forward ray of an existing one,
///      facing the same direction — useful for pockets near the board
///      edge that would otherwise be too small for a standalone walk.
///      Both passes run in a loop because each can unlock the other.
///   4. Endpoint absorption — swallow remaining interior free cells into
///      a neighboring arrow. Free cells on the outermost ring are left
///      alone so the perimeter keeps its intentional gaps.
///
/// Two invariants deserve special mention:
///
///   * **No outward-off-board heads.** Orientations whose head-forward
///     ray has length 0 (head on boundary, direction pointing off the
///     grid) are rejected *everywhere*, not just for seeds. That turns
///     the spike-at-edge pattern into boundary gaps instead.
///   * **~50% seed density.** Full-density seeding would occupy the
///     first [maxLen] rows/cols of every edge and leave interior arrows
///     with no valid ray direction in at least one axis.
///
/// The net effect: the middle of the board fills densely with bent
/// arrows in mixed directions; the perimeter carries a mix of
/// inward-facing and parallel-to-edge seeds plus intentional gaps, but
/// never the regimented outward-spike row that plain reverse
/// construction produces.
///
/// Any cells no stage can absorb are left empty; the painter renders
/// them as the usual faint background dots.
///
/// Complexity: each arrow does O(maxLen + rows + cols) work, so the
/// whole generator is O(cells) — suitable for very large boards.
class InteriorFirstGenerator extends BoardGenerator {
  InteriorFirstGenerator({
    required super.rows,
    required super.cols,
    required this.random,
    this.minLen = 3,
    this.maxLen = 8,
    this.maxBends = 5,
    this.bendProbability = 0.5,
  });

  final int minLen;
  final int maxLen;
  final int maxBends;
  final double bendProbability;
  final Random random;

  static const List<Offset> _directions = <Offset>[
    Offset(1, 0),
    Offset(-1, 0),
    Offset(0, 1),
    Offset(0, -1),
  ];

  // Cells that are still unoccupied by any arrow.
  final Set<int> _free = <int>{};
  // Cells belonging to any already-placed arrow.
  final Set<int> _placed = <int>{};
  // For each placed cell, the index (into [_arrows]) of the arrow owning
  // it. Used to check ray clearance against arrows placed earlier than a
  // given index without rescanning every body.
  final Map<int, int> _placedBy = <int, int>{};
  // Committed arrows, each as a full cell path from tail to head.
  final List<List<Offset>> _arrows = <List<Offset>>[];
  // The head-forward ray (set of cell keys from the cell after the head
  // all the way to the board edge) for each committed arrow, parallel to
  // [_arrows]. Precomputed on commit and refreshed when the head changes.
  final List<Set<int>> _arrowRays = <Set<int>>[];

  @override
  List<List<Offset>> generate() {
    _free.clear();
    _placed.clear();
    _placedBy.clear();
    _arrows.clear();
    _arrowRays.clear();

    for (int row = 0; row < rows; row++) {
      for (int col = 0; col < cols; col++) {
        _free.add(_keyFor(col, row));
      }
    }

    // Stage 1: seed ~50% of boundary cells with bent, randomly-oriented
    // arrows while the board is still empty (so their forward rays are
    // trivially clear regardless of direction).
    _seedInwardEdgeArrows();

    // Stage 2: interior-first fill for everything else.
    _fillPass(
      minLen: minLen,
      maxLen: maxLen,
      walkAttemptsPerStart: 8,
    );

    // Stage 3: body detours and in-line front-of-head placements. Both
    // can only reduce the free set, so the loop is bounded, and each can
    // enable the other (a detour frees a body edge next to a new pocket;
    // an in-line arrow creates a fresh ray that another detour might
    // touch).
    var reshaped = true;
    while (reshaped && _free.isNotEmpty) {
      reshaped = false;
      if (_bodyDetourPass()) reshaped = true;
      if (_frontOfHeadPass()) reshaped = true;
    }

    // Stage 4: single-cell endpoint absorption for whatever's left.
    if (_free.isNotEmpty) {
      _extensionPass();
    }

    return _arrows;
  }

  /// Plants arrows on a random ~50% of the boundary cells *before* any
  /// other placement. Delegates to [_tryBuildArrow] so seeds inherit the
  /// same bend-biased walks as the rest of the generator (they are not
  /// straight lines), but overrides two knobs:
  ///
  ///   * `preferLongerRay: false` — mid-edge boundary cells have a
  ///     perpendicular ray of ~rows-1 and a parallel ray of ~cols/2; the
  ///     longer-ray tiebreak would pick the perpendicular option almost
  ///     every time, which is exactly the "spike pointing inward"
  ///     monoculture we want to avoid. Random orientation gives parallel
  ///     heads (arrows running *along* the edge) an even chance.
  ///   * The global ray-0 rejection in [_tryBuildArrow] prevents any
  ///     boundary cell from acquiring an outward-facing head. That turns
  ///     boundary cells the seed pass skips and the fill pass can't
  ///     legally fill into intentional gaps instead of yet more outward
  ///     spikes.
  ///
  /// Seed density stops at ~50% so roughly half of each edge axis stays
  /// empty and the fill pass retains at least one ray direction for
  /// interior arrows.
  void _seedInwardEdgeArrows() {
    const density = 0.5;

    final seedKeys = <int>{};
    for (int col = 0; col < cols; col++) {
      seedKeys.add(_keyFor(col, 0));
      seedKeys.add(_keyFor(col, rows - 1));
    }
    for (int row = 0; row < rows; row++) {
      seedKeys.add(_keyFor(0, row));
      seedKeys.add(_keyFor(cols - 1, row));
    }
    final seeds = seedKeys.toList()..shuffle(random);

    for (final key in seeds) {
      if (random.nextDouble() >= density) continue;
      if (!_free.contains(key)) continue;
      final arrow = _tryBuildArrow(
        startKey: key,
        minLen: minLen,
        maxLen: maxLen,
        attempts: 8,
        preferLongerRay: false,
      );
      if (arrow != null) _commit(arrow);
    }
  }

  /// Repeatedly sweeps through free cells, trying to grow an arrow from
  /// each. Cells are visited in interior-first order (distance to the
  /// nearest edge, descending) with a random tiebreak so center cells
  /// get first crack at placement while the board is empty and ray
  /// constraints are trivial; edge cells are visited last, where many
  /// attempts will fail and simply leave the cell unfilled.
  void _fillPass({
    required int minLen,
    required int maxLen,
    required int walkAttemptsPerStart,
  }) {
    const maxSweeps = 4;
    for (int sweep = 0; sweep < maxSweeps; sweep++) {
      if (_free.isEmpty) return;
      final startKeys = _free.toList()..shuffle(random);
      startKeys.sort((a, b) => _edgeDistance(b) - _edgeDistance(a));
      var progressed = false;
      for (final startKey in startKeys) {
        if (!_free.contains(startKey)) continue;
        final arrow = _tryBuildArrow(
          startKey: startKey,
          minLen: minLen,
          maxLen: maxLen,
          attempts: walkAttemptsPerStart,
        );
        if (arrow != null) {
          _commit(arrow);
          progressed = true;
        }
      }
      if (!progressed) return;
    }
  }

  /// Reroutes non-terminal body edges of existing arrows through
  /// adjacent 2-cell free pockets. For an edge `p[j] → p[j+1]` we try to
  /// replace it with `p[j] → a → b → p[j+1]`, where `a` and `b` are the
  /// two cells of the unit square on one perpendicular side of the edge.
  /// The last segment `p[n-2] → p[n-1]` is deliberately left out of the
  /// candidate set: keeping it fixed means the head direction (and
  /// therefore the precomputed forward ray) does not change, so the
  /// rerouted arrow inherits the original's solvability with no
  /// re-validation.
  ///
  /// Each candidate cell must be free, outside this arrow's own head ray
  /// (no self-bite), and outside the head-forward ray of any arrow
  /// placed *after* this one (those rays must stay clear at solve time).
  /// The resulting path is rejected if it exceeds [maxBends] — a
  /// rectangular jog always introduces two new 90° turns, so
  /// heavily-bent arrows are passed over.
  ///
  /// Returns true if any arrow was successfully rerouted.
  bool _bodyDetourPass() {
    var anyProgress = false;
    var progressed = true;
    while (progressed) {
      progressed = false;
      final order = List<int>.generate(_arrows.length, (i) => i)
        ..shuffle(random);
      for (final i in order) {
        if (_tryBodyDetour(i)) {
          progressed = true;
          anyProgress = true;
        }
      }
    }
    return anyProgress;
  }

  bool _tryBodyDetour(int i) {
    final arrow = _arrows[i];
    if (arrow.length < 3) return false;

    // Skip the final edge so the last segment — and thus the head ray —
    // stays untouched.
    final edgeIndices = List<int>.generate(arrow.length - 2, (k) => k)
      ..shuffle(random);

    for (final j in edgeIndices) {
      final from = arrow[j];
      final to = arrow[j + 1];
      final delta = to - from;
      final perps = <Offset>[
        Offset(-delta.dy, delta.dx),
        Offset(delta.dy, -delta.dx),
      ]..shuffle(random);

      for (final p in perps) {
        final a = from + p;
        final b = to + p;
        if (!_isInside(a) || !_isInside(b)) continue;
        final aKey = _keyFor(a.dx.toInt(), a.dy.toInt());
        final bKey = _keyFor(b.dx.toInt(), b.dy.toInt());
        if (!_free.contains(aKey) || !_free.contains(bKey)) continue;
        if (_arrowRays[i].contains(aKey) || _arrowRays[i].contains(bKey)) {
          continue;
        }
        if (_isBlockedByLaterRay(i, aKey) ||
            _isBlockedByLaterRay(i, bKey)) {
          continue;
        }

        final newPath = <Offset>[
          ...arrow.sublist(0, j + 1),
          a,
          b,
          ...arrow.sublist(j + 1),
        ];
        if (_countBends(newPath) > maxBends) continue;

        _arrows[i] = newPath;
        _free.remove(aKey);
        _free.remove(bKey);
        _placed.add(aKey);
        _placed.add(bKey);
        _placedBy[aKey] = i;
        _placedBy[bKey] = i;
        // _arrowRays[i] is unchanged because the last segment is preserved.
        return true;
      }
    }
    return false;
  }

  /// Places short straight arrows inside the forward rays of existing
  /// arrows. For each arrow, walks forward from the head along its head
  /// direction collecting consecutive free cells; if the run reaches the
  /// board edge with enough room for a fresh arrow *and* at least one
  /// trailing cell (so the new head does not point off-board), commits a
  /// straight arrow in the same direction.
  ///
  /// Runs that terminate at a later-placed arrow's body are skipped: the
  /// new arrow's own forward ray would hit a placed cell and fail the
  /// standard ray-clear check. That's fine — those gaps are left alone.
  ///
  /// Reverse-construction correctness: the new arrow is appended with
  /// the highest index, so in solve order it moves *before* the existing
  /// arrow whose ray it occupies, clearing that ray in time for the
  /// existing arrow's turn. Its own forward ray is validated against all
  /// previously placed bodies via [_validate].
  bool _frontOfHeadPass() {
    var anyProgress = false;
    var progressed = true;
    while (progressed) {
      progressed = false;
      final order = List<int>.generate(_arrows.length, (i) => i)
        ..shuffle(random);
      for (final i in order) {
        if (_tryFrontOfHead(i)) {
          progressed = true;
          anyProgress = true;
        }
      }
    }
    return anyProgress;
  }

  bool _tryFrontOfHead(int i) {
    final arrow = _arrows[i];
    if (arrow.length < 2) return false;

    final head = arrow.last;
    final beforeHead = arrow[arrow.length - 2];
    final dx = head.dx.toInt() - beforeHead.dx.toInt();
    final dy = head.dy.toInt() - beforeHead.dy.toInt();

    final run = <Offset>[];
    var x = head.dx.toInt() + dx;
    var y = head.dy.toInt() + dy;
    var reachedEdge = false;
    while (true) {
      if (x < 0 || y < 0 || x >= cols || y >= rows) {
        reachedEdge = true;
        break;
      }
      final k = _keyFor(x, y);
      if (!_free.contains(k)) break;
      run.add(Offset(x.toDouble(), y.toDouble()));
      x += dx;
      y += dy;
    }
    // If the run was blocked by a placed cell (not the board edge), any
    // arrow we place here would have that cell in its own forward ray
    // and immediately fail [_validate]. Leave the gap alone.
    if (!reachedEdge) return false;

    // Leave the very last cell of the run free so the new head keeps a
    // non-zero forward ray and doesn't turn into an outward-off-board
    // spike.
    final maxL = run.length - 1;
    if (maxL < minLen) return false;

    // Randomise length to avoid monotonous repeats. Iterating the pass
    // picks up whatever free cells remain.
    final upper = maxL < maxLen ? maxL : maxLen;
    final len = minLen + random.nextInt(upper - minLen + 1);
    final path = run.sublist(0, len);
    if (!_validate(path)) return false;
    _commit(path);
    return true;
  }

  int _countBends(List<Offset> path) {
    if (path.length < 3) return 0;
    var bends = 0;
    var prevDir = path[1] - path[0];
    for (int k = 2; k < path.length; k++) {
      final dir = path[k] - path[k - 1];
      if (dir != prevDir) bends++;
      prevDir = dir;
    }
    return bends;
  }

  /// Chebyshev-style distance from a cell to the nearest board edge.
  /// Cells on the outermost ring return 0; the centermost cells return
  /// `min(rows, cols) ~/ 2`.
  int _edgeDistance(int key) {
    final col = key % cols;
    final row = key ~/ cols;
    var d = col;
    final right = cols - 1 - col;
    if (right < d) d = right;
    if (row < d) d = row;
    final bottom = rows - 1 - row;
    if (bottom < d) d = bottom;
    return d;
  }

  /// Tries to produce a valid arrow starting at [startKey]. Returns null
  /// if every attempted random walk (and both orientations of each)
  /// fails the placement rules.
  ///
  /// Orientations with a head-forward ray of length 0 — i.e. the head
  /// sits on the boundary and points off-board — are always rejected.
  /// This is what eliminates the "spike pointing straight off the grid"
  /// pattern: boundary cells can still be filled, but only with heads
  /// pointing inward or parallel to the nearest edge; cells for which
  /// neither option validates are left as gaps.
  ///
  /// When [preferLongerRay] is true (the default) the orientation whose
  /// head-forward ray is longer wins, which biases mid-board arrows to
  /// face the larger open region. Callers that want orientation parity
  /// (notably the seed pass) can pass `false` for a fair coin-flip
  /// between the two valid orientations.
  List<Offset>? _tryBuildArrow({
    required int startKey,
    required int minLen,
    required int maxLen,
    required int attempts,
    bool preferLongerRay = true,
  }) {
    final start = Offset(
      (startKey % cols).toDouble(),
      (startKey ~/ cols).toDouble(),
    );
    // Try attempts spread across the length range, longest first, and
    // bias the first half of each start's attempts toward heavily-bent
    // walks. Late in generation the head direction is locked (see class
    // doc), so the *only* visible randomness we can inject at the edges
    // is the body shape. Preferring a bent candidate over a straight one
    // — and only falling back to the straight one if every bent walk
    // fails validation — is what breaks up the "spike at the boundary"
    // look.
    final lengthSpan = maxLen - minLen + 1;
    final boostedBend = (bendProbability + 0.55).clamp(0.0, 0.9);
    for (int attempt = 0; attempt < attempts; attempt++) {
      final targetLen = maxLen - (attempt % lengthSpan);
      final useBoosted = attempt < (attempts + 1) ~/ 2;
      final walk = _randomWalk(
        start: start,
        targetLen: targetLen,
        bendProb: useBoosted ? boostedBend : bendProbability,
      );
      if (walk.length < minLen) continue;

      final orientations = <List<Offset>>[
        walk,
        walk.reversed.toList(),
      ]..shuffle(random);
      if (preferLongerRay) {
        orientations.sort((a, b) => _rayLength(b).compareTo(_rayLength(a)));
      }
      for (final oriented in orientations) {
        if (_rayLength(oriented) == 0) continue;
        if (_validate(oriented)) return oriented;
      }
    }
    return null;
  }

  /// Number of cells from the cell immediately past the head to the
  /// board edge, in the head's direction. 0 when the head is already on
  /// the boundary with its direction pointing off-board.
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

  /// Grows a random walk over free cells. Prefers to keep direction;
  /// turns with probability [bendProb], up to [maxBends] turns. Never
  /// revisits a cell and never reverses direction. [bendProb] defaults
  /// to the configured [bendProbability] but callers can override it
  /// per-walk to push shapes toward bendier or straighter variants.
  List<Offset> _randomWalk({
    required Offset start,
    required int targetLen,
    double? bendProb,
  }) {
    final effectiveBend = bendProb ?? bendProbability;
    final path = <Offset>[start];
    final used = <int>{_keyFor(start.dx.toInt(), start.dy.toInt())};
    Offset? lastDir;
    int bends = 0;

    while (path.length < targetLen) {
      final current = path.last;
      final options = <_WalkOption>[];

      for (final dir in _directions) {
        if (lastDir != null && dir == -lastDir) continue;
        final next = current + dir;
        if (!_isInside(next)) continue;
        final nextKey = _keyFor(next.dx.toInt(), next.dy.toInt());
        if (!_free.contains(nextKey) || used.contains(nextKey)) continue;

        final double weight;
        if (lastDir == null) {
          weight = 1.0;
        } else if (dir == lastDir) {
          weight = 1.0 - effectiveBend;
        } else {
          if (bends >= maxBends) continue;
          weight = effectiveBend / 2.0;
        }
        if (weight <= 0) continue;
        options.add(_WalkOption(cell: next, dir: dir, weight: weight));
      }

      if (options.isEmpty) break;
      final chosen = _weightedPick(options);
      if (lastDir != null && chosen.dir != lastDir) bends++;
      path.add(chosen.cell);
      used.add(_keyFor(chosen.cell.dx.toInt(), chosen.cell.dy.toInt()));
      lastDir = chosen.dir;
    }
    return path;
  }

  _WalkOption _weightedPick(List<_WalkOption> options) {
    double total = 0;
    for (final option in options) {
      total += option.weight;
    }
    var pick = random.nextDouble() * total;
    for (final option in options) {
      pick -= option.weight;
      if (pick <= 0) return option;
    }
    return options.last;
  }

  /// Placement rule check for a fully oriented arrow path (tail → head).
  ///
  /// Walks the head-forward ray to the board edge: it must not cross any
  /// of this arrow's own cells (self-bite) nor any previously placed
  /// cell (solvability). Two arrows facing *toward* each other are
  /// automatically rejected by this check — each sees the other in its
  /// ray. Arrows facing *away* in the same row/column are allowed on
  /// purpose.
  bool _validate(List<Offset> path) {
    if (path.length < 2) return true;

    final head = path.last;
    final beforeHead = path[path.length - 2];
    final dx = head.dx.toInt() - beforeHead.dx.toInt();
    final dy = head.dy.toInt() - beforeHead.dy.toInt();

    final pathKeys = <int>{
      for (final cell in path) _keyFor(cell.dx.toInt(), cell.dy.toInt()),
    };
    var x = head.dx.toInt() + dx;
    var y = head.dy.toInt() + dy;
    while (x >= 0 && y >= 0 && x < cols && y < rows) {
      final key = _keyFor(x, y);
      if (pathKeys.contains(key)) return false;
      if (_placed.contains(key)) return false;
      x += dx;
      y += dy;
    }
    return true;
  }

  void _commit(List<Offset> path) {
    final index = _arrows.length;
    _arrows.add(path);
    _arrowRays.add(_computeHeadRay(path));
    for (final cell in path) {
      final key = _keyFor(cell.dx.toInt(), cell.dy.toInt());
      _free.remove(key);
      _placed.add(key);
      _placedBy[key] = index;
    }
  }

  /// Returns the set of cell keys strictly in front of the head, out to
  /// the board edge, in the head's direction. Empty for length-1 paths.
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

  /// Endpoint-absorption mop-up: absorb remaining free cells into
  /// neighboring arrows at either end.
  ///
  /// Tail extension keeps the head and ray fixed; head extension
  /// rebuilds the ray and re-validates it. Both are subject to the same
  /// invariant for other arrows: the new cell cannot land in the
  /// head-forward ray of any arrow placed *after* this one, since those
  /// are still present when this arrow is tapped in the solve.
  void _extensionPass() {
    if (_free.isEmpty) return;
    var progressed = true;
    while (progressed && _free.isNotEmpty) {
      progressed = false;
      final freeKeys = _free.toList()..shuffle(random);
      for (final cellKey in freeKeys) {
        if (!_free.contains(cellKey)) continue;
        // Leave the outermost ring alone: absorbing those cells is what
        // generates the perimeter spikes we're trying to avoid. Any gap
        // still sitting on the boundary after the fill pass is kept as
        // a gap on purpose.
        if (_edgeDistance(cellKey) == 0) continue;
        if (_tryAbsorbIntoNeighbor(cellKey)) progressed = true;
      }
    }
  }

  bool _tryAbsorbIntoNeighbor(int cellKey) {
    final cell = Offset(
      (cellKey % cols).toDouble(),
      (cellKey ~/ cols).toDouble(),
    );

    final order = List<int>.generate(_arrows.length, (i) => i)
      ..shuffle(random);

    for (final i in order) {
      final arrow = _arrows[i];

      // Tail extension: prepend when the cell touches the tail.
      if (_isOrthogonallyAdjacent(arrow.first, cell) &&
          _tryTailExtend(i, cell, cellKey)) {
        return true;
      }

      // Head extension: append when the cell touches the head. For
      // length-1 arrows `first == last`, so this branch gives the
      // opposite-orientation alternative to the tail branch above.
      if (_isOrthogonallyAdjacent(arrow.last, cell) &&
          _tryHeadExtend(i, cell, cellKey)) {
        return true;
      }
    }
    return false;
  }

  bool _tryTailExtend(int i, Offset cell, int cellKey) {
    // Self-bite: the added cell can't lie in this arrow's own forward ray.
    if (_arrowRays[i].contains(cellKey)) return false;
    // Can't block a later-placed arrow's forward ray.
    if (_isBlockedByLaterRay(i, cellKey)) return false;

    _arrows[i] = [cell, ..._arrows[i]];
    _free.remove(cellKey);
    _placed.add(cellKey);
    _placedBy[cellKey] = i;
    // Head and direction unchanged → _arrowRays[i] stays valid.
    return true;
  }

  bool _tryHeadExtend(int i, Offset cell, int cellKey) {
    // Can't block a later-placed arrow's forward ray.
    if (_isBlockedByLaterRay(i, cellKey)) return false;

    final arrow = _arrows[i];
    final oldHead = arrow.last;
    final newDx = cell.dx.toInt() - oldHead.dx.toInt();
    final newDy = cell.dy.toInt() - oldHead.dy.toInt();

    // Build the set of cells belonging to the *extended* arrow so we can
    // detect self-bite into the body (including back into the old head).
    final bodyKeys = <int>{cellKey};
    for (final c in arrow) {
      bodyKeys.add(_keyFor(c.dx.toInt(), c.dy.toInt()));
    }

    // Walk the new head-forward ray and check:
    //   - no self-bite (ray doesn't cross any of our own cells)
    //   - no block by an arrow placed *before* this one (those are still
    //     present when this arrow is tapped in the solve)
    final newRay = <int>{};
    var x = cell.dx.toInt() + newDx;
    var y = cell.dy.toInt() + newDy;
    while (x >= 0 && y >= 0 && x < cols && y < rows) {
      final k = _keyFor(x, y);
      if (bodyKeys.contains(k)) return false;
      final owner = _placedBy[k];
      if (owner != null && owner < i) return false;
      newRay.add(k);
      x += newDx;
      y += newDy;
    }

    _arrows[i] = [...arrow, cell];
    _arrowRays[i] = newRay;
    _free.remove(cellKey);
    _placed.add(cellKey);
    _placedBy[cellKey] = i;
    return true;
  }

  bool _isBlockedByLaterRay(int i, int cellKey) {
    for (int j = i + 1; j < _arrows.length; j++) {
      if (_arrowRays[j].contains(cellKey)) return true;
    }
    return false;
  }

  bool _isOrthogonallyAdjacent(Offset a, Offset b) {
    final dx = (a.dx - b.dx).abs();
    final dy = (a.dy - b.dy).abs();
    return (dx == 1 && dy == 0) || (dx == 0 && dy == 1);
  }

  bool _isInside(Offset cell) =>
      cell.dx >= 0 && cell.dy >= 0 && cell.dx < cols && cell.dy < rows;

  int _keyFor(int col, int row) => row * cols + col;
}

class _WalkOption {
  const _WalkOption({
    required this.cell,
    required this.dir,
    required this.weight,
  });
  final Offset cell;
  final Offset dir;
  final double weight;
}
