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

import 'package:http/http.dart' as http;
import 'package:dskplay/services/data_manager.dart';
import 'package:open_filex/open_filex.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';

const _repo = 'dskmusic/DSKplay';
final workflowRunUrl = Uri.parse(
  'https://github.com/$_repo/actions/workflows/youtube_sync.yml',
);

// Matches the "BuildNumber: <n>" line the release workflow writes into every
// release body, so updates can be detected the same way whether the
// currently-installed APK came from CI or from a local `flutter build` -
// both stamp the real pubspec build number as the Android versionCode.
final _buildNumberPattern = RegExp(r'BuildNumber:\s*(\d+)');

class UpdateInfo {
  const UpdateInfo({
    required this.tag,
    required this.releaseUrl,
    required this.apkUrl,
  });

  final String tag;
  final String releaseUrl;
  final String apkUrl;
}

Future<UpdateInfo?> checkForUpdate({bool ignoreDismissed = false}) async {
  try {
    final response = await http.get(
      Uri.parse('https://api.github.com/repos/$_repo/releases/latest'),
    );
    if (response.statusCode != 200) return null;

    final data = jsonDecode(response.body) as Map;
    final tag = data['tag_name'] as String?;
    if (tag == null) return null;

    final remoteBuild = int.tryParse(
      _buildNumberPattern.firstMatch(data['body'] as String? ?? '')
              ?.group(1) ??
          '',
    );
    if (remoteBuild == null) return null;

    final packageInfo = await PackageInfo.fromPlatform();
    final localBuild = int.tryParse(packageInfo.buildNumber);
    if (localBuild != null && remoteBuild <= localBuild) return null;

    if (!ignoreDismissed) {
      final dismissed = await getData('settings', 'dismissedUpdateTag');
      if (dismissed == tag) return null;
    }

    final assets = (data['assets'] as List?)?.cast<Map>() ?? const [];
    Map? apkAsset;
    for (final asset in assets) {
      if ((asset['name'] as String?)?.endsWith('.apk') ?? false) {
        apkAsset = asset;
        break;
      }
    }
    if (apkAsset == null) return null;

    return UpdateInfo(
      tag: tag,
      releaseUrl:
          data['html_url'] as String? ?? 'https://github.com/$_repo/releases',
      apkUrl: apkAsset['browser_download_url'] as String,
    );
  } catch (_) {
    return null;
  }
}

Future<void> dismissUpdate(String tag) =>
    addOrUpdateData('settings', 'dismissedUpdateTag', tag);

Future<File> downloadUpdate(
  UpdateInfo info, {
  void Function(double progress)? onProgress,
}) async {
  final client = http.Client();
  try {
    final response = await client.send(
      http.Request('GET', Uri.parse(info.apkUrl)),
    );
    final total = response.contentLength ?? 0;

    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}/dskplay_update.apk');
    final sink = file.openWrite();

    var received = 0;
    await for (final chunk in response.stream) {
      sink.add(chunk);
      received += chunk.length;
      if (total > 0) onProgress?.call(received / total);
    }
    await sink.close();

    return file;
  } finally {
    client.close();
  }
}

/// Opens the downloaded APK with the system package installer. Android
/// always requires a user tap to confirm the install; there's no way to make
/// this silent for a non-system app.
Future<void> installUpdate(File apkFile) => OpenFilex.open(apkFile.path);
