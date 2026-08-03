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

import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';

/// Keeps the Android process at foreground priority while a download is
/// running, the same way audio_service already does for playback, so
/// downloads survive the app being swiped away from recents instead of
/// being killed with it.
///
/// Reference-counted: concurrent downloads (e.g. a playlist's parallel
/// workers, or a manual download started while a playlist export is still
/// running) share one native service instead of racing start/stop calls.
class DownloadForegroundService {
  static const _channel = MethodChannel('dskplay/download_service');
  static int _activeCount = 0;
  static Timer? _stopTimer;
  static bool _permissionRequested = false;

  /// Grace period before the native service is actually torn down, so
  /// back-to-back downloads (a playlist's next song, or the user queueing
  /// another one) don't drop the count to zero and back to one in the same
  /// instant - that took audio_service's shared FlutterEngine down with it,
  /// which is precisely the window where downloads kept dying.
  static const Duration _stopDelay = Duration(seconds: 5);

  /// Set when the user taps "Cancelar" on the persistent notification -
  /// active download loops (see common_services.dart and
  /// playlist_download_service.dart) check this and unwind on their own,
  /// since that's the only way to actually stop mid-flight network/ffmpeg
  /// work started from Dart. Force-closing the app used to be the only way
  /// to interrupt this notification, which is what this exists to fix.
  static bool cancelAllRequested = false;

  /// Whether any download - individual or batch (playlist/podcast) - is
  /// currently in progress.
  static bool get isActive => _activeCount > 0;

  /// Awaited (unlike [release]) so a download's actual network I/O never
  /// starts before the protective native service is confirmed running -
  /// otherwise closing the app in the first instant after starting a
  /// download could race the service's own startup.
  static Future<void> acquire() async {
    if (!Platform.isAndroid) return;
    _stopTimer?.cancel();
    _stopTimer = null;
    _activeCount++;
    if (_activeCount == 1) {
      cancelAllRequested = false;
      _channel.setMethodCallHandler(_onNativeCall);
      // The native idle-auto-close fallback (see audio_service.dart) doesn't
      // know a download just started, so it would otherwise kill the
      // process mid-download once its timer elapses.
      unawaited(_channel.invokeMethod('cancelIdleClose').catchError((_) {}));
      // Without this the download still runs, but its notification (and so
      // its Cancelar button) is silently never shown on Android 13+.
      if (!_permissionRequested) {
        _permissionRequested = true;
        try {
          await Permission.notification.request();
        } catch (_) {}
      }
      try {
        await _channel.invokeMethod('start');
      } catch (_) {}
    }
  }

  static Future<void> _onNativeCall(MethodCall call) async {
    if (call.method == 'cancelAll') {
      cancelAllRequested = true;
    }
  }

  static void release() {
    if (!Platform.isAndroid || _activeCount == 0) return;
    _activeCount--;
    if (_activeCount == 0) {
      _stopTimer?.cancel();
      _stopTimer = Timer(_stopDelay, () {
        _stopTimer = null;
        if (_activeCount != 0) return;
        unawaited(_channel.invokeMethod('stop').catchError((_) => null));
      });
    }
  }
}
