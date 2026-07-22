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

/// Anonymous, no-personal-data cloud backup: each install gets a random
/// Firebase UID (no name/email/Google account involved) and its backup
/// snapshot is stored in a single Firestore document keyed by that UID.
class CloudBackupService {
  CloudBackupService._();

  static final CloudBackupService instance = CloudBackupService._();

  static const _autoBackupDebounce = Duration(seconds: 8);
  static const _periodicBackupInterval = Duration(hours: 6);

  bool _ready = false;
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
      // Checked first (rather than always calling signInAnonymously) so a
      // persisted session from a previous run is reliably reused instead of
      // possibly racing Firebase's own session restore and getting a brand
      // new anonymous UID on every cold start.
      if (FirebaseAuth.instance.currentUser == null) {
        await FirebaseAuth.instance.signInAnonymously();
      }
      _ready = true;
      logger.log('Cloud backup ready, device code: $_uid');
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

  /// This device's own backup identifier, shareable as a recovery code to
  /// restore this backup from a different install (e.g. after clearing app
  /// data, which resets the anonymous Firebase session and thus this ID).
  String? get deviceCode => _uid;

  DocumentReference<Map<String, dynamic>>? _documentFor(String? uid) {
    if (uid == null) return null;
    return FirebaseFirestore.instance.collection('backups').doc(uid);
  }

  DocumentReference<Map<String, dynamic>>? get _document => _documentFor(_uid);

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
      await document.set({
        'data': snapshot,
        'updatedAt': FieldValue.serverTimestamp(),
      });
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
    final document = _documentFor(code ?? _uid);
    if (document == null) return (data: null, updatedAt: null);

    try {
      final snapshot = await document.get();
      final raw = snapshot.data();
      if (raw == null) return (data: null, updatedAt: null);

      final rawData = (raw['data'] as Map?)?.cast<String, dynamic>();
      final data = rawData == null
          ? null
          : _normalizeFirestoreValue(rawData) as Map<String, dynamic>;
      final timestamp = raw['updatedAt'];
      final updatedAt = timestamp is Timestamp ? timestamp.toDate() : null;
      return (data: data, updatedAt: updatedAt);
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
