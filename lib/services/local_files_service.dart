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

import 'package:audiotags/audiotags.dart';
import 'package:path_provider/path_provider.dart';

// Local-file browsing/playback, kept independent of the YouTube-backed
// song pipeline. Local songs are given a synthetic ytid (the file path,
// prefixed) so they can flow through the existing queue/playlist/playback
// machinery, which requires a non-empty ytid on every song map.
const String localFileIdPrefix = 'local::';

const List<String> supportedAudioExtensions = [
  '.mp3',
  '.m4a',
  '.flac',
  '.wav',
  '.ogg',
  '.opus',
  '.aac',
  '.wma',
];

const String defaultLocalFilesRoot = '/storage/emulated/0';

bool isLocalSongMap(Map song) =>
    song['ytid']?.toString().startsWith(localFileIdPrefix) ?? false;

String fileNameFromPath(String path) {
  final normalized = path.replaceAll('\\', '/');
  final idx = normalized.lastIndexOf('/');
  return idx == -1 ? normalized : normalized.substring(idx + 1);
}

String _fileExtension(String path) {
  final name = fileNameFromPath(path);
  final dot = name.lastIndexOf('.');
  return dot == -1 ? '' : name.substring(dot).toLowerCase();
}

String _fileNameWithoutExtension(String path) {
  final name = fileNameFromPath(path);
  final dot = name.lastIndexOf('.');
  return dot == -1 ? name : name.substring(0, dot);
}

bool isAudioFile(String path) =>
    supportedAudioExtensions.contains(_fileExtension(path));

/// Lists the entries of [path], folders first then supported audio files,
/// both alphabetically. Returns an empty list if the directory can't be
/// read (missing permission, deleted externally, etc).
Future<List<FileSystemEntity>> listDirectoryEntries(String path) async {
  try {
    final entries = await Directory(path).list(followLinks: false).toList();

    final folders =
        entries
            .whereType<Directory>()
            .where((d) => !fileNameFromPath(d.path).startsWith('.'))
            .toList()
          ..sort(
            (a, b) => fileNameFromPath(
              a.path,
            ).toLowerCase().compareTo(fileNameFromPath(b.path).toLowerCase()),
          );

    final files =
        entries.whereType<File>().where((f) => isAudioFile(f.path)).toList()
          ..sort(
            (a, b) => fileNameFromPath(
              a.path,
            ).toLowerCase().compareTo(fileNameFromPath(b.path).toLowerCase()),
          );

    return [...folders, ...files];
  } catch (_) {
    return [];
  }
}

/// Recursively collects every supported audio file under [directory],
/// bounded in depth to avoid runaway scans of huge/symlinked trees.
Future<List<File>> collectAudioFilesRecursively(
  Directory directory, {
  int maxDepth = 8,
}) async {
  final results = <File>[];

  Future<void> walk(Directory dir, int depth) async {
    if (depth > maxDepth) return;
    List<FileSystemEntity> entries;
    try {
      entries = await dir.list(followLinks: false).toList();
    } catch (_) {
      return;
    }

    final subDirs = <Directory>[];
    for (final entry in entries) {
      if (entry is Directory) {
        if (!fileNameFromPath(entry.path).startsWith('.')) subDirs.add(entry);
      } else if (entry is File && isAudioFile(entry.path)) {
        results.add(entry);
      }
    }
    subDirs.sort(
      (a, b) => fileNameFromPath(
        a.path,
      ).toLowerCase().compareTo(fileNameFromPath(b.path).toLowerCase()),
    );
    for (final subDir in subDirs) {
      await walk(subDir, depth + 1);
    }
  }

  await walk(directory, 0);
  return results;
}

/// Heuristic "Artist - Title" split from a bare file name; falls back to
/// using the whole name as the title when no separator is present.
({String artist, String title}) parseArtistAndTitle(String fileName) {
  final cleaned = fileName.replaceAll('_', ' ').trim();
  final parts = cleaned.split(' - ');
  if (parts.length >= 2 && parts[0].trim().isNotEmpty) {
    return (
      artist: parts[0].trim(),
      title: parts.sublist(1).join(' - ').trim(),
    );
  }
  return (artist: '', title: cleaned);
}

/// Builds a song map for [file] compatible with the existing playback,
/// queue and playlist pipelines (they all key songs off `ytid`).
Map<String, dynamic> localFileToSongMap(File file) {
  final parsed = parseArtistAndTitle(_fileNameWithoutExtension(file.path));
  final ytid = '$localFileIdPrefix${file.path}';
  final folderName = fileNameFromPath(file.parent.path);

  return {
    'id': ytid,
    'ytid': ytid,
    'title': parsed.title.isEmpty ? fileNameFromPath(file.path) : parsed.title,
    'artist': parsed.artist,
    'album': folderName,
    'audioPath': file.path,
    'highResImage': '',
    'lowResImage': '',
    'isLive': false,
    'isLocalFile': true,
  };
}

List<Map<String, dynamic>> localFilesToSongMaps(List<File> files) =>
    files.map(localFileToSongMap).toList();

Directory? _artworkCacheDir;

Future<Directory> _artworkCacheDirectory() async {
  final cached = _artworkCacheDir;
  if (cached != null) return cached;

  final tempDir = await getTemporaryDirectory();
  final dir = Directory('${tempDir.path}/local_artwork');
  if (!await dir.exists()) await dir.create(recursive: true);
  _artworkCacheDir = dir;
  return dir;
}

String _artworkExtension(MimeType? mimeType) {
  switch (mimeType) {
    case MimeType.png:
      return '.png';
    case MimeType.gif:
      return '.gif';
    case MimeType.bmp:
      return '.bmp';
    case MimeType.tiff:
      return '.tiff';
    case MimeType.jpeg:
    case null:
      return '.jpg';
  }
}

/// Extracts the embedded cover art (front cover preferred) from [tag] and
/// caches it on disk, since the rest of the app displays artwork from a
/// file path rather than raw bytes. Returns null if there's no picture.
Future<String?> _extractAndCacheArtwork(String filePath, Tag tag) async {
  if (tag.pictures.isEmpty) return null;

  final picture = tag.pictures.firstWhere(
    (p) => p.pictureType == PictureType.coverFront,
    orElse: () => tag.pictures.first,
  );

  try {
    final dir = await _artworkCacheDirectory();
    final key = filePath.hashCode.toUnsigned(32).toRadixString(16);
    final path = '${dir.path}/$key${_artworkExtension(picture.mimeType)}';
    final file = File(path);
    if (!await file.exists()) {
      await file.writeAsBytes(picture.bytes, flush: true);
    }
    return path;
  } catch (_) {
    return null;
  }
}

/// Like [localFileToSongMap], but also tries reading ID3/Vorbis/MP4 tags
/// (title, artist, album, embedded cover art) via `audiotags`. Falls back
/// to the filename-based heuristic for any field the tags don't provide,
/// or entirely if the file has no tags / the read fails.
Future<Map<String, dynamic>> buildLocalSongMap(File file) async {
  final song = localFileToSongMap(file);
  try {
    final tag = await AudioTags.read(file.path);
    if (tag == null) return song;

    final title = tag.title?.trim();
    final artist = tag.trackArtist?.trim();
    final album = tag.album?.trim();
    if (title != null && title.isNotEmpty) song['title'] = title;
    if (artist != null && artist.isNotEmpty) song['artist'] = artist;
    if (album != null && album.isNotEmpty) song['album'] = album;

    final artworkPath = await _extractAndCacheArtwork(file.path, tag);
    if (artworkPath != null) song['artworkPath'] = artworkPath;
  } catch (_) {
    // Keep the filename-based fallback on any tag-read failure.
  }
  return song;
}

Future<List<Map<String, dynamic>>> buildLocalSongMaps(List<File> files) async {
  return Future.wait(files.map(buildLocalSongMap));
}
