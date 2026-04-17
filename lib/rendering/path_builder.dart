import 'dart:ui';

Path buildPath(List<Offset> points) {
  final path = Path();

  if (points.isEmpty) return path;

  path.moveTo(points.first.dx, points.first.dy);

  for (final p in points.skip(1)) {
    path.lineTo(p.dx, p.dy);
  }

  return path;
}