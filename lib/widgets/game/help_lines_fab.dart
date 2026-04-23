import 'package:flutter/material.dart';

import '../../theme/app_text_styles.dart';

/// Toggles guide lines with a limited number of uses per level.
class HelpLinesFab extends StatelessWidget {
  const HelpLinesFab({
    super.key,
    required this.showHelpLines,
    required this.usesLeft,
    required this.onShow,
    required this.onHide,
  });

  final bool showHelpLines;
  final int usesLeft;
  final VoidCallback onShow;
  final VoidCallback onHide;

  @override
  Widget build(BuildContext context) {
    return FloatingActionButton(
      tooltip: showHelpLines
          ? 'Hide guide lines'
          : 'Show guide lines ($usesLeft/3)',
      onPressed:
          showHelpLines ? onHide : (usesLeft <= 0 ? null : onShow),
      backgroundColor: Colors.white,
      foregroundColor: Colors.black54,
      elevation: 2,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.lightbulb_outline),
          Text(
            '$usesLeft/3',
            style: AppTextStyles.helpFabCounter(),
          ),
        ],
      ),
    );
  }
}
