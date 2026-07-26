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

import 'dart:io';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// Shows a system notification with a progress bar for manual downloads
/// and "make available offline" actions, instead of only the final toast.
/// Android-only: other platforms no-op.
class DownloadNotificationService {
  factory DownloadNotificationService() => _instance;
  DownloadNotificationService._internal();
  static final DownloadNotificationService _instance =
      DownloadNotificationService._internal();

  static const String _channelId = 'downloads';
  static const String _channelName = 'Descargas';
  static const String _channelDescription =
      'Progreso de descargas y disponibilidad sin conexión';

  final _plugin = FlutterLocalNotificationsPlugin();
  bool _initialized = false;
  int _nextId = 100000;

  /// A fresh notification id for a single download/offline operation.
  int nextId() => _nextId++;

  Future<void> _ensureInitialized() async {
    if (_initialized) return;
    const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
    await _plugin.initialize(
      const InitializationSettings(android: androidInit),
    );
    await _plugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >()
        ?.requestNotificationsPermission();
    _initialized = true;
  }

  AndroidNotificationDetails _details({
    required bool ongoing,
    int? progress,
    int maxProgress = 100,
    bool indeterminate = false,
  }) {
    return AndroidNotificationDetails(
      _channelId,
      _channelName,
      channelDescription: _channelDescription,
      importance: Importance.low,
      priority: Priority.low,
      onlyAlertOnce: true,
      ongoing: ongoing,
      autoCancel: !ongoing,
      showProgress: ongoing,
      maxProgress: maxProgress,
      progress: progress ?? 0,
      indeterminate: indeterminate,
    );
  }

  /// Shows/updates an ongoing progress notification for [id].
  /// [progress]/[max] as an explicit percentage, or [indeterminate] for a
  /// spinner when there's nothing measurable to show yet (e.g. tagging).
  Future<void> showProgress(
    int id,
    String title, {
    int? progress,
    int max = 100,
    bool indeterminate = false,
  }) async {
    if (!Platform.isAndroid) return;
    await _ensureInitialized();
    await _plugin.show(
      id,
      title,
      indeterminate ? null : '$progress%',
      NotificationDetails(
        android: _details(
          ongoing: true,
          progress: progress,
          maxProgress: max,
          indeterminate: indeterminate,
        ),
      ),
    );
  }

  /// Replaces the progress notification for [id] with a final result.
  Future<void> showResult(
    int id,
    String title, {
    required bool success,
  }) async {
    if (!Platform.isAndroid) return;
    await _ensureInitialized();
    await _plugin.show(
      id,
      title,
      success ? 'Completado' : 'Ha fallado',
      NotificationDetails(android: _details(ongoing: false)),
    );
  }

  Future<void> cancel(int id) async {
    if (!Platform.isAndroid) return;
    await _plugin.cancel(id);
  }
}
