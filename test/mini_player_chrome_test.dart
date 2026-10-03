import 'package:audio_service/audio_service.dart';
import 'package:dskplay/widgets/mini_player.dart';
import 'package:flutter_test/flutter_test.dart';

// El mini player se reconstruia entero (portada, marquesina, titulo) cada vez
// que avanzaba el reloj. Ahora solo escucha esto, que el reloj no mueve.
void main() {
  final queue = [
    MediaItem(id: '1', title: 'una'),
    MediaItem(id: '2', title: 'otra'),
  ];

  test('el avance de la posicion no cambia el chrome', () {
    final antes = PlaybackState(
      playing: true,
      updatePosition: const Duration(seconds: 10),
    );
    final despues = PlaybackState(
      playing: true,
      updatePosition: const Duration(seconds: 11),
    );

    // Iguales => el distinct del stream se los come y nadie reconstruye.
    expect(playerChromeOf(antes, queue), playerChromeOf(despues, queue));
  });

  test('pausar si llega', () {
    expect(
      playerChromeOf(PlaybackState(playing: true), queue),
      isNot(playerChromeOf(PlaybackState(), queue)),
    );
  });

  test('hasNext mira el sitio en la cola', () {
    expect(playerChromeOf(PlaybackState(queueIndex: 0), queue).hasNext, isTrue);
    expect(
      playerChromeOf(PlaybackState(queueIndex: 1), queue).hasNext,
      isFalse,
    );
    expect(
      playerChromeOf(PlaybackState(queueIndex: 0), [queue.first]).hasNext,
      isFalse,
    );
  });
}
