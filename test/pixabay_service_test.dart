import 'package:dskplay/services/pixabay_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('fromJson tira de webformat/preview cuando falta la grande', () {
    final image = PixabayImage.fromJson({
      'id': 42,
      'previewURL': 'https://p/prev.jpg',
      'webformatURL': 'https://p/web.jpg',
      'largeImageURL': '',
      'tags': 'gato, sofá',
    });
    expect(image.id, '42');
    expect(image.webformatUrl, 'https://p/web.jpg');
    expect(image.largeUrl, 'https://p/web.jpg');

    final onlyPreview = PixabayImage.fromJson({
      'id': 7,
      'previewURL': 'https://p/prev.jpg',
    });
    expect(onlyPreview.webformatUrl, 'https://p/prev.jpg');
    expect(onlyPreview.largeUrl, 'https://p/prev.jpg');
    expect(onlyPreview.tags, '');
  });

  test('lang sólo si Pixabay lo admite', () {
    expect(pixabayLangFor('es'), 'es');
    expect(pixabayLangFor('ta'), 'en');
  });
}
