import 'dart:ui';

import 'package:flutter/material.dart';

class PathAnimation extends StatefulWidget {
  final Path path;
  final Widget child;
  final Duration duration;

  const PathAnimation({
    super.key,
    required this.path,
    required this.child,
    required this.duration,
  });

  @override
  State<PathAnimation> createState() => _PathAnimationState();
}

class _PathAnimationState extends State<PathAnimation>
    with SingleTickerProviderStateMixin {
  late AnimationController controller;
  late PathMetric pathMetric;

  @override
  void initState() {
    super.initState();

    final metrics = widget.path.computeMetrics();
    pathMetric = metrics.first;

    controller = AnimationController(
      vsync: this,
      duration: widget.duration,
    )
      ..forward();
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, child) {
        final distance = pathMetric.length * controller.value;
        final tangent = pathMetric.getTangentForOffset(distance);

        final pos = tangent?.position ?? Offset.zero;

        return Transform.translate(
          offset: pos,
          child: widget.child,
        );
      },
    );
  }
}