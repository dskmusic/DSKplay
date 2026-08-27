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

import 'package:dskplay/constants/app_constants.dart';
import 'package:dskplay/extensions/l10n.dart';
import 'package:dskplay/main.dart' show logger;
import 'package:dskplay/screens/bottom_navigation_page.dart';
import 'package:dskplay/services/common_services.dart';
import 'package:dskplay/services/playlist_download_service.dart';
import 'package:dskplay/services/playlists_manager.dart';
import 'package:dskplay/services/router_service.dart';
import 'package:dskplay/services/settings_manager.dart';
import 'package:dskplay/utilities/app_utils.dart';
import 'package:dskplay/utilities/async_loader.dart';
import 'package:dskplay/utilities/flutter_toast.dart';
import 'package:dskplay/utilities/offline_playlist_dialogs.dart';
import 'package:dskplay/utilities/playlist_dialogs.dart';
import 'package:dskplay/utilities/playlist_utils.dart';
import 'package:dskplay/widgets/confirmation_dialog.dart';
import 'package:dskplay/widgets/mini_player_bottom_space.dart';
import 'package:dskplay/widgets/folder_picker_dialog.dart';
import 'package:dskplay/widgets/multi_select.dart';
import 'package:dskplay/widgets/playlist_bar.dart';
import 'package:dskplay/widgets/section_header.dart';
import 'package:fluentui_system_icons/fluentui_system_icons.dart';
import 'package:flutter/material.dart';

class LibraryPage extends StatefulWidget {
  const LibraryPage({super.key});

  @override
  _LibraryPageState createState() => _LibraryPageState();
}

/// Secciones de la biblioteca con selección múltiple para borrar.
enum _SelectableSection { customPlaylists, likedPlaylists, likedArtists }

// Claves de las cabeceras plegables. Se guardan tal cual en `settings`, así
// que no se renombran sin migrar.
const _kCustomPlaylistsSection = 'customPlaylists';
const _kLikedPlaylistsSection = 'likedPlaylists';
const _kLikedArtistsSection = 'likedArtists';

class _LibraryPageState extends State<LibraryPage> {
  /// Sección en modo selección (null: ninguna). Sólo una a la vez: mezclar
  /// listas y artistas en el mismo borrado no significa nada.
  _SelectableSection? _selectionSection;
  final _selectedIds = <String>{};

  /// Lo que se está mostrando en cada sección seleccionable, para poder
  /// resolver "seleccionar todo" y el borrado sin recalcular los filtros.
  final _sectionItems = <_SelectableSection, List>{};

  void _toggleSection(String sectionId) {
    toggleLibrarySectionCollapsed(sectionId);
    setState(() {});
  }

  void _startSelection(_SelectableSection section, String ytid) {
    if (ytid.isEmpty) return;
    setState(() {
      _selectionSection = section;
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
      _selectionSection = null;
      _selectedIds.clear();
    });
  }

  void _selectAll() {
    final items = _sectionItems[_selectionSection] ?? const [];
    setState(() {
      _selectedIds.addAll(
        items
            .map((playlist) => playlist['ytid']?.toString() ?? '')
            .where((ytid) => ytid.isNotEmpty),
      );
    });
  }

  /// Mueve lo seleccionado a una carpeta. Solo tiene sentido para listas:
  /// los artistas favoritos no viven en carpetas.
  Future<void> _moveSelected() async {
    final section = _selectionSection;
    final ids = _selectedIds.toList();
    if (section == null || ids.isEmpty) return;

    final liked = section == _SelectableSection.likedPlaylists;
    final result = await showFolderPickerDialog(
      context,
      folderKind: liked ? 'liked' : 'custom',
      // Ya están fuera de toda carpeta: "Biblioteca" no movería nada.
      allowLibrary: false,
    );
    if (result?.folderId == null || !mounted) return;

    final items = _sectionItems[section] ?? const [];
    for (final id in ids) {
      final playlist = items.firstWhere(
        (p) => p['ytid']?.toString() == id,
        orElse: () => null,
      );
      if (playlist == null) continue;
      movePlaylistToFolder(playlist, result!.folderId, context, liked: liked);
    }
    if (!mounted) return;
    _exitSelection();
    showToast(context, context.l10n!.playlistsMoved(ids.length));
  }

  Future<void> _deleteSelected() async {
    final section = _selectionSection;
    final ids = _selectedIds.toList();
    if (section == null || ids.isEmpty) return;

    final message = switch (section) {
      _SelectableSection.customPlaylists =>
        context.l10n!.deletePlaylistsQuestion(ids.length),
      _SelectableSection.likedPlaylists =>
        context.l10n!.removeLikedPlaylistsQuestion(ids.length),
      _SelectableSection.likedArtists =>
        context.l10n!.removeLikedArtistsQuestion(ids.length),
    };
    if (!await confirmMultiDelete(context, message)) return;

    final items = _sectionItems[section] ?? const [];
    for (final id in ids) {
      if (section == _SelectableSection.customPlaylists) {
        final playlist = items.firstWhere(
          (p) => p['ytid']?.toString() == id,
          orElse: () => null,
        );
        if (playlist == null) continue;
        removeUserPlaylistEntry(playlist);
        if (offlinePlaylistService.isPlaylistDownloaded(id)) {
          unawaited(offlinePlaylistService.removeOfflinePlaylist(id));
        }
      } else {
        await updatePlaylistLikeStatus(id, false);
      }
    }
    if (!mounted) return;
    _exitSelection();
    showToast(context, context.l10n!.itemsDeleted(ids.length));
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        // El boton del dispositivo deshace primero la seleccion; solo si no
        // hay ninguna se va a la pestana de inicio.
        if (_selectionSection != null) {
          _exitSelection();
          return;
        }
        BottomNavigationPage.handleBackPress(context);
      },
      child: _buildScaffold(context),
    );
  }

  Widget _buildScaffold(BuildContext context) {
    final primaryColor = Theme.of(context).colorScheme.primary;

    // Show offline mode message if there is no content
    if (offlineMode.value) {
      final hasUserContent =
          userPlaylistFolders.value.isNotEmpty ||
          userPlaylists.value.isNotEmpty ||
          userCustomPlaylists.value.isNotEmpty;
      final hasOfflinePlaylists = offlinePlaylistService.offlinePlaylists.value
          .any((p) => p is Map && !PlaylistUtils.isArtistPlaylist(p));
      final hasOfflineArtists = getLikedArtistItems(
        offlineOnly: true,
      ).isNotEmpty;
      final hasOfflineSongs = userOfflineSongs.value.isNotEmpty;

      if (!hasUserContent &&
          !hasOfflinePlaylists &&
          !hasOfflineArtists &&
          !hasOfflineSongs) {
        final colorScheme = Theme.of(context).colorScheme;
        return Scaffold(
          appBar: AppBar(title: Text(context.l10n!.library)),
          body: Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: colorScheme.primaryContainer,
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      FluentIcons.cloud_off_24_regular,
                      size: 40,
                      color: colorScheme.onPrimaryContainer,
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    context.l10n!.offlineMode,
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      color: colorScheme.onSurface,
                      fontWeight: FontWeight.w600,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    context.l10n!.noOfflineLibraryContent,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            ),
          ),
        );
      }
    }

    return Scaffold(
      appBar: _selectionSection != null
          ? buildSelectionAppBar(
              context,
              selectedCount: _selectedIds.length,
              onClose: _exitSelection,
              onSelectAll: _selectAll,
              onDelete: _deleteSelected,
              onMove: _selectionSection == _SelectableSection.likedArtists
                  ? null
                  : _moveSelected,
            )
          : AppBar(
              title: Text(context.l10n!.library),
              actions: [
                IconButton(
                  icon: const Icon(FluentIcons.search_24_regular),
                  tooltip: context.l10n!.search,
                  onPressed: () =>
                      NavigationManager.router.go('/library/search'),
                ),
              ],
            ),
      body: AnimatedBuilder(
        animation: Listenable.merge([
          pinnedPlaylistIds,
          offlineMode,
          compactMode,
          userCustomPlaylists,
          userPlaylistFolders,
          offlinePlaylistService.offlinePlaylists,
          userLikedPlaylists,
          onlinePlaylists,
          userPlaylists,
        ]),
        builder: (context, _) {
          return Padding(
            padding: commonSingleChildScrollViewPadding,
            child: CustomScrollView(
              slivers: [
                ..._buildPinnedSlivers(),
                ..._buildUserPlaylistsSlivers(primaryColor),
                if (!offlineMode.value)
                  ..._buildLikedPlaylistsSlivers(primaryColor),
                ..._buildLikedArtistsSlivers(primaryColor),
                const SliverMiniPlayerBottomSpace(),
              ],
            ),
          );
        },
      ),
    );
  }

  List<Widget> _buildPinnedSlivers() {
    final ids = pinnedPlaylistIds.value;
    if (ids.isEmpty) return [];

    final isOff = offlineMode.value;
    final items = resolvePinnedPlaylists(ids).where((p) {
      return !isOff ||
          offlinePlaylistService.isPlaylistDownloaded(
            p['ytid']?.toString() ?? '',
          );
    }).toList();

    if (items.isEmpty) return [];

    return [
      SliverToBoxAdapter(
        child: SectionHeader(
          title: context.l10n!.pinnedPlaylists,
          icon: FluentIcons.pin_24_filled,
        ),
      ),
      _buildSliverPlaylistList(items),
    ];
  }

  List<Widget> _buildUserPlaylistsSlivers(Color primaryColor) {
    final colorScheme = Theme.of(context).colorScheme;
    final isOffline = offlineMode.value;

    final rawOfflinePlaylists = offlinePlaylistService.offlinePlaylists.value;
    final visibleOfflinePlaylists = rawOfflinePlaylists
        .where((p) => p is Map && !PlaylistUtils.isArtistPlaylist(p))
        .toList();
    final customFolders = playlistFoldersOfKind('custom');
    final folders = isOffline
        ? customFolders.where(PlaylistUtils.folderHasOfflinePlaylists).toList()
        : customFolders;

    final offlinePlaylistsNotInFolders =
        PlaylistUtils.filterOfflinePlaylistsNotInFolders(
          visibleOfflinePlaylists,
          folders,
        );

    final offlineIdsNotInFolders = PlaylistUtils.offlinePlaylistIdsNotInFolders(
      visibleOfflinePlaylists,
      folders,
    );

    final allPlaylistsNotInFolders = getPlaylistsNotInFolders();
    final playlistsNotInFolders = PlaylistUtils.excludePlaylistsWithIds(
      allPlaylistsNotInFolders,
      offlineIdsNotInFolders,
    );

    final hasFolders = folders.isNotEmpty;
    final hasCustomPlaylists = playlistsNotInFolders.isNotEmpty;
    final hasLibraryContent = !isOffline || hasFolders || hasCustomPlaylists;

    final slivers = <Widget>[];

    if (hasLibraryContent) {
      if (!isOffline) {
        slivers.add(SliverToBoxAdapter(child: _buildQuickAccessBlock()));
      }
      final collapsed = isLibrarySectionCollapsed(_kCustomPlaylistsSection);
      slivers.add(
        SliverToBoxAdapter(
          child: SectionHeader(
            title: context.l10n!.customPlaylists,
            icon: FluentIcons.library_24_filled,
            onTap: () => _toggleSection(_kCustomPlaylistsSection),
            isCollapsed: collapsed,
            actionButton: isOffline
                ? null
                : Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        padding: const EdgeInsets.symmetric(horizontal: 2),
                        onPressed: _showCreateFolderDialog,
                        icon: Icon(
                          FluentIcons.folder_add_24_regular,
                          color: colorScheme.onSurfaceVariant,
                        ),
                        tooltip: context.l10n!.createFolder,
                      ),
                      IconButton(
                        padding: const EdgeInsets.symmetric(horizontal: 2),
                        onPressed: () => showCreatePlaylistDialog(context),
                        icon: Icon(
                          FluentIcons.add_24_regular,
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
          ),
        ),
      );

      if (hasFolders && !collapsed) {
        slivers.add(_buildFolderSliverList(folders, hasCustomPlaylists));
      }
      if (hasCustomPlaylists && !collapsed) {
        slivers.add(
          _buildSliverPlaylistList(
            playlistsNotInFolders,
            hasItemsBefore: hasFolders,
            selectionSection: _SelectableSection.customPlaylists,
            // Sin conexión la sección muestra sólo una parte de las listas,
            // así que el índice del arrastre no cuadraría con el guardado.
            onReorder: isOffline ? null : reorderCustomPlaylist,
          ),
        );
      }
    }

    final offlinePlaylists = offlinePlaylistsNotInFolders;

    if (offlinePlaylists.isNotEmpty) {
      slivers
        ..add(
          SliverToBoxAdapter(
            child: SectionHeader(
              title: context.l10n!.offlinePlaylists,
              icon: FluentIcons.cloud_off_24_filled,
            ),
          ),
        )
        ..add(
          _buildSliverPlaylistList(offlinePlaylists, isOfflinePlaylists: true),
        );
    }

    if (!offlineMode.value && userPlaylists.value.isNotEmpty) {
      slivers.add(
        SliverToBoxAdapter(
          child: Column(
            children: [
              SectionHeader(
                title: context.l10n!.addedPlaylists,
                icon: FluentIcons.add_circle_24_filled,
                actionButton: IconButton(
                  padding: const EdgeInsets.only(right: 5),
                  onPressed: () => showCreatePlaylistDialog(context),
                  icon: Icon(
                    FluentIcons.add_24_regular,
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              AsyncLoader<List<dynamic>>(
                future: getUserPlaylistsNotInFolders(),
                emptyWidget: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 20),
                  child: Text(
                    context.l10n!.noPlaylistsAdded,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                    textAlign: TextAlign.center,
                  ),
                ),
                builder: _buildPlaylistListView,
              ),
            ],
          ),
        ),
      );
    }

    return slivers;
  }

  List<Widget> _buildLikedPlaylistsSlivers(Color primaryColor) {
    final folders = playlistFoldersOfKind('liked');
    final likedPlaylists = getLikedPlaylistItems();
    if (likedPlaylists.isEmpty && folders.isEmpty) return [];
    final colorScheme = Theme.of(context).colorScheme;
    final likedCollapsed = isLibrarySectionCollapsed(_kLikedPlaylistsSection);

    return [
      SliverToBoxAdapter(
        child: SectionHeader(
          title: context.l10n!.likedPlaylists,
          icon: FluentIcons.heart_24_filled,
          onTap: () => _toggleSection(_kLikedPlaylistsSection),
          isCollapsed: likedCollapsed,
          actionButton: IconButton(
            padding: const EdgeInsets.symmetric(horizontal: 2),
            onPressed: () => _showCreateFolderDialog(kind: 'liked'),
            icon: Icon(
              FluentIcons.folder_add_24_regular,
              color: colorScheme.onSurfaceVariant,
            ),
            tooltip: context.l10n!.createFolder,
          ),
        ),
      ),
      if (folders.isNotEmpty && !likedCollapsed)
        _buildFolderSliverList(
          folders,
          likedPlaylists.isNotEmpty,
          kind: 'liked',
        ),
      if (likedPlaylists.isNotEmpty && !likedCollapsed)
        _buildSliverPlaylistList(
          likedPlaylists,
          hasItemsBefore: folders.isNotEmpty,
          selectionSection: _SelectableSection.likedPlaylists,
          folderKind: 'liked',
          onReorder: (ytid, newIndex) =>
              reorderLikedLibraryItem(ytid, newIndex, isArtist: false),
        ),
    ];
  }

  /// Accesos rapidos (recientes, favoritas, sin conexion, radio) como bloque
  /// propio encima de todo: colgando de la cabecera de "listas propias", que
  /// en realidad titula lo de abajo, pasaban desapercibidos.
  Widget _buildQuickAccessBlock() {
    final colorScheme = Theme.of(context).colorScheme;
    // El tercer campo es la etiqueta corta de la fila compacta: bajo el icono
    // no cabe el nombre completo, que se sigue usando en el tooltip y en las
    // barras del modo normal.
    final entries = <(IconData, String, String, String)>[
      (
        FluentIcons.history_24_regular,
        context.l10n!.recentlyPlayed,
        'Recientes',
        '/library/userSongs/recents',
      ),
      (
        FluentIcons.heart_24_regular,
        context.l10n!.likedSongs,
        'Te gustan',
        '/library/userSongs/liked',
      ),
      (
        FluentIcons.cloud_off_24_regular,
        context.l10n!.offlineSongs,
        'Sin conexión',
        '/library/userSongs/offline',
      ),
      (
        FluentIcons.sound_source_24_regular,
        context.l10n!.radioStations,
        'Radio',
        '/library/radioStations',
      ),
    ];

    if (!compactMode.value) {
      return Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Column(
          children: [
            for (final (index, entry) in entries.indexed)
              PlaylistBar(
                entry.$2,
                onPressed: () => NavigationManager.router.go(entry.$4),
                cubeIcon: entry.$1,
                borderRadius: getItemBorderRadius(index, entries.length),
                showBuildActions: false,
              ),
          ],
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Material(
        color: colorScheme.surfaceContainerHigh,
        borderRadius: commonCustomBarRadius,
        clipBehavior: Clip.antiAlias,
        child: Row(
          children: [
            for (final (icon, label, shortLabel, route) in entries)
              Expanded(
                child: Tooltip(
                  message: label,
                  child: InkWell(
                    onTap: () => NavigationManager.router.go(route),
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(4, 12, 4, 10),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Container(
                            padding: const EdgeInsets.all(9),
                            decoration: BoxDecoration(
                              color: colorScheme.primaryContainer,
                              shape: BoxShape.circle,
                            ),
                            child: Icon(
                              icon,
                              size: 20,
                              color: colorScheme.onPrimaryContainer,
                            ),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            shortLabel,
                            maxLines: 2,
                            textAlign: TextAlign.center,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 10,
                              height: 1.15,
                              fontWeight: FontWeight.w600,
                              color: colorScheme.onSurface,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  List<Widget> _buildLikedArtistsSlivers(Color primaryColor) {
    final likedArtists = getLikedArtistItems(offlineOnly: offlineMode.value);
    if (likedArtists.isEmpty) return [];
    final collapsed = isLibrarySectionCollapsed(_kLikedArtistsSection);
    return [
      SliverToBoxAdapter(
        child: SectionHeader(
          title: context.l10n!.artist,
          icon: FluentIcons.person_24_filled,
          onTap: () => _toggleSection(_kLikedArtistsSection),
          isCollapsed: collapsed,
        ),
      ),
      if (!collapsed)
        _buildSliverPlaylistList(
          likedArtists,
          selectionSection: _SelectableSection.likedArtists,
          onReorder: (ytid, newIndex) =>
              reorderLikedLibraryItem(ytid, newIndex, isArtist: true),
        ),
    ];
  }

  Widget _buildSliverPlaylistList(
    List playlists, {
    bool isOfflinePlaylists = false,
    bool hasItemsAfter = false,
    bool hasItemsBefore = false,
    void Function(String ytid, int newIndex)? onReorder,
    _SelectableSection? selectionSection,
    String folderKind = 'custom',
  }) {
    final colorScheme = Theme.of(context).colorScheme;
    if (selectionSection != null) _sectionItems[selectionSection] = playlists;
    final selectionMode =
        selectionSection != null && _selectionSection == selectionSection;

    Widget buildTile(int index) {
      final playlist = playlists[index];
      final isArtist = playlist['source']?.toString() == 'youtube-artist';
      final borderRadius = getItemBorderRadius(
        index,
        playlists.length,
        hasItemsBefore: hasItemsBefore,
        hasItemsAfter: hasItemsAfter,
      );
      final tile = PlaylistBar(
        key: listItemKey('library_playlist', index, playlist),
        playlist['title'],
        playlistId: playlist['ytid'],
        playlistArtwork: playlist['image'],
        cubeIcon: isArtist
            ? FluentIcons.person_24_filled
            : FluentIcons.text_bullet_list_24_filled,
        isAlbum: isArtist ? false : playlist['isAlbum'],
        folderKind: folderKind,
        // Las favoritas tambien necesitan el mapa: es lo que lee el menu para
        // moverlas a una carpeta.
        playlistData:
            isArtist ||
                folderKind == 'liked' ||
                playlist['source'] == 'user-created' ||
                playlist['source'] == 'user-youtube' ||
                isOfflinePlaylists
            ? playlist
            : null,
        onDelete:
            playlist['source'] == 'user-created' ||
                playlist['source'] == 'user-youtube' ||
                isOfflinePlaylists
            ? () => isOfflinePlaylists
                  ? _showRemoveOfflinePlaylistDialog(playlist)
                  : _showRemovePlaylistDialog(playlist)
            : null,
        borderRadius: borderRadius,
        reorderHandle: onReorder == null
            ? null
            : ReorderableDragStartListener(
                index: index,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Icon(
                    FluentIcons.re_order_24_regular,
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
      );

      if (selectionSection == null) return tile;
      final ytid = playlist['ytid']?.toString() ?? '';
      return buildSelectableItem(
        selectionMode: selectionMode,
        selected: _selectedIds.contains(ytid),
        onToggle: () => _toggleSelection(ytid),
        onLongPress: () => _startSelection(selectionSection, ytid),
        child: tile,
      );
    }

    if (onReorder != null) {
      return SliverPadding(
        padding: hasItemsAfter ? EdgeInsets.zero : commonListViewBottomPadding,
        sliver: SliverReorderableList(
          itemCount: playlists.length,
          onReorderItem: (oldIndex, newIndex) {
            final ytid = playlists[oldIndex]['ytid']?.toString();
            if (ytid == null) return;
            onReorder(ytid, newIndex);
          },
          proxyDecorator: (child, index, animation) => Material(
            elevation: 8,
            color: colorScheme.surfaceContainerHigh,
            borderRadius: BorderRadius.circular(14),
            shadowColor: colorScheme.shadow.withValues(alpha: 0.35),
            child: child,
          ),
          itemBuilder: (context, index) => KeyedSubtree(
            key: listItemKey('library_playlist', index, playlists[index]),
            child: buildTile(index),
          ),
        ),
      );
    }

    return SliverPadding(
      padding: hasItemsAfter ? EdgeInsets.zero : commonListViewBottomPadding,
      sliver: SliverList.builder(
        itemCount: playlists.length,
        itemBuilder: (BuildContext context, index) => buildTile(index),
      ),
    );
  }

  Widget _buildFolderSliverList(
    List folders,
    bool hasPlaylistsAfter, {
    String kind = 'custom',
  }) {
    final colorScheme = Theme.of(context).colorScheme;
    // Sin conexión la seccion muestra solo parte de las carpetas, asi que el
    // indice del arrastre no cuadraria con el guardado.
    final canReorder = !offlineMode.value;

    Widget buildTile(int index) {
      final folder = folders[index];
      final borderRadius = getItemBorderRadius(
        index,
        folders.length,
        hasItemsAfter: hasPlaylistsAfter,
      );
      return PlaylistBar(
        key: ValueKey('folder_${folder['id']}'),
        folder['name'],
        playlistData: folder,
        folderKind: kind,
        borderRadius: borderRadius,
        onDelete: () => _showDeleteFolderDialog(folder),
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
    }

    if (!canReorder) {
      return SliverList.builder(
        itemCount: folders.length,
        itemBuilder: (context, index) => buildTile(index),
      );
    }

    return SliverReorderableList(
      itemCount: folders.length,
      onReorderItem: (oldIndex, newIndex) {
        final folderId = folders[oldIndex]['id']?.toString();
        if (folderId == null) return;
        reorderPlaylistFolder(folderId, newIndex, kind: kind);
      },
      proxyDecorator: (child, index, animation) => Material(
        elevation: 8,
        color: colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(14),
        shadowColor: colorScheme.shadow.withValues(alpha: 0.35),
        child: child,
      ),
      itemBuilder: (context, index) => KeyedSubtree(
        key: ValueKey('folder_${folders[index]['id']}'),
        child: buildTile(index),
      ),
    );
  }

  Widget _buildPlaylistListView(
    BuildContext context,
    List playlists, {
    bool isOfflinePlaylists = false,
    bool hasItemsAfter = false,
    bool hasItemsBefore = false,
  }) {
    return ListView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      itemCount: playlists.length,
      padding: hasItemsAfter ? EdgeInsets.zero : commonListViewBottomPadding,
      itemBuilder: (BuildContext context, index) {
        final playlist = playlists[index];
        final borderRadius = getItemBorderRadius(
          index,
          playlists.length,
          hasItemsBefore: hasItemsBefore,
          hasItemsAfter: hasItemsAfter,
        );
        return PlaylistBar(
          key: listItemKey('library_playlist', index, playlist),
          playlist['title'],
          playlistId: playlist['ytid'],
          playlistArtwork: playlist['image'],
          isAlbum: playlist['isAlbum'],
          playlistData:
              playlist['source'] == 'user-created' ||
                  playlist['source'] == 'user-youtube' ||
                  isOfflinePlaylists
              ? playlist
              : null,
          onDelete:
              playlist['source'] == 'user-created' ||
                  playlist['source'] == 'user-youtube' ||
                  isOfflinePlaylists
              ? () => isOfflinePlaylists
                    ? _showRemoveOfflinePlaylistDialog(playlist)
                    : _showRemovePlaylistDialog(playlist)
              : null,
          borderRadius: borderRadius,
        );
      },
    );
  }

  void _showRemoveOfflinePlaylistDialog(Map playlist) {
    final playlistId = playlist['ytid']?.toString() ?? '';
    if (playlistId.isEmpty) return;
    showRemoveOfflinePlaylistDialog(context, playlistId);
  }

  void _showRemovePlaylistDialog(Map playlist) => showDialog(
    context: context,
    builder: (BuildContext context) {
      return ConfirmationDialog(
        confirmationMessage: context.l10n!.removePlaylistQuestion,
        submitMessage: context.l10n!.remove,
        onCancel: () {
          Navigator.of(context).pop();
        },
        onSubmit: () {
          Navigator.of(context).pop();

          final playlistId = playlist['ytid']?.toString() ?? '';

          if (playlistId.isEmpty) {
            logger.log('Playlist ID is missing, cannot remove playlist.');
            showToast(context, context.l10n!.error);
            return;
          }

          removeUserPlaylistEntry(playlist);
          if (offlinePlaylistService.isPlaylistDownloaded(playlistId)) {
            unawaited(offlinePlaylistService.removeOfflinePlaylist(playlistId));
          }
        },
      );
    },
  );

  void _showCreateFolderDialog({String kind = 'custom'}) => showDialog(
    context: context,
    builder: (BuildContext context) {
      var folderName = '';
      final colorScheme = Theme.of(context).colorScheme;

      return AlertDialog(
        icon: Container(
          width: 56,
          height: 56,
          decoration: BoxDecoration(
            color: colorScheme.primaryContainer,
            shape: BoxShape.circle,
          ),
          child: Icon(
            FluentIcons.folder_add_24_regular,
            color: colorScheme.primary,
            size: 32,
          ),
        ),
        title: Text(
          context.l10n!.createFolder,
          style: TextStyle(
            color: colorScheme.onSurface,
            fontWeight: FontWeight.w600,
          ),
        ),
        content: TextField(
          decoration: InputDecoration(
            labelText: context.l10n!.folderName,
            hintText: context.l10n!.newFolder,
            prefixIcon: Icon(
              FluentIcons.folder_20_regular,
              color: colorScheme.onSurfaceVariant,
            ),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
            filled: true,
            fillColor: colorScheme.surfaceContainerLow,
          ),
          onChanged: (value) {
            folderName = value;
          },
        ),
        actionsAlignment: MainAxisAlignment.center,
        actions: <Widget>[
          OutlinedButton(
            onPressed: () => Navigator.pop(context),
            style: OutlinedButton.styleFrom(
              side: BorderSide(color: colorScheme.outline),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            child: Text(context.l10n!.cancel),
          ),
          FilledButton.icon(
            onPressed: () {
              if (folderName.trim().isNotEmpty) {
                final result = createPlaylistFolder(
                  folderName.trim(),
                  context,
                  kind,
                );
                showToast(context, result);
              } else {
                showToast(context, context.l10n!.enterFolderName);
              }
              Navigator.pop(context);
            },
            icon: const Icon(FluentIcons.add_20_regular),
            label: Text(context.l10n!.create),
          ),
        ],
      );
    },
  );

  void _showDeleteFolderDialog(Map folder) => showDialog(
    context: context,
    builder: (BuildContext context) {
      return ConfirmationDialog(
        confirmationMessage: context.l10n!.deleteFolderQuestion,
        submitMessage: context.l10n!.delete,
        onCancel: () {
          Navigator.of(context).pop();
        },
        onSubmit: () {
          final result = deletePlaylistFolder(folder['id'], context);
          Navigator.of(context).pop();
          showToast(context, result);
        },
      );
    },
  );
}
