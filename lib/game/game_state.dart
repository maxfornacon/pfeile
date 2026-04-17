import '../models/arrow.dart';

class GameState {
  final List<Arrow> arrows;
  final int lives;

  const GameState({
    required this.arrows,
    this.lives = 3,
  });

  GameState copyWith({
    List<Arrow>? arrows,
    int? lives,
  }) {
    return GameState(
      arrows: arrows ?? this.arrows,
      lives: lives ?? this.lives,
    );
  }
}