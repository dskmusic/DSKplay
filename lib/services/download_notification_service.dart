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
import 'dart:io';

import 'package:dskplay/services/download_foreground_service.dart';
import 'package:flutter/services.dart';

/// Drives the single system notification shown while a download or a
/// "make available offline" action is running. Android-only: other
/// platforms no-op.
///
/// This is only a client: the notification itself is built and posted by
/// DownloadForegroundService on the native side, which is also the one
/// holding it in the foreground and owning its "Cancelar" action. It used
/// to be posted from here too via flutter_local_notifications, on the same
/// id as the native one - two writers over one notification, which is what
/// made the percentage jump backwards, left the useless (Dart-owned)
/// Cancelar on top, and froze the whole thing as soon as the app was
/// swiped from recents.
class DownloadNotificationService {
  factory DownloadNotificationService() => _instance;
  DownloadNotificationService._internal();
  static final DownloadNotificationService _instance =
      DownloadNotificationService._internal();

  static const _channel = MethodChannel('dskplay/download_service');

  // Android silently coalesces notify() calls fired too close together for
  // the same id, so a playlist's per-chunk progress callbacks would burst
  // through and leave the bar stuck on a stale percentage.
  static const Duration _minUpdateInterval = Duration(milliseconds: 400);

  String? _lastTitle;
  int _lastPercent = -1;
  DateTime? _lastSentAt;

  /// Shows/updates the ongoing progress notification.
  ///
  /// Nothing is awaited before the channel send on purpose, and callers may
  /// fire it without awaiting: platform channel messages sent from this
  /// isolate arrive in the order they were sent, so the percentage can
  /// never land out of order. Awaiting *anything* first (a permission
  /// check, plugin init...) let two updates race across the channel, which
  /// is exactly what made the bar go 30% → 20% → 40% → 20%.
  Future<void> showProgress(String title, {int? progress}) async {
    if (!Platform.isAndroid) return;
    if (DownloadForegroundService.cancelAllRequested) return;

    final percent = (progress ?? 0).clamp(0, 100);

    if (title != _lastTitle) {
      _lastTitle = title;
      _lastPercent = -1;
      _lastSentAt = null;
    } else if (percent <= _lastPercent) {
      // Unchanged, or a stale report from a slower parallel worker:
      // progress only ever moves forward within one operation.
      return;
    }

    final now = DateTime.now();
    final lastSentAt = _lastSentAt;
    if (percent < 100 &&
        lastSentAt != null &&
        now.difference(lastSentAt) < _minUpdateInterval) {
      return;
    }

    _lastPercent = percent;
    _lastSentAt = now;
    unawaited(
      _channel
          .invokeMethod('showProgress', {'title': title, 'progress': percent})
          .catchError((_) => null),
    );
  }

  /// Replaces the progress notification with a final result.
  Future<void> showResult(String title, {required bool success}) async {
    if (!Platform.isAndroid) return;
    _lastTitle = null;
    _lastPercent = -1;
    _lastSentAt = null;

    if (DownloadForegroundService.cancelAllRequested) {
      // The user cancelled this on the notification itself - a lingering
      // "Ha fallado" would only be telling them what they already know.
      await cancel();
      return;
    }

    try {
      await _channel.invokeMethod('showResult', {
        'title': title,
        'text': success ? 'Completado' : 'Ha fallado',
        // Confirma brevemente y se quita de en medio; un fallo se queda
        // (descartable a mano) porque el usuario puede necesitar enterarse.
        // Lo descarta el sistema y no un Future de aquí: ese no llegaba a
        // correr cuando audio_service se llevaba por delante el engine junto
        // con la descarga que acababa de soltar el servicio, y el
        // "Completado" se quedaba clavado en la barra para siempre.
        'autoDismissMs': success ? 3000 : 0,
      });
    } catch (_) {}
  }

  Future<void> cancel() async {
    if (!Platform.isAndroid) return;
    _lastTitle = null;
    _lastPercent = -1;
    _lastSentAt = null;
    try {
      await _channel.invokeMethod('cancelNotification');
    } catch (_) {}
  }
}
