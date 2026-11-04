import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../connection/connection.dart';
import '../connection/connection_registry.dart';
import '../connection/plex_account_setup.dart';
import '../database/app_database.dart';
import '../mixins/controller_disposer_mixin.dart';
import '../profiles/active_profile_binder.dart';
import '../profiles/active_profile_provider.dart';
import '../profiles/plex_home_service.dart';
import '../profiles/profile.dart';
import '../profiles/profile_connection_registry.dart';
import '../profiles/profile_selection_policy.dart';
import '../services/plex_auth_service.dart';
import '../services/settings_service.dart';
import '../services/storage_service.dart';
import '../providers/account_preferences_controller.dart';
import '../i18n/strings.g.dart';
import '../utils/app_logger.dart';
import '../utils/dialogs.dart';
import '../utils/platform_detector.dart';
import '../focus/focusable_button.dart';
import '../focus/focusable_text_field.dart';
import '../focus/key_event_utils.dart';
import '../media/media_backend.dart';
import '../media/media_browser_dialect.dart';
import '../navigation/profile_session_screen.dart';
import '../utils/navigation_transitions.dart';
import '../widgets/backend_badge.dart';
import '../widgets/ambient_background.dart';
import '../widgets/glass_surface.dart';
import '../widgets/brand_mark.dart';
import '../widgets/dialog_action_button.dart';
import 'auth/plex_pin_auth_flow.dart';
import 'profile/profile_switch_screen.dart';
import 'settings/add_jellyfin_screen.dart';

class AuthScreen extends StatefulWidget {
  const AuthScreen({
    super.key,
    this.initialErrorMessage,
    this.initializeServices = true,
    this.databaseRecoveryRequired = false,
  });

  final String? initialErrorMessage;
  final bool initializeServices;
  final bool databaseRecoveryRequired;
  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen> {
  bool _isAuthenticating = false;
  String? _errorMessage;
  // Reuse a one-shot service for the debug-token verify path; the Plex
  // PIN/QR flow inside [PlexPinAuthFlow] owns its own service instance.
  PlexAuthService? _verifyOnlyService;
  Future<void>? _recoveryAcknowledgement;
  bool _recoveryAcknowledged = false;

  @override
  void initState() {
    super.initState();
    _errorMessage = widget.initialErrorMessage;
    // Debug-token verification only — release builds must not hold an idle
    // auth service (and its HTTP client) for a dialog that can't open.
    if (kDebugMode && widget.initializeServices) unawaited(_initVerifyService());
  }

  Future<void> _initVerifyService() async {
    final svc = await PlexAuthService.create();
    if (!mounted) {
      svc.dispose();
      return;
    }
    setState(() => _verifyOnlyService = svc);
  }

  @override
  void dispose() {
    _verifyOnlyService?.dispose();
    super.dispose();
  }

  /// Auto-select the active profile after sign-in *only* when there's a
  /// single, unprotected Plex Home user — there's no choice for the user to
  /// make. With multiple Home users (the "real" Home case) we leave the active
  /// id unset so [MainScreen] forces the picker before the binder runs,
  /// avoiding a surprise PIN prompt on whichever user we'd otherwise
  /// pre-select. A PIN-protected single user also goes through the picker —
  /// see [initialPlexHomeProfileFromCache].
  Future<void> _selectInitialProfile(
    PlexHomeService plexHome,
    ActiveProfileProvider activeProfiles,
    PlexAccountConnection accountConn,
  ) async {
    await activeProfiles.initialize();
    final profile = initialPlexHomeProfileFromCache(plexHome, accountConn);
    if (profile == null) {
      await activeProfiles.clearActiveProfile();
      return;
    }
    await activeProfiles.activate(profile);
  }

  Future<bool> _prepareDatabaseRecoveryForSignIn() async {
    if (!widget.databaseRecoveryRequired || _recoveryAcknowledged) return true;
    final acknowledgement = _recoveryAcknowledgement ??= context
        .read<AppDatabase>()
        .acknowledgeTvosDatabaseRecoveryRequired();
    try {
      await acknowledgement;
      _recoveryAcknowledged = true;
      if (mounted) setState(() => _errorMessage = null);
      return mounted;
    } catch (_) {
      _recoveryAcknowledgement = null;
      if (mounted) setState(() => _errorMessage = t.auth.localDataRecoveryRequired);
      return false;
    }
  }

  Future<void> _startPlexAfterRecovery(VoidCallback start) async {
    if (await _prepareDatabaseRecoveryForSignIn()) start();
  }

  /// Persist the new Plex account into the connection pipeline, resolve the
  /// initial active profile when possible, and navigate to the main screen.
  /// The top-level [ActiveProfileBinder] picks up the active profile id and
  /// connects servers via [MultiServerManager.refreshTokensForProfile].
  Future<void> _connectToAllServersAndNavigate(String plexToken) async {
    if (!await _prepareDatabaseRecoveryForSignIn()) return;
    if (!mounted) return;

    setState(() {
      _isAuthenticating = true;
      _errorMessage = null;
    });

    final connectionRegistry = context.read<ConnectionRegistry>();
    final profileConnections = context.read<ProfileConnectionRegistry>();
    final plexHome = context.read<PlexHomeService>();

    try {
      final storage = await StorageService.getInstance();
      final registration = await registerPlexAccountFromToken(
        token: plexToken,
        connections: connectionRegistry,
        profileConnections: profileConnections,
        storage: storage,
        plexHome: plexHome,
      );
      final accountConnection = registration.connection;

      if (accountConnection.servers.isEmpty) {
        // Nothing to roll back — the registered account row is exactly what
        // a retry will upsert over; wiping global credentials here would
        // also nuke the device identity and every server-endpoint cache.
        if (!mounted) return;
        setState(() {
          _isAuthenticating = false;
          _errorMessage = t.serverSelection.noServersFoundForAccount(
            username: registration.username,
            email: registration.email,
          );
        });
        return;
      }

      if (!registration.homeUsersFetched && plexHome.current[accountConnection.id] == null) {
        // A failed home-user fetch is NOT "multiple users, let them pick":
        // with no home users and no locals there is no profile to select,
        // and navigating lands in a dead session. Surface a retry instead.
        if (!mounted) return;
        setState(() {
          _isAuthenticating = false;
          _errorMessage = t.profiles.failedToLoadHomeUsers;
        });
        return;
      }

      if (!mounted) return;
      final activeProfiles = context.read<ActiveProfileProvider>();
      await _selectInitialProfile(plexHome, activeProfiles, accountConnection);

      if (!mounted) return;

      // Start the binder before the picker/MainScreen, mirroring the
      // cold-start SetupScreen ordering. On a fresh install SetupScreen
      // routes here without ever starting it, so without this the profile
      // activated above is bound only by MainScreen's post-frame start() —
      // Discover renders a "No servers available" flash in the gap, and the
      // picker's awaitBindingSettle resolves before anything is bound.
      context.read<ActiveProfileBinder>().start();

      final settings = await SettingsService.getInstance();
      if (!mounted) return;

      final promptHandled = shouldPromptForInitialProfileSelection(
        activeProfile: activeProfiles.active,
        hasProfiles: activeProfiles.profiles.isNotEmpty,
        accountHasHomeUsers: plexHome.current[accountConnection.id]?.isNotEmpty == true,
        requireProfileSelectionOnOpen: activeProfiles.requiresSelectionOnOpen(settings),
      );
      if (promptHandled) {
        final selected = await Navigator.of(
          context,
        ).push<bool>(MaterialPageRoute(builder: (_) => const ProfileSwitchScreen(requireSelection: true)));
        if (!mounted) return;
        if (selected != true || activeProfiles.active == null) {
          setState(() => _isAuthenticating = false);
          return;
        }
      }

      await context.read<AccountPreferencesController>().ensureActiveLoaded();

      if (!mounted) return;
      unawaited(
        Navigator.pushReplacement(context, fadeRoute(ProfileSessionScreen(initialPromptHandled: promptHandled))),
      );
    } catch (e) {
      appLogger.e('Failed to connect to servers', error: e);
      if (!mounted) return;
      setState(() {
        _isAuthenticating = false;
        _errorMessage = t.serverSelection.failedToLoadServers(error: e);
      });
    }
  }

  void _handleDebugTap() {
    if (!kDebugMode) return;
    _showDebugTokenDialog();
  }

  Future<void> _connectToMediaBrowser(MediaBrowserDialect dialect) async {
    if (!await _prepareDatabaseRecoveryForSignIn()) return;
    if (!mounted) return;
    final added = await Navigator.push<bool>(
      context,
      MaterialPageRoute(builder: (_) => AddJellyfinScreen(dialect: dialect)),
    );
    if (!mounted || added != true) return;
    // The connection persisted and the manager registered the client; move
    // straight to the main screen. [MainScreen] reads the active client
    // from the server provider, so no client argument is needed here.
    unawaited(Navigator.pushReplacement(context, fadeRoute(const ProfileSessionScreen())));
  }

  void _showDebugTokenDialog() {
    unawaited(
      showScopedDialog<void>(
        context: context,
        builder: (BuildContext context) {
          return _DebugTokenDialog(verifyService: _verifyOnlyService, onTokenAccepted: _connectToAllServersAndNavigate);
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      canRequestFocus: false,
      onKeyEvent: (_, event) => handleBackKeyNavigation(context, event),
      child: Scaffold(
        body: AmbientBackground(
          child: SafeArea(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final wide = constraints.maxWidth >= 900 && constraints.maxHeight >= 500;
                final compact = constraints.maxHeight < 620;
                final padding = EdgeInsets.all(compact ? 20 : 32);
                final brand = Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    BrandMark(
                      size: wide
                          ? 160
                          : compact
                          ? 80
                          : 128,
                    ),
                    SizedBox(height: compact ? 12 : 24),
                    Text(
                      t.app.title,
                      style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                        fontSize: wide ? 40 : 32,
                        fontWeight: FontWeight.w700,
                        letterSpacing: -1,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ],
                );
                final panel = Center(
                  child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 448), child: _buildAuthPanel()),
                );
                return SingleChildScrollView(
                  padding: padding,
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                      minHeight: (constraints.maxHeight - padding.vertical).clamp(0, double.infinity),
                    ),
                    child: Center(
                      child: SizedBox(
                        width: wide ? 1040 : 448,
                        child: wide
                            ? Row(
                                children: [
                                  Expanded(child: brand),
                                  const SizedBox(width: 64),
                                  Expanded(child: panel),
                                ],
                              )
                            : Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  brand,
                                  SizedBox(height: compact ? 24 : 40),
                                  panel,
                                ],
                              ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildAuthPanel() {
    final theme = Theme.of(context);
    final controls = ButtonStyle(
      minimumSize: const WidgetStatePropertyAll(Size(0, 54)),
      textStyle: WidgetStatePropertyAll(
        theme.textTheme.labelLarge?.copyWith(fontSize: 16, fontWeight: FontWeight.w600),
      ),
      shape: WidgetStatePropertyAll(RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(16)))),
      visualDensity: VisualDensity.standard,
    );
    return Theme(
      data: theme.copyWith(
        visualDensity: VisualDensity.standard,
        elevatedButtonTheme: ElevatedButtonThemeData(style: theme.elevatedButtonTheme.style?.merge(controls)),
        outlinedButtonTheme: OutlinedButtonThemeData(
          style: (theme.outlinedButtonTheme.style ?? const ButtonStyle()).merge(controls),
        ),
      ),
      child: GlassSurface(
        borderRadius: const BorderRadius.all(Radius.circular(28)),
        opacity: 0.62,
        child: Padding(padding: const EdgeInsets.all(28), child: _buildAuthBody()),
      ),
    );
  }

  Widget _buildAuthBody() {
    if (_isAuthenticating) {
      return Column(
        mainAxisSize: .min,
        children: [
          const Center(child: CircularProgressIndicator()),
          const SizedBox(height: 16),
          Text(
            t.auth.waitingForAuth,
            textAlign: TextAlign.center,
            style: Theme.of(
              context,
            ).textTheme.bodyMedium?.copyWith(color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.7)),
          ),
        ],
      );
    }
    return PlexPinAuthFlow(
      onTokenReceived: _connectToAllServersAndNavigate,
      autoStartQrOnTV: false,
      initializeService: widget.initializeServices,
      initialButtonsBuilder: _buildInitialButtons,
    );
  }

  Widget _buildInitialButtons(BuildContext context, VoidCallback startBrowser, VoidCallback startQr, bool busy) {
    final isTV = PlatformDetector.isTV();
    final isAppleTV = PlatformDetector.isAppleTV();
    void startBrowserAfterRecovery() => unawaited(_startPlexAfterRecovery(startBrowser));
    void startQrAfterRecovery() => unawaited(_startPlexAfterRecovery(startQr));
    const jellyfinDialect = MediaBrowserDialect.jellyfin;
    const embyDialect = MediaBrowserDialect.emby;
    void connectToJellyfin() => unawaited(_connectToMediaBrowser(jellyfinDialect));
    void connectToEmby() => unawaited(_connectToMediaBrowser(embyDialect));
    return Column(
      mainAxisSize: .min,
      crossAxisAlignment: .stretch,
      children: [
        if (isTV) ...[
          FocusableButton(
            autofocus: true,
            onPressed: busy ? null : startQrAfterRecovery,
            useBackgroundFocus: true,
            child: ElevatedButton(
              onPressed: busy ? null : startQrAfterRecovery,
              style: ElevatedButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 16)),
              child: Row(
                mainAxisAlignment: .center,
                mainAxisSize: .min,
                children: [
                  const BackendBadge(backend: MediaBackend.plex, size: 18),
                  const SizedBox(width: 8),
                  Text(t.auth.signInWithPlex),
                ],
              ),
            ),
          ),
          if (!isAppleTV) ...[
            const SizedBox(height: 12),
            FocusableButton(
              onPressed: busy ? null : startBrowserAfterRecovery,
              child: OutlinedButton(
                onPressed: busy ? null : startBrowserAfterRecovery,
                style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 16)),
                child: Text(t.auth.useBrowser),
              ),
            ),
          ],
        ] else ...[
          FocusableButton(
            onPressed: busy ? null : startBrowserAfterRecovery,
            useBackgroundFocus: true,
            child: ElevatedButton.icon(
              onPressed: busy ? null : startBrowserAfterRecovery,
              style: ElevatedButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 16)),
              icon: const BackendBadge(backend: MediaBackend.plex, size: 18),
              label: Text(t.auth.signInWithPlex),
            ),
          ),
          const SizedBox(height: 12),
          FocusableButton(
            onPressed: busy ? null : startQrAfterRecovery,
            child: OutlinedButton(
              onPressed: busy ? null : startQrAfterRecovery,
              style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 16)),
              child: Text(t.auth.showQRCode),
            ),
          ),
        ],
        const SizedBox(height: 24),
        Row(
          children: [
            Expanded(child: Divider(color: Theme.of(context).colorScheme.outlineVariant)),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Text(
                t.auth.or,
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6)),
              ),
            ),
            Expanded(child: Divider(color: Theme.of(context).colorScheme.outlineVariant)),
          ],
        ),
        const SizedBox(height: 12),
        FocusableButton(
          onPressed: connectToJellyfin,
          child: OutlinedButton.icon(
            onPressed: connectToJellyfin,
            style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 16)),
            icon: const BackendBadge(backend: MediaBackend.jellyfin, size: 18),
            label: Text(t.auth.connectToMediaBrowser(product: jellyfinDialect.productName)),
          ),
        ),
        const SizedBox(height: 12),
        FocusableButton(
          onPressed: connectToEmby,
          child: OutlinedButton.icon(
            onPressed: connectToEmby,
            style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 16)),
            icon: const BackendBadge(backend: MediaBackend.emby, size: 18),
            label: Text(t.auth.connectToMediaBrowser(product: embyDialect.productName)),
          ),
        ),
        if (kDebugMode) ...[
          const SizedBox(height: 12),
          FocusableButton(
            onPressed: _handleDebugTap,
            child: OutlinedButton(
              onPressed: _handleDebugTap,
              style: OutlinedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 12),
                side: BorderSide(color: Theme.of(context).colorScheme.outline.withValues(alpha: 0.5)),
              ),
              child: const Text('Debug: Enter Plex Token', style: TextStyle(fontSize: 12)),
            ),
          ),
        ],
        if (_errorMessage != null) ...[
          const SizedBox(height: 16),
          Text(
            _errorMessage!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
            textAlign: TextAlign.center,
          ),
        ],
      ],
    );
  }
}

@visibleForTesting
/// The profile to auto-select after sign-in: the account's only Plex Home
/// user, unless it is PIN-protected. A bare activation skips the PIN check
/// the picker performs, and the first bind of the session may reuse a cached
/// user token — after an in-app logout, the one the previous session minted —
/// so a protected user must be picked (and its PIN entered) explicitly.
Profile? initialPlexHomeProfileFromCache(PlexHomeService plexHome, PlexAccountConnection accountConn) {
  final users = plexHome.current[accountConn.id];
  if (users == null || users.length != 1 || users.single.protected) return null;
  return Profile.virtualPlexHome(connectionId: accountConn.id, homeUser: users.single);
}

@visibleForTesting
bool shouldPromptForInitialProfileSelection({
  required Profile? activeProfile,
  required bool hasProfiles,
  required bool accountHasHomeUsers,
  required bool requireProfileSelectionOnOpen,
}) {
  return requireProfileSelectionOnOpen || (activeProfile == null && (hasProfiles || accountHasHomeUsers));
}

/// Stateful so the [TextEditingController] is disposed when the dialog
/// closes — the previous inline `showDialog` builder created the
/// controller in a closure and leaked it on every dismissal.
class _DebugTokenDialog extends StatefulWidget {
  final PlexAuthService? verifyService;
  final Future<void> Function(String token) onTokenAccepted;

  const _DebugTokenDialog({required this.verifyService, required this.onTokenAccepted});

  @override
  State<_DebugTokenDialog> createState() => _DebugTokenDialogState();
}

class _DebugTokenDialogState extends State<_DebugTokenDialog> with ControllerDisposerMixin {
  late final TextEditingController _tokenController = createTextEditingController();
  String? _errorMessage;
  bool _busy = false;

  Future<void> _submit() async {
    final token = _tokenController.text.trim();
    if (token.isEmpty) {
      setState(() => _errorMessage = t.errors.pleaseEnterToken);
      return;
    }
    final svc = widget.verifyService;
    if (svc == null) {
      setState(() => _errorMessage = 'Auth service not ready');
      return;
    }
    final navigator = Navigator.of(context);
    setState(() {
      _errorMessage = null;
      _busy = true;
    });
    try {
      final isValid = await svc.verifyToken(token);
      if (!mounted) return;
      if (!isValid) {
        setState(() {
          _errorMessage = t.errors.invalidToken;
          _busy = false;
        });
        return;
      }
      navigator.pop();
      await widget.onTokenAccepted(token);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _errorMessage = t.errors.failedToVerifyToken(error: e);
        _busy = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Debug: Enter Plex Token'),
      content: Column(
        mainAxisSize: .min,
        children: [
          FocusableTextFormField(
            controller: _tokenController,
            decoration: InputDecoration(
              labelText: 'Plex Auth Token',
              hintText: 'Enter your Plex.tv token',
              errorText: _errorMessage,
              border: const OutlineInputBorder(),
            ),
            obscureText: true,
            maxLines: 1,
            textInputAction: TextInputAction.done,
            onFieldSubmitted: (_) => _busy ? null : _submit(),
          ),
        ],
      ),
      actions: [
        DialogActionButton(onPressed: _busy ? null : () => Navigator.of(context).pop(), label: t.common.cancel),
        DialogActionButton(onPressed: _busy ? null : _submit, label: t.auth.authenticate, isPrimary: true),
      ],
    );
  }
}
