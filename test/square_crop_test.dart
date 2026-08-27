import 'package:dskplay/widgets/image_cropper_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

// Caja del dialogo: recuadro de 300 con dos bandas de 54 arriba y abajo.
const _pad = 54.0;
const _side = 300.0;

/// La imagen entra encajada por su lado corto y centrada en el recuadro.
Rect _crop(Size image, {double scale = 1, double? tx, double? ty}) {
  final display =
      _side / (image.width < image.height ? image.width : image.height);
  return squareCropRect(
    imageSize: image,
    displayScale: display,
    viewportTop: _pad,
    viewportSide: _side,
    scale: scale,
    translateX: tx ?? (_side - image.width * display) / 2,
    translateY: ty ?? _pad + (_side - image.height * display) / 2,
  );
}

void main() {
  test('sin tocar nada recorta el centro de una imagen cuadrada', () {
    final rect = _crop(const Size(1000, 1000));
    expect(rect.width, closeTo(rect.height, 0.01));
    expect(rect.center.dx, closeTo(500, 1));
    expect(rect.center.dy, closeTo(500, 1));
  });

  test('sin tocar nada recorta el centro de una imagen muy vertical', () {
    final rect = _crop(const Size(800, 2400));
    expect(rect.width, closeTo(800, 0.01));
    expect(rect.center.dy, closeTo(1200, 1));
  });

  test('en una imagen vertical se puede arrastrar hasta arriba del todo', () {
    // Arrastrar hacia abajo (ty mayor) sube el recuadro por la imagen.
    final rect = _crop(const Size(800, 2400), ty: 5000);
    expect(rect.top, 0);
    expect(rect.height, closeTo(800, 0.01));
  });

  test('el zoom reduce la zona recortada', () {
    const image = Size(1000, 1000);
    expect(_crop(image, scale: 2).width, closeTo(_crop(image).width / 2, 0.01));
  });

  test('arrastrar fuera de la imagen no se sale de sus limites', () {
    const image = Size(1000, 1000);
    final rect = _crop(image, tx: 5000, ty: -5000);
    expect(rect.left, greaterThanOrEqualTo(0));
    expect(rect.top, greaterThanOrEqualTo(0));
    expect(rect.right, lessThanOrEqualTo(image.width));
    expect(rect.bottom, lessThanOrEqualTo(image.height));
  });
}
