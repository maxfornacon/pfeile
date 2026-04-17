import 'dart:ui';

class Arrow {
  final List<Offset> points;
  final bool removed;

  const Arrow({
    required this.points,
    this.removed = false,
  });

  Arrow copyWith({
    List<Offset>? points,
    bool? removed,
  }) {
    return Arrow(
      points: points ?? this.points,
      removed: removed ?? this.removed,
    );
  }
}