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

import 'package:fluentui_system_icons/fluentui_system_icons.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:dskplay/constants/app_constants.dart';
import 'package:dskplay/extensions/l10n.dart';
import 'package:dskplay/main.dart';
import 'package:dskplay/services/settings_manager.dart';
import 'package:dskplay/utilities/flutter_bottom_sheet.dart'
    show closeCurrentBottomSheet, hasOpenBottomSheet;
import 'package:dskplay/utilities/flutter_toast.dart';
import 'package:dskplay/widgets/mini_player.dart';

class BottomNavigationPage extends StatefulWidget {
  const BottomNavigationPage({required this.child, super.key});

  final StatefulNavigationShell child;

  @override
  State<BottomNavigationPage> createState() => _BottomNavigationPageState();
}

class _BottomNavigationPageState extends State<BottomNavigationPage> {
  late final _miniPlayerVisibilityStream = audioHandler.mediaItem
      .map((mediaItem) => mediaItem != null)
      .distinct();

  bool? _previousOfflineMode;

  /// Track the previously selected tab index to detect double-taps on the same tab.
  int? _previousTabIndex;

  /// Timestamp of the last back press while already on the Home tab with
  /// nothing else open, used to require a second press within a short
  /// window before actually exiting the app.
  DateTime? _lastBackPressAt;

  @override
  Widget build(BuildContext context) {
    return PopScope(
      // Always intercept: this only ever gets a real chance to act once
      // the currently focused nested Navigator/route has nothing left of
      // its own to pop (its own screens/dialogs are handled first).
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;

        // Step 1: close any open picker/bottom sheet (accent color, theme
        // mode, language, audio quality, etc.) instead of jumping past it.
        if (hasOpenBottomSheet) {
          closeCurrentBottomSheet();
          return;
        }

        // Step 2: go back to the Home tab.
        final currentIndex = widget.child.currentIndex;
        if (currentIndex != 0) {
          widget.child.goBranch(0);
          return;
        }

        // Step 3: already home with nothing open — require a second back
        // press within 2 seconds before actually exiting the app.
        final now = DateTime.now();
        if (_lastBackPressAt != null &&
            now.difference(_lastBackPressAt!) < const Duration(seconds: 2)) {
          SystemNavigator.pop();
        } else {
          _lastBackPressAt = now;
          showToast(context, context.l10n!.pressBackAgainToExit);
        }
      },
      child: ValueListenableBuilder<bool>(
        valueListenable: offlineMode,
        builder: (context, isOfflineMode, _) {
          if (_previousOfflineMode != null &&
              _previousOfflineMode != isOfflineMode) {
            SchedulerBinding.instance.addPostFrameCallback((_) {
              _handleOfflineModeChange(isOfflineMode);
            });
          }
          _previousOfflineMode = isOfflineMode;

          return LayoutBuilder(
            builder: (context, constraints) {
              final isLargeScreen = MediaQuery.of(context).size.width >= 600;
              final items = _getNavigationItems(isOfflineMode);

              return Scaffold(
                body: SafeArea(
                  child: Row(
                    children: [
                      if (isLargeScreen)
                        NavigationRail(
                          labelType: NavigationRailLabelType.selected,
                          destinations: items
                              .map(
                                (item) => NavigationRailDestination(
                                  icon: Icon(item.icon),
                                  selectedIcon: Icon(item.selectedIcon),
                                  label: Text(item.label),
                                ),
                              )
                              .toList(),
                          selectedIndex: _getCurrentIndex(items, isOfflineMode),
                          onDestinationSelected: (index) =>
                              _onTabTapped(index, items),
                        ),
                      Expanded(
                        child: StreamBuilder<bool>(
                          initialData: audioHandler.mediaItem.value != null,
                          stream: _miniPlayerVisibilityStream,
                          builder: (context, snapshot) {
                            final mediaQuery = MediaQuery.of(context);
                            final isMiniPlayerVisible = snapshot.data ?? false;
                            final bottomPadding = !isMiniPlayerVisible
                                ? mediaQuery.padding.bottom
                                : mediaQuery.padding.bottom +
                                      miniPlayerTotalHeight;

                            return Stack(
                              alignment: Alignment.bottomCenter,
                              children: [
                                MediaQuery(
                                  data: mediaQuery.copyWith(
                                    padding: mediaQuery.padding.copyWith(
                                      bottom: bottomPadding,
                                    ),
                                  ),
                                  child: widget.child,
                                ),
                                const Padding(
                                  padding: EdgeInsets.symmetric(
                                    horizontal: 8,
                                    vertical: 8,
                                  ),
                                  child: MiniPlayer(),
                                ),
                              ],
                            );
                          },
                        ),
                      ),
                    ],
                  ),
                ),
                bottomNavigationBar: !isLargeScreen
                    ? NavigationBar(
                        selectedIndex: _getCurrentIndex(items, isOfflineMode),
                        labelBehavior: languageSetting == const Locale('en', '')
                            ? NavigationDestinationLabelBehavior
                                  .onlyShowSelected
                            : NavigationDestinationLabelBehavior.alwaysHide,
                        onDestinationSelected: (index) =>
                            _onTabTapped(index, items),
                        destinations: items
                            .map(
                              (item) => NavigationDestination(
                                icon: Icon(item.icon),
                                selectedIcon: Icon(item.selectedIcon),
                                label: item.label,
                              ),
                            )
                            .toList(),
                      )
                    : null,
              );
            },
          );
        },
      ),
    );
  }

  List<_NavigationItem> _getNavigationItems(bool isOfflineMode) {
    final items = <_NavigationItem>[
      _NavigationItem(
        icon: FluentIcons.home_24_regular,
        selectedIcon: FluentIcons.home_24_filled,
        label: context.l10n?.home ?? 'Home',
        route: '/home',
        shellIndex: 0,
      ),
    ];

    // Only add search tab in online mode
    if (!isOfflineMode) {
      items.add(
        _NavigationItem(
          icon: FluentIcons.search_24_regular,
          selectedIcon: FluentIcons.search_24_filled,
          label: context.l10n?.search ?? 'Search',
          route: '/search',
          shellIndex: 1,
        ),
      );
    }

    items.addAll([
      _NavigationItem(
        icon: FluentIcons.book_24_regular,
        selectedIcon: FluentIcons.book_24_filled,
        label: context.l10n?.library ?? 'Library',
        route: '/library',
        shellIndex: 2,
      ),
      _NavigationItem(
        icon: FluentIcons.folder_24_regular,
        selectedIcon: FluentIcons.folder_24_filled,
        label: context.l10n?.localFiles ?? 'Local files',
        route: '/localFiles',
        shellIndex: 3,
      ),
      _NavigationItem(
        icon: FluentIcons.settings_24_regular,
        selectedIcon: FluentIcons.settings_24_filled,
        label: context.l10n?.settings ?? 'Settings',
        route: '/settings',
        shellIndex: 4,
      ),
    ]);

    return items;
  }

  void _handleOfflineModeChange(bool isOfflineMode) {
    if (!mounted) return;

    final currentRoute = GoRouterState.of(context).matchedLocation;

    // If we're switching to offline mode and currently on search tab
    if (isOfflineMode && currentRoute.startsWith('/search')) {
      // Navigate to home
      widget.child.goBranch(0);
    }
  }

  void _onTabTapped(int index, List<_NavigationItem> items) {
    if (index < items.length) {
      final item = items[index];
      final isReselect = _previousTabIndex == index;
      // Library always resets to its root page, even when switching in
      // from another tab, since users expect it to behave like a "home"
      // for that section rather than resuming wherever they left it.
      final isLibraryTab = item.route == '/library';

      // Close any open bottom sheet before switching tabs
      closeCurrentBottomSheet();

      // If user taps the same tab again (or it's the Library tab), reset
      // it to initial state. Otherwise, preserve the branch state.
      if (isReselect || isLibraryTab) {
        widget.child.goBranch(item.shellIndex, initialLocation: true);
      } else {
        widget.child.goBranch(item.shellIndex);
      }

      _previousTabIndex = index;
    }
  }

  int _getCurrentIndex(List<_NavigationItem> items, bool isOfflineMode) {
    final currentShellIndex = widget.child.currentIndex;

    if (items.isEmpty) return 0;

    // Try to find the current shell index in the available items
    final matchedIndex = items.indexWhere(
      (item) => item.shellIndex == currentShellIndex,
    );
    if (matchedIndex != -1) return matchedIndex;

    // If the Search branch (1) is active but Search is hidden in offline mode,
    // fall back to the Home tab.
    if (isOfflineMode && currentShellIndex == 1) return 0;

    // Final fallback: return the first tab to keep UI in a valid state.
    return 0;
  }
}

class _NavigationItem {
  const _NavigationItem({
    required this.icon,
    required this.selectedIcon,
    required this.label,
    required this.route,
    required this.shellIndex,
  });

  final IconData icon;
  final IconData selectedIcon;
  final String label;
  final String route;
  final int shellIndex;
}
