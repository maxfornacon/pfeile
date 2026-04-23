import 'package:flutter/material.dart';

/// Central palette for the game UI and painters.
abstract final class AppColors {
  static const Color scaffoldBackground = Colors.white;

  static const Color boardHitBase = Color(0x01FFFFFF);

  static const Color timerBase = Color(0xFF1C1B1F);

  static const Color accentDanger = Color(0xFFC62828);

  static const Color damageRedDeep = Color(0xFFB71C1C);

  static const Color damageRedMid = Color(0xFFE53935);

  static const Color guideLine = Color(0xFFCFD8DC);

  static const List<Color> arrowPalette = <Color>[
    Colors.blue,
    Colors.teal,
    Colors.deepOrange,
    Colors.purple,
    Colors.brown,
    Colors.indigo,
  ];
}
