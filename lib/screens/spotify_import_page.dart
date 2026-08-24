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
import 'dart:convert';
import 'dart:io';

import 'package:dskplay/extensions/l10n.dart';
import 'package:dskplay/services/playlists_manager.dart';
import 'package:dskplay/services/spotify_csv_import.dart';
import 'package:dskplay/services/spotify_import_service.dart';
import 'package:dskplay/utilities/flutter_toast.dart';
import 'package:dskplay/utilities/url_launcher.dart';
import 'package:dskplay/widgets/confirmation_dialog.dart';
import 'package:dskplay/widgets/mini_player_bottom_space.dart';
import 'package:file_picker/file_picker.dart';
import 'package:fluentui_system_icons/fluentui_system_icons.dart';
import 'package:flutter/material.dart';

/// Los tres exportadores de Spotify a CSV que entiende el parser. Los dos
/// primeros sacan una lista cada vez; TuneMyMusic puede volcar la biblioteca
/// entera (varias listas en un mismo archivo).
const _exporters = [
  (
    name: 'Chosic',
    url: 'https://www.chosic.com/spotify-playlist-exporter/',
    description:
        'Una lista cada vez. Pega el enlace de la lista y descarga '
        'el CSV.',
  ),
  (
    name: 'Exportify',
    url: 'https://exportify.net/',
    description:
        'Una lista cada vez. Entra con tu cuenta de Spotify y '
        'exporta la lista que quieras.',
  ),
  (
    name: 'TuneMyMusic',
    url: 'https://www.tunemymusic.com/',
    description:
        'Listas sueltas o la biblioteca entera: en ese caso el CSV '
        'trae varias listas más tus canciones, álbumes y artistas '
        'favoritos, y aquí se importa todo.',
  ),
];

/// Importa listas de Spotify a partir del CSV de Chosic, Exportify o
/// TuneMyMusic: busca cada canción en YouTube y crea listas propias.
///
/// El trabajo lo lleva [SpotifyImportService], no esta pantalla, así que se
/// puede salir de aquí (o de la app) sin cortar la importación.
class SpotifyImportPage extends StatefulWidget {
  const SpotifyImportPage({super.key});

  @override
  State<SpotifyImportPage> createState() => _SpotifyImportPageState();
}

class _SpotifyImportPageState extends State<SpotifyImportPage> {
  final _nameController = TextEditingController();
  final _csvController = TextEditingController();

  @override
  void dispose() {
    _nameController.dispose();
    _csvController.dispose();
    super.dispose();
  }

  Future<void> _openExporter() async {
    final url = await showModalBottomSheet<String>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Text('¿Desde qué servicio exportas?'),
            ),
            for (final exporter in _exporters)
              ListTile(
                leading: const Icon(FluentIcons.open_24_regular),
                title: Text(exporter.name),
                subtitle: Text(exporter.description),
                isThreeLine: true,
                onTap: () => Navigator.of(sheetContext).pop(exporter.url),
              ),
          ],
        ),
      ),
    );
    if (url != null) await launchURL(Uri.parse(url));
  }

  Future<void> _pickCsv() async {
    final result = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['csv', 'txt'],
    );
    final file = result?.files.firstOrNull;
    final path = file?.path;
    if (path == null) return;

    String content;
    try {
      content = await File(path).readAsString();
    } catch (_) {
      // TuneMyMusic exporta en latin-1 y readAsString revienta con UTF-8.
      content = latin1.decode(await File(path).readAsBytes());
    }
    if (!mounted) return;
    setState(() {
      _csvController.text = content;
      if (_nameController.text.trim().isEmpty) {
        _nameController.text = file!.name.replaceAll(
          RegExp(r'\.(csv|txt)$', caseSensitive: false),
          '',
        );
      }
    });
  }

  Future<void> _import() async {
    final library = parseSpotifyCsv(_csvController.text);
    final playlists = library.playlists;
    final total = countSpotifyLibrary(library);
    if (total == 0) {
      showToast(
        context,
        'No se han encontrado canciones en el CSV',
        icon: FluentIcons.error_circle_24_regular,
      );
      return;
    }

    final typedName = _nameController.text.trim();
    // Con una sola lista manda el nombre que haya escrito el usuario; con
    // varias mandan los del CSV, que es lo que las distingue.
    if (playlists.length == 1 &&
        typedName.isEmpty &&
        (playlists.single.name ?? '').isEmpty) {
      showToast(context, 'Ponle un nombre a la lista');
      return;
    }

    final extras = [
      if (playlists.isNotEmpty) '${playlists.length} listas',
      if (library.likedSongs.isNotEmpty)
        '${library.likedSongs.length} canciones que te gustan',
      if (library.albums.isNotEmpty) '${library.albums.length} álbumes',
      if (library.artists.isNotEmpty) '${library.artists.length} artistas',
    ];
    final isLibrary =
        library.likedSongs.isNotEmpty ||
        library.albums.isNotEmpty ||
        library.artists.isNotEmpty;

    if (playlists.length > 1 || isLibrary) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => ConfirmationDialog(
          confirmationMessage:
              'El CSV trae ${extras.join(', ')}: $total elementos en total. '
              'Las listas se crearán y lo demás se marcará como favorito.',
          submitMessage: dialogContext.l10n!.confirm,
          onCancel: () => Navigator.of(dialogContext).pop(false),
          onSubmit: () => Navigator.of(dialogContext).pop(true),
        ),
      );
      if (confirmed != true || !mounted) return;
    }

    final jobs = <SpotifyImportJob>[];
    for (final playlist in playlists) {
      var name = playlists.length == 1 && typedName.isNotEmpty
          ? typedName
          : (playlist.name ?? typedName);
      if (name.isEmpty) name = 'Lista importada';
      final (_, playlistId) = createCustomPlaylist(name, null, context);
      jobs.add((playlistId: playlistId, name: name, tracks: playlist.tracks));
    }

    unawaited(
      spotifyImportService.run(
        jobs,
        likedSongs: library.likedSongs,
        albums: library.albums,
        artists: library.artists,
      ),
    );
    showToast(
      context,
      'Importando $total elementos. Puedes salir de la app: sigue en la '
      'notificación.',
      duration: const Duration(seconds: 5),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Importar listas de Spotify')),
      body: ValueListenableBuilder<SpotifyImportProgress?>(
        valueListenable: spotifyImportService.progress,
        builder: (context, progress, _) {
          final running = progress?.running ?? false;
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
            children: [
              Text(
                'Exporta tus listas de Spotify como CSV en Chosic, Exportify '
                'o TuneMyMusic, elige el archivo o pega su contenido aquí '
                'abajo y DSK Play buscará cada canción en YouTube. Si el CSV '
                'es de la biblioteca entera también se marcan tus canciones, '
                'álbumes y artistas favoritos. La '
                'importación sigue en marcha aunque salgas de esta pantalla '
                'o cierres la app.',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              const SizedBox(height: 16),
              OutlinedButton.icon(
                onPressed: running ? null : _openExporter,
                icon: const Icon(FluentIcons.open_24_regular),
                label: const Text('Abrir un exportador (elige cuál)'),
              ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: running ? null : _pickCsv,
                icon: const Icon(FluentIcons.document_add_24_regular),
                label: const Text('Elegir archivo CSV'),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _nameController,
                enabled: !running,
                decoration: const InputDecoration(
                  labelText: 'Nombre de la lista',
                  helperText:
                      'Si el CSV trae varias listas se usan sus '
                      'propios nombres',
                  filled: true,
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _csvController,
                enabled: !running,
                minLines: 6,
                maxLines: 12,
                decoration: const InputDecoration(
                  labelText: 'Pegar CSV',
                  alignLabelWithHint: true,
                  filled: true,
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 16),
              if (running)
                _RunningSection(progress: progress!)
              else ...[
                if (progress != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Text(
                      '${progress.added} de ${progress.total} elementos '
                      'importados en "${progress.playlistName}"',
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                  ),
                FilledButton.icon(
                  onPressed: _import,
                  icon: const Icon(FluentIcons.arrow_import_24_regular),
                  label: const Text('Importar'),
                ),
              ],
              const MiniPlayerBottomSpace(),
            ],
          );
        },
      ),
    );
  }
}

class _RunningSection extends StatelessWidget {
  const _RunningSection({required this.progress});

  final SpotifyImportProgress progress;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        LinearProgressIndicator(value: progress.fraction),
        const SizedBox(height: 8),
        Text(
          'Buscando ${progress.done} de ${progress.total} elementos '
          '(${progress.added} añadidos)...',
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 8),
        TextButton(
          onPressed: spotifyImportService.cancel,
          child: const Text('Cancelar'),
        ),
      ],
    );
  }
}
