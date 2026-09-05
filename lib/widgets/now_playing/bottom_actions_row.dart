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

import 'package:audio_service/audio_service.dart';
import 'package:dskplay/extensions/l10n.dart';
import 'package:dskplay/main.dart';
import 'package:dskplay/services/common_services.dart';
import 'package:dskplay/services/settings_manager.dart';
import 'package:dskplay/utilities/flutter_bottom_sheet.dart';
import 'package:dskplay/utilities/flutter_toast.dart';
import 'package:dskplay/utilities/mediaitem.dart';
import 'package:dskplay/utilities/playlist_dialogs.dart';
import 'package:dskplay/widgets/confirmation_dialog.dart';
import 'package:dskplay/widgets/queue_list_view.dart';
import 'package:fluentui_system_icons/fluentui_system_icons.dart';
import 'package:flutter/material.dart';

class BottomActionsRow extends StatefulWidget {
  const BottomActionsRow({
    super.key,
    required this.metadata,
    required this.iconSize,
    required this.isLargeScreen,
    required this.lyricsController,
  });
  final MediaItem metadata;
  final double iconSize;
  final bool isLargeScreen;
  final dynamic lyricsController;

  @override
  State<BottomActionsRow> createState() => _BottomActionsRowState();
}

class _BottomActionsRowState extends State<BottomActionsRow> {
  late final ValueNotifier<bool> _songLikeStatus;
  // metadata.id is a per-queue-slot id (see QueueEntryIdManager), not the
  // song's real ytid, so like/offline status must key off the ytid extra.
  // Computed as getters (not `late final`) because this State is reused
  // across queue skips within the same playlist/album - a cached value
  // would keep pointing at whatever song was playing when the State was
  // first created.
  String? get audioId =>
      (widget.metadata.extras?['ytid'] as String?) ?? widget.metadata.id;
  bool get isRadioStation => widget.metadata.extras?['isLive'] ?? false;

  @override
  void initState() {
    super.initState();
    if (isRadioStation) {
      _songLikeStatus = ValueNotifier<bool>(isRadioStationLiked(audioId ?? ''));
      userLikedRadioStations.addListener(_syncRadioLikeStatus);
    } else {
      _songLikeStatus = ValueNotifier<bool>(isSongAlreadyLiked(audioId));
      userLikedSongsList.addListener(_syncLikeStatus);
    }
  }

  void _syncLikeStatus() {
    final newStatus = isSongAlreadyLiked(audioId);
    if (_songLikeStatus.value != newStatus) {
      _songLikeStatus.value = newStatus;
    }
  }

  void _syncRadioLikeStatus() {
    final newStatus = isRadioStationLiked(audioId ?? '');
    if (_songLikeStatus.value != newStatus) {
      _songLikeStatus.value = newStatus;
    }
  }

  @override
  void didUpdateWidget(BottomActionsRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.metadata.id != widget.metadata.id) {
      if (isRadioStation) {
        _songLikeStatus.value = isRadioStationLiked(audioId ?? '');
      } else {
        _songLikeStatus.value = isSongAlreadyLiked(audioId);
      }
    }
  }

  @override
  void dispose() {
    if (isRadioStation) {
      userLikedRadioStations.removeListener(_syncRadioLikeStatus);
    } else {
      userLikedSongsList.removeListener(_syncLikeStatus);
    }
    _songLikeStatus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final l10n = context.l10n!;

    final screenWidth = MediaQuery.sizeOf(context).width;
    final responsiveIconSize = screenWidth < 360
        ? widget.iconSize * 0.85
        : widget.iconSize;

    return StreamBuilder<List<Map>>(
      stream: audioHandler.queueAsMapStream,
      builder: (context, snapshot) {
        final queue = snapshot.data ?? [];

        final actions = <Widget>[
          // Always the speed control here (music and podcasts alike) - the
          // offline/download action still exists elsewhere in the app (e.g.
          // library rows), just not duplicated in this bar anymore.
          if (!isRadioStation)
            _buildPlaybackSpeedButton(context, colorScheme, responsiveIconSize),
          _buildSleepTimerButton(context, colorScheme, responsiveIconSize),
          if (!offlineMode.value && !isRadioStation)
            _buildSimpleActionButton(
              context: context,
              icon: FluentIcons.album_add_24_regular,
              colorScheme: colorScheme,
              size: responsiveIconSize,
              onPressed: () => showAddToPlaylistDialog(
                context,
                song: mediaItemToMap(widget.metadata),
              ),
              tooltip: l10n.addToPlaylist,
            ),
          if (queue.isNotEmpty && !isRadioStation && !widget.isLargeScreen)
            _buildSimpleActionButton(
              context: context,
              icon: FluentIcons.apps_list_24_filled,
              colorScheme: colorScheme,
              size: responsiveIconSize,
              onPressed: () => showCustomBottomSheet(
                context,
                const QueueWidget(isBottomSheet: true),
              ),
              tooltip: l10n.queue,
            ),
          if (!offlineMode.value) ...[
            if (!isRadioStation)
              _buildSimpleActionButton(
                context: context,
                icon: FluentIcons.text_quote_24_regular,
                colorScheme: colorScheme,
                size: responsiveIconSize,
                onPressed: widget.lyricsController.flipcard,
                tooltip: l10n.lyrics,
              ),
            _buildActionButton(
              context: context,
              icon: FluentIcons.heart_24_regular,
              activeIcon: FluentIcons.heart_24_filled,
              colorScheme: colorScheme,
              size: responsiveIconSize,
              statusNotifier: _songLikeStatus,
              activeColor: colorScheme.primary,
              onPressed: () async {
                final id = audioId;
                if (id == null) return;

                final originalValue = _songLikeStatus.value;

                // Este corazón es de los botones más fáciles de rozar sin
                // querer, así que cualquier quitado -- canción, episodio o
                // emisora -- pasa por la confirmación. Antes sólo preguntaba
                // en los episodios de podcast, y con el texto a pelo en
                // castellano.
                if (originalValue) {
                  final confirmed = await showDialog<bool>(
                    context: context,
                    builder: (dialogContext) => ConfirmationDialog(
                      confirmationMessage:
                          dialogContext.l10n!.removeFromFavoritesConfirm,
                      submitMessage: dialogContext.l10n!.remove,
                      isDangerous: true,
                      onCancel: () => Navigator.of(dialogContext).pop(false),
                      onSubmit: () => Navigator.of(dialogContext).pop(true),
                    ),
                  );
                  if (confirmed != true || !mounted) return;
                }

                _songLikeStatus.value = !originalValue;

                try {
                  if (isRadioStation) {
                    if (originalValue) {
                      await removeRadioStationFromLiked(id);
                    } else {
                      await addRadioStationToLiked(id);
                    }
                  } else {
                    await updateSongLikeStatus(
                      audioId,
                      !originalValue,
                      songData: mediaItemToMap(widget.metadata),
                    );
                  }
                } catch (e) {
                  _songLikeStatus.value = originalValue; // revert on failure
                  logger.log('Error toggling like status', error: e);
                }
              },
              tooltip: l10n.likedSongs,
            ),
          ],
        ];

        return Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: colorScheme.surfaceContainerHigh,
            borderRadius: BorderRadius.circular(20),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: actions,
          ),
        );
      },
    );
  }

  Widget _buildActionButton({
    required BuildContext context,
    required IconData icon,
    required IconData activeIcon,
    required ColorScheme colorScheme,
    required double size,
    required ValueNotifier<bool> statusNotifier,
    required VoidCallback? onPressed,
    Color? activeColor,
    String? tooltip,
  }) {
    return ValueListenableBuilder<bool>(
      valueListenable: statusNotifier,
      builder: (_, isActive, __) {
        return IconButton(
          icon: Icon(
            isActive ? activeIcon : icon,
            color: isActive
                ? (activeColor ?? colorScheme.primary)
                : colorScheme.onSurfaceVariant,
          ),
          iconSize: size,
          tooltip: tooltip,
          style: IconButton.styleFrom(
            backgroundColor: isActive
                ? (activeColor ?? colorScheme.primary).withValues(alpha: 0.15)
                : Colors.transparent,
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
          onPressed: onPressed,
        );
      },
    );
  }

  Widget _buildSimpleActionButton({
    required BuildContext context,
    required IconData icon,
    required ColorScheme colorScheme,
    required double size,
    required VoidCallback onPressed,
    String? tooltip,
  }) {
    return IconButton(
      icon: Icon(icon, color: colorScheme.onSurfaceVariant),
      iconSize: size,
      tooltip: tooltip,
      style: IconButton.styleFrom(
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
      onPressed: onPressed,
    );
  }

  Widget _buildSleepTimerButton(
    BuildContext context,
    ColorScheme colorScheme,
    double size,
  ) {
    return ValueListenableBuilder<Duration?>(
      valueListenable: sleepTimerNotifier,
      builder: (_, value, __) {
        final isActive = value != null;
        return IconButton(
          icon: Icon(
            isActive
                ? FluentIcons.timer_24_filled
                : FluentIcons.timer_24_regular,
            color: isActive
                ? colorScheme.primary
                : colorScheme.onSurfaceVariant,
          ),
          iconSize: size,
          tooltip: context.l10n!.sleepTimer,
          style: IconButton.styleFrom(
            backgroundColor: isActive
                ? colorScheme.primary.withValues(alpha: 0.15)
                : Colors.transparent,
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
          onPressed: () {
            if (isActive) {
              audioHandler.cancelSleepTimer();
              sleepTimerNotifier.value = null;
              showToast(
                context,
                context.l10n!.sleepTimerCancelled,
                duration: const Duration(seconds: 1, milliseconds: 500),
              );
            } else {
              _showSleepTimerDialog(context);
            }
          },
        );
      },
    );
  }

  Widget _buildPlaybackSpeedButton(
    BuildContext context,
    ColorScheme colorScheme,
    double size,
  ) {
    return StreamBuilder<PlaybackState>(
      stream: audioHandler.playbackState,
      initialData: audioHandler.playbackState.valueOrNull,
      builder: (context, snapshot) {
        final speed = snapshot.data?.speed ?? 1.0;
        final isActive = speed != 1.0;
        return IconButton(
          icon: Text(
            '${_formatSpeed(speed)}x',
            style: TextStyle(
              fontSize: size * 0.5,
              fontWeight: FontWeight.bold,
              color: isActive
                  ? colorScheme.primary
                  : colorScheme.onSurfaceVariant,
            ),
          ),
          iconSize: size,
          tooltip: context.l10n!.playbackSpeed,
          style: IconButton.styleFrom(
            backgroundColor: isActive
                ? colorScheme.primary.withValues(alpha: 0.15)
                : Colors.transparent,
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
          onPressed: () => _showPlaybackSpeedDialog(context, speed),
        );
      },
    );
  }
}

String _formatSpeed(double speed) =>
    speed == speed.roundToDouble()
        ? speed.toStringAsFixed(0)
        : speed.toStringAsFixed(1);

const _minCustomSpeed = 0.1;
const _maxCustomSpeed = 10.0;

void _showPlaybackSpeedDialog(BuildContext context, double currentSpeed) {
  const speeds = [0.5, 0.8, 1.0, 1.2, 1.5, 1.8, 2.0, 2.5, 3.0];
  final customSpeedController = TextEditingController();

  showDialog<void>(
    context: context,
    builder: (dialogContext) {
      final colorScheme = Theme.of(dialogContext).colorScheme;

      void applyCustomSpeed() {
        final value = double.tryParse(
          customSpeedController.text.replaceAll(',', '.'),
        );
        if (value == null) return;
        final clamped = value
            .clamp(_minCustomSpeed, _maxCustomSpeed)
            ;
        audioHandler.audioPlayer.setSpeed(clamped);
        Navigator.pop(dialogContext);
      }

      return AlertDialog(
        title: Text(context.l10n!.playbackSpeed),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Wrap(
              spacing: 8,
              runSpacing: 8,
              alignment: WrapAlignment.center,
              children: speeds.map((speed) {
                final selected = speed == currentSpeed;
                return ChoiceChip(
                  label: Text('${_formatSpeed(speed)}x'),
                  selected: selected,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  onSelected: (_) {
                    audioHandler.audioPlayer.setSpeed(speed);
                    Navigator.pop(dialogContext);
                  },
                );
              }).toList(),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: customSpeedController,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => applyCustomSpeed(),
              decoration: InputDecoration(
                labelText: 'Velocidad personalizada (${_minCustomSpeed}x - ${_maxCustomSpeed.toStringAsFixed(0)}x)',
                border: const OutlineInputBorder(),
                suffixText: 'x',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            style: TextButton.styleFrom(
              foregroundColor: colorScheme.onSurfaceVariant,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            child: Text(context.l10n!.cancel),
          ),
        ],
      );
    },
  ).then((_) => customSpeedController.dispose());
}

void _showSleepTimerDialog(BuildContext context) {
  final colorScheme = Theme.of(context).colorScheme;

  showDialog(
    context: context,
    builder: (context) {
      final duration = sleepTimerNotifier.value ?? Duration.zero;
      var hours = duration.inMinutes ~/ 60;
      var minutes = duration.inMinutes % 60;

      return StatefulBuilder(
        builder: (context, setState) {
          return AlertDialog(
            title: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(FluentIcons.timer_24_regular, color: colorScheme.primary),
                const SizedBox(width: 12),
                Text(
                  context.l10n!.sleepTimer,
                  style: TextStyle(
                    color: colorScheme.onSurface,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  context.l10n!.selectDuration,
                  style: TextStyle(
                    color: colorScheme.onSurfaceVariant,
                    fontSize: 14,
                  ),
                ),
                const SizedBox(height: 24),
                _buildTimeSelector(
                  context: context,
                  label: context.l10n!.hours,
                  value: hours,
                  colorScheme: colorScheme,
                  onDecrement: () {
                    if (hours > 0) setState(() => hours--);
                  },
                  onIncrement: () => setState(() => hours++),
                ),
                const SizedBox(height: 16),
                _buildTimeSelector(
                  context: context,
                  label: context.l10n!.minutes,
                  value: minutes,
                  colorScheme: colorScheme,
                  onDecrement: () {
                    if (minutes > 0) setState(() => minutes--);
                  },
                  onIncrement: () {
                    if (minutes < 59) setState(() => minutes++);
                  },
                ),
                const SizedBox(height: 16),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  alignment: WrapAlignment.center,
                  children: [
                    ...[15, 30, 45, 60].map((mins) {
                      return ActionChip(
                        label: Text('$mins min'),
                        backgroundColor: colorScheme.surfaceContainerHighest,
                        labelStyle: TextStyle(
                          color: colorScheme.onSurfaceVariant,
                          fontSize: 12,
                        ),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                        onPressed: () {
                          setState(() {
                            hours = mins ~/ 60;
                            minutes = mins % 60;
                          });
                        },
                      );
                    }),
                    ActionChip(
                      label: Text(context.l10n!.endOfSong),
                      backgroundColor: colorScheme.surfaceContainerHighest,
                      labelStyle: TextStyle(
                        color: colorScheme.onSurfaceVariant,
                        fontSize: 12,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                      onPressed: () {
                        audioHandler.setSleepTimerEndOfSong();
                        showToast(
                          context,
                          context.l10n!.sleepTimerSet,
                          duration: const Duration(
                            seconds: 1,
                            milliseconds: 500,
                          ),
                        );
                        Navigator.pop(context);
                      },
                    ),
                  ],
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                style: TextButton.styleFrom(
                  foregroundColor: colorScheme.onSurfaceVariant,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                child: Text(context.l10n!.cancel),
              ),
              FilledButton(
                onPressed: () {
                  final duration = Duration(hours: hours, minutes: minutes);
                  if (duration.inSeconds > 0) {
                    audioHandler.setSleepTimer(duration);
                    showToast(
                      context,
                      context.l10n!.sleepTimerSet,
                      duration: const Duration(seconds: 1, milliseconds: 500),
                    );
                  }
                  Navigator.pop(context);
                },
                style: FilledButton.styleFrom(
                  backgroundColor: colorScheme.primary,
                  foregroundColor: colorScheme.onPrimary,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                child: Text(context.l10n!.setTimer),
              ),
            ],
          );
        },
      );
    },
  );
}

Widget _buildTimeSelector({
  required BuildContext context,
  required String label,
  required int value,
  required ColorScheme colorScheme,
  required VoidCallback onDecrement,
  required VoidCallback onIncrement,
}) {
  return Container(
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
    decoration: BoxDecoration(
      color: colorScheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(16),
    ),
    child: Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          label,
          style: TextStyle(
            color: colorScheme.onSurface,
            fontWeight: FontWeight.w500,
            fontSize: 16,
          ),
        ),
        Row(
          children: [
            IconButton(
              icon: Icon(
                FluentIcons.line_horizontal_1_24_regular,
                color: colorScheme.onSurfaceVariant,
              ),
              style: IconButton.styleFrom(
                backgroundColor: colorScheme.surface,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
              onPressed: onDecrement,
            ),
            Container(
              width: 48,
              alignment: Alignment.center,
              child: Text(
                '$value',
                style: TextStyle(
                  color: colorScheme.onSurface,
                  fontWeight: FontWeight.bold,
                  fontSize: 20,
                ),
              ),
            ),
            IconButton(
              icon: Icon(
                FluentIcons.add_24_regular,
                color: colorScheme.onSurfaceVariant,
              ),
              style: IconButton.styleFrom(
                backgroundColor: colorScheme.surface,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
              onPressed: onIncrement,
            ),
          ],
        ),
      ],
    ),
  );
}
