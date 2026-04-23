import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../game/game_controller.dart';
import '../game/game_play_session.dart';
import '../game/rendering/painters/damage_edge_flash_painter.dart';
import '../theme/app_colors.dart';
import '../theme/app_text_styles.dart';
import '../widgets/game/game_board_view.dart';
import '../widgets/game/game_finished_overlay.dart';
import '../widgets/game/game_timer_header.dart';
import '../widgets/game/help_lines_fab.dart';
import '../widgets/game/penalty_flash_label.dart';

class GameScreen extends ConsumerStatefulWidget {
  const GameScreen({super.key});

  @override
  ConsumerState<GameScreen> createState() => _GameScreenState();
}

class _GameScreenState extends ConsumerState<GameScreen>
    with SingleTickerProviderStateMixin {
  final GamePlaySession _session = GamePlaySession();
  final GlobalKey _boardInputStackKey = GlobalKey();

  late final Ticker _ticker;
  late final TransformationController _viewerController;
  Size? _lastViewportForCentering;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker((_) => _onTick());
    _viewerController = TransformationController();
  }

  @override
  void dispose() {
    _ticker.dispose();
    _viewerController.dispose();
    super.dispose();
  }

  void _onTick() {
    final controller = ref.read(gameProvider.notifier);
    final needsTicks = _session.tick(controller);
    if (!needsTicks) _ticker.stop();
    setState(() {});
  }

  void _ensureCenteredTransform(
    Size viewport,
    double contentWidth,
    double contentHeight,
  ) {
    if (_lastViewportForCentering == viewport) return;
    _lastViewportForCentering = viewport;
    final tx = (viewport.width - contentWidth) / 2;
    final ty = (viewport.height - contentHeight) / 2;
    _viewerController.value = Matrix4.translationValues(tx, ty, 0);
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(gameProvider);
    if (_session.syncedLevelId != state.levelId) {
      final hadPrevious = _session.syncedLevelId != null;
      _session.syncedLevelId = state.levelId;
      _session.onNewLevelLoaded(hadPreviousLevel: hadPrevious);
    }

    final controller = ref.read(gameProvider.notifier);
    _session.syncRemovalFlights(controller, state.arrows);

    final hasActive =
        _session.activeFlights.isNotEmpty || _session.blockedFlights.isNotEmpty;
    if (hasActive && !_ticker.isActive) _ticker.start();
    if (!controller.isWin && !_ticker.isActive) _ticker.start();

    final occupancy = controller.occupancyMap();
    final arrowCells = <int, List<Offset>>{};
    for (int i = 0; i < state.arrows.length; i++) {
      arrowCells[i] = controller.cellsForArrow(state.arrows[i]);
    }

    final statusText = controller.isWin
        ? 'Level Cleared'
        : 'Tap free arrow heads to clear';

    final clockNow = DateTime.now();
    final damageStrength = _session.damageFlashStrength(clockNow);
    final penaltyStrength = _session.penaltyLabelStrength(clockNow);

    final timerText =
        GamePlaySession.formatStopwatch(_session.displayElapsedMs(clockNow));
    final baseTimerStyle = AppTextStyles.timer(context);
    final timerColor = Color.lerp(
      baseTimerStyle.color ?? AppColors.timerBase,
      AppColors.accentDanger,
      damageStrength,
    )!;

    void handleCellTap(int col, int row) {
      if (_session.showHelpLines) {
        setState(_session.hideHelpLines);
      }
      _session.levelClockStartedAt ??= DateTime.now();

      final tappedIndex = controller.topArrowIndexAtCell(col, row);
      if (tappedIndex == null) return;

      if (controller.tapCell(col, row)) {
        HapticFeedback.mediumImpact();
        return;
      }
      _session.startBlockedSlide(
        tappedIndex,
        controller,
        state.arrows[tappedIndex],
      );
      setState(() {});
    }

    return Scaffold(
      backgroundColor: AppColors.scaffoldBackground,
      floatingActionButton: _session.finishedElapsedMs != null
          ? null
          : HelpLinesFab(
              showHelpLines: _session.showHelpLines,
              usesLeft: _session.helpLineUsesLeft,
              onShow: () => setState(_session.tryShowHelpLines),
              onHide: () => setState(_session.hideHelpLines),
            ),
      body: Stack(
        children: [
          Column(
            children: [
              if (_session.finishedElapsedMs == null)
                GameTimerHeader(
                  timerText: timerText,
                  style: baseTimerStyle.copyWith(color: timerColor),
                )
              else
                const SafeArea(
                  bottom: false,
                  child: SizedBox(height: 8),
                ),
              Expanded(
                child: Transform.translate(
                  offset: _session.shakeOffset(clockNow),
                  child: ClipRect(
                    child: GameBoardView(
                      transformationController: _viewerController,
                      boardInputStackKey: _boardInputStackKey,
                      arrows: state.arrows,
                      arrowCells: arrowCells,
                      occupancy: occupancy,
                      activeFlights: _session.activeFlights,
                      blockedFlights: _session.blockedFlights,
                      showHelpLines: _session.showHelpLines,
                      onEnsureCentered: _ensureCenteredTransform,
                      onCellInteraction: handleCellTap,
                    ),
                  ),
                ),
              ),
              if (_session.finishedElapsedMs == null) ...[
                const SizedBox(height: 12),
                Text(statusText, style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 8),
                FilledButton(
                  onPressed: controller.newGame,
                  child: const Text('New Game'),
                ),
                const SizedBox(height: 12),
              ] else
                const SizedBox(height: 12),
            ],
          ),
          if (damageStrength > 0.001)
            Positioned.fill(
              child: IgnorePointer(
                child: CustomPaint(
                  painter: DamageEdgeFlashPainter(strength: damageStrength),
                ),
              ),
            ),
          if (penaltyStrength > 0.001)
            Positioned.fill(
              child: PenaltyFlashLabel(strength: penaltyStrength),
            ),
          if (_session.finishedElapsedMs != null)
            Positioned.fill(
              child: GameFinishedOverlay(
                timeText: GamePlaySession.formatStopwatch(
                  _session.finishedElapsedMs!,
                ),
                onNewGame: controller.newGame,
              ),
            ),
        ],
      ),
    );
  }
}
