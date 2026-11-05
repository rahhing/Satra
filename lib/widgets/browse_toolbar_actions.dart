import 'dart:async';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';

import '../focus/focusable_action_bar.dart';
import '../i18n/strings.g.dart';
import '../navigation/main_screen_scope.dart';
import '../navigation/settings_shortcut.dart';
import '../profiles/active_profile_provider.dart';
import '../profiles/profile.dart';
import '../profiles/profile_activation.dart';
import '../profiles/profile_avatar.dart';
import '../providers/companion_remote_provider.dart';
import '../providers/multi_server_provider.dart';
import '../screens/companion_remote/mobile_remote_screen.dart';
import '../screens/profile/profile_switch_screen.dart';
import '../screens/profile/profile_teardown.dart';
import '../utils/dialogs.dart';
import '../utils/platform_detector.dart';
import '../watch_together/watch_together.dart';
import 'app_icon.dart';
import 'app_menu.dart';
import 'companion_remote/remote_session_dialog.dart';
import 'server_activities_button.dart';
import 'system_clock.dart';

/// Shared browsing controls for Home and every library section.
class BrowseToolbarActions extends StatefulWidget {
  const BrowseToolbarActions({
    super.key,
    required this.actionBarKey,
    required this.onRefresh,
    required this.onNavigateLeft,
    required this.onNavigateDown,
    this.extraActions = const [],
    this.onProfileSwitchingChanged,
  });

  final GlobalKey<FocusableActionBarState> actionBarKey;
  final VoidCallback onRefresh;
  final VoidCallback onNavigateLeft;
  final VoidCallback onNavigateDown;
  final List<FocusableAction> extraActions;
  final ValueChanged<bool>? onProfileSwitchingChanged;

  @override
  State<BrowseToolbarActions> createState() => _BrowseToolbarActionsState();
}

class _BrowseToolbarActionsState extends State<BrowseToolbarActions> {
  bool _switchingProfile = false;
  final _serverActivitiesButtonKey = GlobalKey<ServerActivitiesButtonState>();
  final _userMenuKey = GlobalKey<AppMenuButtonState<String>>();

  Future<void> _handleLogout() async {
    final confirm = await showConfirmDialog(
      context,
      title: t.common.logout,
      message: t.messages.logoutConfirm,
      confirmText: t.common.logout,
      isDestructive: true,
    );

    if (confirm && mounted) {
      await logoutAllProfiles(context);
    }
  }

  void _handleSwitchProfile(BuildContext context) {
    Navigator.of(
      context,
      rootNavigator: true,
    ).push(MaterialPageRoute(builder: (context) => const ProfileSwitchScreen()));
  }

  void _handleOpenSettings(BuildContext context) {
    final mainScope = MainScreenFocusScope.of(context, listen: false);
    if (mainScope != null) {
      mainScope.openSettings?.call();
      return;
    }

    Navigator.push(context, buildSettingsRoute());
  }

  /// Build the [FocusableAction] wrapping the user menu.
  /// Pulls live state from [ActiveProfileProvider]; the menu reuses
  /// [_userMenuItems] for the menu contents so d-pad and tap paths
  /// stay in sync.
  FocusableAction _buildUserMenuAction(BuildContext context) {
    final activeProvider = context.watch<ActiveProfileProvider>();
    final active = activeProvider.active;
    final profiles = activeProvider.profiles;

    return FocusableAction(
      onPressed: _switchingProfile ? null : () => _userMenuKey.currentState?.showButtonMenu(focusFirstItem: true),
      child: AppMenuButton<String>(
        key: _userMenuKey,
        enabled: !_switchingProfile,
        icon: active != null
            ? ProfileAvatar(profile: active, size: 32, avatarUrl: activeProvider.avatarUrlFor(active.id))
            : const AppIcon(Symbols.account_circle_rounded, fill: 1, size: 32, color: Colors.white),
        tooltip: t.profiles.sectionTitle,
        adaptiveSheet: true,
        anchorAlignment: AppMenuAnchorAlignment.end,
        onSelected: (value) => unawaited(_handleUserMenuAction(context, value)),
        entriesBuilder: (context) =>
            _userMenuItems(context, activeProfile: active, profiles: profiles, activeProvider: activeProvider),
      ),
    );
  }

  List<AppMenuEntry<String>> _userMenuItems(
    BuildContext context, {
    required Profile? activeProfile,
    required List<Profile> profiles,
    required ActiveProfileProvider activeProvider,
  }) {
    final theme = Theme.of(context);
    final switchable = profiles.where((p) => p.id != activeProfile?.id).toList();

    return [
      for (final p in switchable)
        AppMenuItem<String>(
          value: 'profile:${p.id}',
          leading: ProfileAvatar(profile: p, size: 24, avatarUrl: activeProvider.avatarUrlFor(p.id)),
          label: p.displayName,
          trailing: p.isPinProtected
              ? AppIcon(Symbols.lock_rounded, fill: 1, size: 14, color: theme.colorScheme.onSurfaceVariant)
              : null,
        ),
      if (switchable.isNotEmpty) const AppMenuDivider(),
      AppMenuItem<String>(value: 'manage_profiles', icon: Symbols.group_rounded, label: t.profiles.sectionTitle),
      AppMenuItem<String>(value: 'settings', icon: Symbols.settings_rounded, label: t.common.settings),
      AppMenuItem<String>(value: 'logout', icon: Symbols.logout_rounded, label: t.common.logout),
    ];
  }

  Future<void> _handleUserMenuAction(BuildContext context, String value) async {
    if (_switchingProfile) return;
    if (value == 'logout') {
      unawaited(_handleLogout());
      return;
    }
    if (value == 'manage_profiles') {
      _handleSwitchProfile(context);
      return;
    }
    if (value == 'settings') {
      _handleOpenSettings(context);
      return;
    }
    if (value.startsWith('profile:')) {
      final id = value.substring('profile:'.length);
      final active = context.read<ActiveProfileProvider>();
      final target = active.profiles.where((p) => p.id == id).firstOrNull;
      if (target == null) return;
      await _switchProfileFromMenu(target);
    }
  }

  Future<void> _switchProfileFromMenu(Profile profile) async {
    if (_switchingProfile) return;
    setState(() => _switchingProfile = true);
    widget.onProfileSwitchingChanged?.call(true);
    try {
      await switchProfileFromUi(context, profile);
    } finally {
      if (mounted) {
        setState(() => _switchingProfile = false);
        widget.onProfileSwitchingChanged?.call(false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final foregroundColor = colorScheme.onSurface;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (PlatformDetector.isTV()) ...[
          SystemClock(
            style: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(color: foregroundColor, fontWeight: FontWeight.w500),
          ),
          const SizedBox(width: 12),
        ],
        Consumer2<WatchTogetherProvider, CompanionRemoteProvider>(
          builder: (context, watchTogether, companionRemote, _) {
            final isDesktop = PlatformDetector.shouldActAsRemoteHost(context);
            void openWatchTogether() =>
                Navigator.push(context, MaterialPageRoute(builder: (_) => const WatchTogetherScreen()));
            void openCompanionRemote() {
              if (isDesktop) {
                RemoteSessionDialog.show(context);
              } else {
                Navigator.push(context, MaterialPageRoute(builder: (context) => const MobileRemoteScreen()));
              }
            }

            return FocusableActionBar(
              key: widget.actionBarKey,
              onNavigateLeft: widget.onNavigateLeft,
              onNavigateDown: widget.onNavigateDown,
              actions: [
                ...widget.extraActions,
                FocusableAction(
                  icon: Symbols.refresh_rounded,
                  iconColor: foregroundColor,
                  tooltip: t.common.refresh,
                  onPressed: widget.onRefresh,
                ),
                // Watch Together
                FocusableAction(
                  onPressed: openWatchTogether,
                  child: Stack(
                    children: [
                      IconButton(
                        icon: AppIcon(
                          Symbols.group_rounded,
                          fill: watchTogether.isInSession ? 1 : 0,
                          color: watchTogether.isInSession ? colorScheme.primary : foregroundColor,
                        ),
                        onPressed: openWatchTogether,
                        tooltip: t.watchTogether.title,
                      ),
                      // Badges sit over the button they label, so they must
                      // not swallow its hover and clicks (#2846).
                      if (watchTogether.isInSession && watchTogether.participantCount > 1)
                        Positioned(
                          top: 6,
                          right: 6,
                          child: IgnorePointer(
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                              decoration: BoxDecoration(
                                color: colorScheme.primary,
                                borderRadius: const BorderRadius.all(Radius.circular(8)),
                              ),
                              child: Text(
                                '${watchTogether.participantCount}',
                                style: TextStyle(color: colorScheme.onPrimary, fontSize: 10, fontWeight: .bold),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                // Companion Remote
                FocusableAction(
                  onPressed: openCompanionRemote,
                  child: Stack(
                    children: [
                      IconButton(
                        icon: AppIcon(
                          Symbols.phone_android_rounded,
                          fill: companionRemote.isConnected ? 1 : 0,
                          color: companionRemote.isConnected ? colorScheme.primary : foregroundColor,
                        ),
                        onPressed: openCompanionRemote,
                        tooltip: t.companionRemote.title,
                      ),
                      if (companionRemote.isConnected)
                        Positioned(
                          top: 6,
                          right: 6,
                          child: IgnorePointer(
                            child: Container(
                              width: 8,
                              height: 8,
                              decoration: BoxDecoration(
                                color: Colors.green,
                                shape: BoxShape.circle,
                                border: Border.fromBorderSide(BorderSide(color: foregroundColor, width: 1)),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                // Server Tasks — Plex-only (`/activities` API has no
                // Jellyfin equivalent), hide the button entirely on
                // Jellyfin-only profiles so the chrome doesn't show
                // a permanently empty popover.
                if (PlatformDetector.isDesktop(context) &&
                    context.select<MultiServerProvider, bool>((p) => p.hasOnlinePlexServers))
                  FocusableAction(
                    onPressed: () => _serverActivitiesButtonKey.currentState?.togglePanel(),
                    child: ServerActivitiesButton(key: _serverActivitiesButtonKey),
                  ),
                // User menu — profiles + sign out
                _buildUserMenuAction(context),
              ],
            );
          },
        ),
      ],
    );
  }
}
