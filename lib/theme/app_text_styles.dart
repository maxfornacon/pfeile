import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import 'app_colors.dart';

abstract final class AppTextStyles {
  static TextStyle timer(BuildContext context, {Color? color}) {
    final base = GoogleFonts.nunito(
      textStyle: Theme.of(context).textTheme.headlineMedium,
      fontWeight: FontWeight.w600,
      fontFeatures: const [FontFeature.tabularFigures()],
      letterSpacing: 0.5,
    );
    return base.copyWith(
      color: color ?? base.color ?? AppColors.timerBase,
    );
  }

  static TextStyle penaltyFlashLarge() {
    return GoogleFonts.nunito(
      fontSize: 88,
      fontWeight: FontWeight.w500,
      height: 1.0,
      letterSpacing: -1.5,
      color: AppColors.accentDanger,
    );
  }

  static TextStyle helpFabCounter() {
    return const TextStyle(fontSize: 10, fontWeight: FontWeight.w600);
  }
}
