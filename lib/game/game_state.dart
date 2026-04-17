import '../models/arrow.dart';

class GameState {
  final List<Arrow> arrows;

  const GameState({required this.arrows});

  GameState copyWith({List<Arrow>? arrows}) {
    return GameState(arrows: arrows ?? this.arrows);
  }
}
