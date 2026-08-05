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

import 'dart:async';

import 'package:fluentui_system_icons/fluentui_system_icons.dart';
import 'package:flutter/material.dart';
import 'package:dskplay/extensions/l10n.dart';
import 'package:dskplay/services/common_services.dart';
import 'package:dskplay/services/playlists_manager.dart';
import 'package:dskplay/utilities/offline_playlist_dialogs.dart';

/// Likes a playlist, an album or an artist. Shared by the playlist page and
/// the artist page.
class PlaylistLikeButton extends StatefulWidget {
  const PlaylistLikeButton({
    super.key,
    required this.playlistId,
    required this.playlistData,
  });

  final String playlistId;

  /// What to store when the playlist is liked, read on the tap so that a page
  /// still loading its songs stores them once they are there.
  final Map? Function() playlistData;

  @override
  State<PlaylistLikeButton> createState() => _PlaylistLikeButtonState();
}

class _PlaylistLikeButtonState extends State<PlaylistLikeButton> {
  late final ValueNotifier<bool> _isLiked = ValueNotifier<bool>(
    isPlaylistAlreadyLiked(widget.playlistId),
  );

  @override
  void initState() {
    super.initState();
    userLikedPlaylists.addListener(_syncLikeStatus);
  }

  @override
  void didUpdateWidget(covariant PlaylistLikeButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.playlistId != widget.playlistId) _syncLikeStatus();
  }

  @override
  void dispose() {
    userLikedPlaylists.removeListener(_syncLikeStatus);
    _isLiked.dispose();
    super.dispose();
  }

  void _syncLikeStatus() {
    _isLiked.value = isPlaylistAlreadyLiked(widget.playlistId);
  }

  void _toggleLikeStatus() {
    if (_isLiked.value) {
      showRemoveFromLikedPlaylistsDialog(context, _applyLikeStatus);
      return;
    }
    _applyLikeStatus();
  }

  void _applyLikeStatus() {
    _isLiked.value = !_isLiked.value;
    unawaited(
      updatePlaylistLikeStatus(
        widget.playlistId,
        _isLiked.value,
        playlistData: widget.playlistData(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (widget.playlistId.isEmpty) return const SizedBox.shrink();

    return ValueListenableBuilder<bool>(
      valueListenable: _isLiked,
      builder: (context, isLiked, __) {
        final icon = Icon(
          isLiked ? FluentIcons.heart_24_filled : FluentIcons.heart_24_regular,
        );

        return isLiked
            ? IconButton.filled(
                icon: icon,
                iconSize: 24,
                onPressed: _toggleLikeStatus,
                tooltip: context.l10n!.removeFromLikedSongs,
              )
            : IconButton.filledTonal(
                icon: icon,
                iconSize: 24,
                onPressed: _toggleLikeStatus,
                tooltip: context.l10n!.addToLikedSongs,
              );
      },
    );
  }
}
