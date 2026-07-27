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

import 'dart:convert';
import 'dart:io';

import 'package:audiotags/audiotags.dart';
import 'package:fluentui_system_icons/fluentui_system_icons.dart';
import 'package:flutter/material.dart';
import 'package:dskplay/extensions/l10n.dart';
import 'package:dskplay/main.dart' show audioHandler;
import 'package:dskplay/services/io_service.dart';
import 'package:dskplay/services/local_files_service.dart';
import 'package:dskplay/utilities/flutter_toast.dart';
import 'package:dskplay/utilities/playlist_image_picker.dart';

/// Opens a dialog to edit [file]'s ID3/Vorbis/MP4 tag (title, artist,
/// album, cover art) in place. [onSaved] is called after a successful
/// write so the caller can refresh whatever it shows for this file.
void showEditTagsDialog(BuildContext context, File file, {VoidCallback? onSaved}) {
  showDialog(
    context: context,
    builder: (context) => _EditTagsDialog(file: file, onSaved: onSaved),
  );
}

class _EditTagsDialog extends StatefulWidget {
  const _EditTagsDialog({required this.file, this.onSaved});

  final File file;
  final VoidCallback? onSaved;

  @override
  State<_EditTagsDialog> createState() => _EditTagsDialogState();
}

class _EditTagsDialogState extends State<_EditTagsDialog> {
  final _titleController = TextEditingController();
  final _artistController = TextEditingController();
  final _albumController = TextEditingController();
  Tag? _originalTag;
  Picture? _picture;
  bool _loading = true;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _titleController.dispose();
    _artistController.dispose();
    _albumController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final tag = await AudioTags.read(widget.file.path);
    _originalTag = tag;
    _titleController.text = tag?.title ?? '';
    _artistController.text = tag?.trackArtist ?? '';
    _albumController.text = tag?.album ?? '';
    if (tag != null && tag.pictures.isNotEmpty) {
      _picture = tag.pictures.firstWhere(
        (p) => p.pictureType == PictureType.coverFront,
        orElse: () => tag.pictures.first,
      );
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _changeCover() async {
    final picked = await pickImage();
    if (picked == null) return;
    final base64Data = picked.contains(',') ? picked.split(',').last : picked;
    setState(() {
      _picture = Picture(
        pictureType: PictureType.coverFront,
        mimeType: MimeType.jpeg,
        bytes: base64Decode(base64Data),
      );
    });
  }

  Future<void> _saveCoverToDownloads() async {
    final picture = _picture;
    if (picture == null) return;
    if (!await ensureExportStoragePermission()) {
      if (mounted) showToast(context, context.l10n!.error);
      return;
    }
    final dir = Directory(androidDownloadsDirPath);
    if (!await dir.exists()) await dir.create(recursive: true);
    final baseName = fileNameFromPath(
      widget.file.path,
    ).replaceAll(RegExp(r'\.[^.]+$'), '');
    final coverFile = File('$androidDownloadsDirPath/$baseName.jpg');
    await coverFile.writeAsBytes(picture.bytes);
    await scanMediaFile(coverFile.path);
    if (mounted) showToast(context, 'Portada guardada en ${coverFile.path}');
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      await AudioTags.write(
        widget.file.path,
        Tag(
          title: _titleController.text.trim(),
          trackArtist: _artistController.text.trim(),
          album: _albumController.text.trim(),
          albumArtist: _originalTag?.albumArtist,
          year: _originalTag?.year,
          genre: _originalTag?.genre,
          trackNumber: _originalTag?.trackNumber,
          trackTotal: _originalTag?.trackTotal,
          discNumber: _originalTag?.discNumber,
          discTotal: _originalTag?.discTotal,
          lyrics: _originalTag?.lyrics,
          bpm: _originalTag?.bpm,
          pictures: _picture != null ? [_picture!] : [],
        ),
      );
      await scanMediaFile(widget.file.path);

      // The cached cover file gets overwritten in place at the same path
      // (see _extractAndCacheArtwork), so Flutter's image cache would keep
      // serving the old decoded bytes for that same path without this.
      PaintingBinding.instance.imageCache
        ..clear()
        ..clearLiveImages();

      // If this file is currently playing (or queued), push the refreshed
      // title/artist/artwork into the mini player/now playing screen/queue
      // right away instead of waiting for a reload or app restart.
      final ytid = '$localFileIdPrefix${widget.file.path}';
      final updatedSong = await buildLocalSongMap(widget.file);
      audioHandler.refreshSongMetadata(ytid, updatedSong);

      if (mounted) {
        Navigator.pop(context);
        widget.onSaved?.call();
      }
    } catch (e) {
      if (mounted) showToast(context, context.l10n!.error);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
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
          FluentIcons.edit_24_filled,
          color: colorScheme.primary,
          size: 32,
        ),
      ),
      title: Text(
        'Editar etiquetas',
        style: TextStyle(
          color: colorScheme.onSurface,
          fontWeight: FontWeight.w600,
          fontSize: 20,
        ),
        textAlign: TextAlign.center,
      ),
      content: _loading
          ? const SizedBox(
              height: 96,
              child: Center(child: CircularProgressIndicator()),
            )
          : SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 96,
                    height: 96,
                    clipBehavior: Clip.antiAlias,
                    decoration: BoxDecoration(
                      color: colorScheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: _picture != null
                        ? Image.memory(_picture!.bytes, fit: BoxFit.cover)
                        : Icon(
                            FluentIcons.music_note_2_24_filled,
                            color: colorScheme.onSurfaceVariant,
                            size: 40,
                          ),
                  ),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      TextButton.icon(
                        onPressed: _changeCover,
                        icon: const Icon(FluentIcons.image_add_20_regular),
                        label: const Text('Cambiar'),
                      ),
                      if (_picture != null)
                        TextButton.icon(
                          onPressed: _saveCoverToDownloads,
                          icon: const Icon(FluentIcons.arrow_download_24_regular),
                          label: const Text('Guardar'),
                        ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _titleController,
                    decoration: const InputDecoration(labelText: 'Título'),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _artistController,
                    decoration: const InputDecoration(labelText: 'Artista'),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _albumController,
                    decoration: const InputDecoration(labelText: 'Álbum'),
                  ),
                ],
              ),
            ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.pop(context),
          child: Text(context.l10n!.cancel),
        ),
        FilledButton(
          onPressed: _saving || _loading ? null : _save,
          child: _saving
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(context.l10n!.save),
        ),
      ],
    );
  }
}
