import 'dart:io' show Platform;

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';

import 'package:satra/database/app_database.dart';
import 'package:satra/i18n/strings.g.dart';
import 'package:satra/mpv/mpv.dart';
import 'package:satra/providers/playback_state_provider.dart';
import 'package:satra/services/fullscreen_state_manager.dart';
import 'package:satra/services/pip_service.dart';
import 'package:satra/services/settings_service.dart';
import 'package:satra/services/video_volume_controller.dart';
import 'package:satra/utils/platform_detector.dart';
import 'package:satra/watch_together/providers/watch_together_provider.dart';
import 'package:satra/widgets/video_controls/player_chrome_controller.dart';
import 'package:satra/widgets/video_controls/video_control_button.dart';
import 'package:satra/widgets/video_controls/video_controls.dart';
import 'package:satra/widgets/video_controls/widgets/player_toast_indicator.dart';

import '../test_helpers/media_items.dart';
import '../test_helpers/player_streams.dart';
import '../test_helpers/prefs.dart';
import '../test_helpers/theme.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const windowChannel = MethodChannel('window_manager');
  const macWindowChannel = MethodChannel('com.satra/window_utils');
  const pipChannel = MethodChannel('com.satra/pip');

  late _PlayingPlayer player;
  late PlayerChromeController chrome;
  late PlayerToastController toast;
  late VideoVolumeController volume;
  late PlaybackStateProvider playbackState;
  late WatchTogetherProvider watchTogether;
  late AppDatabase database;
  late ValueNotifier<bool> hasFirstFrame;

  setUp(() async {
    LocaleSettings.setLocaleSync(AppLocale.en);
    await initializeDateFormatting('en');
    resetSharedPreferencesForTest();
    SettingsService.resetForTesting();
    final settings = await SettingsService.getInstance();

    TvDetectionService.debugReset();
    await TvDetectionService.getInstance(forceTv: true);
    PlatformDetector.debugSetIsDesktopOSOverride(true);
    PipService().isPipActive.value = false;

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(windowChannel, (
      call,
    ) async {
      return switch (call.method) {
        'isAlwaysOnTop' || 'isMaximized' => false,
        _ => null,
      };
    });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(macWindowChannel, (
      call,
    ) async {
      return call.method == 'isFullscreen' ? false : null;
    });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(pipChannel, (
      call,
    ) async {
      return switch (call.method) {
        'isSupported' => true,
        'enter' => {'success': true},
        _ => null,
      };
    });

    database = AppDatabase.forTesting(NativeDatabase.memory());
    player = _PlayingPlayer();
    chrome = PlayerChromeController(initiallyVisible: true);
    toast = PlayerToastController();
    volume = VideoVolumeController(player: player, settings: settings, initialVolume: 100);
    playbackState = PlaybackStateProvider();
    watchTogether = WatchTogetherProvider();
    hasFirstFrame = ValueNotifier<bool>(true);
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(windowChannel, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(macWindowChannel, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(pipChannel, null);
    PipService().isPipActive.value = false;
    FullscreenStateManager().setFullscreen(false);
    TvDetectionService.debugReset();
    PlatformDetector.debugSetIsDesktopOSOverride(null);
    hasFirstFrame.dispose();
    volume.dispose();
    playbackState.dispose();
    watchTogether.dispose();
    chrome.dispose();
    toast.dispose();
    await database.close();
  });

  test('supportsPictureInPicture stays enabled under forceTv on PiP-capable non-TV hardware', () {
    expect(PlatformDetector.isTV(), isTrue);
    expect(PlatformDetector.isTVDevice(), isFalse);
    final hostCapable = Platform.isAndroid || Platform.isIOS || Platform.isMacOS;
    expect(PlatformDetector.supportsPictureInPicture(), hostCapable);

    TvDetectionService.debugSetAppleTVOverride(true);
    expect(PlatformDetector.supportsPictureInPicture(), isFalse);
  });

  testWidgets(
    'desktop video controls display the native PiP button alongside player controls and reflect active PiP state',
    (tester) async {
      var pipToggleCount = 0;

      await tester.pumpWidget(
        MultiProvider(
          providers: [
            Provider<AppDatabase>.value(value: database),
            ChangeNotifierProvider<PlaybackStateProvider>.value(value: playbackState),
            ChangeNotifierProvider<WatchTogetherProvider>.value(value: watchTogether),
          ],
          child: MaterialApp(
            theme: ThemeData(platform: TargetPlatform.macOS, extensions: const [testMonoTokens]),
            home: Scaffold(
              body: SizedBox(
                width: 1280,
                height: 720,
                child: PlexVideoControls(
                  player: player,
                  volumeController: volume,
                  metadata: testMediaItem(id: 'macos-pip-button'),
                  toastController: toast,
                  chromeController: chrome,
                  hasFirstFrame: hasFirstFrame,
                  canNavigateMediaItems: false,
                  onTogglePIPMode: () {
                    pipToggleCount++;
                  },
                  onCycleBoxFitMode: () {},
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      chrome.cancelAutoHide();

      final pipButtonFinder = find.widgetWithIcon(VideoControlButton, Symbols.picture_in_picture_alt_rounded);
      expect(pipButtonFinder, findsOneWidget);
      expect(find.byTooltip(t.videoControls.pipButton), findsOneWidget);

      final initialButton = tester.widget<VideoControlButton>(pipButtonFinder);
      expect(initialButton.isActive, isFalse);
      expect(initialButton.checked, isFalse);

      await tester.tap(pipButtonFinder);
      await tester.pump();
      expect(pipToggleCount, 1);

      PipService().isPipActive.value = true;
      await tester.pump();

      final activeButton = tester.widget<VideoControlButton>(pipButtonFinder);
      expect(activeButton.isActive, isTrue);
      expect(activeButton.checked, isTrue);

      await tester.tap(pipButtonFinder);
      await tester.pump();
      expect(pipToggleCount, 2);

      await tester.pumpWidget(const SizedBox.shrink());
    },
    skip: !(Platform.isAndroid || Platform.isIOS || Platform.isMacOS),
  );
}

class _PlayingPlayer implements Player {
  @override
  String get playerType => 'mpv';

  @override
  PlayerState get state => PlayerState(
    playing: true,
    position: const Duration(minutes: 5),
    duration: const Duration(minutes: 45),
    seekable: true,
  );

  @override
  PlayerStreams get streams => emptyPlayerStreams();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
