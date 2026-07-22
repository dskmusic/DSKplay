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
import 'package:dskplay/extensions/l10n.dart';
import 'package:dskplay/services/lyrics_manager.dart';
import 'package:dskplay/widgets/spinner.dart';

Future<void> showLyricsResultsPicker(
  BuildContext context, {
  required String artist,
  required String title,
  required ValueChanged<LyricsResult> onSelected,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => _LyricsResultsSheet(
      artist: artist,
      title: title,
      onSelected: onSelected,
    ),
  );
}

class _LyricsResultsSheet extends StatefulWidget {
  const _LyricsResultsSheet({
    required this.artist,
    required this.title,
    required this.onSelected,
  });

  final String artist;
  final String title;
  final ValueChanged<LyricsResult> onSelected;

  @override
  State<_LyricsResultsSheet> createState() => _LyricsResultsSheetState();
}

class _LyricsResultsSheetState extends State<_LyricsResultsSheet> {
  final _searchController = TextEditingController();
  late Future<List<LyricsResult>> _resultsFuture;

  @override
  void initState() {
    super.initState();
    _resultsFuture = LyricsManager().searchAllSources(
      widget.artist,
      widget.title,
    );
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  void _runManualSearch() {
    final query = _searchController.text.trim();
    if (query.isEmpty) return;
    setState(() {
      _resultsFuture = LyricsManager().searchByQuery(query);
    });
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return DraggableScrollableSheet(
      initialChildSize: 0.75,
      minChildSize: 0.4,
      maxChildSize: 0.92,
      expand: false,
      builder: (context, scrollController) {
        return Container(
          decoration: BoxDecoration(
            color: colorScheme.surfaceContainerLow,
            borderRadius: const BorderRadius.only(
              topLeft: Radius.circular(24),
              topRight: Radius.circular(24),
            ),
          ),
          padding: EdgeInsets.only(
            left: 16,
            right: 16,
            top: 16,
            bottom: MediaQuery.of(context).viewInsets.bottom + 16,
          ),
          child: Column(
            children: [
              Text(
                context.l10n!.chooseLyrics,
                style: TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 16,
                  color: colorScheme.onSurface,
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _searchController,
                      textInputAction: TextInputAction.search,
                      onSubmitted: (_) => _runManualSearch(),
                      decoration: InputDecoration(
                        isDense: true,
                        hintText: context.l10n!.searchLyrics,
                        prefixIcon: const Icon(FluentIcons.search_24_regular),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton.filledTonal(
                    icon: const Icon(FluentIcons.arrow_circle_right_24_filled),
                    onPressed: _runManualSearch,
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Expanded(
                child: FutureBuilder<List<LyricsResult>>(
                  future: _resultsFuture,
                  builder: (context, snapshot) {
                    if (snapshot.connectionState != ConnectionState.done) {
                      return const Center(child: Spinner());
                    }

                    final results = snapshot.data ?? [];
                    if (results.isEmpty) {
                      return Center(
                        child: Text(context.l10n!.lyricsNotAvailable),
                      );
                    }

                    return ListView.separated(
                      controller: scrollController,
                      itemCount: results.length,
                      separatorBuilder: (_, __) => const SizedBox(height: 8),
                      itemBuilder: (context, index) {
                        final result = results[index];
                        return _LyricsResultTile(
                          result: result,
                          onTap: () {
                            widget.onSelected(result);
                            Navigator.of(context).pop();
                          },
                        );
                      },
                    );
                  },
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _LyricsResultTile extends StatelessWidget {
  const _LyricsResultTile({required this.result, required this.onTap});

  final LyricsResult result;
  final VoidCallback onTap;

  String get _sourceLabel {
    switch (result.source) {
      case 'lrclib':
        return 'LRCLIB';
      case 'netease':
        return 'NetEase';
      case 'genius':
        return 'Genius';
      case 'lyrics.ovh':
        return 'Lyrics.ovh';
      case 'paroles.net':
        return 'Paroles.net';
      case 'lyricsmania.com':
        return 'LyricsMania';
      default:
        return result.source;
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final preview = result.plainText
        .split('\n')
        .firstWhere((line) => line.trim().isNotEmpty, orElse: () => '');
    final subtitle = result.label.isNotEmpty ? result.label : preview;

    return Material(
      color: colorScheme.surfaceContainerHigh,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(
                          _sourceLabel,
                          style: TextStyle(
                            fontWeight: FontWeight.w700,
                            color: colorScheme.onSurface,
                          ),
                        ),
                        if (result.hasSyncedLyrics) ...[
                          const SizedBox(width: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: colorScheme.primary,
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Text(
                              'LRC',
                              style: TextStyle(
                                fontSize: 10,
                                fontWeight: FontWeight.w700,
                                color: colorScheme.onPrimary,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                    if (subtitle.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(
                        subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: colorScheme.onSurfaceVariant,
                          fontSize: 13,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              Icon(
                FluentIcons.chevron_right_24_regular,
                color: colorScheme.onSurfaceVariant,
                size: 16,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
