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

import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:dskplay/main.dart' show logger;
import 'package:dskplay/services/data_manager.dart';
import 'package:dskplay/services/io_service.dart';

/// Anonymous, no-personal-data cloud backup: sign-in is anonymous (no
/// name/email/Google account involved), but the backup file itself is keyed
/// by this Android install's stable `ANDROID_ID` (see [getAndroidDeviceId])
/// rather than the anonymous auth uid, so the same device code keeps working
/// across an uninstall/reinstall. Storage security rules must allow any
/// authenticated (incl. anonymous) user to read/write `backups/*` for this
/// to work - there's no way to verify from the client alone that a given
/// ANDROID_ID "belongs" to the caller, so this trades a bit of write
/// security (anyone with the code could overwrite that backup) for the code
/// surviving reinstalls.
///
/// The whole backup is a single JSON file per device (`backups/<key>.json`)
/// instead of many small documents - one file write is one Storage
/// operation regardless of how much history it contains, unlike Firestore
/// where every top-level box key was its own document write.
class CloudBackupService {
  CloudBackupService._();

  static final CloudBackupService instance = CloudBackupService._();

  static const _periodicBackupInterval = Duration(hours: 6);

  bool _ready = false;
  String? _deviceId;
  Timer? _periodicTimer;
  Future<void>? _initFuture;
  // Set whenever a backed-up box changes, cleared after a successful
  // upload - lets the background/periodic triggers skip re-uploading the
  // same 1MB+ file every time the app is merely opened and closed again
  // with nothing new to save.
  bool _dirty = false;

  /// Idempotent: safe to call from multiple places (app bootstrap fires it
  /// without awaiting, while upload/download/timestamp calls await it here
  /// to avoid racing ahead of Firebase auth on a cold start).
  Future<void> init() => _initFuture ??= _doInit();

  Future<void> _doInit() async {
    try {
      await Firebase.initializeApp();
      // Waits for the SDK's own restored-session state instead of reading
      // currentUser synchronously right after initializeApp, which can
      // still be null while persistence restoration is in flight - reading
      // it too early risks creating a brand new anonymous UID every cold
      // start instead of reusing the persisted one.
      final restoredUser = await FirebaseAuth.instance.authStateChanges().first;
      if (restoredUser == null) {
        await FirebaseAuth.instance.signInAnonymously();
      }
      _deviceId = await getAndroidDeviceId();
      _ready = true;
      logger.log('Cloud backup ready, device code: $_backupKey');
      _periodicTimer = Timer.periodic(
        _periodicBackupInterval,
        (_) => unawaited(uploadBackup()),
      );
    } catch (e, stackTrace) {
      logger.log(
        'Failed to initialize cloud backup',
        error: e,
        stackTrace: stackTrace,
      );
    }
  }

  String? get _uid => FirebaseAuth.instance.currentUser?.uid;

  /// The Storage file key for this device: its stable ANDROID_ID when
  /// available (survives uninstall/reinstall), falling back to the
  /// anonymous auth uid off Android or if reading ANDROID_ID failed.
  String? get _backupKey => _deviceId ?? _uid;

  /// This device's own backup identifier, shareable as a recovery code to
  /// restore this backup from a different install.
  String? get deviceCode => _backupKey;

  Reference? _referenceFor(String? key) {
    if (key == null) return null;
    return FirebaseStorage.instance.ref('backups/$key.json');
  }

  Reference? get _reference => _referenceFor(_backupKey);

  /// Marks the backup as needing a re-upload. Doesn't upload immediately -
  /// that happens when the app is backgrounded/closed (see
  /// [DskPlayAudioHandler.onTaskRemoved] and the app lifecycle listener in
  /// main.dart) or by the periodic timer below, so a whole listening
  /// session's worth of changes goes out as one upload instead of one per
  /// change.
  void scheduleAutoBackup() {
    if (!_ready) return;
    _dirty = true;
  }

  static const _networkTimeout = Duration(seconds: 20);
  // The upload's size scales with how much history the user has (song
  // library, wrapped stats, podcast episodes...) - give it more room before
  // giving up than the other, fixed-size calls here.
  static const _uploadTimeout = Duration(seconds: 60);

  /// Set on every failed [uploadBackup] call, so the settings UI can show
  /// the real reason (e.g. a Storage permission-denied) instead of a
  /// generic "backup failed" that gives no clue what to fix.
  String? lastUploadError;

  /// Uploads the current backup. Skips the actual upload (returning `true`
  /// as if it succeeded) when nothing has changed since the last successful
  /// one, unless [force] is set - used by the manual "back up now" button,
  /// which should always upload even if that just re-confirms the existing
  /// backup.
  Future<bool> uploadBackup({bool force = false}) async {
    if (!force && !_dirty) return true;
    lastUploadError = null;
    try {
      // Auth/device-id setup involves network calls with no built-in
      // timeout - without this, a bad connection can leave the upload
      // hanging indefinitely with no error and no feedback, which reads to
      // the user as "nothing is happening".
      await init().timeout(
        _networkTimeout,
        onTimeout: () => throw TimeoutException('init/sign-in'),
      );
    } catch (e, stackTrace) {
      logger.log('Cloud backup init timed out', error: e, stackTrace: stackTrace);
      lastUploadError = e.toString();
      return false;
    }
    final reference = _reference;
    if (reference == null) {
      lastUploadError = 'No device/account id available (auth failed?)';
      return false;
    }

    try {
      final snapshot = await buildBackupSnapshot();
      final bytes = utf8.encode(jsonEncode(snapshot));

      await reference
          .putData(bytes, SettableMetadata(contentType: 'application/json'))
          .timeout(
            _uploadTimeout,
            onTimeout: () => throw TimeoutException('uploading backup'),
          );

      await addOrUpdateData(
        'userNoBackup',
        'lastCloudBackupAt',
        DateTime.now(),
      );
      _dirty = false;
      return true;
    } catch (e, stackTrace) {
      logger.log('Cloud backup upload failed', error: e, stackTrace: stackTrace);
      lastUploadError = e.toString();
      return false;
    }
  }

  /// Downloads a backup. Defaults to this device's own backup; pass [code]
  /// (another device's recovery code) to restore from a different install.
  Future<({Map<String, dynamic>? data, DateTime? updatedAt})> downloadBackup({
    String? code,
  }) async {
    await init();
    final reference = _referenceFor(code ?? _backupKey);
    if (reference == null) return (data: null, updatedAt: null);

    try {
      final bytes = await reference.getData(20 * 1024 * 1024);
      if (bytes == null) return (data: null, updatedAt: null);
      final data = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
      final metadata = await reference.getMetadata();
      return (data: data, updatedAt: metadata.updated);
    } catch (e, stackTrace) {
      logger.log(
        'Cloud backup download failed',
        error: e,
        stackTrace: stackTrace,
      );
      return (data: null, updatedAt: null);
    }
  }

  Future<DateTime?> getCloudBackupTimestamp() async {
    await init();
    final reference = _reference;
    if (reference == null) return null;

    try {
      final metadata = await reference.getMetadata().timeout(_networkTimeout);
      return metadata.updated;
    } catch (e, stackTrace) {
      // Also the expected path for "no backup yet" (object-not-found), so
      // this stays quiet instead of logging every first-run check.
      if (e is FirebaseException && e.code == 'object-not-found') return null;
      logger.log(
        'Failed to read cloud backup timestamp',
        error: e,
        stackTrace: stackTrace,
      );
      return null;
    }
  }
}

final cloudBackupService = CloudBackupService.instance;
