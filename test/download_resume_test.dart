import 'dart:io';

import 'package:dskplay/services/io_service.dart';
import 'package:flutter_test/flutter_test.dart';

/// El fallo que motivó downloadUriToFile: un socket que se corta a mitad
/// (Wi-Fi en ahorro de energía al cerrar la app desde recientes) dejaba la
/// descarga colgada para siempre, y al fallar se perdía todo lo bajado.
void main() {
  test('reanuda por rangos tras un corte a mitad', () async {
    final payload = List<int>.generate(64 * 1024, (i) => i % 251);
    var attempts = 0;

    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      attempts++;
      final range = request.headers.value(HttpHeaders.rangeHeader);
      final start = range == null
          ? 0
          : int.parse(RegExp(r'bytes=(\d+)-').firstMatch(range)!.group(1)!);
      final body = payload.sublist(start);
      final response = request.response
        ..statusCode = start == 0 ? HttpStatus.ok : HttpStatus.partialContent
        ..headers.contentLength = body.length;
      // El primer intento anuncia el tamaño completo pero sólo envía la
      // mitad y cierra: el cliente ve la conexión morir a media descarga.
      response.add(attempts == 1 ? body.sublist(0, body.length ~/ 2) : body);
      try {
        await response.close();
      } catch (_) {}
    });

    final file = File('${Directory.systemTemp.createTempSync().path}/dl.bin');
    final ok = await downloadUriToFile(
      Uri.parse('http://${server.address.address}:${server.port}/audio'),
      file,
    );

    expect(ok, isTrue);
    expect(attempts, 2, reason: 'debe reintentar exactamente una vez');
    expect(await file.readAsBytes(), payload, reason: 'sin bytes perdidos ni duplicados');

    await server.close(force: true);
  });
}
