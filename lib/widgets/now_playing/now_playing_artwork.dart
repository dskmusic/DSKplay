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

import 'package:audio_service/audio_service.dart';
import 'package:file_picker/file_picker.dart';
import 'package:fluentui_system_icons/fluentui_system_icons.dart';
import 'package:flutter/material.dart';
import 'package:flutter_flip_card/flutter_flip_card.dart';
import 'package:http/http.dart' as http;
import 'package:dskplay/extensions/l10n.dart';
import 'package:dskplay/main.dart' show logger;
import 'package:dskplay/screens/karaoke_fullscreen_page.dart';
import 'package:dskplay/services/common_services.dart';
import 'package:dskplay/services/io_service.dart';
import 'package:dskplay/services/lyrics_export_service.dart';
import 'package:dskplay/services/lyrics_manager.dart';
import 'package:dskplay/services/settings_manager.dart';
import 'package:dskplay/utilities/async_loader.dart';
import 'package:dskplay/utilities/flutter_toast.dart';
import 'package:dskplay/widgets/now_playing/karaoke_color_dialog.dart';
import 'package:dskplay/widgets/now_playing/karaoke_lyrics_view.dart';
import 'package:dskplay/widgets/now_playing/lyrics_results_picker.dart';
import 'package:dskplay/widgets/song_artwork.dart';

class NowPlayingArtwork extends StatelessWidget {
  const NowPlayingArtwork({
    super.key,
    required this.size,
    required this.metadata,
    required this.lyricsController,
  });
  final Size size;
  final MediaItem metadata;
  final FlipCardController lyricsController;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final screenWidth = size.width;
    final screenHeight = size.height;
    final isLandscape = screenWidth > screenHeight;
    final isDesktop = screenWidth > 800;
    final imageSize = isDesktop
        ? screenHeight * 0.38
        : isLandscape
        ? screenHeight * 0.45
        : screenWidth < 360
        ? screenWidth * 0.75
        : screenWidth < 600
        ? screenWidth * 0.80
        : screenWidth * 0.65;

    const borderRadius = 24.0;

    return FlipCard(
      rotateSide: RotateSide.right,
      onTapFlipping: !offlineMode.value,
      controller: lyricsController,
      frontWidget: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(borderRadius),
          boxShadow: [
            BoxShadow(
              color: colorScheme.shadow.withValues(alpha: 0.15),
              blurRadius: 24,
              offset: const Offset(0, 8),
              spreadRadius: 2,
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(borderRadius),
          child: Stack(
            children: [
              SongArtworkWidget(
                metadata: metadata,
                size: imageSize,
                errorWidgetIconSize: size.width / 8,
                borderRadius: borderRadius,
              ),
              Positioned(
                right: 8,
                bottom: 8,
                child: _SaveCoverButton(metadata: metadata),
              ),
            ],
          ),
        ),
      ),
      backWidget: Container(
        width: imageSize,
        height: imageSize,
        decoration: BoxDecoration(
          color: colorScheme.secondaryContainer,
          borderRadius: BorderRadius.circular(borderRadius),
          boxShadow: [
            BoxShadow(
              color: colorScheme.shadow.withValues(alpha: 0.15),
              blurRadius: 24,
              offset: const Offset(0, 8),
              spreadRadius: 2,
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(borderRadius),
          child: _LyricsBackContent(metadata: metadata),
        ),
      ),
    );
  }
}

class _SaveCoverButton extends StatelessWidget {
  const _SaveCoverButton({required this.metadata});
  final MediaItem metadata;

  String _sanitizedFileName() {
    final name = '${metadata.title} - ${metadata.artist ?? ''}'.trim();
    return name.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
  }

  Future<void> _save(BuildContext context, {required bool chooseFolder}) async {
    final granted = await ensureExportStoragePermission();
    if (!granted) return;

    var targetDir = downloadedMusicDirPath;
    if (chooseFolder) {
      final picked = await FilePicker.getDirectoryPath();
      if (picked == null) return;
      targetDir = picked;
    } else {
      await Directory(targetDir).create(recursive: true);
    }

    try {
      final bytes = metadata.artUri?.scheme == 'file'
          ? await File(metadata.extras?['artWorkPath'] as String).readAsBytes()
          : (await http.get(metadata.artUri!)).bodyBytes;

      final file = File('$targetDir/${_sanitizedFileName()}.jpg');
      await file.writeAsBytes(bytes);

      if (context.mounted) {
        showToast(context, 'Portada guardada en ${file.path}');
      }
    } catch (e, stackTrace) {
      logger.log('Error saving cover image', error: e, stackTrace: stackTrace);
      if (context.mounted) {
        showToast(context, context.l10n!.error);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.black.withValues(alpha: 0.35),
      shape: const CircleBorder(),
      clipBehavior: Clip.antiAlias,
      child: PopupMenuButton<bool>(
        tooltip: 'Guardar portada',
        icon: const Icon(
          FluentIcons.arrow_download_24_regular,
          color: Colors.white,
          size: 20,
        ),
        onSelected: (chooseFolder) => _save(context, chooseFolder: chooseFolder),
        itemBuilder: (context) => const [
          PopupMenuItem(value: false, child: Text('Guardar en Descargas')),
          PopupMenuItem(value: true, child: Text('Elegir carpeta...')),
        ],
      ),
    );
  }
}

class _LyricsBackContent extends StatefulWidget {
  const _LyricsBackContent({required this.metadata});
  final MediaItem metadata;

  @override
  State<_LyricsBackContent> createState() => _LyricsBackContentState();
}

class _LyricsBackContentState extends State<_LyricsBackContent> {
  late Future<LyricsResult?> _lyricsFuture;
  bool _karaokeEnabled = false;

  // Keyed by ytid so switching tabs and coming back to the same song (or
  // even a full rebuild of this widget) reuses whatever was already
  // fetched/picked this session instead of searching again from scratch.
  String get _cacheKey => lyricsCacheKeyFor(
    widget.metadata.extras?['ytid'] as String?,
    widget.metadata.artist,
    widget.metadata.title,
  );

  @override
  void initState() {
    super.initState();
    _lyricsFuture = getSongLyrics(
      widget.metadata.artist,
      widget.metadata.title,
      songId: widget.metadata.extras?['ytid'] as String?,
    );
  }

  @override
  void didUpdateWidget(covariant _LyricsBackContent oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.metadata.title != widget.metadata.title ||
        oldWidget.metadata.artist != widget.metadata.artist) {
      _lyricsFuture = getSongLyrics(
        widget.metadata.artist,
        widget.metadata.title,
        songId: widget.metadata.extras?['ytid'] as String?,
      );
      _karaokeEnabled = false;
    }
  }

  void _openResultsPicker(BuildContext context) {
    showLyricsResultsPicker(
      context,
      artist: widget.metadata.artist ?? '',
      title: widget.metadata.title,
      onSelected: (picked) {
        final cleaned = cleanLyricsResult(picked);
        cacheLyricsResult(_cacheKey, cleaned);
        setState(() {
          _lyricsFuture = Future.value(cleaned);
          _karaokeEnabled = cleaned.hasSyncedLyrics;
        });
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return AsyncLoader<LyricsResult?>(
      future: _lyricsFuture,
      emptyWidget: _buildNotAvailable(context, colorScheme),
      errorBuilder: (ctx, error, stack) =>
          _buildNotAvailable(context, colorScheme),
      builder: (context, result) =>
          _buildLyricsContent(context, colorScheme, result),
    );
  }

  Widget _buildLyricsContent(
    BuildContext context,
    ColorScheme colorScheme,
    LyricsResult? result,
  ) {
    final plainText = result?.plainText;
    final hasSynced = result?.hasSyncedLyrics ?? false;
    final showKaraoke = _karaokeEnabled && hasSynced;

    return Stack(
      children: [
        if (showKaraoke)
          KaraokeLyricsView(lines: result!.syncedLines!)
        else
          SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            physics: const BouncingScrollPhysics(),
            child: Text(
              plainText ?? context.l10n!.lyricsNotAvailable,
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w500,
                color: colorScheme.onSecondaryContainer,
                height: 1.6,
              ),
              textAlign: TextAlign.center,
            ),
          ),
        if (result != null)
          Positioned(
            left: 8,
            bottom: hasSynced ? 44 : 8,
            child: Tooltip(
              message: context.l10n!.chooseLyrics,
              child: Material(
                color: colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(8),
                child: InkWell(
                  borderRadius: BorderRadius.circular(8),
                  onTap: () => _openResultsPicker(context),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 6,
                    ),
                    child: Text(
                      '+',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        if (result != null)
          Positioned(
            left: 8,
            top: 8,
            child: Tooltip(
              message: context.l10n!.fullscreen,
              child: Material(
                color: colorScheme.surfaceContainerHighest.withValues(
                  alpha: 0.85,
                ),
                shape: const CircleBorder(),
                child: InkWell(
                  customBorder: const CircleBorder(),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => KaraokeFullscreenPage(
                        result: result,
                        karaokeEnabled: showKaraoke,
                      ),
                    ),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(8),
                    child: Icon(
                      FluentIcons.full_screen_maximize_24_regular,
                      size: 18,
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ),
            ),
          ),
        Positioned(
          right: 8,
          top: 8,
          child: Tooltip(
            message: context.l10n!.karaokeColors,
            child: Material(
              color: colorScheme.surfaceContainerHighest.withValues(
                alpha: 0.85,
              ),
              shape: const CircleBorder(),
              child: InkWell(
                customBorder: const CircleBorder(),
                onTap: () => showKaraokeColorSettingsDialog(context),
                child: Padding(
                  padding: const EdgeInsets.all(8),
                  child: Icon(
                    FluentIcons.color_24_regular,
                    size: 18,
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ),
          ),
        ),
        if (hasSynced)
          Positioned(
            left: 8,
            bottom: 8,
            child: Tooltip(
              message: context.l10n!.karaokeMode,
              child: Material(
                color: _karaokeEnabled
                    ? colorScheme.primary
                    : colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(8),
                child: InkWell(
                  borderRadius: BorderRadius.circular(8),
                  onTap: () =>
                      setState(() => _karaokeEnabled = !_karaokeEnabled),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 6,
                    ),
                    child: Text(
                      'KAR',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.5,
                        color: _karaokeEnabled
                            ? colorScheme.onPrimary
                            : colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        if (plainText != null && plainText.trim().isNotEmpty)
          Positioned(
            right: 8,
            bottom: 8,
            child: Tooltip(
              message: context.l10n!.exportLyricsAsPdf,
              child: Material(
                color: colorScheme.primary,
                borderRadius: BorderRadius.circular(8),
                child: InkWell(
                  borderRadius: BorderRadius.circular(8),
                  onTap: () => _exportLyricsToPdf(
                    context,
                    title: widget.metadata.title,
                    artist: widget.metadata.artist ?? '',
                    lyrics: plainText,
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 6,
                    ),
                    child: Text(
                      'PDF',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.5,
                        color: colorScheme.onPrimary,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildNotAvailable(BuildContext context, ColorScheme colorScheme) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            FluentIcons.text_quote_24_regular,
            size: 48,
            color: colorScheme.onSecondaryContainer.withValues(alpha: 0.5),
          ),
          const SizedBox(height: 16),
          Text(
            context.l10n!.lyricsNotAvailable,
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w500,
              color: colorScheme.onSecondaryContainer,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 16),
          OutlinedButton.icon(
            onPressed: () => _openResultsPicker(context),
            icon: const Icon(FluentIcons.search_24_regular, size: 18),
            label: Text(context.l10n!.searchLyrics),
          ),
        ],
      ),
    );
  }
}

Future<void> _exportLyricsToPdf(
  BuildContext context, {
  required String title,
  required String artist,
  required String lyrics,
}) async {
  final defaultName = sanitizeFileNameForExport(
    artist.trim().isEmpty ? title : '$artist - $title',
  );

  final fileName = await showDialog<String>(
    context: context,
    builder: (context) => _LyricsFileNameDialog(defaultName: defaultName),
  );
  if (fileName == null || fileName.trim().isEmpty || !context.mounted) return;

  if (!await ensureExportStoragePermission()) {
    if (context.mounted) showToast(context, context.l10n!.exportFailed);
    return;
  }

  final dirPath = await FilePicker.getDirectoryPath(
    initialDirectory: downloadedMusicDirPath,
  );
  if (dirPath == null || !context.mounted) return;

  final path = await exportLyricsAsPdf(
    title: title,
    artist: artist,
    lyrics: lyrics,
    dirPath: dirPath,
    fileName: fileName.trim(),
  );
  if (!context.mounted) return;

  showToast(
    context,
    path != null
        ? '${context.l10n!.savedToDevice} $dirPath'
        : context.l10n!.exportFailed,
  );
}

class _LyricsFileNameDialog extends StatefulWidget {
  const _LyricsFileNameDialog({required this.defaultName});

  final String defaultName;

  @override
  State<_LyricsFileNameDialog> createState() => _LyricsFileNameDialogState();
}

class _LyricsFileNameDialogState extends State<_LyricsFileNameDialog> {
  late final _controller = TextEditingController(text: widget.defaultName);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(context.l10n!.exportLyricsAsPdf),
      content: TextField(
        controller: _controller,
        autofocus: true,
        decoration: InputDecoration(labelText: context.l10n!.pdfFileName),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(context.l10n!.cancel),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_controller.text),
          child: Text(context.l10n!.save),
        ),
      ],
    );
  }
}
