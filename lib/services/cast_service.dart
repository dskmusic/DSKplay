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

import 'package:dskplay/main.dart' show logger;
import 'package:dskplay/models/position_data.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Un receptor al que se puede enviar la reproducción: Chromecast o Smart TV
/// (DLNA). La app no distingue entre ellos salvo para pintar el icono.
class CastDevice {
  const CastDevice({required this.id, required this.name, required this.type});

  factory CastDevice.fromMap(Map<Object?, Object?> map) => CastDevice(
    id: map['id']?.toString() ?? '',
    name: map['name']?.toString() ?? '',
    type: map['type']?.toString() ?? 'cast',
  );

  final String id;
  final String name;

  /// `cast` (Chromecast) o `dlna` (Smart TV).
  final String type;

  bool get isChromecast => type == 'cast';

  @override
  bool operator ==(Object other) => other is CastDevice && other.id == id;

  @override
  int get hashCode => id.hashCode;
}

/// Cliente Dart del puente de cast. Todo el trabajo de verdad (descubrimiento,
/// envío, sondeo y detección de fin de pista) está al otro lado del canal, en
/// `android/.../cast/CastController.kt`.
class CastService {
  CastService._() {
    _channel.setMethodCallHandler(_onNativeCall);
  }

  static final CastService instance = CastService._();

  static const _channel = MethodChannel('com.dskmusic.dskplay/cast');

  /// Receptor en uso, o null cuando el audio suena en el móvil.
  final ValueNotifier<CastDevice?> activeDevice = ValueNotifier(null);

  /// Se va rellenando mientras dura la búsqueda (SSDP tarda unos segundos).
  final ValueNotifier<List<CastDevice>> devices = ValueNotifier(const []);

  final ValueNotifier<bool> isDiscovering = ValueNotifier(false);

  /// Lo que dice el receptor: posición, duración y si está sonando. Alimenta la
  /// barra de progreso y el estado del reproductor mientras se castea.
  final _positionController = StreamController<PositionData>.broadcast();
  Stream<PositionData> get positionStream => _positionController.stream;

  PositionData _lastPosition = PositionData(
    Duration.zero,
    Duration.zero,
    Duration.zero,
  );
  PositionData get lastPosition => _lastPosition;

  bool _remotePlaying = false;
  bool get remotePlaying => _remotePlaying;

  bool get isCasting => activeDevice.value != null;

  /// El receptor terminó la pista: el handler avanza en la cola.
  VoidCallback? onTrackFinished;

  /// Se cayó la sesión (la tele se apagó, el usuario desconectó desde ella,
  /// se perdió el wifi): hay que devolver el sonido al móvil.
  VoidCallback? onDisconnected;

  /// El estado remoto cambió (play/pausa desde el mando de la tele).
  VoidCallback? onRemoteStateChanged;

  Timer? _preparingTimer;
  bool _preparing = false;

  /// Se está preparando un envío: resolver la fuente, descargarla si la tele lo
  /// necesita y esperar a que el receptor arranque de verdad. Mientras tanto la
  /// app lo pinta como "cargando"; en DLNA eso son varios segundos en los que
  /// si no, parece que no está pasando nada.
  bool get preparing => _preparing;

  set preparing(bool value) {
    _preparing = value;
    _preparingTimer?.cancel();
    // Hay teles que se quedan esperando a que les den al play desde su mando:
    // la rueda no puede girar eternamente.
    if (value) {
      _preparingTimer = Timer(const Duration(seconds: 40), () {
        _preparing = false;
        onRemoteStateChanged?.call();
      });
    }
  }

  Future<dynamic> _onNativeCall(MethodCall call) async {
    switch (call.method) {
      case 'onDevice':
        final device = CastDevice.fromMap(
          Map<Object?, Object?>.from(call.arguments as Map),
        );
        if (!devices.value.contains(device)) {
          devices.value = [...devices.value, device];
        }
      case 'onDiscoveryFinished':
        isDiscovering.value = false;
      case 'onPosition':
        final args = Map<Object?, Object?>.from(call.arguments as Map);
        final pos = (args['position'] as int?) ?? -1;
        final dur = (args['duration'] as int?) ?? -1;
        final playing = (args['playing'] as bool?) ?? false;
        _lastPosition = PositionData(
          Duration(seconds: pos < 0 ? 0 : pos),
          // El receptor no informa de cuánto lleva bufferado; con la posición
          // basta para que la barra no se vea vacía por detrás.
          Duration(seconds: pos < 0 ? 0 : pos),
          Duration(seconds: dur < 0 ? 0 : dur),
        );
        if (!_positionController.isClosed) {
          _positionController.add(_lastPosition);
        }
        // La duración no vale como señal: la tele ya la anuncia mientras sigue
        // en TRANSITIONING (la lleva el propio DIDL que le mandamos). Que esté
        // en PLAYING, o que la posición avance, sí es que ya está sonando.
        if (_preparing && (playing || pos > 0)) {
          preparing = false;
          onRemoteStateChanged?.call();
        }
        if (_remotePlaying != playing) {
          _remotePlaying = playing;
          onRemoteStateChanged?.call();
        }
      case 'onLog':
        // Las trazas del lado nativo acaban en el mismo sitio que las de Dart,
        // asi que Ajustes > Copiar logs ya sirve para diagnosticar un cast.
        logger.log('cast/${call.arguments}');
      case 'onTrackFinished':
        onTrackFinished?.call();
      case 'onDisconnected':
        activeDevice.value = null;
        preparing = false;
        _remotePlaying = false;
        onDisconnected?.call();
    }
    return null;
  }

  Future<bool> isAvailable() async {
    try {
      return await _channel.invokeMethod<bool>('isAvailable') ?? false;
    } on PlatformException catch (e) {
      logger.log('cast isAvailable: ${e.message}');
      return false;
    }
  }

  /// Arranca la búsqueda. Chromecast aparece casi al instante; las Smart TV
  /// llegan a lo largo del escaneo SSDP.
  Future<void> startDiscovery() async {
    devices.value = const [];
    isDiscovering.value = true;
    try {
      await _channel.invokeMethod<void>('startDiscovery');
      await _channel.invokeMethod<void>('discover');
    } on PlatformException catch (e) {
      logger.log('cast discover: ${e.message}');
      isDiscovering.value = false;
    }
  }

  Future<void> stopDiscovery() async {
    isDiscovering.value = false;
    try {
      await _channel.invokeMethod<void>('stopDiscovery');
    } on PlatformException catch (_) {}
  }

  /// Envía una pista al receptor. Devuelve null si fue bien, o el mensaje de
  /// error para enseñarlo.
  ///
  /// [localPath] gana a [url]: si la canción está descargada se le sirve el
  /// fichero desde el propio móvil en vez de hacerle bajar el stream.
  Future<String?> load({
    required CastDevice device,
    String? url,
    String? localPath,
    required String title,
    required String artist,
    String? artwork,
    bool isLive = false,
    Duration startAt = Duration.zero,
    Duration duration = Duration.zero,
  }) async {
    try {
      await _channel.invokeMethod<String>('load', {
        'deviceId': device.id,
        'url': url,
        'localPath': localPath,
        'title': title,
        'artist': artist,
        'artwork': artwork,
        'isLive': isLive,
        'startSeconds': startAt.inSeconds,
        'durationMs': duration.inMilliseconds,
      });
      activeDevice.value = device;
      _remotePlaying = true;
      _lastPosition = PositionData(startAt, startAt, duration);
      return null;
    } on PlatformException catch (e) {
      logger.log('cast load: ${e.message}');
      return e.message ?? 'Error';
    }
  }

  Future<void> play() => _send('play', playing: true);

  Future<void> pause() => _send('pause', playing: false);

  Future<void> stop() => _send('stop', playing: false);

  Future<void> seek(Duration position) async {
    _lastPosition = PositionData(position, position, _lastPosition.duration);
    try {
      await _channel.invokeMethod<void>('seek', {
        'seconds': position.inSeconds,
      });
    } on PlatformException catch (e) {
      logger.log('cast seek: ${e.message}');
    }
  }

  /// Cierra la sesión y devuelve el sonido al móvil.
  Future<void> disconnect() async {
    activeDevice.value = null;
    preparing = false;
    _remotePlaying = false;
    try {
      await _channel.invokeMethod<void>('disconnect');
    } on PlatformException catch (e) {
      logger.log('cast disconnect: ${e.message}');
    }
  }

  Future<void> _send(String method, {required bool playing}) async {
    try {
      await _channel.invokeMethod<void>(method);
      _remotePlaying = playing;
    } on PlatformException catch (e) {
      logger.log('cast $method: ${e.message}');
    }
  }
}

final castService = CastService.instance;
