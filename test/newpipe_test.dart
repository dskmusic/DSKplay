import 'package:dskplay/services/newpipe.dart';
import 'package:flutter_test/flutter_test.dart';

// Solo la lógica pura de newpipe.dart: lo que sustituye a VideoId/ChannelId de
// youtube_explode_dart y el orden de los streams. El puente nativo se prueba en
// el dispositivo.
void main() {
  test('parseVideoId acepta las formas de URL que usa la app', () {
    const id = 'dQw4w9WgXcQ';
    expect(VideoId.parseVideoId(id), id);
    expect(VideoId.parseVideoId('https://www.youtube.com/watch?v=$id'), id);
    expect(VideoId.parseVideoId('https://youtu.be/$id'), id);
    expect(VideoId.parseVideoId('https://www.youtube.com/shorts/$id'), id);
    expect(VideoId.parseVideoId('https://www.youtube.com/embed/$id?start=1'), id);
    expect(VideoId.parseVideoId('https://dskmusic.com'), isNull);
  });

  test('parsePlaylistId saca la lista y descarta las mixes', () {
    const id = 'PLgzTt0k8mXzEk586ze4BjvDXR7c-TUSnx';
    expect(PlaylistId.parsePlaylistId(id), id);
    expect(
      PlaylistId.parsePlaylistId('https://www.youtube.com/playlist?list=$id'),
      id,
    );
    expect(
      PlaylistId.parsePlaylistId(
        'https://www.youtube.com/watch?v=dQw4w9WgXcQ&list=$id',
      ),
      id,
    );
    // Las mixes se generan al vuelo y no se pueden abrir como lista.
    expect(
      PlaylistId.parsePlaylistId('https://www.youtube.com/playlist?list=RD123'),
      isNull,
    );
    expect(PlaylistId.parsePlaylistId('https://youtu.be/dQw4w9WgXcQ'), isNull);
  });

  test('validateChannelId solo acepta ids UC de 24 caracteres', () {
    expect(ChannelId.validateChannelId('UCuAXFkgsw1L7xaCfnd5JJOw'), isTrue);
    expect(ChannelId.validateChannelId('UCtoo-short'), isFalse);
    expect(ChannelId.validateChannelId('MPREb_abcdefghijklmnop'), isFalse);
  });

  test('sortByBitrate ordena de mayor a menor y no toca la lista original', () {
    const s = AudioStreamInfo(
      url: '',
      bitrate: 0,
      itag: 0,
      codec: '',
      mime: '',
      container: '',
    );
    final original = [
      AudioStreamInfo(url: 'a', bitrate: 96, itag: s.itag, codec: '', mime: '', container: ''),
      AudioStreamInfo(url: 'b', bitrate: 160, itag: s.itag, codec: '', mime: '', container: ''),
      AudioStreamInfo(url: 'c', bitrate: 128, itag: s.itag, codec: '', mime: '', container: ''),
    ];

    expect(original.sortByBitrate().map((e) => e.url), ['b', 'c', 'a']);
    expect(original.map((e) => e.url), ['a', 'b', 'c']);
    expect(original.withHighestBitrate().url, 'b');
  });
}
