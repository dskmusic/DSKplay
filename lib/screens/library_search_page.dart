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

import 'package:fluentui_system_icons/fluentui_system_icons.dart';
import 'package:flutter/material.dart';
import 'package:dskplay/database/radio_stations.db.dart';
import 'package:dskplay/extensions/l10n.dart';
import 'package:dskplay/main.dart' show audioHandler;
import 'package:dskplay/models/radio_model.dart';
import 'package:dskplay/services/common_services.dart';
import 'package:dskplay/services/playlist_download_service.dart';
import 'package:dskplay/services/playlists_manager.dart';
import 'package:dskplay/utilities/flutter_toast.dart';
import 'package:dskplay/utilities/playlist_utils.dart';
import 'package:dskplay/widgets/playlist_bar.dart';
import 'package:dskplay/widgets/radio_station_card.dart';
import 'package:dskplay/widgets/section_header.dart';

class LibrarySearchPage extends StatefulWidget {
  const LibrarySearchPage({super.key});

  @override
  State<LibrarySearchPage> createState() => _LibrarySearchPageState();
}

const _diacriticsMap = {
  'á': 'a', 'à': 'a', 'ä': 'a', 'â': 'a', 'ã': 'a', 'å': 'a',
  'é': 'e', 'è': 'e', 'ë': 'e', 'ê': 'e',
  'í': 'i', 'ì': 'i', 'ï': 'i', 'î': 'i',
  'ó': 'o', 'ò': 'o', 'ö': 'o', 'ô': 'o', 'õ': 'o',
  'ú': 'u', 'ù': 'u', 'ü': 'u', 'û': 'u',
  'ñ': 'n', 'ç': 'c', 'ý': 'y', 'ÿ': 'y',
};

/// Lowercases and strips common Latin diacritics so e.g. "victor" matches
/// "Víctor".
String _normalizeForSearch(String value) {
  final buffer = StringBuffer();
  for (final rune in value.toLowerCase().runes) {
    final char = String.fromCharCode(rune);
    buffer.write(_diacriticsMap[char] ?? char);
  }
  return buffer.toString();
}

class _LibrarySearchPageState extends State<LibrarySearchPage> {
  final _controller = TextEditingController();
  final _focusNode = FocusNode();
  String _query = '';
  List<dynamic> _addedPlaylists = [];

  @override
  void initState() {
    super.initState();
    _focusNode.requestFocus();
    getUserPlaylistsNotInFolders().then((value) {
      if (mounted) setState(() => _addedPlaylists = value);
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  bool _matches(String text) =>
      _normalizeForSearch(text).contains(_normalizeForSearch(_query.trim()));

  void _clear() {
    _controller.clear();
    setState(() => _query = '');
  }

  @override
  Widget build(BuildContext context) {
    final query = _query.trim();

    final folders = query.isEmpty
        ? const <Map>[]
        : userPlaylistFolders.value
              .where((f) => _matches(f['name']?.toString() ?? ''))
              .toList();

    final playlists = query.isEmpty
        ? const <Map>[]
        : <Map>[
            ...getPlaylistsNotInFolders(),
            ...getLikedPlaylistItems(),
            ...offlinePlaylistService.offlinePlaylists.value
                .whereType<Map>()
                .where((p) => !PlaylistUtils.isArtistPlaylist(p)),
            ..._addedPlaylists.whereType<Map>(),
          ].where((p) => _matches(p['title']?.toString() ?? '')).toList();

    final artists = query.isEmpty
        ? const <Map>[]
        : getLikedArtistItems()
              .where((a) => _matches(a['title']?.toString() ?? ''))
              .toList();

    final hiddenIds = userHiddenRadioStationIds.value;
    final stations = query.isEmpty
        ? const <RadioStation>[]
        : <RadioStation>[
            ...userCustomRadioStations.value,
            ...radioStationsDB.where((s) => !hiddenIds.contains(s.id)),
          ].where((s) => _matches(s.name) || _matches(s.genre ?? '')).toList();

    final hasResults =
        folders.isNotEmpty ||
        playlists.isNotEmpty ||
        artists.isNotEmpty ||
        stations.isNotEmpty;

    return Scaffold(
      appBar: AppBar(
        title: TextField(
          controller: _controller,
          focusNode: _focusNode,
          autofocus: true,
          decoration: InputDecoration(
            hintText: context.l10n!.search,
            border: InputBorder.none,
          ),
          onChanged: (value) => setState(() => _query = value),
        ),
        actions: [
          if (_controller.text.isNotEmpty)
            IconButton(
              icon: const Icon(FluentIcons.dismiss_24_regular),
              tooltip: context.l10n!.clear,
              onPressed: _clear,
            ),
        ],
      ),
      body: query.isEmpty
          ? const SizedBox.shrink()
          : !hasResults
          ? Center(child: Text(context.l10n!.noResultsFound))
          : ListView(
              children: [
                if (artists.isNotEmpty) ...[
                  SectionHeader(
                    title: context.l10n!.artist,
                    icon: FluentIcons.person_24_filled,
                  ),
                  ...artists.map(
                    (a) => PlaylistBar(
                      a['title']?.toString() ?? '',
                      playlistId: a['ytid']?.toString(),
                      playlistArtwork: a['image']?.toString(),
                      cubeIcon: FluentIcons.person_24_filled,
                      playlistData: a,
                    ),
                  ),
                ],
                if (playlists.isNotEmpty) ...[
                  SectionHeader(
                    title: context.l10n!.customPlaylists,
                    icon: FluentIcons.library_24_filled,
                  ),
                  ...playlists.map(
                    (p) => PlaylistBar(
                      p['title']?.toString() ?? '',
                      playlistId: p['ytid']?.toString(),
                      playlistArtwork: p['image']?.toString(),
                      isAlbum: p['isAlbum'] as bool?,
                      playlistData:
                          p['source'] == 'user-created' ||
                              p['source'] == 'user-youtube'
                          ? p
                          : null,
                    ),
                  ),
                ],
                if (folders.isNotEmpty) ...[
                  SectionHeader(
                    title: context.l10n!.customPlaylists,
                    icon: FluentIcons.folder_24_filled,
                  ),
                  ...folders.map(
                    (f) => PlaylistBar(
                      f['name']?.toString() ?? '',
                      playlistData: f,
                    ),
                  ),
                ],
                if (stations.isNotEmpty) ...[
                  SectionHeader(
                    title: context.l10n!.radioStations,
                    icon: FluentIcons.sound_source_24_regular,
                  ),
                  ...stations.map(
                    (s) => Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 4,
                      ),
                      child: RadioStationCard(
                        station: s,
                        onPressed: () async {
                          final success = await audioHandler.playRadioStream(
                            id: s.id,
                            name: s.name,
                            streamUrl: s.streamUrl,
                            image: s.image,
                            genre: s.genre,
                          );
                          if (!success && context.mounted) {
                            showToast(context, 'Failed to play radio station');
                          }
                        },
                      ),
                    ),
                  ),
                ],
              ],
            ),
    );
  }
}
