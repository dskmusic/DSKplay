import 'dart:async';
import 'dart:io';

import 'package:dskplay/main.dart';
import 'package:dskplay/screens/now_playing_page.dart';
import 'package:dskplay/services/local_files_service.dart';
import 'package:dskplay/models/podcast_model.dart';
import 'package:dskplay/models/radio_model.dart';
import 'package:dskplay/services/playlists_manager.dart';
import 'package:dskplay/services/podcast_feed_service.dart';
import 'package:dskplay/services/podcast_manager.dart';
import 'package:dskplay/services/router_service.dart';
import 'package:dskplay/utilities/artwork_provider.dart';
import 'package:dskplay/utilities/flutter_toast.dart';
import 'package:dskplay/utilities/playlist_image_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

const _channel = MethodChannel('dskplay/pin_shortcut');


Uri _playUri(String kind, Map<String, String> params) => Uri(
  scheme: 'dskplay',
  host: 'play',
  pathSegments: [kind],
  queryParameters: params,
);

// ---------------------------------------------------------------------------
// Crear el acceso directo
// ---------------------------------------------------------------------------

/// Canción (online o fichero local).
Future<void> pinSongShortcut(BuildContext context, Map song) {
  final title = song['title']?.toString().trim() ?? '';
  final image = [song['artworkPath'], song['highResImage'], song['lowResImage']]
      .map((e) => e?.toString() ?? '')
      .firstWhere((e) => e.isNotEmpty, orElse: () => '');

  if (song['isLocalFile'] == true && song['audioPath'] != null) {
    final path = song['audioPath'].toString();
    return _pin(
      context,
      id: 'file:$path',
      label: title.isEmpty ? fileNameFromPath(path) : title,
      uri: _playUri('file', {'path': path}),
      image: image,
    );
  }

  final ytid = song['ytid']?.toString() ?? '';
  return _pin(
    context,
    id: 'song:$ytid',
    label: title,
    uri: _playUri('song', {
      'id': ytid,
      'title': title,
      'artist': song['artist']?.toString() ?? '',
      'img': image,
    }),
    image: image,
  );
}

/// Lista, álbum o artista. Para un artista pregunta si quiere su radio
/// (aleatorio) o todas sus canciones en orden.
Future<void> pinPlaylistShortcut(
  BuildContext context, {
  required String id,
  required String title,
  String? image,
  bool isArtist = false,
}) async {
  var kind = 'playlist';
  if (isArtist) {
    final choice = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text(title),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, 'artist_radio'),
            child: const Text('Radio (aleatorio)'),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, 'artist'),
            child: const Text('Todas las canciones'),
          ),
        ],
      ),
    );
    if (choice == null || !context.mounted) return;
    kind = choice;
  }
  return _pin(
    context,
    id: '$kind:$id',
    label: title,
    uri: _playUri(kind, {
      'id': id,
      'title': title,
      if (image != null && image.isNotEmpty) 'img': image,
    }),
    image: image,
  );
}

/// Carpeta local (todas sus canciones, subcarpetas incluidas).
Future<void> pinFolderShortcut(BuildContext context, String path) => _pin(
  context,
  id: 'folder:$path',
  label: fileNameFromPath(path),
  uri: _playUri('folder', {'path': path}),
);

/// Emisora de radio.
Future<void> pinRadioShortcut(BuildContext context, RadioStation station) =>
    _pin(
      context,
      id: 'radio:${station.id}',
      label: station.name,
      uri: _playUri('radio', {
        'id': station.id,
        'name': station.name,
        'stream': station.streamUrl,
        'img': station.image,
        if (station.genre != null) 'genre': station.genre!,
      }),
      image: station.image,
    );

/// Podcast: al tocarlo reproduce el siguiente episodio sin escuchar, segun el
/// orden por fecha que tenga el podcast en ese momento.
Future<void> pinPodcastShortcut(BuildContext context, Podcast podcast) => _pin(
  context,
  id: 'podcast:${podcast.id}',
  label: podcast.title,
  uri: _playUri('podcast', {
    'id': podcast.id,
    'feed': podcast.feedUrl,
    'title': podcast.title,
  }),
  image: podcast.image,
);

Future<void> _pin(
  BuildContext context, {
  required String id,
  required String label,
  required Uri uri,
  String? image,
}) async {
  final choice = await showDialog<({String name, String? image})>(
    context: context,
    builder: (_) => _PinShortcutDialog(name: label, image: image),
  );
  if (choice == null || !context.mounted) return;

  try {
    final ok =
        await _channel.invokeMethod<bool>('pin', {
          'id': id,
          'label': choice.name,
          'uri': uri.toString(),
          'image': choice.image,
        }) ??
        false;
    if (context.mounted) {
      showToast(
        context,
        ok
            ? 'Confirma en el escritorio para añadir el acceso directo'
            : 'Tu launcher no permite crear accesos directos',
      );
    }
  } catch (e, stackTrace) {
    logger.log('Error pinning shortcut', error: e, stackTrace: stackTrace);
    if (context.mounted) showToast(context, 'No se pudo crear el acceso directo');
  }
}

class _PinShortcutDialog extends StatefulWidget {
  const _PinShortcutDialog({required this.name, this.image});

  final String name;
  final String? image;

  @override
  State<_PinShortcutDialog> createState() => _PinShortcutDialogState();
}

class _PinShortcutDialogState extends State<_PinShortcutDialog> {
  late final _controller = TextEditingController(text: widget.name);
  late String? _image = widget.image;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _changeImage() async {
    final picked = await pickImage(context);
    if (picked != null && mounted) setState(() => _image = picked);
  }

  @override
  Widget build(BuildContext context) {
    final hasImage = _image != null && _image!.isNotEmpty;
    return AlertDialog(
      title: const Text('Añadir al escritorio'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(14),
            child: SizedBox(
              width: 72,
              height: 72,
              child: hasImage
                  ? Image(
                      image: ArtworkProvider.get(_image!),
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => const _AppIconPreview(),
                    )
                  : const _AppIconPreview(),
            ),
          ),
          TextButton(
            onPressed: _changeImage,
            child: const Text('Cambiar imagen'),
          ),
          TextField(
            controller: _controller,
            decoration: const InputDecoration(labelText: 'Nombre'),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancelar'),
        ),
        FilledButton(
          onPressed: () {
            final name = _controller.text.trim();
            Navigator.pop(context, (
              name: name.isEmpty ? widget.name : name,
              image: _image,
            ));
          },
          child: const Text('Añadir'),
        ),
      ],
    );
  }
}

class _AppIconPreview extends StatelessWidget {
  const _AppIconPreview();

  @override
  Widget build(BuildContext context) =>
      Image.asset('assets/logo.png', fit: BoxFit.cover);
}

// ---------------------------------------------------------------------------
// Reproducir al tocar el acceso directo (dskplay://play/<tipo>?...)
// ---------------------------------------------------------------------------

Future<void> handlePlayShortcut(Uri uri) async {
  final q = uri.queryParameters;
  final kind = uri.pathSegments.isNotEmpty ? uri.pathSegments.first : '';
  try {
    switch (kind) {
      case 'song':
        final img = q['img'] ?? '';
        // Antes de reproducir: play() no devuelve hasta que se pausa.
        unawaited(_showPlayer());
        await audioHandler.addPlaylistToQueue(
          [
            {
              'id': q['id'],
              'ytid': q['id'],
              'title': q['title'] ?? '',
              'artist': q['artist'] ?? '',
              'highResImage': img,
              'lowResImage': img,
              'isLive': false,
            },
          ],
          replace: true,
          startIndex: 0,
        );
      case 'file':
        final file = File(q['path'] ?? '');
        if (!await file.exists()) return _fail('El archivo ya no existe');
        unawaited(_showPlayer());
        await audioHandler.addPlaylistToQueue(
          [await buildLocalSongMap(file)],
          replace: true,
          startIndex: 0,
        );
      case 'folder':
        final path = q['path'] ?? '';
        final dir = Directory(path);
        if (!await dir.exists()) return _fail('La carpeta ya no existe');
        final files = await collectAudioFilesRecursively(dir);
        if (files.isEmpty) return _fail('La carpeta no tiene canciones');
        unawaited(_showPlayer());
        await audioHandler.addPlaylistToQueue(
          await buildLocalSongMaps(files),
          replace: true,
          startIndex: 0,
          source: {
            'title': fileNameFromPath(path),
            'route':
                '${NavigationManager.localFilesPath}?path=${Uri.encodeComponent(path)}',
          },
        );
      case 'radio':
        unawaited(_showPlayer());
        final ok = await audioHandler.playRadioStream(
          id: q['id'] ?? '',
          name: q['name'] ?? '',
          streamUrl: q['stream'] ?? '',
          image: q['img'] ?? '',
          genre: q['genre'],
        );
        if (!ok) return _fail('No se pudo reproducir la emisora');
      case 'podcast':
        final feed = await fetchPodcastFeed(q['feed'] ?? '');
        if (feed == null) return _fail('No se pudo cargar el podcast');
        final ascending = podcastManager.episodeSortAscendingFor(
          q['id'] ?? feed.podcast.id,
        );
        final episodes = [...feed.episodes]
          ..sort((a, b) {
            final dateA = a.pubDate ?? DateTime(0);
            final dateB = b.pubDate ?? DateTime(0);
            return ascending ? dateA.compareTo(dateB) : dateB.compareTo(dateA);
          });
        final next = episodes
            .where((e) => !podcastManager.isListened(e.key))
            .firstOrNull;
        if (next == null) return _fail('Todos los episodios están escuchados');
        unawaited(_showPlayer());
        final ok = await audioHandler.playPodcastEpisode(
          next,
          podcastTitle: feed.podcast.title,
          initialPosition: podcastManager.savedPosition(next.key),
          localPath:
              podcastManager.getDownloadedEpisode(next.key)?['audioPath']
                  as String?,
        );
        if (!ok) return _fail('No se pudo reproducir el episodio');
      case 'playlist':
      case 'artist':
      case 'artist_radio':
        final isArtist = kind != 'playlist';
        final playlist = await getPlaylistInfoForWidget(
          q['id'],
          isArtist: isArtist,
          artistName: q['title'],
          artistImage: q['img'],
        );
        final songs = (playlist?['list'] as List? ?? const [])
            .whereType<Map>()
            .toList();
        if (playlist == null || songs.isEmpty) {
          return _fail('No se pudo cargar el contenido');
        }
        unawaited(_showPlayer());
        if (kind == 'artist_radio') {
          await audioHandler.addPlaylistToQueue(
            songs..shuffle(),
            replace: true,
            startIndex: 0,
          );
        } else {
          await audioHandler.playPlaylistSong(
            playlist: playlist,
            songIndex: 0,
          );
        }
    }
  } catch (e, stackTrace) {
    logger.log('Error playing shortcut', error: e, stackTrace: stackTrace);
    _fail('No se pudo reproducir');
  }
}

/// El enlace de arranque en frio llega antes de que exista el navegador.
Future<BuildContext?> _readyContext() async {
  for (var i = 0; i < 100; i++) {
    final ctx = NavigationManager.router.routerDelegate.navigatorKey.currentContext;
    if (ctx != null) return ctx;
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  return null;
}

Future<void> _fail(String message) async {
  final ctx = await _readyContext();
  if (ctx != null && ctx.mounted) showToast(ctx, message);
}

Future<void> _showPlayer() async {
  final ctx = await _readyContext();
  if (ctx != null && ctx.mounted && !isNowPlayingOpen) {
    unawaited(Navigator.of(ctx).push(createNowPlayingRoute()));
  }
}
