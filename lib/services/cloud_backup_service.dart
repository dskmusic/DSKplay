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

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:dskplay/main.dart' show logger;
import 'package:dskplay/services/data_manager.dart';
import 'package:dskplay/services/io_service.dart';

/// Anonymous, no-personal-data cloud backup: sign-in is anonymous (no
/// name/email/Google account involved), but the backup document itself is
/// keyed by this Android install's stable `ANDROID_ID` (see
/// [getAndroidDeviceId]) rather than the anonymous auth uid, so the same
/// device code keeps working across an uninstall/reinstall. Firestore
/// security rules must allow any authenticated (incl. anonymous) user to
/// read/write `/backups/{userId}` for this to work - there's no way to
/// verify from the client alone that a given ANDROID_ID "belongs" to the
/// caller, so this trades a bit of write security (anyone with the code
/// could overwrite that backup) for the code surviving reinstalls.
class CloudBackupService {
  CloudBackupService._();

  static final CloudBackupService instance = CloudBackupService._();

  static const _autoBackupDebounce = Duration(seconds: 8);
  static const _periodicBackupInterval = Duration(hours: 6);

  bool _ready = false;
  String? _deviceId;
  Timer? _debounceTimer;
  Timer? _periodicTimer;
  Future<void>? _initFuture;

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

  /// The Firestore document key for this device: its stable ANDROID_ID
  /// when available (survives uninstall/reinstall), falling back to the
  /// anonymous auth uid off Android or if reading ANDROID_ID failed.
  String? get _backupKey => _deviceId ?? _uid;

  /// This device's own backup identifier, shareable as a recovery code to
  /// restore this backup from a different install.
  String? get deviceCode => _backupKey;

  DocumentReference<Map<String, dynamic>>? _documentFor(String? key) {
    if (key == null) return null;
    return FirebaseFirestore.instance.collection('backups').doc(key);
  }

  DocumentReference<Map<String, dynamic>>? get _document =>
      _documentFor(_backupKey);

  /// Debounced auto-backup: called on every backed-up data change, but only
  /// actually uploads once the changes settle for a few seconds, so a burst
  /// of edits results in a single upload instead of one per change.
  void scheduleAutoBackup() {
    if (!_ready) return;
    _debounceTimer?.cancel();
    _debounceTimer = Timer(
      _autoBackupDebounce,
      () => unawaited(uploadBackup()),
    );
  }

  Future<bool> uploadBackup() async {
    await init();
    final document = _document;
    if (document == null) return false;

    try {
      final snapshot = await buildBackupSnapshot();

      // Firestore caps a single document at 1 MiB. Writing the whole backup
      // (song library, wrapped stats, and every podcast's subscriptions,
      // listened episodes and per-podcast stats) as one nested field on one
      // document can blow past that for a long-time user or a large podcast
      // history, which fails the *entire* upload silently - nothing gets
      // backed up, not just the part that grew too big. Splitting into one
      // small document per top-level box key keeps each write far under the
      // limit no matter how much history any single box key accumulates.
      final entries = document.collection('entries');
      final existing = await entries.get();
      final batch = FirebaseFirestore.instance.batch();
      for (final doc in existing.docs) {
        batch.delete(doc.reference);
      }
      for (final boxEntry in snapshot.entries) {
        final boxData = boxEntry.value;
        if (boxData is! Map) continue;
        for (final keyEntry in boxData.entries) {
          batch.set(entries.doc('${boxEntry.key}__${keyEntry.key}'), {
            'box': boxEntry.key,
            'key': keyEntry.key,
            'value': keyEntry.value,
          });
        }
      }
      // A plain DateTime (not FieldValue.serverTimestamp()) so it reads
      // back immediately: a server timestamp resolves to null on reads
      // until the write is acknowledged by the server, which can take a
      // while - this value is only ever shown to the device that wrote it.
      // Replaces the document outright, which also drops any legacy 'data'
      // field from a pre-chunking backup.
      batch.set(document, {'updatedAt': DateTime.now()});
      await batch.commit();

      await addOrUpdateData(
        'userNoBackup',
        'lastCloudBackupAt',
        DateTime.now(),
      );
      return true;
    } catch (e, stackTrace) {
      logger.log('Cloud backup upload failed', error: e, stackTrace: stackTrace);
      return false;
    }
  }

  /// Downloads a backup. Defaults to this device's own backup; pass [code]
  /// (another device's recovery code) to restore from a different install.
  Future<({Map<String, dynamic>? data, DateTime? updatedAt})> downloadBackup({
    String? code,
  }) async {
    await init();
    final document = _documentFor(code ?? _backupKey);
    if (document == null) return (data: null, updatedAt: null);

    try {
      final docSnapshot = await document.get();
      final raw = docSnapshot.data();
      if (raw == null) return (data: null, updatedAt: null);

      final entriesSnapshot = await document.collection('entries').get();
      final data = <String, Map<String, dynamic>>{};
      if (entriesSnapshot.docs.isEmpty) {
        // Legacy pre-chunking backups nested everything under a single
        // 'data' field - keep reading those so a device that hasn't
        // re-uploaded since the chunking change doesn't lose its backup.
        final legacy = (raw['data'] as Map?)?.cast<String, dynamic>();
        if (legacy != null) {
          for (final boxEntry in legacy.entries) {
            final boxData = boxEntry.value;
            if (boxData is Map) {
              data[boxEntry.key] = boxData.cast<String, dynamic>();
            }
          }
        }
      } else {
        for (final entryDoc in entriesSnapshot.docs) {
          final entryData = entryDoc.data();
          final box = entryData['box'] as String?;
          final key = entryData['key'] as String?;
          if (box == null || key == null) continue;
          (data[box] ??= <String, dynamic>{})[key] = entryData['value'];
        }
      }

      final normalized = _normalizeFirestoreValue(data) as Map<String, dynamic>;
      final timestamp = raw['updatedAt'];
      final updatedAt = timestamp is Timestamp ? timestamp.toDate() : null;
      return (data: normalized, updatedAt: updatedAt);
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
    final document = _document;
    if (document == null) return null;

    try {
      final snapshot = await document.get();
      final timestamp = snapshot.data()?['updatedAt'];
      return timestamp is Timestamp ? timestamp.toDate() : null;
    } catch (e, stackTrace) {
      logger.log(
        'Failed to read cloud backup timestamp',
        error: e,
        stackTrace: stackTrace,
      );
      return null;
    }
  }
}

/// Converts any raw Firestore [Timestamp]s back into [DateTime]s. Needed
/// for backups uploaded before dates were JSON-encoded as ISO strings,
/// which Firestore instead stored using its own native Timestamp type.
dynamic _normalizeFirestoreValue(dynamic value) {
  if (value is Timestamp) {
    return value.toDate();
  } else if (value is Map) {
    return {
      for (final entry in value.entries)
        entry.key.toString(): _normalizeFirestoreValue(entry.value),
    };
  } else if (value is List) {
    return value.map(_normalizeFirestoreValue).toList();
  }
  return value;
}

final cloudBackupService = CloudBackupService.instance;
