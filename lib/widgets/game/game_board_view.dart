import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../game/game_controller.dart';
import '../../game/game_layout.dart';
import '../../game/rendering/painters/arrows_painter.dart';
import '../../game/rendering/painters/grid_painter.dart';
import '../../game/rendering/painters/guide_lines_painter.dart';
import '../../game/animations/arrow_flight.dart';
import '../../models/arrow.dart';
import '../../theme/app_colors.dart';

/// Zoomable board, grid, arrows, optional guide lines, and tap handling.
class GameBoardView extends StatelessWidget {
  const GameBoardView({
    super.key,
    required this.transformationController,
    required this.boardInputStackKey,
    required this.arrows,
    required this.arrowCells,
    required this.occupancy,
    required this.activeFlights,
    required this.blockedFlights,
    required this.showHelpLines,
    required this.onEnsureCentered,
    required this.onCellInteraction,
  });

  final TransformationController transformationController;
  final GlobalKey boardInputStackKey;
  final List<Arrow> arrows;
  final Map<int, List<Offset>> arrowCells;
  final Map<String, List<int>> occupancy;
  final Map<int, RemovalFlight> activeFlights;
  final Map<int, BlockedSlideFlight> blockedFlights;
  final bool showHelpLines;
  final void Function(Size viewport, double contentWidth, double contentHeight)
      onEnsureCentered;
  final void Function(int col, int row) onCellInteraction;

  static final Offset _boardOrigin = Offset(
    GameLayout.boardTouchPad,
    GameLayout.boardTouchPad,
  );

  @override
  Widget build(BuildContext context) {
    final cellSize = GameLayout.cellSize;
    final boardWidth = GameController.cols * cellSize;
    final boardHeight = GameController.rows * cellSize;
    final contentWidth = boardWidth + 2 * GameLayout.boardTouchPad;
    final contentHeight = boardHeight + 2 * GameLayout.boardTouchPad;

    return LayoutBuilder(
      builder: (context, constraints) {
        final vp = constraints.biggest;
        onEnsureCentered(vp, contentWidth, contentHeight);

        return InteractiveViewer(
          transformationController: transformationController,
          constrained: false,
          clipBehavior: Clip.none,
          boundaryMargin: const EdgeInsets.all(400),
          minScale: 0.5,
          maxScale: 4.0,
          panEnabled: true,
          scaleEnabled: true,
          child: SizedBox(
            width: contentWidth,
            height: contentHeight,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                Positioned(
                  left: GameLayout.boardTouchPad,
                  top: GameLayout.boardTouchPad,
                  width: boardWidth,
                  height: boardHeight,
                  child: CustomPaint(
                    painter: GridPainter(
                      rows: GameController.rows,
                      cols: GameController.cols,
                      cellSize: cellSize,
                      occupancy: occupancy,
                      activeFlights: activeFlights,
                      blockedFlights: blockedFlights,
                    ),
                  ),
                ),
                if (showHelpLines)
                  Positioned.fill(
                    child: IgnorePointer(
                      child: CustomPaint(
                        painter: GuideLinesPainter(
                          cellSize: cellSize,
                          arrows: arrows,
                          arrowCells: arrowCells,
                          activeFlights: activeFlights,
                          blockedFlights: blockedFlights,
                          boardOrigin: _boardOrigin,
                        ),
                      ),
                    ),
                  ),
                Positioned.fill(
                  child: GestureDetector(
                    onTapUp: (details) {
                      final box = boardInputStackKey.currentContext
                          ?.findRenderObject() as RenderBox?;
                      if (box == null || !box.hasSize) return;
                      var p = box.globalToLocal(details.globalPosition);
                      p = Offset(
                        p.dx.clamp(0.0, box.size.width).toDouble(),
                        p.dy.clamp(0.0, box.size.height).toDouble(),
                      );
                      var bx = p.dx - GameLayout.boardTouchPad;
                      var by = p.dy - GameLayout.boardTouchPad;
                      bx = bx.clamp(0.0, boardWidth - 1e-9);
                      by = by.clamp(0.0, boardHeight - 1e-9);
                      final col = math.min(
                        GameController.cols - 1,
                        math.max(0, (bx / cellSize).floor()),
                      );
                      final row = math.min(
                        GameController.rows - 1,
                        math.max(0, (by / cellSize).floor()),
                      );
                      onCellInteraction(col, row);
                    },
                    child: Stack(
                      key: boardInputStackKey,
                      clipBehavior: Clip.none,
                      fit: StackFit.expand,
                      children: [
                        Positioned.fill(
                          child: ColoredBox(
                            color: AppColors.boardHitBase,
                          ),
                        ),
                        Positioned(
                          left: GameLayout.boardTouchPad,
                          top: GameLayout.boardTouchPad,
                          width: boardWidth,
                          height: boardHeight,
                          child: CustomPaint(
                            painter: ArrowsPainter(
                              cellSize: cellSize,
                              arrows: arrows,
                              arrowCells: arrowCells,
                              activeFlights: activeFlights,
                              blockedFlights: blockedFlights,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
