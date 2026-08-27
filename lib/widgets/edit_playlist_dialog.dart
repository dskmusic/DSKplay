import 'package:dskplay/extensions/l10n.dart';
import 'package:dskplay/utilities/playlist_image_picker.dart';
import 'package:fluentui_system_icons/fluentui_system_icons.dart';
import 'package:flutter/material.dart';

class EditPlaylistDialog extends StatefulWidget {
  const EditPlaylistDialog({
    super.key,
    required this.playlistData,
    this.isFolder = false,
  });

  final Map playlistData;

  /// Con una carpeta cambian los textos y se devuelve `{name, image}`: la
  /// caratula se elige igual que en una lista (dispositivo, Pixabay o URL).
  final bool isFolder;

  @override
  State<EditPlaylistDialog> createState() => _EditPlaylistDialogState();
}

class _EditPlaylistDialogState extends State<EditPlaylistDialog> {
  late TextEditingController _titleController;
  late TextEditingController _imageUrlController;
  String? _imageBase64;

  @override
  void initState() {
    super.initState();
    _titleController = TextEditingController(
      text: widget.isFolder
          ? widget.playlistData['name']
          : widget.playlistData['title'],
    );
    final image = widget.playlistData['image'] as String?;
    if (image != null && image.startsWith('data:')) {
      _imageBase64 = image;
      _imageUrlController = TextEditingController(text: '');
    } else {
      _imageBase64 = null;
      _imageUrlController = TextEditingController(text: image);
    }
  }

  @override
  void dispose() {
    _titleController.dispose();
    _imageUrlController.dispose();
    super.dispose();
  }

  bool get _hasImage =>
      _imageBase64 != null || _imageUrlController.text.isNotEmpty;

  Future<void> _pickImage() async {
    final result = await pickImage(context);
    if (result != null) {
      setState(() {
        _imageBase64 = result;
        _imageUrlController.text = '';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    Widget _imagePreview() {
      return buildImagePreview(
        imageBase64: _imageBase64,
        imageUrl: _imageUrlController.text.isEmpty
            ? null
            : _imageUrlController.text,
      );
    }

    return AlertDialog(
      title: Text(
        widget.isFolder ? context.l10n!.editFolder : context.l10n!.editPlaylist,
        style: TextStyle(
          color: colorScheme.onSurface,
          fontWeight: FontWeight.w600,
        ),
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            TextField(
              controller: _titleController,
              decoration: InputDecoration(
                labelText: widget.isFolder
                    ? context.l10n!.folderName
                    : context.l10n!.customPlaylistName,
                prefixIcon: Icon(
                  FluentIcons.text_field_20_regular,
                  color: colorScheme.onSurfaceVariant,
                ),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                filled: true,
                fillColor: colorScheme.surfaceContainerLow,
              ),
            ),
            if (_imageBase64 == null) ...[
              const SizedBox(height: 12),
              TextField(
                controller: _imageUrlController,
                decoration: InputDecoration(
                  labelText: context.l10n!.customPlaylistImgUrl,
                  prefixIcon: Icon(
                    FluentIcons.image_20_regular,
                    color: colorScheme.onSurfaceVariant,
                  ),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  filled: true,
                  fillColor: colorScheme.surfaceContainerLow,
                ),
                onChanged: (_) => setState(() => _imageBase64 = null),
              ),
            ],
            const SizedBox(height: 12),
            if (_imageUrlController.text.isEmpty || _imageBase64 != null) ...[
              buildImagePickerRow(context, _pickImage, _imageBase64 != null),
              _imagePreview(),
            ],
            // Sin esto una carpeta con caratula elegida no puede volver al
            // icono: el campo de URL queda oculto al haber imagen.
            if (widget.isFolder && _hasImage)
              TextButton.icon(
                onPressed: () => setState(() {
                  _imageBase64 = null;
                  _imageUrlController.clear();
                }),
                icon: const Icon(FluentIcons.arrow_undo_20_regular, size: 18),
                label: Text(context.l10n!.resetToDefaults),
              ),
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(
            context.l10n!.cancel,
            style: TextStyle(color: colorScheme.onSurfaceVariant),
          ),
        ),
        FilledButton.icon(
          onPressed: () {
            if (widget.isFolder) {
              Navigator.pop(context, {
                'name': _titleController.text,
                'image': _imageBase64 ?? _imageUrlController.text,
              });
              return;
            }

            final newPlaylist = {
              'ytid': widget.playlistData['ytid'],
              'title': _titleController.text,
              'source': widget.playlistData['source'] ?? 'user-created',
              if (_imageBase64 != null)
                'image': _imageBase64
              else if (_imageUrlController.text.isNotEmpty)
                'image': _imageUrlController.text,
              'list': widget.playlistData['list'],
              if (widget.playlistData['createdAt'] != null)
                'createdAt': widget.playlistData['createdAt'],
            };

            Navigator.pop(context, newPlaylist);
          },
          icon: const Icon(FluentIcons.save_20_regular),
          label: Text(context.l10n!.update),
        ),
      ],
    );
  }
}
