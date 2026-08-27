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

import 'package:dskplay/constants/app_constants.dart';
import 'package:dskplay/extensions/l10n.dart';
import 'package:dskplay/services/playlists_manager.dart';
import 'package:dskplay/services/settings_manager.dart';
import 'package:dskplay/utilities/app_utils.dart';
import 'package:dskplay/utilities/artwork_provider.dart';
import 'package:dskplay/utilities/flutter_toast.dart';
import 'package:dskplay/utilities/playlist_utils.dart';
import 'package:dskplay/widgets/confirmation_dialog.dart';
import 'package:dskplay/widgets/dialog_item.dart';
import 'package:dskplay/widgets/edit_playlist_dialog.dart';
import 'package:dskplay/widgets/folder_picker_dialog.dart';
import 'package:dskplay/widgets/mini_player_bottom_space.dart';
import 'package:dskplay/widgets/multi_select.dart';
import 'package:dskplay/widgets/playlist_bar.dart';
import 'package:dskplay/widgets/popup_menu_item.dart';
import 'package:fluentui_system_icons/fluentui_system_icons.dart';
import 'package:flutter/material.dart';

class PlaylistFolderPage extends StatefulWidget {
  const PlaylistFolderPage({
    super.key,
    required this.folderId,
    required this.folderName,
  });

  final String folderId;
  final String folderName;

  @override
  State<PlaylistFolderPage> createState() => _PlaylistFolderPageState();
}

class _PlaylistFolderPageState extends State<PlaylistFolderPage> {
  late String _folderName;

  /// Selección múltiple dentro de la carpeta: se entra manteniendo pulsada
  /// una lista, igual que en la biblioteca.
  final _selectedIds = <String>{};
  bool _selectionMode = false;

  /// Lo que se está pintando ahora mismo, para resolver "seleccionar todo" y
  /// los lotes sin recalcular filtros.
  List _visiblePlaylists = const [];

  void _startSelection(String ytid) {
    if (ytid.isEmpty) return;
    setState(() {
      _selectionMode = true;
      _selectedIds
        ..clear()
        ..add(ytid);
    });
  }

  void _toggleSelection(String ytid) {
    setState(() {
      if (!_selectedIds.remove(ytid)) _selectedIds.add(ytid);
    });
  }

  void _exitSelection() {
    setState(() {
      _selectionMode = false;
      _selectedIds.clear();
    });
  }

  void _selectAll() {
    setState(() {
      _selectedIds.addAll(
        _visiblePlaylists
            .map((playlist) => playlist['ytid']?.toString() ?? '')
            .where((ytid) => ytid.isNotEmpty),
      );
    });
  }

  List _selectedPlaylists() => _selectedIds
      .map(
        (id) => _visiblePlaylists.firstWhere(
          (p) => p['ytid']?.toString() == id,
          orElse: () => null,
        ),
      )
      .where((p) => p != null)
      .toList();

  Future<void> _moveSelected() async {
    if (_selectedIds.isEmpty) return;
    final liked = _folderKind == 'liked';
    final result = await showFolderPickerDialog(
      context,
      folderKind: liked ? 'liked' : 'custom',
      excludeFolderId: widget.folderId,
    );
    if (result == null || !mounted) return;

    final selected = _selectedPlaylists();
    for (final playlist in selected) {
      movePlaylistToFolder(playlist, result.folderId, context, liked: liked);
    }
    if (!mounted) return;
    _exitSelection();
    showToast(context, context.l10n!.playlistsMoved(selected.length));
  }

  Future<void> _removeSelectedFromFolder() async {
    if (_selectedIds.isEmpty) return;
    final selected = _selectedPlaylists();
    if (!await confirmMultiDelete(
      context,
      context.l10n!.removeFromFolderQuestion(selected.length),
    )) {
      return;
    }
    if (!mounted) return;

    final liked = _folderKind == 'liked';
    for (final playlist in selected) {
      movePlaylistToFolder(playlist, null, context, liked: liked);
    }
    if (!mounted) return;
    _exitSelection();
    showToast(
      context,
      context.l10n!.playlistsRemovedFromFolder(selected.length),
    );
  }

  @override
  void initState() {
    super.initState();
    _folderName = widget.folderName;
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<List>(
      valueListenable: userPlaylistFolders,
      builder: (context, _, __) {
        final isOffline = offlineMode.value;
        final playlists = isOffline
            ? getPlaylistsInFolder(
                widget.folderId,
              ).where(PlaylistUtils.isPlaylistOffline).toList()
            : getPlaylistsInFolder(widget.folderId);
        final isLikedFolder = _folderKind == 'liked';
        _visiblePlaylists = playlists;
        return Scaffold(
          appBar: _selectionMode
              ? buildSelectionAppBar(
                  context,
                  selectedCount: _selectedIds.length,
                  onClose: _exitSelection,
                  onSelectAll: _selectAll,
                  onDelete: _removeSelectedFromFolder,
                  onMove: _moveSelected,
                )
              : null,
          body: PopScope(
            // El boton del dispositivo tambien deshace la seleccion, no
            // solo la X de la barra.
            canPop: !_selectionMode,
            onPopInvokedWithResult: (didPop, _) {
              if (!didPop) _exitSelection();
            },
            child: CustomScrollView(
              slivers: [
                if (!_selectionMode)
                  SliverAppBar(
                    pinned: true,
                    expandedHeight: 300,
                    flexibleSpace: FlexibleSpaceBar(
                      collapseMode: CollapseMode.pin,
                      background: _buildHeader(context, playlists.length),
                    ),
                    actions: [
                      PopupMenuButton<String>(
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                        color: Theme.of(context).colorScheme.surface,
                        itemBuilder: (context) => [
                          buildPopupMenuItem<String>(
                            value: 'add',
                            icon: FluentIcons.add_24_regular,
                            label: context.l10n!.addPlaylist,
                            colorScheme: Theme.of(context).colorScheme,
                            iconSize: 18,
                            spacing: 10,
                          ),
                          buildPopupMenuItem<String>(
                            value: 'rename',
                            icon: FluentIcons.edit_24_regular,
                            label: context.l10n!.editFolder,
                            colorScheme: Theme.of(context).colorScheme,
                            iconSize: 18,
                            spacing: 10,
                          ),
                          buildPopupMenuItem<String>(
                            value: 'delete',
                            icon: FluentIcons.delete_24_regular,
                            label: context.l10n!.deleteFolder,
                            colorScheme: Theme.of(context).colorScheme,
                            iconColor: Theme.of(context).colorScheme.error,
                            labelStyle: TextStyle(
                              color: Theme.of(context).colorScheme.error,
                            ),
                            iconSize: 18,
                            spacing: 10,
                          ),
                        ],
                        onSelected: (value) {
                          if (value == 'add') {
                            _showAddPlaylistDialog();
                          } else if (value == 'rename') {
                            _showRenameFolderDialog();
                          } else if (value == 'delete') {
                            _showDeleteFolderDialog();
                          }
                        },
                      ),
                    ],
                  ),
                if (playlists.isEmpty)
                  SliverFillRemaining(child: _buildEmptyState())
                else
                  SliverPadding(
                    padding: commonListViewBottomPadding,
                    sliver: _buildPlaylistSliver(
                      playlists,
                      isLikedFolder: isLikedFolder,
                      // Sin conexion la carpeta muestra solo parte de sus listas,
                      // asi que el indice del arrastre no cuadraria.
                      canReorder: !isOffline,
                    ),
                  ),
                const SliverMiniPlayerBottomSpace(),
              ],
            ),
          ),
        );
      },
    );
  }

  /// 'liked' cuando la carpeta agrupa listas favoritas, 'custom' para las de
  /// la seccion de listas propias.
  String get _folderKind {
    final folder = userPlaylistFolders.value.firstWhere(
      (f) => f['id']?.toString() == widget.folderId,
      orElse: () => const {},
    );
    return folder['kind']?.toString() ?? 'custom';
  }

  String? get _folderImage {
    final image = userPlaylistFolders.value
        .firstWhere(
          (f) => f['id'] == widget.folderId,
          orElse: () => {},
        )['image']
        ?.toString();
    return (image == null || image.isEmpty) ? null : image;
  }

  Widget _buildPlaylistSliver(
    List playlists, {
    required bool isLikedFolder,
    required bool canReorder,
  }) {
    final colorScheme = Theme.of(context).colorScheme;

    Widget buildTile(int index) {
      final playlist = playlists[index];
      final ytid = playlist['ytid']?.toString() ?? '';
      final tile = PlaylistBar(
        key: listItemKey('folder_playlist', index, playlist),
        playlist['title'],
        playlistId: playlist['ytid'],
        playlistArtwork: playlist['image'],
        playlistData: playlist,
        folderKind: isLikedFolder ? 'liked' : 'custom',
        onDelete: () => _showRemovePlaylistDialog(playlist),
        borderRadius: getItemBorderRadius(index, playlists.length),
        reorderHandle: canReorder
            ? ReorderableDragStartListener(
                index: index,
                child: const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 8),
                  child: Icon(FluentIcons.re_order_24_regular),
                ),
              )
            : null,
      );

      return buildSelectableItem(
        selectionMode: _selectionMode,
        selected: _selectedIds.contains(ytid),
        onToggle: () => _toggleSelection(ytid),
        onLongPress: () => _startSelection(ytid),
        child: tile,
      );
    }

    if (!canReorder) {
      return SliverList.builder(
        itemCount: playlists.length,
        itemBuilder: (context, index) => buildTile(index),
      );
    }

    return SliverReorderableList(
      itemCount: playlists.length,
      onReorderItem: (oldIndex, newIndex) {
        final ytid = playlists[oldIndex]['ytid']?.toString();
        if (ytid == null) return;
        reorderPlaylistInFolder(widget.folderId, ytid, newIndex);
      },
      proxyDecorator: (child, index, animation) => Material(
        elevation: 8,
        color: colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(14),
        shadowColor: colorScheme.shadow.withValues(alpha: 0.35),
        child: child,
      ),
      itemBuilder: (context, index) => KeyedSubtree(
        key: listItemKey('folder_playlist', index, playlists[index]),
        child: buildTile(index),
      ),
    );
  }

  Widget _buildHeader(BuildContext context, int playlistCount) {
    final colorScheme = Theme.of(context).colorScheme;
    final theme = Theme.of(context);
    return Container(
      alignment: Alignment.center,
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 16),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Stack(
            alignment: Alignment.bottomRight,
            children: [
              _buildFolderArtwork(colorScheme),
              if (_folderImage != null)
                Container(
                  margin: const EdgeInsets.only(right: 6, bottom: 6),
                  padding: const EdgeInsets.all(6),
                  decoration: BoxDecoration(
                    color: colorScheme.secondaryContainer,
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    FluentIcons.folder_24_filled,
                    size: 20,
                    color: colorScheme.onSecondaryContainer,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 20),
          Text(
            _folderName,
            style: theme.textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.w700,
              color: colorScheme.onSurface,
              letterSpacing: -0.3,
            ),
            overflow: TextOverflow.ellipsis,
            maxLines: 2,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 10),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
            decoration: BoxDecoration(
              color: colorScheme.secondaryContainer,
              borderRadius: BorderRadius.circular(20),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  FluentIcons.text_bullet_list_24_filled,
                  size: 14,
                  color: colorScheme.onSecondaryContainer,
                ),
                const SizedBox(width: 6),
                Text(
                  playlistCount == 1
                      ? '1 ${context.l10n!.playlist.toLowerCase()}'
                      : '$playlistCount ${context.l10n!.playlists.toLowerCase()}',
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: colorScheme.onSecondaryContainer,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.2,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFolderArtwork(ColorScheme colorScheme) {
    return ClipPath(
      clipper: const ShapeBorderClipper(
        shape: StarBorder(
          points: 8,
          pointRounding: 0.8,
          valleyRounding: 0.2,
          innerRadiusRatio: 0.6,
        ),
      ),
      child: Container(
        width: 130,
        height: 130,
        color: colorScheme.surfaceContainerHighest,
        child: _folderImage == null
            ? Icon(
                FluentIcons.folder_24_filled,
                size: 64,
                color: colorScheme.onSurfaceVariant,
              )
            : Image(
                image: ArtworkProvider.get(_folderImage!),
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => Icon(
                  FluentIcons.folder_24_filled,
                  size: 64,
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              FluentIcons.folder_24_regular,
              size: 64,
              color: Theme.of(context).colorScheme.onSurface.withAlpha(120),
            ),
            const SizedBox(height: 16),
            Text(
              context.l10n!.emptyFolderMsg,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurface.withAlpha(180),
                fontSize: 16,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _showAddPlaylistDialog() async {
    final isLikedFolder = _folderKind == 'liked';
    final candidates = isLikedFolder
        ? getLikedPlaylistItems()
        : [
            ...getPlaylistsNotInFolders(),
            ...await getUserPlaylistsNotInFolders(),
          ];

    if (!mounted) return;

    if (candidates.isEmpty) {
      showToast(context, context.l10n!.noPlaylistsAdded);
      return;
    }

    await showDialog(
      context: context,
      builder: (context) {
        final colorScheme = Theme.of(context).colorScheme;
        return AlertDialog(
          icon: Container(
            width: 56,
            height: 56,
            decoration: BoxDecoration(
              color: colorScheme.secondaryContainer,
              shape: BoxShape.circle,
            ),
            child: Icon(
              FluentIcons.text_bullet_list_add_24_filled,
              color: colorScheme.secondary,
              size: 28,
            ),
          ),
          title: Text(
            context.l10n!.addPlaylist,
            style: TextStyle(
              color: colorScheme.onSurface,
              fontWeight: FontWeight.w600,
            ),
          ),
          content: SizedBox(
            width: double.maxFinite,
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: candidates.length,
              itemBuilder: (context, index) {
                final playlist = candidates[index];
                return Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  child: DialogItem(
                    icon: FluentIcons.text_bullet_list_24_filled,
                    iconColor: colorScheme.tertiary,
                    iconBgColor: colorScheme.tertiaryContainer,
                    label: playlist['title'] ?? '',
                    onTap: () {
                      Navigator.pop(context);
                      movePlaylistToFolder(
                        playlist,
                        widget.folderId,
                        context,
                        liked: isLikedFolder,
                      );
                    },
                  ),
                );
              },
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(context.l10n!.cancel),
            ),
          ],
        );
      },
    );
  }

  void _showRemovePlaylistDialog(Map playlist) {
    showDialog(
      context: context,
      builder: (context) => ConfirmationDialog(
        submitMessage: context.l10n!.remove,
        confirmationMessage: context.l10n!.removeFromFolder,
        onCancel: () => Navigator.of(context).pop(),
        onSubmit: () {
          Navigator.of(context).pop();
          movePlaylistToFolder(
            playlist,
            null,
            context,
            liked: _folderKind == 'liked',
          );
        },
      ),
    );
  }

  Future<void> _showRenameFolderDialog() async {
    final folder = userPlaylistFolders.value.firstWhere(
      (f) => f['id'] == widget.folderId,
      orElse: () => {},
    );
    if (folder.isEmpty) return;

    final result = await showDialog<Map?>(
      context: context,
      builder: (_) => EditPlaylistDialog(playlistData: folder, isFolder: true),
    );
    if (result == null || !mounted) return;

    setPlaylistFolderImage(widget.folderId, result['image']?.toString() ?? '');
    final newName = result['name'].toString();
    showToast(context, renamePlaylistFolder(widget.folderId, newName, context));
    if (newName.trim().isNotEmpty) {
      setState(() => _folderName = newName.trim());
    }
  }

  void _showDeleteFolderDialog() {
    showDialog(
      context: context,
      builder: (context) => ConfirmationDialog(
        submitMessage: context.l10n!.delete,
        confirmationMessage: context.l10n!.deleteFolderQuestion,
        onCancel: () => Navigator.of(context).pop(),
        onSubmit: () {
          Navigator.of(context).pop();
          deletePlaylistFolder(widget.folderId, context);
          Navigator.of(context).pop(); // Go back to library
        },
      ),
    );
  }
}
