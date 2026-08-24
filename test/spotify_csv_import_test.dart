import 'package:dskplay/services/spotify_csv_import.dart';
import 'package:flutter_test/flutter_test.dart';

// Cabeceras reales de los tres exportadores (filas recortadas).
const _chosic =
    '#,Track name,Artist name,Album,Duration\r\n'
    '1,"Hello, Goodbye","The Beatles, Ringo",Magical,3:27\r\n'
    '2,Yesterday,The Beatles,Help!,2:05\r\n';

const _exportify =
    '\uFEFFTrack URI,Track Name,Album Name,Artist Name(s),Release Date,'
    'Duration (ms),Popularity\n'
    'spotify:track:00FDHurakzVEiPutdUxXXq,"Wouldn\'t It Be Good",'
    '"Human Racing","Nik Kershaw",1984-01-01,277053,70\n';

const _tuneMyMusic =
    '\uFEFFTrack name,Artist name,Album,Playlist name,Type,ISRC,Spotify - id\n'
    '"New Life","Victor Castilla","Family","Favorite Songs","Favorite",'
    '"QZDFP2082658","2yv7elUgfYw9EYYXuYQtC4"\n'
    '"Disco 1","Alguien","X","Disco Del Sol","Playlist","A","b"\n'
    '"Disco 2","Otro","Y","Disco Del Sol","Playlist","C","d"\n'
    '"Mariah Carey","","","Favorite Artists","Artist","",""\n'
    '"Trazos","Victor Castilla","Trazos","Favorite Albums","Album","E","f"\n';

void main() {
  test('Chosic: una lista sin nombre, comas dentro de comillas', () {
    final playlists = parseSpotifyCsv(_chosic).playlists;
    expect(playlists.length, 1);
    expect(playlists.single.name, isNull);
    final tracks = playlists.single.tracks;
    expect(tracks.length, 2);
    expect(tracks.first.title, 'Hello, Goodbye');
    expect(tracks.first.artist, 'The Beatles');
  });

  test('Exportify: "Track URI" no se confunde con el título, y BOM', () {
    final tracks = parseSpotifyCsvTracks(_exportify);
    expect(tracks.length, 1);
    expect(tracks.single.title, "Wouldn't It Be Good");
    expect(tracks.single.artist, 'Nik Kershaw');
  });

  test('TuneMyMusic: separa listas, favoritas, álbumes y artistas', () {
    final library = parseSpotifyCsv(_tuneMyMusic);
    expect(library.playlists.map((p) => p.name), ['Disco Del Sol']);
    expect(library.playlists.single.tracks.length, 2);
    expect(library.likedSongs.single.title, 'New Life');
    expect(library.likedSongs.single.artist, 'Victor Castilla');
    expect(library.albums.single.title, 'Trazos');
    expect(library.albums.single.artist, 'Victor Castilla');
    expect(library.artists, ['Mariah Carey']);
    expect(countSpotifyLibrary(library), 5);
  });

  test('acepta punto y coma, comillas escapadas y filas vacías', () {
    const csv = 'Song Name;Artist Name(s)\n"Say ""Hi""";A\n\n;\n';
    final tracks = parseSpotifyCsvTracks(csv);
    expect(tracks.length, 1);
    expect(tracks.single.title, 'Say "Hi"');
    expect(tracks.single.artist, 'A');
  });

  test('sin cabecera reconocible asume titulo,artista', () {
    final tracks = parseSpotifyCsvTracks(
      'Imagine,John Lennon\nWoman,John Lennon',
    );
    expect(tracks.length, 2);
    expect(tracks.first.title, 'Imagine');
  });

  test('CSV vacío no revienta', () {
    expect(countSpotifyLibrary(parseSpotifyCsv('   ')), 0);
  });
}
