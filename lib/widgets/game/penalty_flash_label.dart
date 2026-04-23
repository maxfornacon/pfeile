import 'package:flutter/material.dart';

import '../../theme/app_text_styles.dart';

/// Large “+5” seconds penalty feedback when a blocked arrow hits.
class PenaltyFlashLabel extends StatelessWidget {
  const PenaltyFlashLabel({
    super.key,
    required this.strength,
  });

  final double strength;

  @override
  Widget build(BuildContext context) {
    if (strength <= 0.001) return const SizedBox.shrink();
    return IgnorePointer(
      child: Center(
        child: Opacity(
          opacity: strength,
          child: Transform.scale(
            scale: 1.0 +
                Curves.easeIn.transform(
                  (1.0 - strength).clamp(0.0, 1.0),
                ) *
                    1.75,
            child: Text(
              '+5',
              style: AppTextStyles.penaltyFlashLarge(),
            ),
          ),
        ),
      ),
    );
  }
}
