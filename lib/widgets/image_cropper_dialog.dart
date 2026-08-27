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
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:dskplay/extensions/l10n.dart';
import 'package:dskplay/widgets/spinner.dart';
import 'package:flutter/material.dart';

/// Zona de la imagen original (en pixeles) que queda dentro del recuadro
/// cuadrado, dado el desplazamiento y zoom del `InteractiveViewer`.
///
/// [displayScale] son los pixeles de pantalla que ocupa un pixel de la imagen
/// antes de tocar el zoom; el recuadro empieza en [viewportTop] y mide
/// [viewportSide] de lado.
///
/// Va aparte del widget para poder probarla sin montar interfaz.
Rect squareCropRect({
  required Size imageSize,
  required double displayScale,
  required double viewportTop,
  required double viewportSide,
  required double scale,
  required double translateX,
  required double translateY,
}) {
  final unit = displayScale * scale;
  final side = math.min(
    viewportSide / unit,
    math.min(imageSize.width, imageSize.height),
  );
  final left = (-translateX / unit).clamp(0.0, imageSize.width - side);
  final top = ((viewportTop - translateY) / unit).clamp(
    0.0,
    imageSize.height - side,
  );

  return Rect.fromLTWH(left, top, side, side);
}

/// Lado del recuadro de recorte que cabe en la pantalla.
double cropViewportSide(BuildContext context) =>
    math.min<double>(MediaQuery.sizeOf(context).width - 96, 300);

/// Deja al usuario encuadrar la imagen en 1:1 y devuelve un data URI PNG.
/// Devuelve null si cancela.
Future<String?> showSquareCropDialog(
  BuildContext context,
  String dataUri,
) async {
  final base64Data = dataUri.contains(',') ? dataUri.split(',').last : dataUri;
  final Uint8List bytes;
  try {
    bytes = base64Decode(base64Data);
  } catch (_) {
    return dataUri;
  }

  final cropped = await showDialog<String>(
    context: context,
    builder: (_) => _SquareCropDialog(bytes),
  );
  return cropped;
}

class _SquareCropDialog extends StatefulWidget {
  const _SquareCropDialog(this.bytes);

  final Uint8List bytes;

  @override
  State<_SquareCropDialog> createState() => _SquareCropDialogState();
}

class _SquareCropDialogState extends State<_SquareCropDialog> {
  final _controller = TransformationController();
  ui.Image? _image;
  bool _working = false;

  @override
  void initState() {
    super.initState();
    unawaited(_decode());
  }

  @override
  void dispose() {
    _controller.dispose();
    _image?.dispose();
    super.dispose();
  }

  Future<void> _decode() async {
    final image = await decodeImageFromList(widget.bytes);
    if (!mounted) return;

    // La imagen entra encajada por su lado corto y centrada en el recuadro:
    // asi una foto muy vertical sobra por arriba y por abajo y se puede
    // arrastrar sin tener que ampliarla antes.
    final side = cropViewportSide(context);
    final pad = side * 0.18;
    final display = _displayScale(image, side);
    setState(() {
      _image = image;
      _controller.value = Matrix4.translationValues(
        (side - image.width * display) / 2,
        pad + (side - image.height * display) / 2,
        0,
      );
    });
  }

  double _displayScale(ui.Image image, double side) =>
      side / math.min(image.width, image.height);

  Future<void> _crop(double side, double pad) async {
    final image = _image;
    if (image == null || _working) return;
    setState(() => _working = true);

    final matrix = _controller.value;
    final src = squareCropRect(
      imageSize: Size(image.width.toDouble(), image.height.toDouble()),
      displayScale: _displayScale(image, side),
      viewportTop: pad,
      viewportSide: side,
      scale: matrix.getMaxScaleOnAxis(),
      translateX: matrix.storage[12],
      translateY: matrix.storage[13],
    );

    // Sin subir de 720: la caratula mas grande que usa la app es bastante
    // menor y el data URI acaba en Hive.
    final outSide = math.min(src.width.round(), 720);
    final recorder = ui.PictureRecorder();
    ui.Canvas(recorder).drawImageRect(
      image,
      src,
      Rect.fromLTWH(0, 0, outSide.toDouble(), outSide.toDouble()),
      Paint()..filterQuality = FilterQuality.high,
    );
    final picture = recorder.endRecording();
    final result = await picture.toImage(outSide, outSide);
    final data = await result.toByteData(format: ui.ImageByteFormat.png);
    picture.dispose();
    result.dispose();

    if (!mounted) return;
    if (data == null) {
      Navigator.of(context).pop();
      return;
    }
    Navigator.of(
      context,
    ).pop('data:image/png;base64,${base64Encode(data.buffer.asUint8List())}');
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final image = _image;
    final side = cropViewportSide(context);
    final pad = side * 0.18;
    final display = image == null ? 1.0 : _displayScale(image, side);

    return AlertDialog(
      title: Text(context.l10n!.adjustImage),
      content: image == null
          ? const SizedBox(height: 120, child: Center(child: Spinner()))
          : Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: SizedBox(
                    width: side,
                    height: side + pad * 2,
                    child: Stack(
                      children: [
                        InteractiveViewer(
                          transformationController: _controller,
                          // El hijo va a su tamano real (no al de la caja) y
                          // el margen deja que el recuadro llegue justo al
                          // borde de la imagen, ni mas ni menos.
                          constrained: false,
                          boundaryMargin: EdgeInsets.symmetric(vertical: pad),
                          minScale: 1,
                          maxScale: 6,
                          child: SizedBox(
                            width: image.width * display,
                            height: image.height * display,
                            child: RawImage(image: image, fit: BoxFit.fill),
                          ),
                        ),
                        IgnorePointer(
                          child: Column(
                            children: [
                              Container(height: pad, color: Colors.black54),
                              Container(
                                height: side,
                                decoration: BoxDecoration(
                                  border: Border.all(
                                    color: Colors.white70,
                                    width: 2,
                                  ),
                                ),
                              ),
                              Container(height: pad, color: Colors.black54),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  context.l10n!.adjustImageHint,
                  style: TextStyle(
                    fontSize: 12,
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(context.l10n!.cancel),
        ),
        TextButton(
          onPressed: image == null || _working ? null : () => _crop(side, pad),
          child: Text(context.l10n!.confirm),
        ),
      ],
    );
  }
}
