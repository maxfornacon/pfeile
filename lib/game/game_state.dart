import '../models/arrow.dart';

class GameState {
  final List<Arrow> arrows;
  final int levelId;

  const GameState({required this.arrows, this.levelId = 0});

  GameState copyWith({List<Arrow>? arrows, int? levelId}) {
    return GameState(
      arrows: arrows ?? this.arrows,
      levelId: levelId ?? this.levelId,
    );
  }
}
