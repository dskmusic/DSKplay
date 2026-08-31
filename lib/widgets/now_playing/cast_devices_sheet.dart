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

import 'package:dskplay/extensions/l10n.dart';
import 'package:dskplay/main.dart';
import 'package:dskplay/services/cast_service.dart';
import 'package:fluentui_system_icons/fluentui_system_icons.dart';
import 'package:flutter/material.dart';

/// Lista de receptores a los que enviar la reproducción. La búsqueda arranca al
/// abrir y se para al cerrar: SSDP mete tráfico multicast, no tiene sentido
/// dejarlo corriendo de fondo.
Future<void> showCastDevicesSheet(BuildContext context) {
  castService.startDiscovery();
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: Colors.transparent,
    builder: (_) => const _CastDevicesSheet(),
  ).whenComplete(castService.stopDiscovery);
}

class _CastDevicesSheet extends StatelessWidget {
  const _CastDevicesSheet();

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return AnimatedBuilder(
      animation: Listenable.merge([
        castService.devices,
        castService.isDiscovering,
        castService.activeDevice,
      ]),
      builder: (context, _) {
        final devices = castService.devices.value;
        final active = castService.activeDevice.value;
        final searching = castService.isDiscovering.value;

        return Container(
          decoration: BoxDecoration(
            color: colorScheme.surfaceContainerLow,
            borderRadius: const BorderRadius.only(
              topLeft: Radius.circular(24),
              topRight: Radius.circular(24),
            ),
          ),
          // La barra de gestos de Android se comia el "dejar de enviar".
          padding: EdgeInsets.fromLTRB(
            16,
            16,
            16,
            24 + MediaQuery.viewPaddingOf(context).bottom,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Text(
                    context.l10n!.castTo,
                    style: TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 16,
                      color: colorScheme.onSurface,
                    ),
                  ),
                  const Spacer(),
                  if (searching)
                    const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                ],
              ),
              const SizedBox(height: 8),
              if (devices.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 32),
                  child: Text(
                    searching
                        ? context.l10n!.searchingDevices
                        : context.l10n!.noCastDevicesFound,
                    textAlign: TextAlign.center,
                    style: TextStyle(color: colorScheme.onSurfaceVariant),
                  ),
                )
              else
                // Los receptores van llegando de uno en uno mientras dura el
                // escaneo, asi que la hoja crece con la lista en vez de
                // reservar un alto fijo.
                Flexible(
                  child: ListView.builder(
                    shrinkWrap: true,
                    itemCount: devices.length,
                    itemBuilder: (context, index) {
                      final device = devices[index];
                      final isActive = device == active;
                      return ListTile(
                        leading: Icon(
                          device.isChromecast
                              ? FluentIcons.cast_24_regular
                              : FluentIcons.tv_24_regular,
                          color: isActive ? colorScheme.primary : null,
                        ),
                        title: Text(device.name),
                        trailing: isActive
                            ? Icon(
                                FluentIcons.checkmark_24_filled,
                                color: colorScheme.primary,
                              )
                            : null,
                        onTap: isActive
                            ? null
                            : () => _connect(context, device),
                      );
                    },
                  ),
                ),
              if (active != null) ...[
                const Divider(height: 24),
                ListTile(
                  leading: Icon(
                    FluentIcons.plug_disconnected_24_regular,
                    color: colorScheme.error,
                  ),
                  title: Text(
                    context.l10n!.stopCasting,
                    style: TextStyle(color: colorScheme.error),
                  ),
                  onTap: () {
                    Navigator.pop(context);
                    audioHandler.stopCasting();
                  },
                ),
              ],
            ],
          ),
        );
      },
    );
  }

  Future<void> _connect(BuildContext context, CastDevice device) async {
    // El messenger se coge antes de cerrar: despues este context ya no vale.
    final messenger = ScaffoldMessenger.of(context);
    Navigator.pop(context);
    final error = await audioHandler.startCasting(device);
    if (error != null) {
      messenger.showSnackBar(SnackBar(content: Text(error)));
    }
  }
}
