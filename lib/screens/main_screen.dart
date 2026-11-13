import '../widgets/cycling_media_backdrop.dart';
import 'dart:async';
import '../media/ids.dart';
import '../media/media_server_client.dart';
import '../navigation/main_screen_scope.dart';
import '../navigation/page_refresh_shortcut.dart';
import 'dart:io' show Platform, exit;

export '../navigation/main_screen_scope.dart'
    show MainScreenFocusScope, MainScreenScopeAspect, SideNavigationBleedBuilder;

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show KeyDownEvent, KeyRepeatEvent, KeyUpEvent, LogicalKeyboardKey;
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';
import 'package:window_manager/window_manager.dart';
import '../i18n/strings.g.dart';
import '../services/app_exit_service.dart';
import '../services/hover_preview_controller.dart';
import '../services/tvos_system_navigation_service.dart';
import '../services/update_service.dart';
import '../spotlight/spotlight_settings_index.dart';
import '../spotlight/spotlight_shortcut.dart';
import '../utils/app_logger.dart';
import '../widgets/auth_error_banner.dart';
import '../widgets/app_icon.dart';
import '../utils/iphone_duo.dart';
import '../utils/platform_detector.dart';
import '../utils/scroll_to_top.dart';
import '../utils/snackbar_helper.dart';
import '../utils/update_dialog.dart';
import '../utils/video_player_navigation.dart';
import '../mixins/mounted_set_state_mixin.dart';
import '../mixins/refreshable.dart';
import '../widgets/overlay_sheet.dart';
import '../mixins/tab_visibility_aware.dart';
import '../navigation/navigation_tabs.dart';
import '../navigation/profile_navigation_scope.dart';
import '../navigation/settings_shortcut.dart';
import '../profiles/active_profile_binder.dart';
import '../connection/connection_registry.dart';
import '../profiles/active_profile_provider.dart';
import '../profiles/plex_home_service.dart';
import '../profiles/profile_selection_policy.dart';
import '../providers/catalog_sources_provider.dart';
import '../providers/account_preferences_controller.dart';
import '../providers/download_provider.dart';
import '../providers/multi_server_provider.dart';
import '../providers/hidden_libraries_provider.dart';
import '../providers/libraries_provider.dart';
import '../providers/playback_state_provider.dart';
import '../providers/seerr_account_provider.dart';
import '../widgets/settings_builder.dart';
import '../widgets/tv_virtual_keyboard.dart';
import '../services/api_cache.dart';
import '../services/multi_server_manager.dart';
import '../services/offline_watch_sync_service.dart';
import '../services/settings_service.dart';
import '../providers/offline_mode_provider.dart';
import '../services/companion_remote/companion_remote_host_controller.dart';
import '../services/companion_remote/companion_remote_receiver.dart';
import '../services/fullscreen_state_manager.dart';
import '../providers/companion_remote_provider.dart';
import '../services/deep_links/deep_link_launcher.dart';
import '../services/deep_links/deep_link_service.dart';
import '../widgets/music/mini_player.dart';
import '../widgets/mobile_glass_tab_bar.dart';
import '../widgets/mobile_navigation_rail.dart';
import '../widgets/vertical_bar_shell.dart';
import '../widgets/glass_surface.dart';
import '../widgets/utility_panel_route.dart';
import '../widgets/retained_tab_view.dart';
import '../widgets/focusable_tab_chip.dart';
import '../focus/covered_route_focus_boundary.dart';
import '../focus/dpad_navigator.dart';
import '../focus/key_event_utils.dart';
import 'discover_screen.dart';
import 'explore_screen.dart';
import 'libraries/library_quick_picker_sheet.dart';
import 'libraries/libraries_screen.dart';
import 'livetv/live_tv_screen.dart';
import 'downloads/downloads_screen.dart';
import 'settings/settings_screen.dart';
import 'profile/profile_switch_screen.dart';
import 'video_player_screen.dart';
import 'profile/profile_teardown.dart';
import '../watch_together/watch_together.dart';

/// Desktop embedders report every hardware key as a keyboard key, so a remote
/// (HDMI-CEC, IR receiver) Escape cannot be told apart from a keyboard Escape.
/// TV mode is the signal that the machine is remote-driven: there Escape stays
/// Back and keeps the press-back-again exit (#2490).
@visibleForTesting
bool shouldHandleDesktopRootEscape({
  required bool isDesktop,
  required bool isTV,
  required bool isPhysicalKeyboardEvent,
  required LogicalKeyboardKey logicalKey,
  required bool isCurrentRoute,
  required bool isHomeTab,
}) {
  return isDesktop &&
      !isTV &&
      isPhysicalKeyboardEvent &&
      logicalKey == LogicalKeyboardKey.escape &&
      isCurrentRoute &&
      isHomeTab;
}

/// Whether a lifecycle resume should raise the "ask for a profile on open"
/// picker.
///
/// Mobile-only: on desktop `resumed` fires on every window focus gain
/// (alt-tab, click), which is far too frequent — the startup prompt is
/// sufficient there. An open player does not exempt the resume: "ask on
/// open" exists so that whoever wakes the device cannot carry on with the
/// previous profile's session, and a show left paused overnight is exactly
/// that (#2195). The player stays paused under the picker
/// ([VideoPlayerScreenState.holdActivePlaybackUntil]). A session that kept
/// playing in Picture in Picture never left the user's sight, so it never
/// arms [ProfileSelectionResumeGate]. Never during a live companion-remote
/// session: a phone driving another device backgrounds and sleeps
/// constantly, and the picker + PIN would bury a session that already
/// belongs to the profile that started it (#2087).
@visibleForTesting
bool shouldShowProfileSelectionOnResume({
  required bool resumedFromBackground,
  required bool isOffline,
  required bool alreadyShowingProfileSelection,
  required bool isMobilePlatform,
  required bool hasActiveCompanionRemoteSession,
}) {
  return resumedFromBackground &&
      !isOffline &&
      !alreadyShowingProfileSelection &&
      isMobilePlatform &&
      !hasActiveCompanionRemoteSession;
}

/// Latches whether the app has genuinely left the foreground since the last
/// `resumed`, and consumes that fact on the next resume so the "ask for a
/// profile on open" rule can re-apply exactly once per backgrounding.
///
/// System overlays (Fire TV Alexa, notification shade, Control Center) only
/// produce `inactive -> resumed` — the app never left the foreground — so
/// they must not prompt (#1990). iOS returns from the background as
/// `hidden -> inactive -> resumed`, so inspecting only the immediately
/// previous state would miss a real return; latching the deepest state seen
/// handles both. The startup flow owns the cold open, so a first `resumed`
/// with no prior backgrounding does not prompt.
///
/// A backgrounding the active player spends in Picture in Picture does not
/// latch: the session never left the user's sight. Only the way out decides
/// that. Flutter walks every state in between, so a return from `paused`
/// passes back through `hidden`, by when PiP may already have handed the
/// session back to the app; that frame must not latch it after the fact.
@visibleForTesting
class ProfileSelectionResumeGate {
  bool _wasBackgrounded = false;
  AppLifecycleState? _lastState;

  /// Whether a genuine backgrounding has been observed since the last resume.
  bool get wasBackgrounded => _wasBackgrounded;

  /// Feeds one lifecycle transition through the gate. Returns true exactly
  /// once per backgrounding: on the first `resumed` after the sequence
  /// reached `hidden`/`paused`/`detached` other than in Picture in Picture.
  /// Consuming resets the latch.
  ///
  /// [sessionContinuesInPip] is whether the active player keeps playing in
  /// PiP were the app backgrounded now; it is read only for frames on the way
  /// out.
  bool consumePromptOn(AppLifecycleState state, {bool sessionContinuesInPip = false}) {
    final previous = _lastState;
    _lastState = state;
    switch (state) {
      case AppLifecycleState.resumed:
        final shouldPrompt = _wasBackgrounded;
        _wasBackgrounded = false;
        return shouldPrompt;
      case AppLifecycleState.hidden:
        if (previous != AppLifecycleState.paused && !sessionContinuesInPip) _wasBackgrounded = true;
        return false;
      case AppLifecycleState.paused:
        if (!sessionContinuesInPip) _wasBackgrounded = true;
        return false;
      case AppLifecycleState.detached:
        _wasBackgrounded = true;
        return false;
      case AppLifecycleState.inactive:
        return false;
    }
  }
}

/// Latches when the app leaves the foreground and, on the next `resumed`,
/// reports whether it stayed backgrounded long enough that on-screen content
/// should be refetched (#2043).
///
/// TV launchers resume the resident process rather than cold-starting it, so
/// "opening the app" hours later otherwise shows the in-memory grids from the
/// previous session. The [staleAfter] threshold keeps short interruptions
/// (app switch, notification shade, desktop alt-tab reaching `hidden`) from
/// refetching and resetting scroll/focus state, and `inactive`-only overlays
/// never latch at all — same shape as [ProfileSelectionResumeGate].
@visibleForTesting
class ContentRefreshResumeGate {
  ContentRefreshResumeGate({this.staleAfter = const Duration(minutes: 5), DateTime Function()? now})
    : _now = now ?? DateTime.now;

  /// Minimum time spent backgrounded before a resume triggers a refresh.
  final Duration staleAfter;
  final DateTime Function() _now;

  DateTime? _backgroundedAt;

  /// Feeds one lifecycle transition through the gate. Returns true exactly
  /// once per backgrounding: on the first `resumed` after the sequence
  /// reached `hidden`/`paused`/`detached` at least [staleAfter] ago. Keeps
  /// the *earliest* backgrounded timestamp, so `hidden -> paused` churn while
  /// backgrounded doesn't restart the clock.
  bool consumeRefreshOn(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.resumed:
        final backgroundedAt = _backgroundedAt;
        _backgroundedAt = null;
        return backgroundedAt != null && _now().difference(backgroundedAt) >= staleAfter;
      case AppLifecycleState.hidden:
      case AppLifecycleState.paused:
      case AppLifecycleState.detached:
        _backgroundedAt ??= _now();
        return false;
      case AppLifecycleState.inactive:
        return false;
    }
  }
}

@visibleForTesting
bool shouldRetryActiveProfileBindAfterReconnect({
  required bool hasActiveProfile,
  required bool hasVisibleConnectedServers,
  required bool hasManagerOnlineServers,
  required bool hasKnownOfflineServers,
}) {
  return hasActiveProfile && !hasVisibleConnectedServers && (hasManagerOnlineServers || !hasKnownOfflineServers);
}

@visibleForTesting
bool shouldRenderMainScreenOffline({
  required bool providerOffline,
  required bool startupOfflineUntilConnected,
  required bool hasVisibleConnectedServers,
}) {
  return providerOffline || (startupOfflineUntilConnected && !hasVisibleConnectedServers);
}

@visibleForTesting
List<NavigationTab> mainScreenBottomNavigationTabs({
  required List<NavigationTab> visibleTabs,
  required bool isMobile,
  required bool isOffline,
  required NavigationTabId currentTab,
}) {
  if (!isMobile) return visibleTabs;
  return visibleTabs.where((tab) {
    if (tab.id != NavigationTabId.settings) return true;
    return isOffline || currentTab == NavigationTabId.settings;
  }).toList();
}

@visibleForTesting
bool shouldPassTvosMenuToSystem({
  required bool isAppleTV,
  required bool isShowingProfileSelection,
  required bool isOverlaySheetOpen,
  required bool isRouteCurrent,
  required bool hasVisibleTabs,
  required bool isCurrentTabRoot,
}) {
  return isAppleTV &&
      !isShowingProfileSelection &&
      !isOverlaySheetOpen &&
      isRouteCurrent &&
      hasVisibleTabs &&
      isCurrentTabRoot;
}

@visibleForTesting
enum ProfileInvalidationAction { none, invalidateNow }

@visibleForTesting
ProfileInvalidationAction profileInvalidationAction({
  required String? previousProfileId,
  required String? currentProfileId,
  required bool wasBindingPreviously,
  required bool isBindingNow,
}) {
  // An active-id change remounts the whole session subtree
  // ([ProfileSessionScreen] keys on the id), recreating this screen and
  // every session-scoped provider — nothing to invalidate from here. The
  // app-global pieces (ApiCache volatile rows) are cleared at that remount
  // seam, where the unmount can't outrun the work.
  if (currentProfileId != previousProfileId) {
    return ProfileInvalidationAction.none;
  }
  if (wasBindingPreviously && !isBindingNow) {
    return ProfileInvalidationAction.invalidateNow;
  }
  return ProfileInvalidationAction.none;
}

/// The initial-profile prompt flow behind [_MainScreenState]'s post-frame
/// prompt and its late-profiles re-arm, extracted so the mid-await re-entry
/// race is testable without the full MainScreen tree.
///
/// [claimPrompt] must synchronously claim the "picker is up" guard and return
/// false when it is already claimed. The claim is taken before the first
/// await: the provider notifies mid-initialize (e.g. a fresh sign-in's slow
/// home-user fetch), and the listener's re-entrant call would otherwise stack
/// a second requireSelection picker on the root navigator. [releasePrompt]
/// clears the claim on every exit; on the push path that re-clear is
/// idempotent with [pushProfileSelection]'s own post-pop clear.
@visibleForTesting
Future<void> runInitialProfilePrompt({
  required ActiveProfileProvider activeProfile,
  required bool Function() claimPrompt,
  required void Function() releasePrompt,
  required bool Function() isMounted,
  required bool isOfflineMode,
  required Future<bool> Function() hasConnections,
  required Future<void> Function() settleSession,
  required Future<void> Function() pushProfileSelection,
  Future<SettingsService> Function() settings = SettingsService.getInstance,
}) async {
  if (!claimPrompt()) return;
  try {
    // The provider's initialize() is fire-and-forget from MultiProvider —
    // wait for it to settle so `active` and `profiles` reflect storage
    // before we decide whether to prompt.
    await activeProfile.initialize();
    if (!isMounted()) return;

    final settingsService = await settings();
    if (!isMounted()) return;

    // Connections but ZERO resolvable profiles (e.g. the home-user fetch
    // failed at sign-in): a session with nothing to select and no picker is
    // a dead end. Mirror the boot guard — prune orphans and route to auth
    // when nothing selectable remains.
    if (activeProfile.active == null && activeProfile.profiles.isEmpty) {
      // Offline, "unresolvable" may just be an unreachable plex.tv — don't
      // kick the user to auth over it.
      if (!isOfflineMode && await hasConnections() && isMounted()) {
        appLogger.w('MainScreen: connections exist but no profiles resolved — settling session');
        await settleSession();
      }
      return;
    }

    // Always prompt when there's no active profile but profiles exist
    // (fresh sign-in with multiple Plex Home users): otherwise the binder
    // has no profile to bind, and the user lands on an empty screen with
    // no way back to the picker.
    final hasNoActive = activeProfile.active == null && activeProfile.profiles.isNotEmpty;

    if (!hasNoActive && !activeProfile.requiresSelectionOnOpen(settingsService)) return;

    await pushProfileSelection();
  } finally {
    releasePrompt();
  }
}

class MainScreen extends StatefulWidget {
  final bool isOfflineMode;

  /// When `true`, the previous screen (typically [SetupScreen]) already
  /// resolved the launch profile prompt — skip the postFrame prompt that
  /// would otherwise re-fire it.
  final bool initialPromptHandled;

  const MainScreen({super.key, this.isOfflineMode = false, this.initialPromptHandled = false});

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen>
    with RouteAware, WindowListener, WidgetsBindingObserver, MountedSetStateMixin {
  NavigationTabId _currentTab = NavigationTabId.discover;
  int _navigationGeneration = 0;
  String? _selectedLibraryGlobalKey;
  Future<void>? _desktopExitFuture;

  /// Whether the app is in offline mode (no server connection)
  bool _isOffline = false;

  /// Computed index — searches the same _getVisibleTabs() that _buildScreens iterates,
  /// so _screens[_currentIndex] is always the widget for _currentTab.
  int get _currentIndex {
    final tabs = _getVisibleTabs(_isOffline);
    final idx = tabs.indexWhere((t) => t.id == _currentTab);
    return (idx >= 0 ? idx : 0).clamp(0, _screens.length - 1);
  }

  /// Last selected online tab (restored when coming back online after an offline fallback)
  NavigationTabId? _lastOnlineTabId;

  /// A preferred startup section (Live TV or Explore) that wasn't visible yet
  /// at cold start because servers bind and catalog sources hydrate
  /// asynchronously. Applied once it becomes available (see
  /// [_applyPendingStartupTab]); cleared on any explicit selection.
  NavigationTabId? _pendingStartupTab;

  /// Whether we auto-switched to Downloads because the previous tab was unavailable offline
  bool _autoSwitchedToDownloads = false;

  OfflineModeProvider? _offlineModeProvider;
  MultiServerProvider? _multiServerProvider;
  CatalogSourcesProvider? _catalogSourcesProvider;
  ValueListenable<bool>? _showExploreTabListenable;
  RouteObserver<PageRoute<dynamic>>? _profileRouteObserver;
  SpotlightController? _spotlightController;
  bool _lastHasLiveTv = false;
  bool _lastHasExplore = false;

  /// Whether a reconnection attempt is in progress
  bool _isReconnecting = false;

  /// Startup routed here explicitly offline. Keep the offline shell until a
  /// visible server actually connects; provider warmup can be optimistic when
  /// failed Plex servers have no live client yet.
  bool _offlineUntilConnected = false;

  /// Prevents double-pushing the profile selection screen
  bool _isShowingProfileSelection = false;

  /// Latches a genuine backgrounding so "ask for a profile on open" fires
  /// exactly once on the next resume, while transient focus losses
  /// (`inactive`, e.g. the Fire TV Alexa overlay) never prompt.
  final _profileSelectionResumeGate = ProfileSelectionResumeGate();

  /// Latches a genuine backgrounding and, on resume, reports whether the app
  /// was gone long enough that the content tabs should refetch (#2043).
  final _contentRefreshResumeGate = ContentRefreshResumeGate();

  late List<Widget> _screens;

  /// Tabs selected at least once in the current MainScreen lifetime. Unvisited
  /// slots stay as zero-size placeholders; selected tabs remain in the
  /// IndexedStack so their scroll, focus, and screen state are retained.
  final Set<NavigationTabId> _mountedTabs = {};

  /// One [GlobalKey] per tab, so a tab's live [State] can be reached from
  /// anywhere in this class via [_onScreen]. Deliberately untyped: every
  /// consumer discards the concrete `State<X>` type and pattern-matches on a
  /// capability mixin (Refreshable, FocusableTab, …) instead.
  final Map<NavigationTabId, GlobalKey> _screenKeys = {for (final id in NavigationTabId.values) id: GlobalKey()};
  bool _utilityPanelOpen = false;

  /// Measures the mobile navigation area (bottom bar or landscape rail) for
  /// the music mini-player.
  final GlobalKey _navBarKey = GlobalKey();
  MiniPlayerInsetController? _miniPlayerInsets;

  final FocusScopeNode _contentFocusScope = FocusScopeNode(debugLabel: 'Content');
  bool _isOverlaySheetOpen = false;

  /// The binder is now owned by a top-level [Provider] (see main.dart) so
  /// the splash can await its first settle before navigating here. We just
  /// observe its [ActiveProfileProvider.isBinding] state for the once-only
  /// priming below.
  PlexHomeService? _plexHomeService;
  ActiveProfileProvider? _activeProfileForListener;
  String? _lastSeenProfileId;
  // Tracks ActiveProfileProvider.isBinding from the previous notification
  // so we can detect a binding-just-settled transition for the *same*
  // active profile id (e.g. after a borrow/remove rebind).
  bool _wasBindingPrev = false;
  bool _hadProfiles = false;

  /// Subscription to MultiServerManager status changes. Held for the
  /// MainScreen lifetime (cancelled in dispose) so queued downloads resume
  /// whenever a server comes online — first connect after launch or a later
  /// reconnect.
  StreamSubscription<Map<String, bool>>? _serverStatusSub;

  /// Online-server snapshot covered by the last queued-download resume. A
  /// server missing from the latest snapshot drops out of the set, so a
  /// disconnect/reconnect surfaces it as newly online again and triggers a
  /// fresh resume for rows the queue drain skipped while it was away.
  final Set<String> _resumeCoveredServerIds = {};

  /// Listener that fires when [ActiveProfileBinder] settles (Plex *and*
  /// Jellyfin both bound). Drives the once-per-launch priming of
  /// LibrariesProvider + watch sync + tab fullRefresh.
  VoidCallback? _bindingSettleListener;
  bool _startupServicesPrimed = false;
  Timer? _startupSettleTimeout;

  /// Hard ceiling on how long we wait for [ActiveProfileBinder] to settle
  /// before priming libraries, watch sync, and downloads anyway.
  static const _startupSettleFallback = Duration(seconds: 15);
  static const _backExitWindow = Duration(seconds: 3);
  DateTime? _lastBackPressAt;

  @override
  void initState() {
    super.initState();
    _isOffline = widget.isOfflineMode;
    _offlineUntilConnected = widget.isOfflineMode;

    WidgetsBinding.instance.addObserver(this);

    if (PlatformDetector.isDesktopOS()) {
      windowManager.addListener(this);
      windowManager.setPreventClose(true);
    }

    // Synchronize _lastHasLiveTv with provider before building screens
    // so _buildScreens and _hasLiveTv getter agree from the start.
    try {
      _lastHasLiveTv = context.read<MultiServerProvider>().hasLiveTv;
    } catch (_) {
      _lastHasLiveTv = false;
    }
    try {
      _lastHasExplore = context.read<CatalogSourcesProvider>().hasAnySource && _showExploreTabSetting;
    } catch (_) {
      _lastHasExplore = false;
    }
    // Re-evaluate Explore tab visibility when the appearance toggle flips
    // mid-session; the catalog-sources listener covers source changes.
    _showExploreTabListenable = SettingsService.instanceOrNull?.listenable(SettingsService.showExploreTab);
    _showExploreTabListenable?.addListener(_handleCatalogSourcesChanged);
    _currentTab = _defaultTabForMode(_isOffline);
    _lastOnlineTabId = _isOffline ? null : NavigationTabId.discover;
    _autoSwitchedToDownloads = _isOffline && _currentTab == NavigationTabId.downloads;
    // If the preferred startup section isn't visible yet (e.g. Live TV before
    // servers finish binding), remember it and switch once it becomes available.
    final preferredStartup = SettingsService.instanceOrNull?.read(SettingsService.startupSection);
    _pendingStartupTab = (!_isOffline && preferredStartup != null && preferredStartup != _currentTab)
        ? preferredStartup
        : null;
    _mountedTabs.add(_currentTab);
    _screens = _buildScreens(_isOffline);

    // Warm the TV keyboard's text-layout caches off the first real open
    // (measured ~315ms first-open frame on low-end boxes, mostly cold font
    // shaping). Delayed past the startup burst; no-op off TV.
    if (PlatformDetector.isTV()) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        Future.delayed(const Duration(seconds: 3), () {
          if (mounted) warmUpTvVirtualKeyboardText(context);
        });
      });
    }

    // Set up Watch Together callbacks immediately (must be synchronous to catch early messages)
    if (!_isOffline) {
      _setupWatchTogetherCallback();
    }

    // Wire profile binder + tracker bootstrap (skip in offline mode)
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;

      final activeProfile = context.read<ActiveProfileProvider>();
      _activeProfileForListener = activeProfile;
      _lastSeenProfileId = activeProfile.activeId;
      _hadProfiles = activeProfile.profiles.isNotEmpty;
      activeProfile.addListener(_onActiveProfileChanged);
      _plexHomeService = context.read<PlexHomeService>();
      if (!_isOffline) unawaited(_plexHomeService!.start());
      final manager = context.read<MultiServerProvider>().serverManager;
      final binder = context.read<ActiveProfileBinder>();
      binder.start();
      _runStartupOnFirstOnlineServer(manager);

      if (!_isOffline) {
        await context.read<AccountPreferencesController>().ensureActiveLoaded();
        if (!mounted) return;

        // Ensure first login (or any unset profile state) requires explicit selection.
        await _promptForInitialProfileSelection();
        if (!mounted) return;

        // Auto-start companion remote server once the active profile is known.
        if (_companionRemoteSetup) {
          unawaited(_autoStartCompanionRemoteServer());
        }
      }

      // Links act once the profile is settled and its preferences are loaded.
      _attachDeepLinks();

      // Focus content initially (replaces autofocus which caused focus stealing issues)
      // Skip if profile selection is on top — it manages its own focus.
      if (!_isShowingProfileSelection) {
        CoveredRouteFocusBoundary.requestInitialFocus(context, _contentFocusScope);
      }

      _updateTvosMenuPassthrough();

      // Check for updates on startup
      unawaited(_checkForUpdatesOnStartup());
    });
  }

  /// Run startup tasks that depend on having at least one online server:
  /// initialize and load the libraries provider, kick off the initial
  /// watch-state sync, and resume any queued downloads.
  void _runStartupOnFirstOnlineServer(MultiServerManager manager) {
    if (_isOffline) return;

    final activeProfile = context.read<ActiveProfileProvider>();

    void primeServicesOnBindingSettle({bool fromTimeout = false}) {
      if (_startupServicesPrimed || !mounted) return;
      if (activeProfile.isBinding && !fromTimeout) return;
      if (fromTimeout) {
        appLogger.w(
          'ActiveProfileBinder still binding after ${_startupSettleFallback.inSeconds}s '
          '— priming services anyway; the settle will prime again.',
        );
      }
      _startupServicesPrimed = !activeProfile.isBinding;
      _startupSettleTimeout?.cancel();
      _startupSettleTimeout = null;

      unawaited(_primeOnlineServices(manager));
    }

    void tryDownloadResume() {
      final onlineClients = manager.onlineClients;
      _resumeQueuedDownloadsForServers(onlineClients.keys.toSet(), onlineClients.values.firstOrNull);
    }

    _bindingSettleListener = () => primeServicesOnBindingSettle();
    activeProfile.addListener(_bindingSettleListener!);

    _startupSettleTimeout?.cancel();
    _startupSettleTimeout = Timer(_startupSettleFallback, () {
      primeServicesOnBindingSettle(fromTimeout: true);
    });

    primeServicesOnBindingSettle();
    tryDownloadResume();

    _serverStatusSub = manager.statusStream.listen((_) => tryDownloadResume());
  }

  /// Shared online-entry hook for cold startup and reconnect-from-offline.
  Future<void> _primeOnlineServices(MultiServerManager manager) async {
    if (manager.onlineServerIds.isNotEmpty) {
      if (!mounted) return;
      final mp = context.read<MultiServerProvider>();
      if (mp.hasConnectedServers) {
        final lp = context.read<LibrariesProvider>();
        lp.initialize(mp.aggregationService);
        await lp.loadLibraries();
        if (!mounted) return;
        context.read<OfflineWatchSyncService>().onServersConnected();
        unawaited(context.read<DownloadProvider>().refreshMetadataFromCache());
        _resumeQueuedDownloadsForServers(
          mp.onlineServerIds.toSet(),
          mp.onlineServerIds.map((id) => mp.getClientForServer(ServerId(id))).nonNulls.firstOrNull,
        );
      }
    }

    if (!mounted) return;
    _primeContentTabs();
  }

  void _resumeQueuedDownloadsForServers(Set<String> onlineServerIds, MediaServerClient? onlineClient) {
    final newlyOnline = onlineServerIds.difference(_resumeCoveredServerIds);
    if (!mounted || newlyOnline.isEmpty || onlineClient == null) {
      _resumeCoveredServerIds.retainAll(onlineServerIds);
      return;
    }
    _resumeCoveredServerIds
      ..clear()
      ..addAll(onlineServerIds);
    final downloadProvider = context.read<DownloadProvider>();
    final serverManager = context.read<MultiServerProvider>().serverManager;
    unawaited(
      downloadProvider.ensureInitialized().then((_) {
        if (!mounted) return;
        downloadProvider.resumeQueuedDownloads(onlineClient);
        unawaited(downloadProvider.syncDownloadCollections(serverManager, newlyOnline));
      }),
    );
  }

  void _onActiveProfileChanged() {
    final activeProfile = _activeProfileForListener;
    if (activeProfile == null) return;
    final id = activeProfile.activeId;
    final isBindingNow = activeProfile.isBinding;
    final action = profileInvalidationAction(
      previousProfileId: _lastSeenProfileId,
      currentProfileId: id,
      wasBindingPreviously: _wasBindingPrev,
      isBindingNow: isBindingNow,
    );
    _lastSeenProfileId = id;
    _wasBindingPrev = isBindingNow;

    final hasProfilesNow = activeProfile.profiles.isNotEmpty;
    if (!_hadProfiles && hasProfilesNow && id == null && !_isShowingProfileSelection) {
      unawaited(_promptForInitialProfileSelection());
    }
    _hadProfiles = hasProfilesNow;

    if (action == ProfileInvalidationAction.invalidateNow) {
      unawaited(_invalidateAllScreens());
    }
  }

  Future<void> _promptForInitialProfileSelection() async {
    if (!mounted || _isShowingProfileSelection) return;
    if (widget.initialPromptHandled) return;

    final activeProfile = context.read<ActiveProfileProvider>();
    final connections = context.read<ConnectionRegistry>();
    await runInitialProfilePrompt(
      activeProfile: activeProfile,
      claimPrompt: () {
        if (_isShowingProfileSelection) return false;
        _isShowingProfileSelection = true;
        return true;
      },
      releasePrompt: () => _isShowingProfileSelection = false,
      isMounted: () => mounted,
      isOfflineMode: widget.isOfflineMode,
      hasConnections: () async => (await connections.list()).isNotEmpty,
      settleSession: () => settleSessionAfterRemoval(SessionTeardownScope.of(context)),
      pushProfileSelection: _pushProfileSelection,
    );
  }

  /// Push the picker in "must choose" mode, suppressing the tvOS menu-button
  /// passthrough for as long as it is up.
  Future<void> _pushProfileSelection() async {
    _isShowingProfileSelection = true;
    _setTvosMenuPassthrough(false);
    _detachDeepLinks();
    await Navigator.of(
      context,
      rootNavigator: true,
    ).push(MaterialPageRoute(builder: (context) => const ProfileSwitchScreen(requireSelection: true)));
    if (!mounted) return;
    _isShowingProfileSelection = false;
    _updateTvosMenuPassthrough();
    _attachDeepLinks();
  }

  DeepLinkSession? _deepLinkSession;

  /// Acts on `satra://` links for this profile session ([DeepLinkService]).
  void _attachDeepLinks() {
    if (!mounted || _isShowingProfileSelection) return;
    final session = _deepLinkSession ??= DeepLinkSession(
      profileId: context.read<ActiveProfileProvider>().activeId,
      launch: (link) async {
        if (mounted) await launchDeepLink(context, link, isOffline: _isOffline);
      },
    );
    DeepLinkService.instance.attach(session);
  }

  void _detachDeepLinks() {
    if (_deepLinkSession case final session?) DeepLinkService.instance.detach(session);
  }

  Future<void> _checkForUpdatesOnStartup() async {
    if (!mounted) return;

    final settingsService = await SettingsService.getInstance();
    if (!settingsService.read(SettingsService.autoCheckUpdatesOnStartup)) return;

    if (UpdateService.useNativeUpdater) {
      await UpdateService.checkForUpdatesNative(inBackground: true);
      return;
    }

    try {
      final updateInfo = await UpdateService.checkForUpdatesOnStartup();

      if (updateInfo != null && updateInfo['hasUpdate'] == true && mounted) {
        await _showUpdateDialog(updateInfo);
      }
    } catch (e) {
      appLogger.e('Error checking for updates', error: e);
    }
  }

  Future<void> _showUpdateDialog(Map<String, dynamic> updateInfo) => showUpdateAvailableDialog(
    context,
    updateInfo,
    title: t.update.available,
    dismissLabel: t.common.later,
    showSkipVersion: true,
  );

  /// Lets the Watch Together room open its file when no player is open.
  void _setupWatchTogetherCallback() {
    try {
      final watchTogether = context.read<WatchTogetherProvider>();
      _watchTogether = watchTogether;
      watchTogether.navigatorOpener = _navigateToWatchTogetherMedia;
    } catch (e) {
      appLogger.w('Could not set up Watch Together callback', error: e);
    }
  }

  /// Opens the Watch Together room's file in a new player. Returns whether
  /// navigation started.
  Future<bool> _navigateToWatchTogetherMedia(WatchCopy copy) async {
    if (!mounted) return false;
    try {
      return await navigateToWatchTogetherPlayback(context, copy);
    } catch (e) {
      appLogger.e('WatchTogether: Failed to navigate to media', error: e);
      return false;
    }
  }

  bool _companionRemoteSetup = false;
  WatchTogetherProvider? _watchTogether;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();

    final provider = context.read<OfflineModeProvider?>();
    if (provider != null && provider != _offlineModeProvider) {
      _offlineModeProvider?.removeListener(_handleOfflineStatusChanged);
      _offlineModeProvider = provider;
      _offlineModeProvider!.addListener(_handleOfflineStatusChanged);
      if (!widget.isOfflineMode && !_isOffline && provider.isOffline) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _handleOfflineStatusChanged();
        });
      }
    }

    final multiServer = context.read<MultiServerProvider>();
    if (multiServer != _multiServerProvider) {
      _multiServerProvider?.removeListener(_handleLiveTvChanged);
      _multiServerProvider = multiServer;
      _multiServerProvider!.addListener(_handleLiveTvChanged);
    }

    final catalogSources = context.read<CatalogSourcesProvider>();
    if (catalogSources != _catalogSourcesProvider) {
      _catalogSourcesProvider?.removeListener(_handleCatalogSourcesChanged);
      _catalogSourcesProvider = catalogSources;
      _catalogSourcesProvider!.addListener(_handleCatalogSourcesChanged);
    }

    final spotlightController = SpotlightScope.maybeOf(context);
    if (spotlightController != _spotlightController) {
      if (identical(_spotlightController?.callbacksProvider, _buildSpotlightCallbacks)) {
        _spotlightController?.callbacksProvider = null;
      }
      _spotlightController = spotlightController;
      _spotlightController?.callbacksProvider = _buildSpotlightCallbacks;
    }

    if (!_companionRemoteSetup && PlatformDetector.shouldActAsRemoteHost(context)) {
      _companionRemoteSetup = true;
      _setupCompanionRemote();
    }

    _miniPlayerInsets = context.read<MiniPlayerInsetController?>();

    final scopedRouteObserver = ProfileNavigationScope.of(context).routeObserver;
    if (scopedRouteObserver != _profileRouteObserver) {
      _profileRouteObserver?.unsubscribe(this);
      _profileRouteObserver = scopedRouteObserver;
      final route = ModalRoute.of(context);
      if (route is PageRoute<dynamic>) {
        scopedRouteObserver.subscribe(this, route);
      }
    }
  }

  SpotlightShellCallbacks _buildSpotlightCallbacks() {
    return SpotlightShellCallbacks(
      onSelectHome: () => _selectTab(NavigationTabId.discover),
      onSelectLibrary: _selectLibrary,
      onSelectExplore: _lastHasExplore ? () => _selectTab(NavigationTabId.explore) : null,
      onSelectLiveTv: _hasLiveTv ? () => _selectTab(NavigationTabId.liveTv) : null,
      onOpenDownloads: _openDownloads,
      onOpenSettings: _openSettings,
      onRefresh: _triggerCurrentScreenRefresh,
      onReconnect: _isOffline ? _triggerReconnect : null,
      isOffline: _isOffline,
      hasExplore: _lastHasExplore,
      hasLiveTv: _hasLiveTv,
    );
  }

  void _setupCompanionRemote() {
    final companionRemote = context.read<CompanionRemoteProvider>();
    companionRemote.onCommandReceived = (command) {
      if (mounted) {
        CompanionRemoteReceiver.instance.handleCommand(command, context);
      }
    };

    final receiver = CompanionRemoteReceiver.instance;
    receiver.navigationOwner = this;
    receiver.onTabNext = () {
      final tabs = _getVisibleTabs(_isOffline);
      final idx = tabs.indexWhere((t) => t.id == _currentTab);
      if (idx >= 0) _selectTab(tabs[(idx + 1) % tabs.length].id);
    };
    receiver.onTabPrevious = () {
      final tabs = _getVisibleTabs(_isOffline);
      final idx = tabs.indexWhere((t) => t.id == _currentTab);
      if (idx >= 0) _selectTab(tabs[(idx - 1 + tabs.length) % tabs.length].id);
    };
    receiver.onTabDiscover = () => _selectTab(NavigationTabId.discover);
    receiver.onTabLibraries = () => _selectTab(NavigationTabId.libraries);
    receiver.onTabSearch = () => _openSpotlight();
    receiver.onTabDownloads = _openDownloads;
    receiver.onTabSettings = _openSettings;
    receiver.onHome = () {
      final tabs = _getVisibleTabs(_isOffline);
      if (tabs.isEmpty) return;
      _selectTab(tabs.first.id);
    };
    receiver.onSearchAction = (query) {
      final trimmed = query?.trim();
      _openSpotlight(initialQuery: (trimmed != null && trimmed.isNotEmpty) ? trimmed : null);
    };
  }

  Future<void> _autoStartCompanionRemoteServer() async {
    try {
      final settings = await SettingsService.getInstance();
      if (!settings.read(SettingsService.enableCompanionRemoteServer)) return;
      if (!mounted) return;
      await startCompanionRemoteHost(context);
    } catch (e) {
      appLogger.e('CompanionRemote: Failed to auto-start server', error: e);
    }
  }

  @override
  void dispose() {
    if (_watchTogether?.navigatorOpener == _navigateToWatchTogetherMedia) _watchTogether?.navigatorOpener = null;
    if (identical(_spotlightController?.callbacksProvider, _buildSpotlightCallbacks)) {
      _spotlightController?.callbacksProvider = null;
    }
    WidgetsBinding.instance.removeObserver(this);
    _profileRouteObserver?.unsubscribe(this);
    if (PlatformDetector.isDesktopOS()) {
      windowManager.removeListener(this);
      windowManager.setPreventClose(false);
    }
    _offlineModeProvider?.removeListener(_handleOfflineStatusChanged);
    _multiServerProvider?.removeListener(_handleLiveTvChanged);
    _catalogSourcesProvider?.removeListener(_handleCatalogSourcesChanged);
    _showExploreTabListenable?.removeListener(_handleCatalogSourcesChanged);
    if (_bindingSettleListener != null) {
      _activeProfileForListener?.removeListener(_bindingSettleListener!);
    }
    _activeProfileForListener?.removeListener(_onActiveProfileChanged);
    _serverStatusSub?.cancel();
    _startupSettleTimeout?.cancel();
    _startupSettleTimeout = null;
    _contentFocusScope.dispose();
    _setTvosMenuPassthrough(false);

    if (_companionRemoteSetup) {
      final receiver = CompanionRemoteReceiver.instance;
      if (identical(receiver.navigationOwner, this)) {
        receiver.onTabNext = null;
        receiver.onTabPrevious = null;
        receiver.onTabDiscover = null;
        receiver.onTabLibraries = null;
        receiver.onTabSearch = null;
        receiver.onTabDownloads = null;
        receiver.onTabSettings = null;
        receiver.onHome = null;
        receiver.onSearchAction = null;
        receiver.navigationOwner = null;
      }
    }
    _detachDeepLinks();

    super.dispose();
  }

  @override
  void onWindowClose() => _requestDesktopExit();

  void _requestDesktopExit() {
    unawaited(
      _desktopExitFuture ??= _exitDesktopGracefully().whenComplete(() {
        _desktopExitFuture = null;
      }),
    );
  }

  Future<void> _exitDesktopGracefully() async {
    try {
      await AppExitService.requestGracefulExit();
    } catch (e, st) {
      appLogger.w('Graceful window close failed; destroying window', error: e, stackTrace: st);
      try {
        await windowManager.destroy().timeout(const Duration(seconds: 3));
      } catch (fallbackError, fallbackStack) {
        appLogger.e('Window destruction failed; forcing exit', error: fallbackError, stackTrace: fallbackStack);
        exit(1);
      }
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final resumedFromBackground = _profileSelectionResumeGate.consumePromptOn(
      state,
      sessionContinuesInPip: VideoPlayerScreenState.activeSessionContinuesInPip,
    );
    final refreshStaleContent = _contentRefreshResumeGate.consumeRefreshOn(state);
    if (resumedFromBackground && mounted) {
      unawaited(context.read<SeerrAccountProvider?>()?.refreshUser());
    }
    if (shouldShowProfileSelectionOnResume(
      resumedFromBackground: resumedFromBackground,
      isOffline: _isOffline,
      alreadyShowingProfileSelection: _isShowingProfileSelection,
      isMobilePlatform: Platform.isAndroid || Platform.isIOS,
      hasActiveCompanionRemoteSession: resumedFromBackground && context.read<CompanionRemoteProvider>().isInSession,
    )) {
      _showProfileSelectionOnResume();
    }
    if (refreshStaleContent) _refreshContentAfterStaleResume();
  }

  void _refreshContentAfterStaleResume() {
    if (_isOffline || !_startupServicesPrimed || !mounted) return;
    if (VideoPlayerScreenState.activeGlobalKey != null) return;
    if (!context.read<MultiServerProvider>().hasConnectedServers) return;
    appLogger.d('Refreshing content tabs after stale resume');
    unawaited(context.read<LibrariesProvider>().refresh());
    for (final tab in _contentTabs) {
      _onScreen<Refreshable>(tab, (screen) => screen.refresh());
    }
  }

  Future<void> _showProfileSelectionOnResume() async {
    final settingsService = await SettingsService.getInstance();
    if (!mounted) return;

    if (!context.read<ActiveProfileProvider>().requiresSelectionOnOpen(settingsService)) return;
    if (DeepLinkService.instance.selectsProfile) return;

    final selection = _pushProfileSelection();
    VideoPlayerScreenState.holdActivePlaybackUntil(selection);
    await selection;
  }

  /// Retain tab state while easing the newly selected page into view.
  Widget _buildTickerAwareStack() {
    return Column(
      children: [
        const AuthErrorBanner(),
        Expanded(
          child: BackdropTransitionScope(
            child: TabChipMotionScope(
              child: RetainedTabView(index: _currentIndex, children: _screens),
            ),
          ),
        ),
      ],
    );
  }

  List<Widget> _buildScreens(bool offline) {
    return [for (final tab in _getVisibleTabs(offline)) _buildScreenSlot(tab.id)];
  }

  Widget _buildScreenSlot(NavigationTabId tab) {
    if (!_mountedTabs.contains(tab)) return const SizedBox.shrink();

    return switch (tab) {
      NavigationTabId.discover => DiscoverScreen(key: _screenKeys[tab]),
      NavigationTabId.explore => ExploreScreen(key: _screenKeys[tab]),
      NavigationTabId.libraries => LibrariesScreen(
        key: _screenKeys[tab],
        onLibrarySelected: _handleLibrariesScreenSelected,
      ),
      NavigationTabId.liveTv => LiveTvScreen(key: _screenKeys[tab]),
      NavigationTabId.downloads => DownloadsScreen(key: _screenKeys[tab]),
      NavigationTabId.settings => SettingsScreen(key: _screenKeys[tab]),
    };
  }

  NavigationTabId _normalizeTabForMode(NavigationTabId currentTab, bool isOffline) {
    final tabs = _getVisibleTabs(isOffline);
    if (tabs.any((t) => t.id == currentTab)) return currentTab;
    return _defaultTabForMode(isOffline);
  }

  NavigationTabId _defaultTabForMode(bool isOffline) => NavigationTab.resolveDefaultTab(
    isOffline: isOffline,
    hasLiveTv: _hasLiveTv,
    hasExplore: _lastHasExplore,
    preferredStartup: SettingsService.instanceOrNull?.read(SettingsService.startupSection),
  );

  void _triggerReconnect() {
    if (_isReconnecting) return;
    setState(() => _isReconnecting = true);

    final multiServerProvider = context.read<MultiServerProvider>();
    final serverManager = multiServerProvider.serverManager;
    final activeProfile = context.read<ActiveProfileProvider>();
    final binder = context.read<ActiveProfileBinder>();
    unawaited(() async {
      try {
        binder.start();
        await serverManager.checkServerHealth();
        await serverManager.reconnectOfflineServers(forceRediscovery: true);
        if (!mounted) return;
        if (shouldRetryActiveProfileBindAfterReconnect(
          hasActiveProfile: activeProfile.active != null,
          hasVisibleConnectedServers: multiServerProvider.hasConnectedServers,
          hasManagerOnlineServers: serverManager.onlineServerIds.isNotEmpty,
          hasKnownOfflineServers: serverManager.offlineServerIds.isNotEmpty,
        )) {
          await binder.rebindActive();
        }
        if (!mounted) return;
        if (multiServerProvider.hasConnectedServers) {
          _offlineUntilConnected = false;
          _handleOfflineStatusChanged();
        } else {
          showMainSnackBar(t.errors.connectionFailed);
        }
      } finally {
        setStateIfMounted(() => _isReconnecting = false);
      }
    }());
  }

  void _handleTabAvailabilityChanged() {
    final previousTab = _currentTab;
    final nextTab = _normalizeTabForMode(previousTab, _isOffline);
    final restoreContentFocus = previousTab != nextTab && _contentFocusScope.hasFocus;
    setState(() {
      _currentTab = nextTab;
      _mountedTabs.add(nextTab);
      _screens = _buildScreens(_isOffline);
    });
    _updateTvosMenuPassthrough();

    if (restoreContentFocus) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || _currentTab != nextTab) return;
        _onScreen<FocusableTab>(nextTab, (screen) => screen.focusActiveTabIfReady());
      });
    }
  }

  void _handleLiveTvChanged() {
    final hasLiveTv = _multiServerProvider?.hasLiveTv ?? false;
    if (hasLiveTv == _lastHasLiveTv) return;
    _lastHasLiveTv = hasLiveTv;

    _handleTabAvailabilityChanged();
    _applyPendingStartupTab();
  }

  void _applyPendingStartupTab() {
    final pending = _pendingStartupTab;
    if (pending != null && _getVisibleTabs(_isOffline).any((t) => t.id == pending)) {
      _selectTab(pending);
    }
  }

  bool get _showExploreTabSetting => SettingsService.instanceOrNull?.read(SettingsService.showExploreTab) ?? true;

  void _handleCatalogSourcesChanged() {
    final hasExplore = (_catalogSourcesProvider?.hasAnySource ?? false) && _showExploreTabSetting;
    if (hasExplore == _lastHasExplore) return;
    _lastHasExplore = hasExplore;

    _handleTabAvailabilityChanged();
    _applyPendingStartupTab();
  }

  void _handleOfflineStatusChanged() {
    final hasVisibleConnectedServers = context.read<MultiServerProvider>().hasConnectedServers;
    if (hasVisibleConnectedServers) _offlineUntilConnected = false;
    final providerOffline = _offlineModeProvider?.isOffline ?? false;
    final newOffline = shouldRenderMainScreenOffline(
      providerOffline: providerOffline,
      startupOfflineUntilConnected: _offlineUntilConnected,
      hasVisibleConnectedServers: hasVisibleConnectedServers,
    );

    if (newOffline == _isOffline) return;

    final previousTab = _currentTab;
    final wasOffline = _isOffline;
    final restoreContentFocus = _contentFocusScope.hasFocus;
    setState(() {
      _isReconnecting = false;
      _isOffline = newOffline;
      _selectedLibraryGlobalKey = _isOffline ? null : _selectedLibraryGlobalKey;

      if (_isOffline) {
        if (!wasOffline) {
          _lastOnlineTabId = previousTab;
        }

        final normalizedTab = _normalizeTabForMode(_currentTab, _isOffline);
        _currentTab = normalizedTab;

        _autoSwitchedToDownloads =
            previousTab != NavigationTabId.downloads && normalizedTab == NavigationTabId.downloads;
      } else {
        if (_autoSwitchedToDownloads) {
          final restoredTab = _lastOnlineTabId ?? NavigationTabId.discover;
          _currentTab = _normalizeTabForMode(restoredTab, _isOffline);
        } else {
          _currentTab = _normalizeTabForMode(_currentTab, _isOffline);
        }
        _autoSwitchedToDownloads = false;
      }
      _mountedTabs.add(_currentTab);
      _screens = _buildScreens(_isOffline);
    });
    final currentTab = _currentTab;
    if (previousTab != currentTab && restoreContentFocus) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || _currentTab != currentTab) return;
        _onScreen<FocusableTab>(currentTab, (screen) => screen.focusActiveTabIfReady());
      });
    }
    _updateTvosMenuPassthrough();

    if (!_isOffline) {
      final plexHome = _plexHomeService ??= context.read<PlexHomeService>();
      unawaited(plexHome.start());
      unawaited(() async {
        final mp = context.read<MultiServerProvider>();
        final binder = context.read<ActiveProfileBinder>();
        binder.start();
        if (!mp.hasConnectedServers && context.read<ActiveProfileProvider>().active != null) {
          await binder.rebindActive();
          if (!mounted) return;
        }
        await context.read<AccountPreferencesController>().ensureActiveLoaded();
        if (!mounted) return;
        await _primeOnlineServices(mp.serverManager);
      }());
    }
  }

  void _handleOverlaySheetOpenChanged(bool open) {
    if (_isOverlaySheetOpen == open) return;
    _isOverlaySheetOpen = open;
    _updateTvosMenuPassthrough();
  }

  bool get _shouldPassTvosMenuToSystem {
    final tabs = _getVisibleTabs(_isOffline);
    return shouldPassTvosMenuToSystem(
      isAppleTV: PlatformDetector.isAppleTV(),
      isShowingProfileSelection: _isShowingProfileSelection,
      isOverlaySheetOpen: _isOverlaySheetOpen,
      isRouteCurrent: ModalRoute.of(context)?.isCurrent == true,
      hasVisibleTabs: tabs.isNotEmpty,
      isCurrentTabRoot: tabs.isNotEmpty && _currentTab == tabs.first.id,
    );
  }

  void _setTvosMenuPassthrough(bool enabled) {
    if (!PlatformDetector.isAppleTV()) return;
    unawaited(TvosSystemNavigationService.setMenuPassthroughEnabled(enabled));
  }

  void _updateTvosMenuPassthrough() {
    if (!mounted) return;
    _setTvosMenuPassthrough(_shouldPassTvosMenuToSystem);
  }

  bool _suppressBackAfterPop = false;

  KeyEventResult _handleMainBack() {
    final tabs = _getVisibleTabs(_isOffline);
    if (tabs.isEmpty) return KeyEventResult.handled;

    final homeTab = tabs.first.id;
    if (_currentTab != homeTab) {
      _selectTab(homeTab);
      _lastBackPressAt = null;
      return KeyEventResult.handled;
    }

    if (PlatformDetector.isAppleTV()) {
      _lastBackPressAt = null;
      appLogger.d(
        'tvOS Menu reached MainScreen at the home root: '
        'passthrough=$_shouldPassTvosMenuToSystem picker=$_isShowingProfileSelection '
        'focus=${FocusManager.instance.primaryFocus?.debugLabel}',
      );
      return KeyEventResult.handled;
    }

    final now = DateTime.now();
    final lastBackPressAt = _lastBackPressAt;
    if (lastBackPressAt != null && now.difference(lastBackPressAt) < _backExitWindow) {
      _lastBackPressAt = null;
      if (PlatformDetector.isDesktopOS()) {
        _requestDesktopExit();
      } else {
        unawaited(AppExitService.requestExit());
      }
      return KeyEventResult.handled;
    }

    _lastBackPressAt = now;
    showMainSnackBar(t.common.pressBackAgainToExit, duration: _backExitWindow);
    return KeyEventResult.handled;
  }

  KeyEventResult _handleMainBackKeyAction(KeyEvent event) {
    if (!event.logicalKey.isBackKey) return KeyEventResult.ignored;

    if (BackKeyUpSuppressor.consumeIfSuppressed(event)) {
      return KeyEventResult.handled;
    }

    if (PlatformDetector.isAppleTV() && event is KeyDownEvent) {
      final result = _handleMainBack();
      if (result == KeyEventResult.handled) {
        BackKeyCoordinator.markHandled();
      }
      return result;
    }
    if (PlatformDetector.isAppleTV() && event is KeyUpEvent) {
      return KeyEventResult.handled;
    }

    if (event is KeyUpEvent) {
      final result = _handleMainBack();
      if (result == KeyEventResult.handled) {
        BackKeyCoordinator.markHandled();
      }
      return result;
    }
    if (event is KeyDownEvent || event is KeyRepeatEvent) {
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  KeyEventResult _handleBackKey(KeyEvent event) {
    if (ModalRoute.of(context)?.isCurrent != true) {
      return KeyEventResult.ignored;
    }

    if (_suppressBackAfterPop && event.logicalKey.isBackKey) {
      if (event is KeyUpEvent) _suppressBackAfterPop = false;
      return KeyEventResult.handled;
    }

    return _handleMainBackKeyAction(event);
  }

  KeyEventResult _handleFullscreenShortcut(KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    if (event.logicalKey != LogicalKeyboardKey.f11) return KeyEventResult.ignored;
    if (!PlatformDetector.isDesktopOS()) return KeyEventResult.ignored;

    unawaited(FullscreenStateManager().toggleFullscreen());
    return KeyEventResult.handled;
  }

  KeyEventResult _handleDesktopRootEscape(KeyEvent event) {
    final tabs = _getVisibleTabs(_isOffline);
    final shouldHandle = shouldHandleDesktopRootEscape(
      isDesktop: PlatformDetector.isDesktopOS(),
      isTV: PlatformDetector.isTV(),
      isPhysicalKeyboardEvent: event.isPhysicalKeyboardEvent,
      logicalKey: event.logicalKey,
      isCurrentRoute: ModalRoute.of(context)?.isCurrent == true,
      isHomeTab: tabs.isNotEmpty && _currentTab == tabs.first.id,
    );
    if (!shouldHandle) return KeyEventResult.ignored;

    if (event is KeyUpEvent) {
      BackKeyCoordinator.markHandled();
      unawaited(FullscreenStateManager().exitFullscreenIfActive());
    }
    return event is KeyDownEvent || event is KeyRepeatEvent || event is KeyUpEvent
        ? KeyEventResult.handled
        : KeyEventResult.ignored;
  }

  KeyEventResult _handlePageRefreshShortcut(KeyEvent event) {
    return dispatchPageRefreshShortcut(event, _screenKeys[_currentTab]?.currentState);
  }

  KeyEventResult _handleSettingsShortcut(KeyEvent event) {
    if (!isSettingsShortcut(event)) return KeyEventResult.ignored;
    _openSettings();
    return KeyEventResult.handled;
  }

  @override
  void didPush() {
    if (_currentTab == NavigationTabId.discover) {
      _onDiscoverBecameVisible();
    }
  }

  @override
  void didPushNext() {
    _setTvosMenuPassthrough(false);
    _miniPlayerInsets?.setNavBarSuspended(true);
    if (_currentTab == NavigationTabId.discover) {
      _onScreen<TabVisibilityAware>(NavigationTabId.discover, (screen) => screen.onTabHidden());
    }
  }

  @override
  void didPopNext() {
    _suppressBackAfterPop = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _suppressBackAfterPop = false;
      });
    });

    _updateTvosMenuPassthrough();
    _miniPlayerInsets?.setNavBarSuspended(false);
    if (_currentTab == NavigationTabId.discover) {
      _onScreen<TabVisibilityAware>(NavigationTabId.discover, (screen) => screen.onTabShown());
      _onDiscoverBecameVisible();
    }
  }

  void _onDiscoverBecameVisible() {
    appLogger.d('Navigated to home');
    _onScreen<Refreshable>(NavigationTabId.discover, (screen) => screen.refresh());
  }

  Future<void> _invalidateAllScreens() async {
    appLogger.d('Invalidating screen data after profile switch');

    final multiServerProvider = context.read<MultiServerProvider>();
    final hiddenLibrariesProvider = context.read<HiddenLibrariesProvider>();
    final librariesProvider = context.read<LibrariesProvider>();
    final playbackStateProvider = context.read<PlaybackStateProvider>();

    try {
      await ApiCache.clearRegisteredVolatile();
    } catch (e, st) {
      appLogger.w('Failed to clear ApiCache on profile switch', error: e, stackTrace: st);
    }

    await hiddenLibrariesProvider.refresh();
    if (!mounted) return;

    librariesProvider.clear();

    if (multiServerProvider.serverManager.serverIds.isNotEmpty) {
      if (!mounted) return;
      context.read<OfflineWatchSyncService>().onServersConnected();
      unawaited(context.read<DownloadProvider>().refreshMetadataFromCache());
      librariesProvider.initialize(multiServerProvider.aggregationService);
      await librariesProvider.refresh();
    }

    playbackStateProvider.clearShuffle();

    _fullRefreshContentTabs();
  }

  void _selectTab(NavigationTabId tab) {
    if (!_getVisibleTabs(_isOffline).any((t) => t.id == tab)) return;

    final opensDesktopUtilityPanel =
        PlatformDetector.isDesktopOS() &&
        !PlatformDetector.isTVDevice() &&
        (tab == NavigationTabId.settings || (tab == NavigationTabId.downloads && !_isOffline));
    if (opensDesktopUtilityPanel) {
      if (_utilityPanelOpen) return;
      _utilityPanelOpen = true;
      final Widget panel = switch (tab) {
        NavigationTabId.downloads => const DownloadsScreen(),
        _ => const SettingsScreen(),
      };
      Navigator.of(context)
          .push(utilityPanelRoute(child: panel, name: tab == NavigationTabId.settings ? kSettingsRouteName : null))
          .whenComplete(() => _utilityPanelOpen = false);
      return;
    }

    final generation = ++_navigationGeneration;
    final previousTab = _currentTab;
    final wasMounted = _mountedTabs.contains(tab);
    setState(() {
      _currentTab = tab;
      if (!wasMounted) {
        _mountedTabs.add(tab);
        _screens = _buildScreens(_isOffline);
      }
      _pendingStartupTab = null;
      if (!_isOffline) {
        _lastOnlineTabId = tab;
      } else if (previousTab != tab) {
        _autoSwitchedToDownloads = false;
      }
    });
    _updateTvosMenuPassthrough();

    if (previousTab != tab) {
      _onScreen<TabVisibilityAware>(previousTab, (screen) => screen.onTabHidden());
    }

    void notifySelectedScreen() {
      if (previousTab != tab) {
        _onScreen<TabVisibilityAware>(tab, (screen) => screen.onTabShown());
        _onScreen<FocusableTab>(tab, (screen) => screen.focusActiveTabIfReady());
      }

      if (!_isOffline && tab == NavigationTabId.discover) {
        _onDiscoverBecameVisible();
      }
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || generation != _navigationGeneration || _currentTab != tab) return;
      notifySelectedScreen();
    });
  }

  void _selectLibrary(String libraryGlobalKey) {
    if (!_getVisibleTabs(_isOffline).any((tab) => tab.id == NavigationTabId.libraries)) return;

    _selectedLibraryGlobalKey = libraryGlobalKey;
    _selectTab(NavigationTabId.libraries);
    final generation = _navigationGeneration;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          generation != _navigationGeneration ||
          _currentTab != NavigationTabId.libraries ||
          _selectedLibraryGlobalKey != libraryGlobalKey) {
        return;
      }
      _onScreen<LibraryLoadable>(
        NavigationTabId.libraries,
        (screen) => screen.loadLibraryByKey(libraryGlobalKey, defaultToRecommended: true),
      );
      _onScreen<FocusableTab>(NavigationTabId.libraries, (screen) => screen.focusActiveTabIfReady());
    });
  }

  void _openDownloads() {
    if (PlatformDetector.shouldUseSideNavigation(context)) {
      _selectTab(NavigationTabId.downloads);
      return;
    }

    Navigator.push(context, MaterialPageRoute(builder: (_) => const DownloadsScreen()));
  }

  void _openSettings() {
    if (PlatformDetector.shouldUseSideNavigation(context)) {
      _selectTab(NavigationTabId.settings);
      return;
    }

    Navigator.push(context, buildSettingsRoute());
  }

  void _openSpotlight({String? initialQuery}) {
    SpotlightScope.open(context, initialQuery: initialQuery);
  }

  void _triggerCurrentScreenRefresh() {
    _onScreen<ManualRefreshable>(_currentTab, (screen) => screen.manualRefresh());
  }

  void _handleLibrariesScreenSelected(String libraryGlobalKey) {
    if (_selectedLibraryGlobalKey == libraryGlobalKey) return;
    setState(() => _selectedLibraryGlobalKey = libraryGlobalKey);
  }

  void _showLibraryQuickPicker(BuildContext context) {
    if (_isOffline) return;

    final controller = OverlaySheetController.of(context);
    final groupByServer = SettingsService.instanceOrNull?.read(SettingsService.groupLibrariesByServer) ?? false;

    controller
        .show<String>(
          showDragHandle: true,
          builder: (sheetContext) {
            return Consumer2<LibrariesProvider, HiddenLibrariesProvider>(
              builder: (context, librariesProvider, hiddenLibrariesProvider, _) {
                if (!hiddenLibrariesProvider.isInitialized) {
                  return LibraryQuickPickerSheet(
                    libraries: const [],
                    selectedLibraryKey: _selectedLibraryGlobalKey,
                    isLoading: true,
                    groupByServer: groupByServer,
                    emptyMessage: t.libraries.noLibrariesFound,
                    onSelected: (libraryGlobalKey) => controller.close(libraryGlobalKey),
                  );
                }

                final allLibraries = librariesProvider.libraries;
                final hiddenKeys = hiddenLibrariesProvider.hiddenLibraryKeys;
                final visibleLibraries = allLibraries
                    .where((library) => !hiddenKeys.contains(library.globalKey))
                    .toList();
                final emptyMessage = allLibraries.isEmpty
                    ? t.libraries.noLibrariesFound
                    : t.libraries.allLibrariesHidden;

                return LibraryQuickPickerSheet(
                  libraries: visibleLibraries,
                  selectedLibraryKey: _selectedLibraryGlobalKey,
                  isLoading: librariesProvider.isLoading,
                  groupByServer: groupByServer,
                  emptyMessage: emptyMessage,
                  onSelected: (libraryGlobalKey) => controller.close(libraryGlobalKey),
                );
              },
            );
          },
        )
        .then((libraryGlobalKey) {
          if (!mounted || libraryGlobalKey == null) return;
          _selectLibrary(libraryGlobalKey);
        });
  }

  bool get _hasLiveTv => _lastHasLiveTv;

  List<NavigationTab> _getVisibleTabs(bool isOffline) {
    return NavigationTab.getVisibleTabs(isOffline: isOffline, hasLiveTv: _hasLiveTv, hasExplore: _lastHasExplore);
  }

  List<NavigationTab> _getBottomNavigationTabs(BuildContext context) {
    return mainScreenBottomNavigationTabs(
      visibleTabs: _getVisibleTabs(_isOffline),
      isMobile: PlatformDetector.isMobile(context),
      isOffline: _isOffline,
      currentTab: _currentTab,
    );
  }

  void _onScreen<T>(NavigationTabId tab, void Function(T state) fn) {
    if (_screenKeys[tab]?.currentState case final T state) fn(state);
  }

  void _fullRefreshContentTabs() {
    for (final tab in _contentTabs) {
      _onScreen<FullRefreshable>(tab, (screen) => screen.fullRefresh());
    }
  }

  void _primeContentTabs() {
    for (final tab in _contentTabs) {
      _onScreen<FullRefreshable>(tab, (screen) => screen.primeRefresh());
    }
  }

  static const _contentTabs = [NavigationTabId.discover, NavigationTabId.libraries];

  Widget _buildBottomNavigationBar(BuildContext context, {required bool hideLabels}) {
    return MobileGlassTabBar(
      tabs: _getBottomNavigationTabs(context),
      selectedTab: _currentTab,
      hideLabels: hideLabels,
      onDestinationSelected: _selectTab,
      onActiveTabReselected: () => _onScreen<ScrollToTopable>(_currentTab, (screen) => screen.scrollToTop()),
      onLibrariesLongPress: () => _showLibraryQuickPicker(context),
      onSearchPressed: _isOffline ? null : () => _openSpotlight(),
    );
  }

  void _scheduleNavBarMeasure({required bool rail, bool reportsInset = true}) {
    final controller = _miniPlayerInsets;
    if (controller == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (!reportsInset) {
        controller.setNavInsets(bottom: 0, start: 0);
        return;
      }
      final box = _navBarKey.currentContext?.findRenderObject() as RenderBox?;
      if (box == null || !box.hasSize) return;
      controller.setNavInsets(bottom: rail ? 0 : box.size.height, start: rail ? box.size.width : 0);
    });
  }

  @override
  Widget build(BuildContext context) {
    final useSideNav = PlatformDetector.shouldUseSideNavigation(context);
    return CoveredRouteFocusBoundary(child: _buildContent(context, useSideNav));
  }

  Widget _buildContent(BuildContext context, bool useSideNav) {
    if (useSideNav) {
      return OverlaySheetHost(
        onOpenChanged: _handleOverlaySheetOpenChanged,
        canPop: false,
        child: Focus(
          onKeyEvent: (node, event) {
            final rootEscapeResult = _handleDesktopRootEscape(event);
            if (rootEscapeResult == KeyEventResult.handled) return rootEscapeResult;
            final fullscreenResult = _handleFullscreenShortcut(event);
            if (fullscreenResult == KeyEventResult.handled) return fullscreenResult;
            final refreshResult = _handlePageRefreshShortcut(event);
            if (refreshResult == KeyEventResult.handled) return refreshResult;
            final settingsResult = _handleSettingsShortcut(event);
            if (settingsResult == KeyEventResult.handled) return settingsResult;
            return _handleBackKey(event);
          },
          child: LayoutBuilder(
            builder: (context, constraints) {
              final viewportWidth = constraints.maxWidth;
              return MainScreenFocusScope(
                sideNavigationWidth: 0,
                reservedSideNavigationWidth: 0,
                foregroundLeft: 0,
                foregroundWidth: viewportWidth,
                viewportWidth: viewportWidth,
                selectLibrary: _selectLibrary,
                selectHome: () => _selectTab(NavigationTabId.discover),
                selectExplore: _lastHasExplore ? () => _selectTab(NavigationTabId.explore) : null,
                selectLiveTv: _hasLiveTv ? () => _selectTab(NavigationTabId.liveTv) : null,
                openDownloads: _openDownloads,
                openSettings: _openSettings,
                openSpotlight: _openSpotlight,
                reconnectOffline: _isOffline ? _triggerReconnect : null,
                child: ColoredBox(
                  color: Theme.of(context).scaffoldBackgroundColor,
                  child: FocusScope(
                    node: _contentFocusScope,
                    child: NotificationListener<ScrollNotification>(
                      onNotification: (notification) {
                        if (notification is ScrollStartNotification) {
                          unawaited(HoverPreviewController.instance.stop());
                        }
                        return false;
                      },
                      child: _buildTickerAwareStack(),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      );
    }

    return OverlaySheetHost(
      onOpenChanged: _handleOverlaySheetOpenChanged,
      canPop: false,
      onSystemBack: () {
        if (BackKeyCoordinator.consumeIfHandled()) return;
        _handleMainBack();
      },
      child: MainScreenFocusScope(
        selectHome: _isOffline ? null : () => _selectTab(NavigationTabId.discover),
        selectLibrary: _isOffline ? null : _selectLibrary,
        selectExplore: !_isOffline && _lastHasExplore ? () => _selectTab(NavigationTabId.explore) : null,
        selectLiveTv: !_isOffline && _hasLiveTv ? () => _selectTab(NavigationTabId.liveTv) : null,
        openDownloads: _openDownloads,
        openSettings: _openSettings,
        openSpotlight: _openSpotlight,
        child: ScaffoldMessenger(
          key: ProfileNavigationScope.of(context).mainScaffoldMessengerKey,
          child: switch (IphoneDuo.verticalBarEdgeOf(context)) {
            final VerticalBarEdge edge => _buildVerticalBarShell(context, edge),
            null when PlatformDetector.shouldUseLandscapeNavigationRail(context) => _buildLandscapeShell(context),
            null => _buildPortraitShell(context),
          },
        ),
      ),
    );
  }

  /// iPhone Duo with the system vertical bar: the tabs live in the bar.
  Widget _buildVerticalBarShell(BuildContext context, VerticalBarEdge edge) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: VerticalBarShell(
        edge: edge,
        railBuilder: (context, barWidth) => SettingValueBuilder<bool>(
          pref: SettingsService.showNavBarLabels,
          builder: (context, showNavBarLabels, _) {
            _scheduleNavBarMeasure(rail: true, reportsInset: false);
            return MobileNavigationRail(
              key: _navBarKey,
              tabs: _getBottomNavigationTabs(context),
              selectedTab: _currentTab,
              showLabels: showNavBarLabels,
              onDestinationSelected: _selectTab,
              onLibrariesLongPress: () => _showLibraryQuickPicker(context),
              onSearchPressed: _isOffline ? null : () => _openSpotlight(),
              isOffline: _isOffline,
              isReconnecting: _isReconnecting,
              onReconnect: _triggerReconnect,
              minWidth: barWidth,
              groupAlignment: 1,
              backgroundColor: Colors.transparent,
            );
          },
        ),
        child: _buildTickerAwareStack(),
      ),
    );
  }

  /// Mobile landscape: the bottom bar's destinations on a leading rail, the
  /// content beside it.
  Widget _buildLandscapeShell(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Builder(
        builder: (context) {
          final isRtl = Directionality.of(context) == TextDirection.rtl;
          return Row(
            children: [
              SettingValueBuilder<bool>(
                pref: SettingsService.showNavBarLabels,
                builder: (context, showNavBarLabels, _) {
                  _scheduleNavBarMeasure(rail: true);
                  return MobileNavigationRail(
                    key: _navBarKey,
                    tabs: _getBottomNavigationTabs(context),
                    selectedTab: _currentTab,
                    showLabels: showNavBarLabels,
                    onDestinationSelected: _selectTab,
                    onLibrariesLongPress: () => _showLibraryQuickPicker(context),
                    onSearchPressed: _isOffline ? null : () => _openSpotlight(),
                    isOffline: _isOffline,
                    isReconnecting: _isReconnecting,
                    onReconnect: _triggerReconnect,
                  );
                },
              ),
              Expanded(
                child: MediaQuery.removePadding(
                  context: context,
                  removeLeft: !isRtl,
                  removeRight: isRtl,
                  child: _buildTickerAwareStack(),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildPortraitShell(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      extendBody: true,
      body: _buildTickerAwareStack(),
      bottomNavigationBar: Column(
        key: _navBarKey,
        mainAxisSize: .min,
        children: [
          if (_isOffline)
            SafeArea(
              top: false,
              bottom: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: GlassSurface(
                  interactive: true,
                  borderRadius: const BorderRadius.all(Radius.circular(999)),
                  sigma: 24,
                  opacity: 0.58,
                  child: Material(
                    type: MaterialType.transparency,
                    child: InkWell(
                      borderRadius: const BorderRadius.all(Radius.circular(999)),
                      onTap: _isReconnecting ? null : _triggerReconnect,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          mainAxisAlignment: .center,
                          children: [
                            if (_isReconnecting)
                              SizedBox(
                                width: 15,
                                height: 15,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: Theme.of(context).colorScheme.primary,
                                ),
                              )
                            else
                              AppIcon(Symbols.wifi_rounded, size: 17, color: Theme.of(context).colorScheme.primary),
                            const SizedBox(width: 8),
                            Text(
                              t.common.reconnect,
                              style: TextStyle(
                                fontSize: 13.5,
                                fontWeight: .w600,
                                color: Theme.of(context).colorScheme.primary,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          SettingValueBuilder<bool>(
            pref: SettingsService.showNavBarLabels,
            builder: (context, showNavBarLabels, _) {
              final hideLabels = !showNavBarLabels;
              _scheduleNavBarMeasure(rail: false);
              return SafeArea(
                top: false,
                minimum: EdgeInsets.fromLTRB(
                  PlatformDetector.isHandheldIOS(context) ? 6 : 16,
                  0,
                  PlatformDetector.isHandheldIOS(context) ? 6 : 16,
                  10,
                ),
                child: _buildBottomNavigationBar(context, hideLabels: hideLabels),
              );
            },
          ),
        ],
      ),
    );
  }
}
