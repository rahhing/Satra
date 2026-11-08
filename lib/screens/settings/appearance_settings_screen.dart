import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';

import '../../i18n/strings.g.dart';
import '../../providers/catalog_sources_provider.dart';
import '../../providers/theme_provider.dart';
import '../../services/settings_service.dart' hide ThemeMode;
import '../../focus/focusable_slider.dart';
import '../../services/device_performance.dart';
import '../../utils/platform_detector.dart';
import '../../utils/desktop_ui_scale.dart';
import '../../widgets/app_icon.dart';
import '../../widgets/overlay_sheet.dart';
import '../../widgets/setting_tile.dart';
import '../../widgets/settings_page.dart';
import '../../widgets/settings_builder.dart';
import '../../widgets/settings_section.dart';
import 'app_icon_setting.dart';
import 'settings_utils.dart';
import 'theme_settings_screen.dart';

class AppearanceSettingsScreen extends StatelessWidget {
  const AppearanceSettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    // Hosts the App icon picker and the Supporter sheet it opens. Content
    // builds below the host so they find it instead of falling back to a
    // modal route, which keeps its drag handle and gives no D-pad focus on TV.
    return OverlaySheetHost(canPop: true, child: Builder(builder: _buildContent));
  }

  Widget _buildContent(BuildContext context) {
    // Nullable watch: hosts without the profile session scope (tests) simply
    // never show the Explore toggle, mirroring the tab's own visibility.
    final hasExplore = context.watch<CatalogSourcesProvider?>()?.hasAnySource ?? false;
    return SettingsPage(
      title: Text(t.settings.appearance),
      children: [
        SettingsGroup(
          title: t.settings.display,
          children: [
            _themeSelector(),
            if (AppIconSetting.isShown(context)) const AppIconSetting(),
            if (PlatformDetector.isAutomotive()) _displayScaleSelector(),
            if (PlatformDetector.isDesktopOS() &&
                DesktopUiScale.isDesktopPlatform(Theme.of(context).platform) &&
                !PlatformDetector.isTV() &&
                !PlatformDetector.isAutomotive())
              _desktopScaleSelector(),
            if (Platform.isAndroid) _visualEffectsSelector(context),
          ],
        ),

        SettingsGroup(
          title: t.settings.libraryAndCards,
          children: [
            _viewModeSelector(),
            _densitySelector(),
            _gridSpacingSelector(),
            _cornerRadiusSelector(),
            _episodePosterModeSelector(),
            SettingSwitchTile(
              pref: SettingsService.showEpisodeNumberOnCards,
              icon: Symbols.tag_rounded,
              title: t.settings.showEpisodeNumberOnCards,
              subtitle: t.settings.showEpisodeNumberOnCardsDescription,
            ),
            if (!PlatformDetector.isTV())
              SettingSwitchTile(
                pref: SettingsService.showSeasonPostersOnTabs,
                icon: Symbols.image_rounded,
                title: t.settings.showSeasonPostersOnTabs,
                subtitle: t.settings.showSeasonPostersOnTabsDescription,
              ),
            SettingSwitchTile(
              pref: SettingsService.hideSpoilers,
              icon: Symbols.visibility_off_rounded,
              title: t.settings.hideSpoilers,
              subtitle: t.settings.hideSpoilersDescription,
            ),
            SettingSwitchTile(
              pref: SettingsService.showWatchedIndicators,
              icon: Symbols.check_circle_rounded,
              title: t.settings.showWatchedIndicators,
              subtitle: t.settings.showWatchedIndicatorsDescription,
            ),
            if (PlatformDetector.isTV())
              SettingSwitchTile(
                pref: SettingsService.tvFullCardLayout,
                icon: Symbols.image_rounded,
                title: t.settings.tvFullCardLayout,
                subtitle: t.settings.tvFullCardLayoutDescription,
              ),
            if (PlatformDetector.isTV())
              SettingSwitchTile(
                pref: SettingsService.tvCornerSpotlightBackdrop,
                icon: Symbols.picture_in_picture_alt_rounded,
                title: t.settings.tvCornerSpotlightBackdrop,
                subtitle: t.settings.tvCornerSpotlightBackdropDescription,
              ),
            if (PlatformDetector.isTV())
              SettingSwitchTile(
                pref: SettingsService.focusGlow,
                icon: Symbols.lightbulb_rounded,
                title: t.settings.focusGlow,
                subtitle: t.settings.focusGlowDescription,
              ),
          ],
        ),

        SettingsGroup(
          title: t.settings.homeScreen,
          children: [
            if (!PlatformDetector.isTV())
              SettingSwitchTile(
                pref: SettingsService.showHeroSection,
                icon: Symbols.featured_play_list_rounded,
                title: t.settings.showHeroSection,
                subtitle: t.settings.showHeroSectionDescription,
              ),
            _continueWatchingActionSelector(),
            _episodeActionSelector(),
            SettingSwitchTile(
              pref: SettingsService.useGlobalHubs,
              icon: Symbols.home_rounded,
              title: t.settings.useGlobalHubs,
              subtitle: t.settings.useGlobalHubsDescription,
            ),
            SettingSwitchTile(
              pref: SettingsService.showServerNameOnHubs,
              icon: Symbols.dns_rounded,
              title: t.settings.showServerNameOnHubs,
              subtitle: t.settings.showServerNameOnHubsDescription,
            ),
          ],
        ),

        SettingsGroup(
          title: t.settings.navigation,
          children: [
            if (PlatformDetector.shouldUseSideNavigation(context) && !PlatformDetector.isTVDevice())
              _dockSideSelector(),
            if (hasExplore)
              SettingSwitchTile(
                pref: SettingsService.showExploreTab,
                icon: Symbols.explore_rounded,
                title: t.settings.showExploreTab,
                subtitle: t.settings.showExploreTabDescription,
              ),
            if (PlatformDetector.shouldUseSideNavigation(context))
              SettingSwitchTile(
                pref: SettingsService.alwaysKeepSidebarOpen,
                icon: Symbols.dock_to_left_rounded,
                title: t.settings.alwaysKeepSidebarOpen,
                subtitle: t.settings.alwaysKeepSidebarOpenDescription,
              ),
            if (PlatformDetector.shouldUseSideNavigation(context))
              SettingSwitchTile(
                pref: SettingsService.groupLibrariesByServer,
                icon: Symbols.dns_rounded,
                title: t.settings.groupLibrariesByServer,
                subtitle: t.settings.groupLibrariesByServerDescription,
              ),
            if (!PlatformDetector.shouldUseSideNavigation(context))
              SettingSwitchTile(
                pref: SettingsService.showNavBarLabels,
                icon: Symbols.label_rounded,
                title: t.settings.showNavBarLabels,
                subtitle: t.settings.showNavBarLabelsDescription,
              ),
            SettingSwitchTile(
              pref: SettingsService.showUnwatchedCount,
              icon: Symbols.counter_1_rounded,
              title: t.settings.showUnwatchedCount,
              subtitle: t.settings.showUnwatchedCountDescription,
            ),
          ],
        ),

        SettingsGroup(
          title: t.settings.liveTv,
          children: [
            SettingSwitchTile(
              pref: SettingsService.liveTvDefaultFavorites,
              icon: Symbols.star_rounded,
              title: t.settings.liveTvDefaultFavorites,
              subtitle: t.settings.liveTvDefaultFavoritesDescription,
            ),
          ],
        ),
        const SizedBox(height: 24),
      ],
    );
  }

  // Opens the theme picker; the subtitle and icon follow the theme on screen,
  // which is the device's default theme while a stored Supporter theme is
  // locked.
  Widget _themeSelector() {
    return Consumer<ThemeProvider>(
      builder: (context, themeProvider, _) {
        return SettingNavigationTile(
          icon: themeProvider.themeModeIcon,
          title: t.settings.theme,
          subtitle: themeModeLabel(themeProvider.themeMode),
          destinationBuilder: (_) => const ThemeSettingsScreen(),
        );
      },
    );
  }

  // Same label-row-plus-control layout as SegmentedSetting so slider and
  // button-group tiles read as one family inside a SettingsGroup.
  Widget _densitySelector() {
    return SettingValueBuilder<int>(
      pref: SettingsService.libraryDensity,
      builder: (context, density, _) {
        final theme = Theme.of(context);
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Column(
            crossAxisAlignment: .start,
            children: [
              Row(
                children: [
                  const AppIcon(Symbols.grid_view_rounded, fill: 1),
                  const SizedBox(width: 16),
                  Text(t.settings.libraryDensity, style: settingsOptionTitleStyle(context)),
                ],
              ),
              const SizedBox(height: 12),
              FocusableSlider(
                value: density.toDouble(),
                min: 1,
                max: 5,
                divisions: 4,
                onChanged: (v) => SettingsService.instance.write(SettingsService.libraryDensity, v.round()),
              ),
              Row(
                mainAxisAlignment: .spaceBetween,
                children: [
                  Text(t.settings.compact, style: theme.textTheme.bodySmall),
                  Text(t.settings.comfortable, style: theme.textTheme.bodySmall),
                ],
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _displayScaleSelector() {
    return SettingValueBuilder<double>(
      pref: SettingsService.automotiveUiScale,
      builder: (context, scale, _) {
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Column(
            crossAxisAlignment: .start,
            children: [
              Row(
                children: [
                  const AppIcon(Symbols.format_size_rounded, fill: 1),
                  const SizedBox(width: 16),
                  Text(t.settings.displayScale, style: settingsOptionTitleStyle(context)),
                  const Spacer(),
                  Text('${scale.toStringAsFixed(2)}×', style: Theme.of(context).textTheme.bodyMedium),
                ],
              ),
              const SizedBox(height: 12),
              FocusableSlider(
                value: scale,
                min: AutomotiveUiScale.min,
                max: AutomotiveUiScale.max,
                divisions: 20,
                onChanged: (value) => SettingsService.instance.write(SettingsService.automotiveUiScale, value),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _desktopScaleSelector() => SettingSelectionTile<double>(
    pref: SettingsService.desktopUiScale,
    icon: Symbols.format_size_rounded,
    title: t.settings.displayScale,
    subtitleBuilder: (value) =>
        value == DesktopUiScale.automatic ? t.settings.desktopScaleAutomatic : '${(value * 100).round()}%',
    options: [
      for (final value in DesktopUiScale.options)
        DialogOption(
          value: value,
          title: value == DesktopUiScale.automatic ? t.settings.desktopScaleAutomatic : '${(value * 100).round()}%',
          subtitle: value == DesktopUiScale.automatic ? t.settings.desktopScaleDescription : null,
        ),
    ],
  );

  Widget _viewModeSelector() => SettingSegmentedTile<ViewMode>(
    pref: SettingsService.viewMode,
    icon: Symbols.view_list_rounded,
    title: t.settings.viewMode,
    segments: [
      ButtonSegment(value: ViewMode.grid, label: Text(t.settings.gridView)),
      ButtonSegment(value: ViewMode.list, label: Text(t.settings.listView)),
    ],
  );

  Widget _dockSideSelector() => SettingValueBuilder<DockSide>(
    pref: SettingsService.dockSide,
    builder: (context, side, _) => ListTile(
      leading: const AppIcon(Symbols.dock_to_left_rounded),
      title: const Text('Dock position'),
      trailing: DropdownButton<DockSide>(
        key: const ValueKey('dock_position'),
        value: side,
        underline: const SizedBox.shrink(),
        borderRadius: BorderRadius.circular(12),
        items: const [
          DropdownMenuItem(value: DockSide.left, child: Text('Left')),
          DropdownMenuItem(value: DockSide.right, child: Text('Right')),
        ],
        onChanged: (value) {
          if (value != null) SettingsService.instance.write(SettingsService.dockSide, value);
        },
      ),
    ),
  );

  Widget _cornerRadiusSelector() => SettingValueBuilder<double>(
    pref: SettingsService.pillCornerRadius,
    builder: (context, radius, _) => Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const AppIcon(Symbols.rounded_corner_rounded),
              const SizedBox(width: 16),
              Text('Corner rounding', style: settingsOptionTitleStyle(context)),
              const Spacer(),
              Text('${radius.round()}'),
            ],
          ),
          const SizedBox(height: 8),
          const Text('Shape cards, Continue Watching, the dock, and navigation pills.'),
          FocusableSlider(
            key: const ValueKey('pill_corner_radius'),
            value: radius,
            min: 0,
            max: 32,
            divisions: 32,
            onChanged: (value) => SettingsService.instance.write(SettingsService.pillCornerRadius, value),
          ),
          Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: const [Text('Square'), Text('Rounded')]),
        ],
      ),
    ),
  );

  Widget _gridSpacingSelector() => SettingSegmentedTile<GridSpacing>(
    pref: SettingsService.gridSpacing,
    icon: Symbols.padding_rounded,
    title: t.settings.gridSpacing,
    segments: [
      ButtonSegment(value: GridSpacing.tight, label: Text(t.settings.gridSpacingTight)),
      ButtonSegment(value: GridSpacing.normal, label: Text(t.settings.gridSpacingNormal)),
      ButtonSegment(value: GridSpacing.spacious, label: Text(t.settings.gridSpacingSpacious)),
    ],
  );

  Widget _episodePosterModeSelector() => SettingSegmentedTile<EpisodePosterMode>(
    pref: SettingsService.episodePosterMode,
    icon: Symbols.image_rounded,
    title: t.settings.episodePosterMode,
    segments: [
      ButtonSegment(value: EpisodePosterMode.seriesPoster, label: Text(t.settings.seriesPoster)),
      ButtonSegment(value: EpisodePosterMode.seasonPoster, label: Text(t.settings.seasonPoster)),
      ButtonSegment(value: EpisodePosterMode.episodeThumbnail, label: Text(t.settings.episodeThumbnail)),
    ],
  );

  Widget _continueWatchingActionSelector() => SettingSegmentedTile<ContinueWatchingAction>(
    pref: SettingsService.continueWatchingAction,
    icon: Symbols.play_circle_rounded,
    title: t.settings.continueWatchingAction,
    segments: [
      ButtonSegment(value: ContinueWatchingAction.play, label: Text(t.settings.continueWatchingPlay)),
      ButtonSegment(value: ContinueWatchingAction.details, label: Text(t.settings.continueWatchingDetails)),
    ],
  );

  Widget _episodeActionSelector() => SettingSegmentedTile<EpisodeAction>(
    pref: SettingsService.episodeAction,
    icon: Symbols.tv_rounded,
    title: t.settings.episodeAction,
    segments: [
      ButtonSegment(value: EpisodeAction.play, label: Text(t.settings.episodePlay)),
      ButtonSegment(value: EpisodeAction.details, label: Text(t.settings.episodeDetails)),
    ],
  );

  String _visualEffectsLabel(VisualEffectsSetting value) => switch (value) {
    VisualEffectsSetting.auto => t.settings.visualEffectsAuto,
    VisualEffectsSetting.full => t.settings.visualEffectsFull,
    VisualEffectsSetting.reduced => t.settings.visualEffectsReduced,
  };

  Widget _visualEffectsSelector(BuildContext context) => SettingSelectionTile<VisualEffectsSetting>(
    pref: SettingsService.visualEffects,
    icon: Symbols.animation_rounded,
    title: t.settings.visualEffects,
    subtitleBuilder: _visualEffectsLabel,
    options: [
      DialogOption(
        value: VisualEffectsSetting.auto,
        title: t.settings.visualEffectsAuto,
        subtitle: t.settings.visualEffectsAutoDescription,
      ),
      DialogOption(value: VisualEffectsSetting.full, title: t.settings.visualEffectsFull),
      DialogOption(
        value: VisualEffectsSetting.reduced,
        title: t.settings.visualEffectsReduced,
        subtitle: t.settings.visualEffectsReducedDescription,
      ),
    ],
  );
}
