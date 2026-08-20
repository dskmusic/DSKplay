import 'dart:io';

import 'package:dskplay/services/ytmusic.dart';
import 'package:flutter_test/flutter_test.dart';

// Sonda en vivo (fuera de la suite: el fichero no acaba en _test.dart).
// Pega de verdad contra YouTube Music para ver qué devuelve
// el cliente portado. No forma parte de la suite (se corre a mano).
void main() {
  setUpAll(() => HttpOverrides.global = null);

  test('searchArtists', () async {
    final artists = await ytMusic.searchArtists('Coldplay');
    print('artistas: ${artists.length}');
    for (final a in artists.take(3)) {
      print('  ${a.id} | ${a.name}');
    }
    expect(artists, isNotEmpty);
  });

  test('getArtistReleases + getAlbumTracks', () async {
    final artists = await ytMusic.searchArtists('Coldplay');
    final id = artists.first.id;
    final releases = await ytMusic.getArtistReleases(id);
    print('releases: ${releases.length}');
    for (final r in releases.take(5)) {
      print('  ${r.id} | ${r.title} | ${r.type} | ${r.year}');
    }
    expect(releases, isNotEmpty);

    final tracks = await ytMusic.getAlbumTracks(
      releases.first.id,
      author: artists.first.name,
      channelId: id,
    );
    print('tracks de ${releases.first.title}: ${tracks.length}');
    for (final t in tracks.take(3)) {
      print('  ${t.id} | ${t.title} | ${t.author} | ${t.duration}');
    }
    expect(tracks, isNotEmpty);
  });

  test('getAlbum', () async {
    final artists = await ytMusic.searchArtists('Coldplay');
    final releases = await ytMusic.getArtistReleases(artists.first.id);
    final album = await ytMusic.getAlbum(releases.first.id);
    print('album: ${album.title} | ${album.artist} | ${album.year}');
    print('  tracks: ${album.tracks.length}');
    expect(album.tracks, isNotEmpty);
  });

  test('getArtistProfile', () async {
    final artists = await ytMusic.searchArtists('Coldplay');
    final p = await ytMusic.getArtistProfile(artists.first.id);
    print('monthlyListeners: ${p.monthlyListeners}');
    print('topSongs: ${p.topSongs.length}');
    print('releases: ${p.releases.length}');
    print('relatedArtists: ${p.relatedArtists.length}');
  });
}
