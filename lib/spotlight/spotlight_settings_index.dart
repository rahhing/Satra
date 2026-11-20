import 'dart:async';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';

import '../i18n/strings.g.dart';
import '../media/media_kind.dart';
import '../media/media_library.dart';
import '../navigation/settings_shortcut.dart';
import '../profiles/active_profile_provider.dart';
import '../screens/companion_remote/mobile_remote_screen.dart';
import '../screens/downloads/downloads_screen.dart';
import '../screens/profile/profile_switch_screen.dart';
import '../screens/settings/about_screen.dart';
import '../screens/settings/add_connection_screen.dart';
import '../screens/settings/appearance_settings_screen.dart';
import '../screens/settings/general_settings_screen.dart';
import '../screens/settings/keyboard_shortcuts_screen.dart';
import '../screens/settings/logs_screen.dart';
import '../screens/settings/mpv_config_screen.dart';
import '../screens/settings/playback_settings_screen.dart';
import '../screens/settings/services_settings_screen.dart';
import '../screens/settings/settings_screen.dart';
import '../screens/settings/subtitle_styling_screen.dart';
import '../screens/settings/theme_settings_screen.dart';
import '../services/fullscreen_state_manager.dart';
import '../services/keyboard_shortcuts_service.dart';
import '../utils/platform_detector.dart';
import '../watch_together/watch_together.dart';
import '../widgets/artwork_atmosphere.dart';
import '../widgets/companion_remote/remote_session_dialog.dart';
import '../widgets/library_management_sheet.dart';
import '../widgets/utility_panel_route.dart';
import 'spotlight_models.dart';

/// Callbacks linking the Universal Spotlight to the active [MainScreen] shell.
class SpotlightShellCallbacks {
  const SpotlightShellCallbacks({
    this.onSelectHome,
    this.onSelectLibrary,
    this.onSelectExplore,
    this.onSelectLiveTv,
    this.onOpenDownloads,
    this.onOpenSettings,
    this.onRefresh,
    this.onReconnect,
    this.isOffline = false,
    this.hasExplore = false,
    this.hasLiveTv = false,
  });

  final VoidCallback? onSelectHome;
  final void Function(String libraryGlobalKey)? onSelectLibrary;
  final VoidCallback? onSelectExplore;
  final VoidCallback? onSelectLiveTv;
  final VoidCallback? onOpenDownloads;
  final VoidCallback? onOpenSettings;
  final VoidCallback? onRefresh;
  final VoidCallback? onReconnect;
  final bool isOffline;
  final bool hasExplore;
  final bool hasLiveTv;
}

void _pushUtilityOrPage(NavigatorState navigator, Widget screen, {String? routeName}) {
  final isDesktopWindow = PlatformDetector.isDesktopOS() && !PlatformDetector.isTVDevice();
  navigator.push(
    isDesktopWindow
        ? utilityPanelRoute(child: screen, name: routeName)
        : MaterialPageRoute<void>(
            settings: RouteSettings(name: routeName),
            builder: (_) => screen,
          ),
  );
}

IconData _iconForLibraryKind(MediaKind kind) {
  return switch (kind) {
    MediaKind.movie => Symbols.movie_rounded,
    MediaKind.show || MediaKind.season || MediaKind.episode => Symbols.tv_rounded,
    MediaKind.artist || MediaKind.album || MediaKind.track => Symbols.music_note_rounded,
    MediaKind.photo => Symbols.photo_rounded,
    _ => Symbols.video_library_rounded,
  };
}

/// Builds localized [SpotlightEntry] items for libraries, quick actions, and
/// settings pages/options.
List<SpotlightEntry> buildLocalSpotlightEntries({
  required BuildContext hostContext,
  required NavigatorState hostNavigator,
  required List<MediaLibrary> visibleLibraries,
  required bool hasMultipleServers,
  required SpotlightShellCallbacks callbacks,
}) {
  final entries = <SpotlightEntry>[];

  // 1. Visible Libraries
  for (final library in visibleLibraries) {
    entries.add(
      SpotlightEntry(
        id: 'library:${library.globalKey}',
        title: library.title,
        subtitle: hasMultipleServers ? library.serverName : null,
        badge: t.spotlight.categories.libraries,
        icon: _iconForLibraryKind(library.kind),
        category: SpotlightCategory.libraries,
        type: SpotlightEntryType.library,
        basePriority: 85,
        keywords: ['library', 'libraries', library.kind.id, if (library.serverName != null) library.serverName!],
        onActivate: () => callbacks.onSelectLibrary?.call(library.globalKey),
      ),
    );
  }

  // 2. App Navigation & Quick Actions
  if (!callbacks.isOffline && callbacks.onSelectHome != null) {
    entries.add(
      SpotlightEntry(
        id: 'action:home',
        title: t.spotlight.actions.goHome,
        badge: t.spotlight.categories.actions,
        icon: Symbols.home_rounded,
        category: SpotlightCategory.actions,
        type: SpotlightEntryType.action,
        basePriority: 95,
        keywords: [t.common.home, 'home', 'discover', 'dashboard', 'start'],
        onActivate: () => callbacks.onSelectHome?.call(),
      ),
    );
  }

  if (!callbacks.isOffline && callbacks.hasExplore && callbacks.onSelectExplore != null) {
    entries.add(
      SpotlightEntry(
        id: 'action:explore',
        title: t.spotlight.actions.openExplore,
        badge: t.spotlight.categories.actions,
        icon: Symbols.explore_rounded,
        category: SpotlightCategory.actions,
        type: SpotlightEntryType.action,
        basePriority: 78,
        keywords: [t.navigation.explore, 'explore', 'discover', 'catalog', 'trending', 'popular'],
        onActivate: () => callbacks.onSelectExplore?.call(),
      ),
    );
  }

  if (!callbacks.isOffline && callbacks.hasLiveTv && callbacks.onSelectLiveTv != null) {
    entries.add(
      SpotlightEntry(
        id: 'action:livetv',
        title: t.spotlight.actions.openLiveTv,
        badge: t.spotlight.categories.actions,
        icon: Symbols.live_tv_rounded,
        category: SpotlightCategory.actions,
        type: SpotlightEntryType.action,
        basePriority: 78,
        keywords: [t.navigation.liveTv, 'live', 'tv', 'channels', 'guide', 'epg', 'broadcast'],
        onActivate: () => callbacks.onSelectLiveTv?.call(),
      ),
    );
  }

  if (!PlatformDetector.isAppleTV()) {
    entries.add(
      SpotlightEntry(
        id: 'action:downloads',
        title: t.spotlight.actions.openDownloads,
        badge: t.spotlight.categories.actions,
        icon: Symbols.download_rounded,
        category: SpotlightCategory.actions,
        type: SpotlightEntryType.action,
        basePriority: 90,
        keywords: [t.navigation.downloads, 'downloads', 'offline', 'saved', 'sync'],
        onActivate: () {
          if (callbacks.onOpenDownloads != null) {
            callbacks.onOpenDownloads!();
          } else {
            _pushUtilityOrPage(hostNavigator, const DownloadsScreen());
          }
        },
      ),
    );
  }

  entries.add(
    SpotlightEntry(
      id: 'action:settings',
      title: t.spotlight.actions.openSettings,
      badge: t.spotlight.categories.actions,
      icon: Symbols.settings_rounded,
      category: SpotlightCategory.actions,
      type: SpotlightEntryType.action,
      basePriority: 88,
      keywords: [t.common.settings, 'settings', 'preferences', 'options', 'configuration'],
      onActivate: () {
        if (callbacks.onOpenSettings != null) {
          callbacks.onOpenSettings!();
        } else {
          hostNavigator.push(buildSettingsRoute());
        }
      },
    ),
  );

  if (PlatformDetector.isDesktopOS() && !PlatformDetector.isTVDevice()) {
    final isFs = FullscreenStateManager().isFullscreen;
    entries.add(
      SpotlightEntry(
        id: 'action:fullscreen',
        title: isFs ? t.common.exitFullscreen : t.spotlight.actions.toggleFullscreen,
        badge: t.spotlight.categories.actions,
        icon: isFs ? Symbols.fullscreen_exit_rounded : Symbols.fullscreen_rounded,
        category: SpotlightCategory.actions,
        type: SpotlightEntryType.action,
        basePriority: 82,
        keywords: [t.spotlight.actions.toggleFullscreen, t.common.fullscreen, 'fullscreen', 'window', 'maximize'],
        onActivate: () => unawaited(FullscreenStateManager().toggleFullscreen()),
      ),
    );
  }

  entries.add(
    SpotlightEntry(
      id: 'action:switch_profile',
      title: t.spotlight.actions.switchProfile,
      badge: t.spotlight.categories.actions,
      icon: Symbols.group_rounded,
      category: SpotlightCategory.actions,
      type: SpotlightEntryType.action,
      basePriority: 74,
      keywords: [t.profiles.sectionTitle, 'profile', 'profiles', 'user', 'account', 'switch'],
      onActivate: () {
        final rootNav = Navigator.of(hostContext, rootNavigator: true);
        _pushUtilityOrPage(rootNav, const ProfileSwitchScreen());
      },
    ),
  );

  if (!callbacks.isOffline) {
    entries.add(
      SpotlightEntry(
        id: 'action:watch_together',
        title: t.spotlight.actions.watchTogether,
        badge: t.spotlight.categories.actions,
        icon: Symbols.group_rounded,
        category: SpotlightCategory.actions,
        type: SpotlightEntryType.action,
        basePriority: 70,
        keywords: [t.watchTogether.title, 'watch', 'together', 'party', 'room', 'friends'],
        onActivate: () => hostNavigator.push(MaterialPageRoute<void>(builder: (_) => const WatchTogetherScreen())),
      ),
    );
  }

  entries.add(
    SpotlightEntry(
      id: 'action:companion_remote',
      title: t.spotlight.actions.companionRemote,
      badge: t.spotlight.categories.actions,
      icon: Symbols.phone_android_rounded,
      category: SpotlightCategory.actions,
      type: SpotlightEntryType.action,
      basePriority: 68,
      keywords: [t.companionRemote.title, 'remote', 'companion', 'phone', 'control', 'qr'],
      onActivate: () {
        if (!hostContext.mounted) return;
        if (PlatformDetector.shouldActAsRemoteHost(hostContext)) {
          RemoteSessionDialog.show(hostContext);
        } else {
          hostNavigator.push(MaterialPageRoute<void>(builder: (_) => const MobileRemoteScreen()));
        }
      },
    ),
  );

  if (visibleLibraries.isNotEmpty) {
    entries.add(
      SpotlightEntry(
        id: 'action:manage_libraries',
        title: t.spotlight.actions.manageLibraries,
        subtitle: t.settings.manageLibrariesDescription,
        badge: t.spotlight.categories.actions,
        icon: Symbols.edit_rounded,
        category: SpotlightCategory.actions,
        type: SpotlightEntryType.action,
        basePriority: 66,
        keywords: const ['manage', 'libraries', 'reorder', 'hide', 'pin'],
        onActivate: () {
          if (hostContext.mounted) showLibraryManagementSheet(hostContext);
        },
      ),
    );
  }

  if (callbacks.onRefresh != null) {
    entries.add(
      SpotlightEntry(
        id: 'action:refresh',
        title: t.spotlight.actions.refreshLibrary,
        badge: t.spotlight.categories.actions,
        icon: Symbols.refresh_rounded,
        category: SpotlightCategory.actions,
        type: SpotlightEntryType.action,
        basePriority: 64,
        keywords: [t.common.refresh, 'refresh', 'reload', 'sync'],
        onActivate: () => callbacks.onRefresh?.call(),
      ),
    );
  }

  if (callbacks.isOffline && callbacks.onReconnect != null) {
    entries.add(
      SpotlightEntry(
        id: 'action:reconnect',
        title: t.spotlight.actions.reconnectServers,
        badge: t.spotlight.categories.actions,
        icon: Symbols.wifi_rounded,
        category: SpotlightCategory.actions,
        type: SpotlightEntryType.action,
        basePriority: 92,
        keywords: [t.common.reconnect, 'reconnect', 'online', 'connect', 'network', 'server'],
        onActivate: () => callbacks.onReconnect?.call(),
      ),
    );
  }

  entries.add(
    SpotlightEntry(
      id: 'action:add_server',
      title: t.spotlight.actions.addServer,
      badge: t.spotlight.categories.actions,
      icon: Symbols.add_link_rounded,
      category: SpotlightCategory.actions,
      type: SpotlightEntryType.action,
      basePriority: 62,
      keywords: [t.connections.addConnection, 'server', 'connection', 'plex', 'jellyfin', 'emby', 'add'],
      onActivate: () {
        final active = hostContext.mounted ? hostContext.read<ActiveProfileProvider>().active : null;
        _pushUtilityOrPage(hostNavigator, AddConnectionScreen(targetProfile: active), routeName: kSettingsRouteName);
      },
    ),
  );

  // 3. Settings Pages & Individual Setting Shortcuts
  void openSettingScreen(Widget screen) => _pushUtilityOrPage(hostNavigator, screen, routeName: kSettingsRouteName);

  entries.addAll([
    SpotlightEntry(
      id: 'setting:general',
      title: t.settings.general,
      subtitle: t.settings.generalDescription,
      badge: t.common.settings,
      icon: Symbols.tune_rounded,
      category: SpotlightCategory.settings,
      type: SpotlightEntryType.setting,
      basePriority: 72,
      keywords: const [
        'general',
        'language',
        'locale',
        'startup',
        'autoplay',
        'next',
        'episode',
        'fullscreen',
        'profile',
        'track',
      ],
      onActivate: () => openSettingScreen(const GeneralSettingsScreen()),
    ),
    SpotlightEntry(
      id: 'setting:appearance',
      title: t.settings.appearance,
      subtitle: '${t.settings.theme} · ${t.settings.libraryDensity} · ${t.settings.display}',
      badge: t.common.settings,
      icon: Symbols.palette_rounded,
      category: SpotlightCategory.settings,
      type: SpotlightEntryType.setting,
      basePriority: 72,
      keywords: const [
        'appearance',
        'display',
        'density',
        'grid',
        'list',
        'hero',
        'poster',
        'spoilers',
        'watched',
        'unwatched',
        'scale',
        'corner',
        'rounding',
        'card hover lift',
        'shelf title opacity',
        'spotlight artwork opacity',
        'browse effects',
      ],
      onActivate: () => openSettingScreen(const AppearanceSettingsScreen()),
    ),
    SpotlightEntry(
      id: 'setting:theme',
      title: t.settings.theme,
      subtitle: t.settings.appearance,
      badge: t.common.settings,
      icon: Symbols.dark_mode_rounded,
      category: SpotlightCategory.settings,
      type: SpotlightEntryType.setting,
      basePriority: 68,
      keywords: const ['theme', 'dark', 'light', 'oled', 'midnight', 'colors', 'accent', 'icon'],
      onActivate: () => openSettingScreen(const ThemeSettingsScreen()),
    ),
    SpotlightEntry(
      id: 'setting:liquid_glass',
      title: t.settings.liquidGlass,
      subtitle: t.settings.appearance,
      badge: t.common.settings,
      icon: Symbols.water_drop_rounded,
      category: SpotlightCategory.settings,
      type: SpotlightEntryType.setting,
      basePriority: 68,
      keywords: const [
        'liquid',
        'glass',
        'opacity',
        'opaque',
        'blur',
        'brightness',
        'distortion',
        'refraction',
        'frosted',
        'translucency',
        'appearance',
      ],
      onActivate: () => openSettingScreen(const AppearanceSettingsScreen()),
    ),
    SpotlightEntry(
      id: 'setting:glass_blur_amount',
      title: t.settings.glassBlurAmount,
      subtitle: t.settings.appearance,
      badge: t.common.settings,
      icon: Symbols.blur_on_rounded,
      category: SpotlightCategory.settings,
      type: SpotlightEntryType.setting,
      basePriority: 66,
      keywords: const ['blur', 'amount', 'strength', 'radius', 'sigma', 'frosted', 'glass', 'appearance'],
      onActivate: () => openSettingScreen(const AppearanceSettingsScreen()),
    ),
    SpotlightEntry(
      id: 'setting:glass_background_brightness',
      title: t.settings.glassBackgroundBrightness,
      subtitle: t.settings.appearance,
      badge: t.common.settings,
      icon: Symbols.brightness_6_rounded,
      category: SpotlightCategory.settings,
      type: SpotlightEntryType.setting,
      basePriority: 66,
      keywords: const ['background', 'brightness', 'dim', 'darken', 'lighten', 'blur', 'glass', 'appearance'],
      onActivate: () => openSettingScreen(const AppearanceSettingsScreen()),
    ),
    if ((PlatformDetector.isMobile(hostContext) && !PlatformDetector.isAutomotive()) ||
        ArtworkAtmosphereScope.supportsDesktopArtwork(hostContext))
      SpotlightEntry(
        id: 'setting:darken_mobile_backdrop',
        title: t.settings.darkenMobileBackdrop,
        subtitle: t.settings.appearance,
        badge: t.common.settings,
        icon: Symbols.contrast_rounded,
        category: SpotlightCategory.settings,
        type: SpotlightEntryType.setting,
        basePriority: 66,
        keywords: const ['backdrop', 'darken', 'dim', 'bright', 'continue watching', 'blur', 'home', 'appearance'],
        onActivate: () => openSettingScreen(const AppearanceSettingsScreen()),
      ),
    if (!PlatformDetector.shouldUseSideNavigation(hostContext)) ...[
      SpotlightEntry(
        id: 'setting:search_in_top_bar',
        title: t.settings.searchInTopBar,
        subtitle: t.settings.appearance,
        badge: t.common.settings,
        icon: Symbols.search_rounded,
        category: SpotlightCategory.settings,
        type: SpotlightEntryType.setting,
        basePriority: 64,
        keywords: const ['search', 'top', 'bottom', 'bar', 'dock', 'navigation', 'appearance'],
        onActivate: () => openSettingScreen(const AppearanceSettingsScreen()),
      ),
      SpotlightEntry(
        id: 'setting:separate_bottom_search_button',
        title: t.settings.separateBottomSearchButton,
        subtitle: t.settings.appearance,
        badge: t.common.settings,
        icon: Symbols.dock_to_right_rounded,
        category: SpotlightCategory.settings,
        type: SpotlightEntryType.setting,
        basePriority: 62,
        keywords: const ['search', 'separate', 'detached', 'orb', 'bottom', 'bar', 'dock', 'navigation', 'appearance'],
        onActivate: () => openSettingScreen(const AppearanceSettingsScreen()),
      ),
    ],
    SpotlightEntry(
      id: 'setting:playback',
      title: t.settings.videoPlayback,
      subtitle: t.settings.videoPlaybackDescription,
      badge: t.common.settings,
      icon: Symbols.play_circle_rounded,
      category: SpotlightCategory.settings,
      type: SpotlightEntryType.setting,
      basePriority: 72,
      keywords: const [
        'playback',
        'video',
        'audio',
        'passthrough',
        'hardware',
        'decoding',
        'buffer',
        'hdr',
        'dolby',
        'mpv',
        'external',
        'player',
        'speed',
      ],
      onActivate: () => openSettingScreen(const PlaybackSettingsScreen()),
    ),
    SpotlightEntry(
      id: 'setting:subtitles',
      title: t.screens.subtitleStyling,
      subtitle: t.settings.videoPlayback,
      badge: t.common.settings,
      icon: Symbols.subtitles_rounded,
      category: SpotlightCategory.settings,
      type: SpotlightEntryType.setting,
      basePriority: 66,
      keywords: const ['subtitles', 'captions', 'font', 'size', 'color', 'border', 'background', 'ass'],
      onActivate: () => openSettingScreen(const SubtitleStylingScreen()),
    ),
    SpotlightEntry(
      id: 'setting:mpv',
      title: t.screens.mpvConfig,
      subtitle: t.settings.videoPlayback,
      badge: t.common.settings,
      icon: Symbols.terminal_rounded,
      category: SpotlightCategory.settings,
      type: SpotlightEntryType.setting,
      basePriority: 60,
      keywords: const ['mpv', 'config', 'conf', 'shader', 'anime4k', 'advanced'],
      onActivate: () => openSettingScreen(const MpvConfigScreen()),
    ),
    SpotlightEntry(
      id: 'setting:services',
      title: t.settings.services,
      subtitle: t.settings.servicesDescription,
      badge: t.common.settings,
      icon: Symbols.sync_rounded,
      category: SpotlightCategory.settings,
      type: SpotlightEntryType.setting,
      basePriority: 68,
      keywords: const ['services', 'trakt', 'anilist', 'mal', 'myanimelist', 'simkl', 'seerr', 'mdblist', 'discord'],
      onActivate: () => openSettingScreen(const ServicesSettingsScreen()),
    ),
    if (KeyboardShortcutsService.isPlatformSupported())
      SpotlightEntry(
        id: 'setting:keyboard_shortcuts',
        title: t.settings.keyboardShortcuts,
        subtitle: t.settings.keyboardShortcutsDescription,
        badge: t.common.settings,
        icon: Symbols.keyboard_rounded,
        category: SpotlightCategory.settings,
        type: SpotlightEntryType.setting,
        basePriority: 66,
        keywords: const ['keyboard', 'shortcuts', 'hotkeys', 'controls', 'keybindings'],
        onActivate: () {
          unawaited(
            KeyboardShortcutsService.getInstance().then((service) {
              openSettingScreen(KeyboardShortcutsScreen(keyboardService: service));
            }),
          );
        },
      ),
    SpotlightEntry(
      id: 'setting:hide_spoilers',
      title: t.settings.hideSpoilers,
      subtitle: t.settings.hideSpoilersDescription,
      badge: t.settings.appearance,
      icon: Symbols.visibility_off_rounded,
      category: SpotlightCategory.settings,
      type: SpotlightEntryType.setting,
      basePriority: 58,
      keywords: const ['spoilers', 'blur', 'unwatched', 'thumbnails', 'episodes'],
      onActivate: () => openSettingScreen(const AppearanceSettingsScreen()),
    ),
    SpotlightEntry(
      id: 'setting:language',
      title: t.settings.language,
      subtitle: t.settings.general,
      badge: t.settings.general,
      icon: Symbols.language_rounded,
      category: SpotlightCategory.settings,
      type: SpotlightEntryType.setting,
      basePriority: 58,
      keywords: const ['language', 'locale', 'translation', 'english'],
      onActivate: () => openSettingScreen(const GeneralSettingsScreen()),
    ),
    SpotlightEntry(
      id: 'setting:hardware_decoding',
      title: t.settings.hardwareDecoding,
      subtitle: t.settings.hardwareDecodingDescription,
      badge: t.settings.videoPlayback,
      icon: Symbols.memory_rounded,
      category: SpotlightCategory.settings,
      type: SpotlightEntryType.setting,
      basePriority: 56,
      keywords: const ['hardware', 'decoding', 'gpu', 'acceleration', 'video'],
      onActivate: () => openSettingScreen(const PlaybackSettingsScreen()),
    ),
    SpotlightEntry(
      id: 'setting:logs',
      title: t.screens.logs,
      subtitle: t.settings.debugLogging,
      badge: t.common.settings,
      icon: Symbols.article_rounded,
      category: SpotlightCategory.settings,
      type: SpotlightEntryType.setting,
      basePriority: 54,
      keywords: const ['logs', 'debug', 'diagnostics', 'troubleshooting', 'error'],
      onActivate: () => openSettingScreen(const LogsScreen()),
    ),
    SpotlightEntry(
      id: 'setting:downloads_storage',
      title: t.navigation.downloads,
      subtitle: t.common.settings,
      badge: t.common.settings,
      icon: Symbols.folder_rounded,
      category: SpotlightCategory.settings,
      type: SpotlightEntryType.setting,
      basePriority: 54,
      keywords: const ['download', 'location', 'storage', 'wifi', 'cache', 'export', 'import', 'backup'],
      onActivate: () => openSettingScreen(const SettingsScreen()),
    ),
    SpotlightEntry(
      id: 'setting:about',
      title: t.settings.about,
      subtitle: t.settings.aboutDescription,
      badge: t.common.settings,
      icon: Symbols.info_rounded,
      category: SpotlightCategory.settings,
      type: SpotlightEntryType.setting,
      basePriority: 52,
      keywords: const ['about', 'version', 'licenses', 'update', 'credits'],
      onActivate: () => openSettingScreen(const AboutScreen()),
    ),
  ]);

  return entries;
}
