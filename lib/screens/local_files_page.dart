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

import 'dart:io';

import 'package:fluentui_system_icons/fluentui_system_icons.dart';
import 'package:flutter/material.dart';
import 'package:dskplay/extensions/l10n.dart';
import 'package:dskplay/main.dart';
import 'package:dskplay/services/io_service.dart';
import 'package:dskplay/services/local_files_service.dart';
import 'package:dskplay/utilities/flutter_toast.dart';
import 'package:dskplay/utilities/playlist_dialogs.dart';
import 'package:dskplay/widgets/mini_player_bottom_space.dart';
import 'package:dskplay/widgets/overflow_menu_button.dart';
import 'package:dskplay/widgets/popup_menu_item.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:share_plus/share_plus.dart';

class LocalFilesPage extends StatefulWidget {
  const LocalFilesPage({super.key});

  @override
  State<LocalFilesPage> createState() => _LocalFilesPageState();
}

class _LocalFilesPageState extends State<LocalFilesPage> {
  bool? _hasPermission;
  bool _loading = false;
  String _currentPath = defaultLocalFilesRoot;
  final List<String> _folderStack = [];
  List<FileSystemEntity> _entries = [];

  bool _selectionMode = false;
  final Set<String> _selectedPaths = {};

  bool _isSearching = false;
  final TextEditingController _searchController = TextEditingController();
  int _searchToken = 0;
  bool _isScanning = false;
  String? _scanProgressPath;
  DateTime _lastProgressUpdate = DateTime.fromMillisecondsSinceEpoch(0);
  List<FileSystemEntity>? _searchResults;

  bool _showingFavorites = false;
  List<String> _favoriteFolders = [];

  bool get _canGoUp => _folderStack.isNotEmpty;
  bool get _inOverlayMode => _isSearching || _showingFavorites;

  @override
  void initState() {
    super.initState();
    _checkPermission();
    _loadFavorites();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadFavorites() async {
    final favorites = await getFavoriteFolders();
    if (!mounted) return;
    setState(() => _favoriteFolders = favorites);
  }

  Future<void> _toggleFavorite(String path) async {
    await toggleFavoriteFolder(path);
    await _loadFavorites();
  }

  void _startSearch() {
    setState(() {
      _isSearching = true;
      _showingFavorites = false;
    });
  }

  void _stopSearch() {
    _searchToken++;
    setState(() {
      _isSearching = false;
      _searchController.clear();
      _searchResults = null;
      _isScanning = false;
      _scanProgressPath = null;
    });
  }

  void _clearSearchText() {
    _searchToken++;
    setState(() {
      _searchController.clear();
      _searchResults = null;
      _isScanning = false;
      _scanProgressPath = null;
    });
  }

  void _onSearchChanged(String query) {
    final trimmed = query.trim();
    _searchToken++;
    final token = _searchToken;

    if (trimmed.isEmpty) {
      setState(() {
        _searchResults = null;
        _isScanning = false;
        _scanProgressPath = null;
      });
      return;
    }

    setState(() {
      _isScanning = true;
      _scanProgressPath = null;
      _searchResults = null;
    });
    _runSearch(trimmed, token);
  }

  Future<void> _runSearch(String query, int token) async {
    final results = await searchFilesAndFolders(
      _currentPath,
      query,
      isCancelled: () => token != _searchToken,
      onProgress: (path) {
        if (token != _searchToken || !mounted) return;
        final now = DateTime.now();
        if (now.difference(_lastProgressUpdate) <
            const Duration(milliseconds: 150)) {
          return;
        }
        _lastProgressUpdate = now;
        setState(() => _scanProgressPath = path);
      },
    );
    if (!mounted || token != _searchToken) return;
    setState(() {
      _searchResults = results;
      _isScanning = false;
      _scanProgressPath = null;
    });
  }

  void _toggleFavoritesView() {
    setState(() {
      _showingFavorites = !_showingFavorites;
      if (_showingFavorites) _isSearching = false;
    });
  }

  void _navigateToFolder(String path) {
    if (_isSearching) _stopSearch();
    if (_showingFavorites) setState(() => _showingFavorites = false);
    _openFolder(path);
  }

  Future<void> _playFoundFile(File file) async {
    final siblings = await listAudioFilesInSameFolder(file);
    final index = siblings.indexWhere((f) => f.path == file.path);
    final songs = await buildLocalSongMaps(siblings);
    await audioHandler.playPlaylistSong(
      playlist: {'list': songs},
      songIndex: index == -1 ? 0 : index,
    );
    if (mounted) {
      _stopSearch();
      setState(() => _showingFavorites = false);
    }
  }

  Future<void> _checkPermission() async {
    final granted = await Permission.manageExternalStorage.isGranted;
    if (!mounted) return;
    setState(() => _hasPermission = granted);
    if (granted) await _loadCurrentDirectory();
  }

  Future<void> _requestPermission() async {
    final granted = await ensureExportStoragePermission();
    if (!mounted) return;
    setState(() => _hasPermission = granted);
    if (granted) await _loadCurrentDirectory();
  }

  Future<void> _loadCurrentDirectory() async {
    setState(() => _loading = true);
    final entries = await listDirectoryEntries(_currentPath);
    if (!mounted) return;
    setState(() {
      _entries = entries;
      _loading = false;
    });
  }

  void _openFolder(String path) {
    setState(() {
      _folderStack.add(_currentPath);
      _currentPath = path;
      _exitSelectionModeSilently();
    });
    _loadCurrentDirectory();
  }

  void _goUp() {
    if (!_canGoUp) return;
    setState(() {
      _currentPath = _folderStack.removeLast();
      _exitSelectionModeSilently();
    });
    _loadCurrentDirectory();
  }

  void _exitSelectionModeSilently() {
    _selectionMode = false;
    _selectedPaths.clear();
  }

  void _enterSelectionMode(String path) {
    setState(() {
      _selectionMode = true;
      _selectedPaths.add(path);
    });
  }

  void _toggleSelected(String path) {
    setState(() {
      if (!_selectedPaths.remove(path)) _selectedPaths.add(path);
      if (_selectedPaths.isEmpty) _selectionMode = false;
    });
  }

  void _exitSelectionMode() {
    setState(_exitSelectionModeSilently);
  }

  List<File> _siblingAudioFiles() => _entries.whereType<File>().toList();

  Future<List<Map<String, dynamic>>> _collectSongsFor(
    Iterable<FileSystemEntity> entities,
  ) async {
    final songs = <Map<String, dynamic>>[];
    for (final entity in entities) {
      if (entity is File) {
        songs.add(await buildLocalSongMap(entity));
      } else if (entity is Directory) {
        final files = await collectAudioFilesRecursively(entity);
        songs.addAll(await buildLocalSongMaps(files));
      }
    }
    return songs;
  }

  Future<void> _playFromSelection() async {
    final entities = _entries.where((e) => _selectedPaths.contains(e.path));
    final songs = await _collectSongsFor(entities);
    if (songs.isEmpty) return;
    await audioHandler.addPlaylistToQueue(songs, replace: true, startIndex: 0);
    if (mounted) _exitSelectionMode();
  }

  Future<void> _addSelectionToQueue() async {
    final entities = _entries.where((e) => _selectedPaths.contains(e.path));
    final songs = await _collectSongsFor(entities);
    if (songs.isEmpty) return;
    await audioHandler.addPlaylistToQueue(songs);
    if (!mounted) return;
    showToast(context, context.l10n!.songAdded);
    _exitSelectionMode();
  }

  Future<void> _addSelectionToPlaylist() async {
    final entities = _entries.where((e) => _selectedPaths.contains(e.path));
    final songs = await _collectSongsFor(entities);
    if (songs.isEmpty || !mounted) return;
    showAddToPlaylistDialog(context, songs: songs);
    _exitSelectionMode();
  }

  Future<void> _playFile(File file) async {
    final siblings = _siblingAudioFiles();
    final index = siblings.indexWhere((f) => f.path == file.path);
    final songs = await buildLocalSongMaps(siblings);
    await audioHandler.playPlaylistSong(
      playlist: {'list': songs},
      songIndex: index == -1 ? 0 : index,
    );
  }

  Future<void> _playFolder(Directory dir) async {
    final files = await collectAudioFilesRecursively(dir);
    if (files.isEmpty) return;
    await audioHandler.addPlaylistToQueue(
      await buildLocalSongMaps(files),
      replace: true,
      startIndex: 0,
    );
  }

  Future<void> _addFolderToQueue(Directory dir) async {
    final files = await collectAudioFilesRecursively(dir);
    if (files.isEmpty || !mounted) return;
    await audioHandler.addPlaylistToQueue(await buildLocalSongMaps(files));
    if (mounted) showToast(context, context.l10n!.songAdded);
  }

  Future<void> _addFolderToPlaylist(Directory dir) async {
    final files = await collectAudioFilesRecursively(dir);
    final songs = await buildLocalSongMaps(files);
    if (songs.isEmpty || !mounted) return;
    showAddToPlaylistDialog(context, songs: songs);
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_canGoUp && !_selectionMode && !_inOverlayMode,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (_selectionMode) {
          _exitSelectionMode();
        } else if (_isSearching) {
          _stopSearch();
        } else if (_showingFavorites) {
          setState(() => _showingFavorites = false);
        } else if (_canGoUp) {
          _goUp();
        }
      },
      child: Scaffold(
        appBar: _selectionMode
            ? _buildSelectionAppBar()
            : _isSearching
            ? _buildSearchAppBar()
            : _buildAppBar(),
        body: _buildBody(),
      ),
    );
  }

  PreferredSizeWidget _buildAppBar() {
    return AppBar(
      leading: _showingFavorites
          ? IconButton(
              icon: const Icon(FluentIcons.arrow_left_24_regular),
              onPressed: () => setState(() => _showingFavorites = false),
            )
          : _canGoUp
          ? IconButton(
              icon: const Icon(FluentIcons.arrow_left_24_regular),
              onPressed: _goUp,
            )
          : null,
      title: Text(
        _showingFavorites
            ? 'Favoritos'
            : _canGoUp
            ? fileNameFromPath(_currentPath)
            : context.l10n!.localFiles,
      ),
      actions: _hasPermission != true || _showingFavorites
          ? null
          : [
              IconButton(
                icon: const Icon(FluentIcons.search_24_regular),
                tooltip: 'Buscar',
                onPressed: _startSearch,
              ),
              IconButton(
                icon: const Icon(FluentIcons.heart_24_regular),
                tooltip: 'Favoritos',
                onPressed: _toggleFavoritesView,
              ),
            ],
    );
  }

  PreferredSizeWidget _buildSearchAppBar() {
    return AppBar(
      leading: IconButton(
        icon: const Icon(FluentIcons.arrow_left_24_regular),
        onPressed: _stopSearch,
      ),
      title: TextField(
        controller: _searchController,
        autofocus: true,
        decoration: InputDecoration(
          hintText: 'Buscar carpetas o canciones...',
          border: InputBorder.none,
          suffixIcon: _searchController.text.isEmpty
              ? null
              : IconButton(
                  icon: const Icon(FluentIcons.dismiss_circle_24_regular),
                  onPressed: _clearSearchText,
                ),
        ),
        onChanged: _onSearchChanged,
      ),
    );
  }

  PreferredSizeWidget _buildSelectionAppBar() {
    return AppBar(
      leading: IconButton(
        icon: const Icon(FluentIcons.dismiss_24_regular),
        onPressed: _exitSelectionMode,
      ),
      title: Text('${_selectedPaths.length} ${context.l10n!.itemsSelected}'),
      actions: [
        IconButton(
          icon: const Icon(FluentIcons.play_24_regular),
          tooltip: context.l10n!.play,
          onPressed: _playFromSelection,
        ),
        IconButton(
          icon: const Icon(FluentIcons.text_bullet_list_add_24_regular),
          tooltip: context.l10n!.addToQueue,
          onPressed: _addSelectionToQueue,
        ),
        IconButton(
          icon: const Icon(FluentIcons.album_add_24_regular),
          tooltip: context.l10n!.addToPlaylist,
          onPressed: _addSelectionToPlaylist,
        ),
      ],
    );
  }

  Widget _buildBody() {
    final colorScheme = Theme.of(context).colorScheme;

    if (_hasPermission == null) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_hasPermission == false) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                FluentIcons.folder_24_regular,
                size: 64,
                color: colorScheme.onSurface.withValues(alpha: 0.4),
              ),
              const SizedBox(height: 16),
              Text(
                context.l10n!.localFilesDescription,
                textAlign: TextAlign.center,
                style: TextStyle(color: colorScheme.onSurfaceVariant),
              ),
              const SizedBox(height: 20),
              FilledButton(
                onPressed: _requestPermission,
                child: Text(context.l10n!.grantStorageAccess),
              ),
            ],
          ),
        ),
      );
    }

    if (_showingFavorites) {
      return _buildFavoritesList(colorScheme);
    }

    if (_isSearching) {
      return _buildSearchBody(colorScheme);
    }

    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_entries.isEmpty) {
      return Center(
        child: Text(
          context.l10n!.noResultsFound,
          style: TextStyle(color: colorScheme.onSurfaceVariant),
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: _entries.length + 1,
      itemBuilder: (context, index) {
        if (index == _entries.length) return const MiniPlayerBottomSpace();

        final entry = _entries[index];
        final isSelected = _selectedPaths.contains(entry.path);

        if (entry is Directory) {
          return _FolderRow(
            directory: entry,
            selectionMode: _selectionMode,
            isSelected: isSelected,
            isFavorite: _favoriteFolders.contains(entry.path),
            onTap: () => _selectionMode
                ? _toggleSelected(entry.path)
                : _openFolder(entry.path),
            onLongPress: () => _enterSelectionMode(entry.path),
            onPlay: () => _playFolder(entry),
            onAddToQueue: () => _addFolderToQueue(entry),
            onAddToPlaylist: () => _addFolderToPlaylist(entry),
            onToggleFavorite: () => _toggleFavorite(entry.path),
          );
        }

        final file = entry as File;
        return _LocalFileRow(
          file: file,
          selectionMode: _selectionMode,
          isSelected: isSelected,
          onTap: () =>
              _selectionMode ? _toggleSelected(file.path) : _playFile(file),
          onLongPress: () => _enterSelectionMode(file.path),
        );
      },
    );
  }

  Widget _buildFavoritesList(ColorScheme colorScheme) {
    final validFavorites = _favoriteFolders
        .where((path) => Directory(path).existsSync())
        .toList();

    if (validFavorites.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Text(
            'Aún no tienes carpetas favoritas. Mantén pulsada una carpeta, o '
            'usa el menú de los tres puntos, para añadirla aquí.',
            textAlign: TextAlign.center,
            style: TextStyle(color: colorScheme.onSurfaceVariant),
          ),
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: validFavorites.length + 1,
      itemBuilder: (context, index) {
        if (index == validFavorites.length) {
          return const MiniPlayerBottomSpace();
        }
        final directory = Directory(validFavorites[index]);
        return _FolderRow(
          directory: directory,
          selectionMode: false,
          isSelected: false,
          isFavorite: true,
          onTap: () => _navigateToFolder(directory.path),
          onLongPress: () {},
          onPlay: () => _playFolder(directory),
          onAddToQueue: () => _addFolderToQueue(directory),
          onAddToPlaylist: () => _addFolderToPlaylist(directory),
          onToggleFavorite: () => _toggleFavorite(directory.path),
        );
      },
    );
  }

  Widget _buildSearchBody(ColorScheme colorScheme) {
    if (_isScanning) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const CircularProgressIndicator(),
              const SizedBox(height: 16),
              Text(
                'Buscando...',
                style: TextStyle(color: colorScheme.onSurfaceVariant),
              ),
              if (_scanProgressPath != null) ...[
                const SizedBox(height: 4),
                Text(
                  _scanProgressPath!,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: colorScheme.onSurfaceVariant,
                    fontSize: 12,
                  ),
                ),
              ],
            ],
          ),
        ),
      );
    }

    final results = _searchResults;
    if (results == null) {
      return Center(
        child: Text(
          'Escribe para buscar en tus archivos locales',
          style: TextStyle(color: colorScheme.onSurfaceVariant),
        ),
      );
    }

    if (results.isEmpty) {
      return Center(
        child: Text(
          context.l10n!.noResultsFound,
          style: TextStyle(color: colorScheme.onSurfaceVariant),
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: results.length + 1,
      itemBuilder: (context, index) {
        if (index == results.length) return const MiniPlayerBottomSpace();
        final entry = results[index];

        if (entry is Directory) {
          return _FolderRow(
            directory: entry,
            selectionMode: false,
            isSelected: false,
            isFavorite: _favoriteFolders.contains(entry.path),
            onTap: () => _navigateToFolder(entry.path),
            onLongPress: () {},
            onPlay: () => _playFolder(entry),
            onAddToQueue: () => _addFolderToQueue(entry),
            onAddToPlaylist: () => _addFolderToPlaylist(entry),
            onToggleFavorite: () => _toggleFavorite(entry.path),
          );
        }

        final file = entry as File;
        return _LocalFileRow(
          file: file,
          selectionMode: false,
          isSelected: false,
          onTap: () => _playFoundFile(file),
          onLongPress: () {},
        );
      },
    );
  }
}

class _FolderRow extends StatelessWidget {
  const _FolderRow({
    required this.directory,
    required this.selectionMode,
    required this.isSelected,
    required this.isFavorite,
    required this.onTap,
    required this.onLongPress,
    required this.onPlay,
    required this.onAddToQueue,
    required this.onAddToPlaylist,
    required this.onToggleFavorite,
  });

  final Directory directory;
  final bool selectionMode;
  final bool isSelected;
  final bool isFavorite;
  final VoidCallback onTap;
  final VoidCallback onLongPress;
  final VoidCallback onPlay;
  final VoidCallback onAddToQueue;
  final VoidCallback onAddToPlaylist;
  final VoidCallback onToggleFavorite;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final l10n = context.l10n!;

    return ListTile(
      onTap: onTap,
      onLongPress: onLongPress,
      leading: Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(
          color: colorScheme.secondaryContainer,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Icon(
          FluentIcons.folder_24_filled,
          color: colorScheme.onSecondaryContainer,
        ),
      ),
      title: Text(
        fileNameFromPath(directory.path),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: selectionMode
          ? Checkbox(value: isSelected, onChanged: (_) => onTap())
          : OverflowMenuButton<String>(
              onSelected: (value) {
                switch (value) {
                  case 'play':
                    onPlay();
                  case 'add_to_queue':
                    onAddToQueue();
                  case 'add_to_playlist':
                    onAddToPlaylist();
                  case 'toggle_favorite':
                    onToggleFavorite();
                }
              },
              itemBuilder: (context) => [
                buildPopupMenuItem<String>(
                  value: 'play',
                  icon: FluentIcons.play_24_regular,
                  label: l10n.playFolder,
                  colorScheme: colorScheme,
                ),
                buildPopupMenuItem<String>(
                  value: 'add_to_queue',
                  icon: FluentIcons.text_bullet_list_add_24_regular,
                  label: l10n.addToQueue,
                  colorScheme: colorScheme,
                ),
                buildPopupMenuItem<String>(
                  value: 'add_to_playlist',
                  icon: FluentIcons.album_add_24_regular,
                  label: l10n.addToPlaylist,
                  colorScheme: colorScheme,
                ),
                buildPopupMenuItem<String>(
                  value: 'toggle_favorite',
                  icon: isFavorite
                      ? FluentIcons.heart_24_filled
                      : FluentIcons.heart_24_regular,
                  label: isFavorite
                      ? 'Quitar de favoritos'
                      : 'Añadir a favoritos',
                  colorScheme: colorScheme,
                ),
              ],
            ),
    );
  }
}

class _LocalFileRow extends StatefulWidget {
  const _LocalFileRow({
    required this.file,
    required this.selectionMode,
    required this.isSelected,
    required this.onTap,
    required this.onLongPress,
  });

  final File file;
  final bool selectionMode;
  final bool isSelected;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  @override
  State<_LocalFileRow> createState() => _LocalFileRowState();
}

class _LocalFileRowState extends State<_LocalFileRow> {
  // Shown immediately (filename-based); replaced once the ID3/Vorbis/MP4
  // tag read (including embedded cover art) resolves, if it finds one.
  late Map<String, dynamic> _song = localFileToSongMap(widget.file);

  @override
  void initState() {
    super.initState();
    _loadTags();
  }

  @override
  void didUpdateWidget(covariant _LocalFileRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.file.path != widget.file.path) {
      _song = localFileToSongMap(widget.file);
      _loadTags();
    }
  }

  Future<void> _loadTags() async {
    final enriched = await buildLocalSongMap(widget.file);
    if (mounted) setState(() => _song = enriched);
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final l10n = context.l10n!;
    final title = (_song['title'] as String?)?.trim().isNotEmpty ?? false
        ? _song['title'] as String
        : fileNameFromPath(widget.file.path);
    final artist = (_song['artist'] as String?)?.trim() ?? '';
    final artworkPath = _song['artworkPath'] as String?;

    return ListTile(
      onTap: widget.onTap,
      onLongPress: widget.onLongPress,
      leading: Container(
        width: 44,
        height: 44,
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(10),
        ),
        child: artworkPath != null
            ? Image.file(
                File(artworkPath),
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => Icon(
                  FluentIcons.music_note_2_24_filled,
                  color: colorScheme.onSurfaceVariant,
                ),
              )
            : Icon(
                FluentIcons.music_note_2_24_filled,
                color: colorScheme.onSurfaceVariant,
              ),
      ),
      title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: artist.isNotEmpty
          ? Text(artist, maxLines: 1, overflow: TextOverflow.ellipsis)
          : null,
      trailing: widget.selectionMode
          ? Checkbox(value: widget.isSelected, onChanged: (_) => widget.onTap())
          : OverflowMenuButton<String>(
              onSelected: _handleMenuAction,
              itemBuilder: (context) => [
                buildPopupMenuItem<String>(
                  value: 'play',
                  icon: FluentIcons.play_24_regular,
                  label: l10n.play,
                  colorScheme: colorScheme,
                ),
                buildPopupMenuItem<String>(
                  value: 'play_next',
                  icon: FluentIcons.receipt_play_24_regular,
                  label: l10n.playNext,
                  colorScheme: colorScheme,
                ),
                buildPopupMenuItem<String>(
                  value: 'add_to_queue',
                  icon: FluentIcons.text_bullet_list_add_24_regular,
                  label: l10n.addToQueue,
                  colorScheme: colorScheme,
                ),
                buildPopupMenuItem<String>(
                  value: 'add_to_playlist',
                  icon: FluentIcons.album_add_24_regular,
                  label: l10n.addToPlaylist,
                  colorScheme: colorScheme,
                ),
                buildPopupMenuItem<String>(
                  value: 'share',
                  icon: FluentIcons.share_24_regular,
                  label: l10n.share,
                  colorScheme: colorScheme,
                ),
              ],
            ),
    );
  }

  Future<void> _handleMenuAction(String value) async {
    switch (value) {
      case 'play':
        widget.onTap();
      case 'play_next':
        await audioHandler.playNext(_song);
        if (mounted) {
          showToast(
            context,
            context.l10n!.songAdded,
            duration: const Duration(seconds: 1),
          );
        }
      case 'add_to_queue':
        await audioHandler.addToQueue(_song);
        if (mounted) {
          showToast(
            context,
            context.l10n!.songAdded,
            duration: const Duration(seconds: 1),
          );
        }
      case 'add_to_playlist':
        if (mounted) showAddToPlaylistDialog(context, song: _song);
      case 'share':
        await SharePlus.instance.share(
          ShareParams(files: [XFile(widget.file.path)]),
        );
    }
  }
}
