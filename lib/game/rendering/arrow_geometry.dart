import 'dart:ui';

/// Same corner rounding as [buildRoundedArrowPath] stroke — used for removal sampling.
Path buildRoundedArrowPath(List<Offset> points, double cornerRadius) {
  final path = Path();
  if (points.isEmpty) return path;
  if (points.length == 1) {
    path.moveTo(points.first.dx, points.first.dy);
    return path;
  }

  path.moveTo(points.first.dx, points.first.dy);
  for (int i = 1; i < points.length - 1; i++) {
    final prev = points[i - 1];
    final curr = points[i];
    final next = points[i + 1];

    final inVec = curr - prev;
    final outVec = next - curr;
    final inLen = inVec.distance;
    final outLen = outVec.distance;

    if (inLen == 0 || outLen == 0) {
      path.lineTo(curr.dx, curr.dy);
      continue;
    }

    final radius = cornerRadius < (inLen / 2) ? cornerRadius : (inLen / 2);
    final clampedRadius = radius < (outLen / 2) ? radius : (outLen / 2);

    final inDir = Offset(inVec.dx / inLen, inVec.dy / inLen);
    final outDir = Offset(outVec.dx / outLen, outVec.dy / outLen);

    final cornerStart = Offset(
      curr.dx - (inDir.dx * clampedRadius),
      curr.dy - (inDir.dy * clampedRadius),
    );
    final cornerEnd = Offset(
      curr.dx + (outDir.dx * clampedRadius),
      curr.dy + (outDir.dy * clampedRadius),
    );

    path.lineTo(cornerStart.dx, cornerStart.dy);
    path.quadraticBezierTo(curr.dx, curr.dy, cornerEnd.dx, cornerEnd.dy);
  }

  path.lineTo(points.last.dx, points.last.dy);
  return path;
}

List<double> _vertexDistancesAlongRoundedPath(
  PathMetric metric,
  List<Offset> centers,
) {
  final n = centers.length;
  final result = List<double>.filled(n, 0);
  if (n == 0) return result;
  result[0] = 0;
  final len = metric.length;
  if (len <= 0) return result;

  const samples = 256;
  for (int i = 1; i < n; i++) {
    final target = centers[i];
    var bestD = 0.0;
    var bestDist = double.infinity;
    for (int s = 0; s <= samples; s++) {
      final d = len * s / samples;
      final pos = metric.getTangentForOffset(d)?.position;
      if (pos == null) continue;
      final dist = (pos - target).distance;
      if (dist < bestDist) {
        bestDist = dist;
        bestD = d;
      }
    }
    result[i] = bestD < result[i - 1] ? result[i - 1] : bestD;
  }
  return result;
}

Offset _pointOnExtendedRoundedPathPixel(
  List<Offset> cells,
  Offset direction,
  double cellSize,
  double position,
  PathMetric metric,
  List<double> vertexDistances,
) {
  if (cells.isEmpty) return Offset.zero;

  final centers = cells
      .map(
        (c) => Offset((c.dx + 0.5) * cellSize, (c.dy + 0.5) * cellSize),
      )
      .toList();

  if (cells.length == 1) {
    return centers.first +
        Offset(
          direction.dx * position * cellSize,
          direction.dy * position * cellSize,
        );
  }

  final lastIndex = cells.length - 1;

  if (position <= 0) return centers.first;

  if (position <= lastIndex) {
    final lower = position.floor();
    final upper = (lower + 1).clamp(0, lastIndex);
    final t = position - lower;
    final d0 = vertexDistances[lower];
    final d1 = vertexDistances[upper];
    final dist = d0 + (d1 - d0) * t;
    final clamped = dist.clamp(0.0, metric.length);
    return metric.getTangentForOffset(clamped)!.position;
  }

  final extra = position - lastIndex;
  final endPos = metric.getTangentForOffset(metric.length)!.position;
  return endPos +
      Offset(direction.dx * extra * cellSize, direction.dy * extra * cellSize);
}

/// Grid coordinates along the same spine as the rounded on-screen stroke (for exit checks).
Offset _pointOnExtendedRoundedPathGrid(
  List<Offset> cells,
  Offset direction,
  double cellSize,
  double position,
  PathMetric metric,
  List<double> vertexDistances,
) {
  final p = _pointOnExtendedRoundedPathPixel(
    cells,
    direction,
    cellSize,
    position,
    metric,
    vertexDistances,
  );
  return Offset(p.dx / cellSize - 0.5, p.dy / cellSize - 0.5);
}

List<Offset> straighteningCells(
  List<Offset> cells,
  Offset direction,
  double shift,
  double cellSize,
) {
  if (cells.isEmpty) return const <Offset>[];
  final cornerRadius = cellSize * 0.26;

  if (cells.length == 1) {
    return [
      cells.first + Offset(direction.dx * shift, direction.dy * shift),
    ];
  }

  final pixelCenters = cells
      .map(
        (c) => Offset((c.dx + 0.5) * cellSize, (c.dy + 0.5) * cellSize),
      )
      .toList();
  final path = buildRoundedArrowPath(pixelCenters, cornerRadius);
  final metric = path.computeMetrics().first;
  final vertexDistances = _vertexDistancesAlongRoundedPath(metric, pixelCenters);

  return List<Offset>.generate(cells.length, (i) {
    return _pointOnExtendedRoundedPathGrid(
      cells,
      direction,
      cellSize,
      i + shift,
      metric,
      vertexDistances,
    );
  });
}

double _gridSpinePositionToArcLength(
  double position,
  int lastIndex,
  List<double> vertexDistances,
  double pathLength,
) {
  if (position <= 0) return 0;
  if (position >= lastIndex) return pathLength;
  final lower = position.floor();
  final upper = (lower + 1).clamp(0, lastIndex);
  final t = position - lower;
  final d0 = vertexDistances[lower];
  final d1 = vertexDistances[upper];
  return d0 + (d1 - d0) * t;
}

/// Same rounded spine as static arrows, without polyline faceting — for removal /
/// blocked-slide strokes. [headDirection] is non-normalized for arrow head drawing.
(Path bodyPath, Offset tip, Offset headDirection) removalArrowStrokeGeometry(
  List<Offset> cells,
  Offset direction,
  double shift,
  double cellSize,
) {
  final cornerRadius = cellSize * 0.26;
  final empty = (Path(), Offset.zero, Offset(cellSize, 0.0));

  if (cells.length < 2) return empty;

  final lastIndex = cells.length - 1;
  final bodyLength = lastIndex.toDouble();
  final pos0 = shift;
  final pos1 = shift + bodyLength;
  if (pos1 <= pos0) return empty;

  final pixelCenters = cells
      .map(
        (c) => Offset((c.dx + 0.5) * cellSize, (c.dy + 0.5) * cellSize),
      )
      .toList();
  final rounded = buildRoundedArrowPath(pixelCenters, cornerRadius);
  final metric = rounded.computeMetrics().first;
  final vertexDistances = _vertexDistancesAlongRoundedPath(metric, pixelCenters);
  final pathLen = metric.length;

  double arcLen(double p) =>
      _gridSpinePositionToArcLength(p, lastIndex, vertexDistances, pathLen);

  Offset pointAt(double p) => _pointOnExtendedRoundedPathPixel(
        cells,
        direction,
        cellSize,
        p,
        metric,
        vertexDistances,
      );

  final tip = pointAt(pos1);
  final headDirection = pos1 > lastIndex + 1e-9
      ? Offset(direction.dx * cellSize, direction.dy * cellSize)
      : () {
          final dTip = arcLen(pos1.clamp(0.0, lastIndex.toDouble()))
              .clamp(0.0, pathLen);
          final tan = metric.getTangentForOffset(dTip);
          if (tan == null) {
            return Offset(direction.dx * cellSize, direction.dy * cellSize);
          }
          return Offset(tan.vector.dx, tan.vector.dy) * cellSize;
        }();

  if (pos0 >= lastIndex - 1e-9) {
    final start = pointAt(pos0);
    final path = Path()
      ..moveTo(start.dx, start.dy)
      ..lineTo(tip.dx, tip.dy);
    return (path, tip, headDirection);
  }

  final dStart =
      arcLen(pos0.clamp(0.0, lastIndex.toDouble())).clamp(0.0, pathLen);
  if (pos1 <= lastIndex + 1e-9) {
    final dEnd = arcLen(pos1).clamp(0.0, pathLen);
    if (dEnd > dStart + 1e-9) {
      final path = metric.extractPath(dStart, dEnd, startWithMoveTo: true);
      return (path, tip, headDirection);
    }
    final p0 = pointAt(pos0);
    final path = Path()
      ..moveTo(p0.dx, p0.dy)
      ..lineTo(tip.dx, tip.dy);
    return (path, tip, headDirection);
  }

  Path path;
  if (pathLen > dStart + 1e-9) {
    path = metric.extractPath(dStart, pathLen, startWithMoveTo: true);
  } else {
    final p0 = pointAt(pos0);
    path = Path()..moveTo(p0.dx, p0.dy);
  }
  final onCurveEnd = pointAt(lastIndex.toDouble());
  if ((tip - onCurveEnd).distance > 1e-4) {
    path.lineTo(tip.dx, tip.dy);
  }

  return (path, tip, headDirection);
}

List<Offset> removalPolylinePixelSamples(
  List<Offset> cells,
  Offset direction,
  double shift,
  double cellSize, {
  double spacing = 0.18,
}) {
  if (cells.isEmpty) return const <Offset>[];
  final cornerRadius = cellSize * 0.26;

  if (cells.length == 1) {
    final center = Offset(
      (cells.first.dx + 0.5) * cellSize,
      (cells.first.dy + 0.5) * cellSize,
    );
    return <Offset>[
      center +
          Offset(
            direction.dx * shift * cellSize,
            direction.dy * shift * cellSize,
          ),
    ];
  }

  final pixelCenters = cells
      .map(
        (c) => Offset((c.dx + 0.5) * cellSize, (c.dy + 0.5) * cellSize),
      )
      .toList();
  final path = buildRoundedArrowPath(pixelCenters, cornerRadius);
  final metric = path.computeMetrics().first;
  final vertexDistances = _vertexDistancesAlongRoundedPath(metric, pixelCenters);

  final bodyLength = (cells.length - 1).toDouble();
  final segments = (bodyLength / spacing).ceil();
  final sampleCount = segments < 1 ? 2 : segments + 1;
  final points = <Offset>[];
  for (int i = 0; i < sampleCount; i++) {
    final t = sampleCount > 1 ? i / (sampleCount - 1) : 0.0;
    final pos = shift + (bodyLength * t);
    points.add(
      _pointOnExtendedRoundedPathPixel(
        cells,
        direction,
        cellSize,
        pos,
        metric,
        vertexDistances,
      ),
    );
  }
  return points;
}
