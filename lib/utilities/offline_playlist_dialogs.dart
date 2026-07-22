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

import 'package:flutter/material.dart';
import 'package:dskplay/extensions/l10n.dart';
import 'package:dskplay/services/playlist_download_service.dart';
import 'package:dskplay/utilities/flutter_toast.dart';
import 'package:dskplay/widgets/confirmation_dialog.dart';

void showRemoveOfflinePlaylistDialog(BuildContext context, String playlistId) {
  showDialog<void>(
    context: context,
    builder: (BuildContext context) {
      return ConfirmationDialog(
        confirmationMessage: context.l10n!.removeOfflinePlaylistConfirm,
        submitMessage: context.l10n!.remove,
        isDangerous: true,
        onCancel: () => Navigator.pop(context),
        onSubmit: () {
          offlinePlaylistService.removeOfflinePlaylist(playlistId);
          Navigator.pop(context);
          showToast(context, context.l10n!.playlistRemovedFromOffline);
        },
      );
    },
  );
}
