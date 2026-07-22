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

import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:hive/hive.dart';
import 'package:dskplay/extensions/l10n.dart';
import 'package:dskplay/main.dart' show logger;
import 'package:dskplay/services/io_service.dart';

/// Boxes included in a user backup (local file or cloud), in this order.
const List<String> backedUpBoxNames = ['user', 'settings'];

/// Set by app bootstrap to trigger a debounced cloud auto-backup whenever
/// backed-up data changes, without a circular import between this file and
/// the cloud backup service (which itself needs to read this data back out).
void Function()? onUserDataChanged;

/// Recursively converts Hive-native values (which may include [DateTime],
/// not directly JSON-encodable) into a JSON-safe structure.
dynamic _toJsonSafe(dynamic value) {
  if (value is DateTime) {
    return {'__type': 'DateTime', 'value': value.toIso8601String()};
  } else if (value is Map) {
    return {
      for (final entry in value.entries)
        entry.key.toString(): _toJsonSafe(entry.value),
    };
  } else if (value is List) {
    return value.map(_toJsonSafe).toList();
  }
  return value;
}

/// Reverses [_toJsonSafe], restoring [DateTime] values.
dynamic _fromJsonSafe(dynamic value) {
  if (value is Map) {
    if (value['__type'] == 'DateTime' && value['value'] is String) {
      return DateTime.parse(value['value'] as String);
    }
    return {
      for (final entry in value.entries)
        entry.key.toString(): _fromJsonSafe(entry.value),
    };
  } else if (value is List) {
    return value.map(_fromJsonSafe).toList();
  }
  return value;
}

/// Builds a single JSON-safe snapshot of every backed-up box, shared by the
/// local file export and the cloud backup upload so both stay in sync.
Future<Map<String, dynamic>> buildBackupSnapshot() async {
  final snapshot = <String, dynamic>{};
  for (final boxName in backedUpBoxNames) {
    final box = await _openBox(boxName);
    snapshot[boxName] = {
      for (final key in box.keys) key.toString(): _toJsonSafe(box.get(key)),
    };
  }
  return snapshot;
}

/// Writes a previously-built snapshot back into its boxes (used by both the
/// local file restore and the cloud restore).
Future<void> applyBackupSnapshot(Map<String, dynamic> snapshot) async {
  for (final boxName in backedUpBoxNames) {
    final boxData = snapshot[boxName];
    if (boxData is! Map) continue;
    final box = await _openBox(boxName);
    await box.clear();
    for (final entry in boxData.entries) {
      await box.put(entry.key.toString(), _fromJsonSafe(entry.value));
    }
  }
}

// Cache durations for different types of data
const Duration songCacheDuration = Duration(hours: 1, minutes: 30);
const Duration playlistCacheDuration = Duration(hours: 5);
const Duration searchCacheDuration = Duration(days: 4);
const Duration defaultCacheDuration = Duration(days: 7);

// In-memory cache for frequently accessed items
final _memoryCache = <String, _CacheEntry>{};

class _CacheEntry {
  _CacheEntry(this.data, this.timestamp);
  final dynamic data;
  final DateTime timestamp;

  bool isValid(Duration cacheDuration) {
    return DateTime.now().difference(timestamp) < cacheDuration;
  }
}

// Maximum number of entries allowed in the memory cache
const int _maxMemoryCacheSize = 500;
const int _memoryCacheTrimSize = 100;

void _setMemoryCacheEntry(String key, _CacheEntry entry) {
  _memoryCache
    ..remove(key)
    ..[key] = entry;
  _trimMemoryCacheIfNeeded();
}

void _touchMemoryCacheEntry(String key) {
  final entry = _memoryCache.remove(key);
  if (entry != null) {
    _memoryCache[key] = entry;
  }
}

void _trimMemoryCacheIfNeeded() {
  if (_memoryCache.length > _maxMemoryCacheSize) {
    final keysToRemove = _memoryCache.keys.take(_memoryCacheTrimSize).toList();
    for (final key in keysToRemove) {
      _memoryCache.remove(key);
    }
  }
}

Future<void> addOrUpdateData<T>(String category, String key, T value) async {
  final _box = await _openBox(category);
  await _box.put(key, value);

  if (category == 'cache') {
    await _box.put('${key}_date', DateTime.now());

    // Update memory cache too
    final cacheKey = '${category}_$key';
    _setMemoryCacheEntry(cacheKey, _CacheEntry(value, DateTime.now()));
  } else if (backedUpBoxNames.contains(category)) {
    onUserDataChanged?.call();
  }
}

Future<dynamic> getData(
  String category,
  String key, {
  dynamic defaultValue,
  Duration? cachingDuration,
}) async {
  // Set appropriate cache duration based on key
  cachingDuration ??= _getCacheDurationForKey(key);

  // Check memory cache first
  final cacheKey = '${category}_$key';
  final memCacheEntry = _memoryCache[cacheKey];
  if (memCacheEntry != null && memCacheEntry.isValid(cachingDuration)) {
    _touchMemoryCacheEntry(cacheKey);
    return memCacheEntry.data;
  }
  _trimMemoryCacheIfNeeded();

  final _box = await _openBox(category);
  if (category == 'cache') {
    final cacheIsValid = isCacheValid(_box, key, cachingDuration);
    if (!cacheIsValid) {
      await deleteData(category, key);
      await deleteData(category, '${key}_date');
      return defaultValue;
    }
  }

  final data = await _box.get(key, defaultValue: defaultValue);

  // Store in memory cache for faster access next time
  if (data != null && category == 'cache') {
    final timestamp = await _box.get('${key}_date') ?? DateTime.now();
    _setMemoryCacheEntry(cacheKey, _CacheEntry(data, timestamp));
  }

  return data;
}

Future<void> deleteData(String category, String key) async {
  _memoryCache
    ..remove('${category}_$key')
    ..remove('${category}_${key}_date');

  final _box = await _openBox(category);
  await _box.delete(key);
}

Future<bool> clearCache() async {
  try {
    // Clear memory cache
    _memoryCache.clear();

    final cacheBox = await _openBox('cache');
    await cacheBox.clear();
    return true;
  } catch (e, stackTrace) {
    logger.log('Failed to clear cache', error: e, stackTrace: stackTrace);
    return false;
  }
}

// Clean up old cache entries to prevent excessive storage usage
Future<void> cleanupOldCacheEntries() async {
  try {
    final cacheBox = await _openBox('cache');
    final now = DateTime.now();

    // Get all keys except the ones with _date suffix
    final keys = cacheBox.keys
        .where((k) => !k.toString().endsWith('_date'))
        .toList();

    for (final key in keys) {
      final dateKey = '${key}_date';
      final date = cacheBox.get(dateKey);

      if (date == null) {
        await cacheBox.delete(key);
        continue;
      }

      final age = now.difference(date);
      // Very old cache entries (older than 30 days) should be removed
      if (age > const Duration(days: 30)) {
        await cacheBox.delete(key);
        await cacheBox.delete(dateKey);
      }
    }
  } catch (e, stackTrace) {
    logger.log(
      'Error cleaning up old cache entries',
      error: e,
      stackTrace: stackTrace,
    );
  }
}

// Check if the cache is still valid based on the caching duration
bool isCacheValid(Box box, String key, Duration cachingDuration) {
  final date = box.get('${key}_date');
  if (date == null) {
    return false;
  }
  final age = DateTime.now().difference(date);
  return age < cachingDuration;
}

Duration _getCacheDurationForKey(String key) {
  if (key.startsWith('song_') || key.contains('manifest_')) {
    return songCacheDuration;
  } else if (key.startsWith('playlist_') || key.contains('playlistSongs')) {
    return playlistCacheDuration;
  } else if (key.startsWith('search_')) {
    return searchCacheDuration;
  }
  return defaultCacheDuration;
}

Future<Box> _openBox(String category) async {
  if (Hive.isBoxOpen(category)) {
    return Hive.box(category);
  } else {
    return Hive.openBox(category);
  }
}

const String backupFileName = 'dskplay_backup.json';

Future<({String message, bool success})> backupData(
  BuildContext context,
) async {
  await ensureExportStoragePermission();
  final dlPath = await FilePicker.getDirectoryPath();

  if (dlPath == null) {
    return (message: '${context.l10n!.chooseBackupDir}!', success: false);
  }

  try {
    final snapshot = await buildBackupSnapshot();
    final targetFile = File('$dlPath/$backupFileName');
    await targetFile.parent.create(recursive: true);
    await targetFile.writeAsString(jsonEncode(snapshot));

    await addOrUpdateData('userNoBackup', 'lastLocalBackupAt', DateTime.now());

    return (message: '${context.l10n!.backedupSuccess}!', success: true);
  } catch (e, stackTrace) {
    logger.log('Backup error', error: e, stackTrace: stackTrace);
    return (message: '${context.l10n!.backupError}: $e', success: false);
  }
}

Future<({String message, bool success})> restoreData(
  BuildContext context,
) async {
  final result = await FilePicker.pickFiles();

  if (result == null || result.files.isEmpty) {
    return (message: '${context.l10n!.chooseBackupFiles}!', success: false);
  }

  final path = result.files.single.path;
  if (path == null) {
    return (message: '${context.l10n!.chooseBackupFiles}!', success: false);
  }

  try {
    final raw = await File(path).readAsString();
    final snapshot = jsonDecode(raw) as Map<String, dynamic>;
    await applyBackupSnapshot(snapshot);

    return (message: '${context.l10n!.restoredSuccess}!', success: true);
  } catch (e, stackTrace) {
    logger.log('Restore error', error: e, stackTrace: stackTrace);
    return (message: '${context.l10n!.restoreError}: $e', success: false);
  }
}
