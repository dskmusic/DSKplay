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

import 'package:dskplay/main.dart';
import 'package:dskplay/services/artist_service.dart';
import 'package:dskplay/services/common_services.dart';
import 'package:dskplay/services/download_foreground_service.dart';
import 'package:dskplay/services/download_notification_service.dart';
import 'package:dskplay/services/newpipe.dart';
import 'package:dskplay/services/playlists_manager.dart';
import 'package:dskplay/services/spotify_csv_import.dart';
import 'package:dskplay/utilities/formatter.dart';
import 'package:flutter/foundation.dart';

/// Una lista a importar: la lista ya creada (`playlistId`) y sus pistas.
typedef SpotifyImportJob = ({
  String playlistId,
  String name,
  List<SpotifyTrack> tracks,
});

class SpotifyImportProgress {
  const SpotifyImportProgress({
    required this.playlistName,
    required this.done,
    required this.total,
    required this.added,
    required this.running,
  });

  final String playlistName;
  final int done;
  final int total;
  final int added;
  final bool running;

  double get fraction => total == 0 ? 0 : done / total;
}

/// Importación de listas de Spotify (CSV) fuera de la pantalla que la lanza.
///
/// Vive fuera del State a propósito: apoyándose en el servicio en primer
/// plano de las descargas, la búsqueda sigue corriendo con la app
/// minimizada, con la pantalla cerrada e incluso tras deslizar la app fuera
/// de recientes, y el progreso se ve en la misma notificación (con su
/// "Cancelar") que ya usan descargas y exportaciones.
class SpotifyImportService {
  factory SpotifyImportService() => _instance;
  SpotifyImportService._internal();
  static final SpotifyImportService _instance =
      SpotifyImportService._internal();

  /// Última importación: en curso (`running`) o la recién terminada, para
  /// que al volver a la pantalla se siga viendo en qué quedó.
  final progress = ValueNotifier<SpotifyImportProgress?>(null);

  bool _cancelled = false;

  bool get isRunning => progress.value?.running ?? false;

  void cancel() => _cancelled = true;

  /// Busca cada pista en YouTube y la añade a su lista (las listas ya deben
  /// existir; las crea quien tiene BuildContext).
  ///
  /// Acepta varias de golpe porque TuneMyMusic exporta la biblioteca entera
  /// en un solo CSV: listas, canciones que gustan, álbumes y artistas son
  /// una sola importación, con una sola notificación.
  Future<void> run(
    List<SpotifyImportJob> jobs, {
    List<SpotifyTrack> likedSongs = const [],
    List<SpotifyTrack> albums = const [],
    List<String> artists = const [],
  }) async {
    final extras = likedSongs.length + albums.length + artists.length;
    final total =
        jobs.fold<int>(0, (sum, job) => sum + job.tracks.length) + extras;
    if (isRunning || total == 0) return;
    _cancelled = false;
    var added = 0;
    var done = 0;
    final label = extras > 0
        ? 'tu biblioteca de Spotify'
        : (jobs.length == 1 ? jobs.single.name : '${jobs.length} listas');
    void publish({required bool running}) {
      progress.value = SpotifyImportProgress(
        playlistName: label,
        done: done,
        total: total,
        added: added,
        running: running,
      );
    }

    publish(running: true);
    // ponytail: comparte la notificación (un solo id) con las descargas, así
    // que importar y descargar a la vez se pisan el título. Si alguna vez
    // molesta, el arreglo está en el lado nativo, no aquí.
    final notifications = DownloadNotificationService();
    final title = 'Importando "$label"';
    await DownloadForegroundService.acquire();
    unawaited(notifications.showProgress(title, progress: 0));

    bool stopped() =>
        _cancelled || DownloadForegroundService.cancelAllRequested;

    void step(int count) {
      done += count;
      publish(running: true);
      unawaited(
        notifications.showProgress(
          title,
          progress: (done * 100 / total).round(),
        ),
      );
    }

    try {
      for (final job in jobs) {
        // ponytail: de 4 en 4. Secuencial son minutos en una lista larga y
        // más paralelismo empieza a comerse peticiones de YouTube.
        for (var i = 0; i < job.tracks.length; i += 4) {
          if (stopped()) return;
          final songs = await Future.wait(
            job.tracks.skip(i).take(4).map(_findOnYouTube),
          );
          for (final song in songs) {
            if (song == null) continue;
            if (addSongToCustomPlaylistById(job.playlistId, song) ==
                AddSongResult.added) {
              added++;
            }
          }
          step(songs.length);
        }
      }

      // ponytail: las tres secciones de la biblioteca van de una en una, son
      // pocas filas comparadas con las listas.
      for (final track in likedSongs) {
        if (stopped()) return;
        final song = await _findOnYouTube(track);
        if (song != null) {
          await updateSongLikeStatus(song['ytid'], true, songData: song);
          added++;
        }
        step(1);
      }

      for (final album in albums) {
        if (stopped()) return;
        if (await _likeAlbum(album)) added++;
        step(1);
      }

      for (final artist in artists) {
        if (stopped()) return;
        if (await _likeArtist(artist)) added++;
        step(1);
      }
    } finally {
      publish(running: false);
      DownloadForegroundService.release();
      unawaited(
        notifications.showResult(
          '$added de $total elementos importados en "$label"',
          success: added > 0,
        ),
      );
    }
  }

  /// El CSV sólo trae el nombre del disco, así que hay que localizarlo en
  /// YouTube Music antes de poder marcarlo como favorito.
  Future<bool> _likeAlbum(SpotifyTrack album) async {
    try {
      final query = '${album.title} ${album.artist}'.trim();
      final results = await NewPipe.search(
        query,
        filters: const [SearchFilter.musicAlbums],
      );
      final found = NewPipe.playlistsOf(results).firstOrNull;
      if (found == null) return false;
      await updatePlaylistLikeStatus(
        found.id,
        true,
        playlistData: {
          'ytid': found.id,
          'title': found.title,
          'image': found.thumbnail,
          'source': 'youtube',
          'isAlbum': true,
          'list': [],
        },
      );
      return true;
    } catch (e, stackTrace) {
      logger.log(
        'Error importing Spotify album',
        error: e,
        stackTrace: stackTrace,
      );
      return false;
    }
  }

  /// Los artistas favoritos viven en la misma lista que las listas que gustan,
  /// con el mapa que ya prepara [searchVerifiedArtists].
  Future<bool> _likeArtist(String name) async {
    try {
      final found = (await searchVerifiedArtists(name, limit: 1)).firstOrNull;
      final artistId = found?['ytid']?.toString();
      if (found == null || artistId == null || artistId.isEmpty) return false;
      await updatePlaylistLikeStatus(artistId, true, playlistData: found);
      return true;
    } catch (e, stackTrace) {
      logger.log(
        'Error importing Spotify artist',
        error: e,
        stackTrace: stackTrace,
      );
      return false;
    }
  }

  Future<Map<String, dynamic>?> _findOnYouTube(SpotifyTrack track) async {
    try {
      final query = '${track.title} ${track.artist}'.trim();
      final results = await NewPipe.search(query);
      final video = NewPipe.videosOf(results).firstOrNull;
      return video == null ? null : returnSongLayout(0, video);
    } catch (e, stackTrace) {
      logger.log(
        'Error searching Spotify track',
        error: e,
        stackTrace: stackTrace,
      );
      return null;
    }
  }
}

final spotifyImportService = SpotifyImportService();
