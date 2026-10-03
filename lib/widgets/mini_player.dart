/*
 *     Copyright (C) 2026 Víctor Castilla
 *
 *     DSK Play is free software: you can redistribute it and/or modify
 *     it under the terms of the GNU General Public License as published by
 *     the Free Software Foundation, either version 3 of the License, or
 *     (at your option) any later version.
 *
 *     DSK Play is distributed in the hope that it will be useful,
 *     but WITHOUT ANY WARRANTY; without even the implied warranty of
 *     MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 *     GNU General Public License for more details.
 *
 *     You should have received a copy of the GNU General Public License
 *     along with this program.  If not, see <https://www.gnu.org/licenses/>.
 *
 *
 *     For more information about DSK Play, including how to contribute,
 *     please visit: https://dskmusic.com or https://github.com/dskmusic
 */

import 'dart:math' as math;

import 'package:audio_service/audio_service.dart';
import 'package:dskplay/main.dart';
import 'package:dskplay/models/position_data.dart';
import 'package:dskplay/screens/now_playing_page.dart';
import 'package:dskplay/widgets/marquee.dart';
import 'package:dskplay/widgets/song_artwork.dart';
import 'package:fluentui_system_icons/fluentui_system_icons.dart';
import 'package:flutter/material.dart';
import 'package:rxdart/rxdart.dart';

/// Lo unico del mini player que no depende del reloj: cambia al pausar, al
/// pasar de cancion o al tocar la cola.
typedef PlayerChrome = ({
  bool playing,
  AudioProcessingState processingState,
  bool hasNext,
});

/// Recorta de [state] lo que el mini player pinta de verdad.
///
/// `playbackState` emite tambien al avanzar la posicion, y de todo lo que
/// trae aqui solo se usan tres campos: quedandose con ellos, dos estados que
/// solo difieran en el reloj salen iguales y el `distinct` de abajo los tira.
PlayerChrome playerChromeOf(PlaybackState state, List<MediaItem> queue) => (
  playing: state.playing,
  processingState: state.processingState,
  hasNext: queue.length > 1 && (state.queueIndex ?? 0) < queue.length - 1,
);

/// La posicion se queda fuera a proposito.
///
/// Antes entraba aqui y el `StreamBuilder` que cuelga de este stream
/// reconstruia el mini player entero —portada, marquesina, titulo, artista—
/// varias veces por segundo, cuando el unico que mira la posicion es el aro
/// de progreso del boton de play ([_ProgressRing]).
final Stream<PlayerChrome> _playerChromeStream = Rx.combineLatest2(
  audioHandler.playbackStateStream,
  audioHandler.queue.distinct(),
  playerChromeOf,
).distinct().asBroadcastStream();

PlayerChrome _chromeNow() => playerChromeOf(
  audioHandler.playbackState.valueOrNull ?? PlaybackState(),
  audioHandler.queue.valueOrNull ?? const <MediaItem>[],
);

class MiniPlayer extends StatelessWidget {
  const MiniPlayer({super.key});

  static const double playerHeight = 72;
  static const double _borderRadius = 20;
  static const double _artworkSize = 52;
  static const double _artworkRadius = 14;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return AnimatedSize(
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOutCubic,
      child: StreamBuilder<MediaItem?>(
        stream: audioHandler.mediaItem,
        builder: (context, mediaSnapshot) {
          final metadata = mediaSnapshot.data;
          if (metadata == null) return const SizedBox.shrink();

          return StreamBuilder<PlayerChrome>(
            stream: _playerChromeStream,
            // playbackState/queue are already available synchronously (via
            // valueOrNull) the moment metadata is non-null - e.g. right after
            // a cold-start restore, which only seeds those two plus
            // mediaItem, not a live position tick. Without this, the mini
            // player would stay hidden until _playerChromeStream's
            // combineLatest happens to emit, which may lag behind the first
            // frame.
            initialData: _chromeNow(),
            builder: (context, stateSnapshot) {
              final chrome = stateSnapshot.data;
              if (chrome == null) return const SizedBox.shrink();

              return _MiniPlayerBody(
                colorScheme: colorScheme,
                metadata: metadata,
                chrome: chrome,
              );
            },
          );
        },
      ),
    );
  }
}

class _MiniPlayerBody extends StatefulWidget {
  const _MiniPlayerBody({
    required this.colorScheme,
    required this.metadata,
    required this.chrome,
  });

  final ColorScheme colorScheme;
  final MediaItem metadata;
  final PlayerChrome chrome;

  @override
  State<_MiniPlayerBody> createState() => _MiniPlayerBodyState();
}

class _MiniPlayerBodyState extends State<_MiniPlayerBody>
    with SingleTickerProviderStateMixin {
  late final AnimationController _animationController;
  late final Animation<double> _scaleAnimation;

  @override
  void initState() {
    super.initState();
    _animationController = AnimationController(
      duration: const Duration(milliseconds: 100),
      vsync: this,
    );
    _scaleAnimation = Tween<double>(begin: 1, end: 0.98).animate(
      CurvedAnimation(parent: _animationController, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _animationController.dispose();
    super.dispose();
  }

  static const double _dragThresholdForNavigation = 10;

  void _handleVerticalDrag(DragUpdateDetails details) {
    if ((details.primaryDelta ?? 0) < -_dragThresholdForNavigation) {
      _navigateToNowPlaying();
    }
  }

  void _navigateToNowPlaying() {
    Navigator.of(context).push(createNowPlayingRoute());
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = widget.colorScheme;
    final metadata = widget.metadata;

    return AnimatedBuilder(
      animation: _scaleAnimation,
      builder: (context, child) {
        return Transform.scale(
          scale: _scaleAnimation.value,
          child: GestureDetector(
            onTapDown: (_) => _animationController.forward(),
            onTapUp: (_) => _animationController.reverse(),
            onTapCancel: () => _animationController.reverse(),
            onVerticalDragUpdate: _handleVerticalDrag,
            onTap: _navigateToNowPlaying,
            child: Container(
              height: MiniPlayer.playerHeight,
              decoration: BoxDecoration(
                color: colorScheme.surfaceContainerHigh,
                borderRadius: BorderRadius.circular(MiniPlayer._borderRadius),
                boxShadow: [
                  BoxShadow(
                    color: colorScheme.shadow.withValues(alpha: 0.08),
                    blurRadius: 8,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(MiniPlayer._borderRadius),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  child: Row(
                    children: [
                      _ArtworkWidget(metadata: metadata),
                      Expanded(
                        child: AnimatedSwitcher(
                          duration: const Duration(milliseconds: 300),
                          switchInCurve: Curves.easeIn,
                          switchOutCurve: Curves.easeOut,
                          layoutBuilder: (currentChild, previousChildren) =>
                              Stack(
                                alignment: Alignment.centerLeft,
                                children: [
                                  ...previousChildren,
                                  if (currentChild != null) currentChild,
                                ],
                              ),
                          transitionBuilder: (child, animation) =>
                              FadeTransition(opacity: animation, child: child),
                          child: KeyedSubtree(
                            key: ValueKey(metadata.id),
                            child: _MetadataWidget(
                              title: metadata.title,
                              artist: metadata.artist,
                              colorScheme: colorScheme,
                            ),
                          ),
                        ),
                      ),
                      _ControlsWidget(
                        colorScheme: colorScheme,
                        chrome: widget.chrome,
                        fallbackDuration: metadata.duration ?? Duration.zero,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _ArtworkWidget extends StatelessWidget {
  const _ArtworkWidget({required this.metadata});
  final MediaItem metadata;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(right: 12),
      child: Hero(
        tag: 'now_playing_artwork',
        child: DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(MiniPlayer._artworkRadius),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.1),
                blurRadius: 4,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: SongArtworkWidget(
            metadata: metadata,
            size: MiniPlayer._artworkSize,
            errorWidgetIconSize: 24,
            borderRadius: MiniPlayer._artworkRadius,
          ),
        ),
      ),
    );
  }
}

class _MetadataWidget extends StatelessWidget {
  const _MetadataWidget({
    required this.title,
    required this.artist,
    required this.colorScheme,
  });

  final String title;
  final String? artist;
  final ColorScheme colorScheme;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          MarqueeWidget(
            manualScrollEnabled: false,
            animationDuration: const Duration(seconds: 8),
            backDuration: const Duration(seconds: 2),
            pauseDuration: const Duration(seconds: 2),
            child: Text(
              title,
              style: TextStyle(
                color: colorScheme.secondary,
                fontSize: 15,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.1,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (artist != null && artist!.isNotEmpty) ...[
            const SizedBox(height: 2),
            Text(
              artist!,
              style: TextStyle(
                color: colorScheme.onSurfaceVariant,
                fontSize: 13,
                fontWeight: FontWeight.w400,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ],
      ),
    );
  }
}

class _ControlsWidget extends StatelessWidget {
  const _ControlsWidget({
    required this.colorScheme,
    required this.chrome,
    required this.fallbackDuration,
  });

  final ColorScheme colorScheme;
  final PlayerChrome chrome;

  /// Duracion del `MediaItem`, para el aro mientras el reproductor aun no ha
  /// dicho la suya.
  final Duration fallbackDuration;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _CircularPlayButton(
          colorScheme: colorScheme,
          chrome: chrome,
          fallbackDuration: fallbackDuration,
        ),
        if (chrome.hasNext) ...[
          const SizedBox(width: 4),
          IconButton(
            onPressed: audioHandler.skipToNext,
            splashColor: Colors.transparent,
            highlightColor: Colors.transparent,
            icon: Icon(
              FluentIcons.next_24_filled,
              color: colorScheme.onSurfaceVariant,
              size: 24,
            ),
            visualDensity: VisualDensity.compact,
          ),
        ],
      ],
    );
  }
}

class _CircularPlayButton extends StatelessWidget {
  const _CircularPlayButton({
    required this.colorScheme,
    required this.chrome,
    required this.fallbackDuration,
  });

  final ColorScheme colorScheme;
  final PlayerChrome chrome;
  final Duration fallbackDuration;

  @override
  Widget build(BuildContext context) {
    final processingState = chrome.processingState;
    final isPlaying = chrome.playing;
    final isLoading =
        processingState == AudioProcessingState.loading ||
        processingState == AudioProcessingState.buffering;
    final isCompleted = processingState == AudioProcessingState.completed;

    return SizedBox(
      width: 48,
      height: 48,
      child: Stack(
        alignment: Alignment.center,
        children: [
          _ProgressRing(
            backgroundColor: colorScheme.surfaceContainerHighest,
            progressColor: colorScheme.primary,
            fallbackDuration: fallbackDuration,
          ),
          if (isLoading)
            SizedBox(
              width: 24,
              height: 24,
              child: CircularProgressIndicator(
                strokeWidth: 2.5,
                valueColor: AlwaysStoppedAnimation<Color>(colorScheme.primary),
              ),
            )
          else
            IconButton(
              onPressed: isCompleted
                  ? () => audioHandler.playAgain()
                  : (isPlaying ? audioHandler.pause : audioHandler.play),
              splashColor: Colors.transparent,
              highlightColor: Colors.transparent,
              icon: Icon(
                isCompleted
                    ? FluentIcons.arrow_counterclockwise_24_filled
                    : (isPlaying
                          ? FluentIcons.pause_16_filled
                          : FluentIcons.play_16_filled),
                color: colorScheme.primary,
                size: 22,
              ),
              visualDensity: VisualDensity.compact,
            ),
        ],
      ),
    );
  }
}

/// Lo unico del mini player suscrito a la posicion. El `RepaintBoundary` corta
/// aqui el repintado: lo de alrededor no se entera de que el aro avanza.
class _ProgressRing extends StatelessWidget {
  const _ProgressRing({
    required this.backgroundColor,
    required this.progressColor,
    required this.fallbackDuration,
  });

  final Color backgroundColor;
  final Color progressColor;
  final Duration fallbackDuration;

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: StreamBuilder<PositionData>(
        stream: audioHandler.positionDataStream,
        builder: (context, snapshot) {
          final data = snapshot.data;
          final total = (data?.duration ?? Duration.zero) > Duration.zero
              ? data!.duration
              : fallbackDuration;
          final progress = total.inMilliseconds == 0
              ? 0.0
              : ((data?.position.inMilliseconds ?? 0) / total.inMilliseconds)
                    .clamp(0.0, 1.0);

          return CustomPaint(
            size: const Size(48, 48),
            painter: _CircularProgressPainter(
              progress: progress,
              backgroundColor: backgroundColor,
              progressColor: progressColor,
              strokeWidth: 3,
            ),
          );
        },
      ),
    );
  }
}

class _CircularProgressPainter extends CustomPainter {
  _CircularProgressPainter({
    required this.progress,
    required this.backgroundColor,
    required this.progressColor,
    required this.strokeWidth,
  });

  final double progress;
  final Color backgroundColor;
  final Color progressColor;
  final double strokeWidth;

  final waveAmplitude = 1.5;
  final waveFrequency = 12.0;
  final animationValue = 0.0;

  Path _buildWavyArcPath(Size size, double startAngle, double sweepAngle) {
    final cx = size.width / 2;
    final cy = size.height / 2;
    final baseRadius = (size.width - strokeWidth) / 2;
    final steps = (sweepAngle.abs() * 180 / math.pi).round().clamp(4, 720);
    final path = Path();

    for (var i = 0; i <= steps; i++) {
      final t = i / steps;
      final angle = startAngle + sweepAngle * t;
      final wave =
          waveAmplitude * math.sin(waveFrequency * angle + animationValue);
      final r = baseRadius + wave;
      final x = cx + r * math.cos(angle);
      final y = cy + r * math.sin(angle);
      i == 0 ? path.moveTo(x, y) : path.lineTo(x, y);
    }
    return path;
  }

  @override
  void paint(Canvas canvas, Size size) {
    final trackPaint = Paint()
      ..color = backgroundColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    canvas.drawPath(
      _buildWavyArcPath(size, -math.pi / 2, 2 * math.pi),
      trackPaint,
    );

    if (progress > 0) {
      final progressPaint = Paint()
        ..color = progressColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWidth
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round;

      canvas.drawPath(
        _buildWavyArcPath(size, -math.pi / 2, 2 * math.pi * progress),
        progressPaint,
      );
    }
  }

  @override
  bool shouldRepaint(_CircularProgressPainter old) =>
      old.progress != progress ||
      old.backgroundColor != backgroundColor ||
      old.progressColor != progressColor ||
      old.animationValue != animationValue;
}
