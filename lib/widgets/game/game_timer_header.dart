import 'package:flutter/material.dart';

/// Stopwatch row shown while the level is in progress.
class GameTimerHeader extends StatelessWidget {
  const GameTimerHeader({
    super.key,
    required this.timerText,
    required this.style,
  });

  final String timerText;
  final TextStyle style;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      bottom: false,
      child: Padding(
        padding: const EdgeInsets.only(top: 8, left: 16, right: 16),
        child: SizedBox(
          width: double.infinity,
          child: Text(
            timerText,
            textAlign: TextAlign.center,
            style: style,
          ),
        ),
      ),
    );
  }
}
