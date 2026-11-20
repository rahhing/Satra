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
import '../../widgets/artwork_atmosphere.dart';
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
    final showHoverEffects = PlatformDetector.isDesktopOS() && !PlatformDetector.isTVDevice();
    final desktopBackdrop = ArtworkAtmosphereScope.supportsDesktopArtwork(context);
    return SettingsPage(
      title: Text(t.settings.appearance),
      children: [
        SettingValueBuilder<bool>(
          pref: SettingsService.liquidGlass,
          builder: (context, liquidGlass, _) => SettingsGroup(
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
              SettingSwitchTile(
                pref: SettingsService.liquidGlass,
                icon: Symbols.water_drop_rounded,
                title: t.settings.liquidGlass,
                subtitle: t.settings.liquidGlassDescription,
              ),
              if (liquidGlass)
                _liquidGlassOpacitySlider()
              else ...[
                _glassBlurAmountSlider(),
                _glassBackgroundBrightnessSlider(),
              ],
            ],
          ),
        ),

        if (desktopBackdrop || showHoverEffects || PlatformDetector.isTV())
          SettingsBuilder(
            prefs: const [SettingsService.useClassicMobileBackdrop, SettingsService.darkenMobileBackdrop],
            builder: (context) => SettingsGroup(
              title: t.settings.browseEffects,
              children: [
                if (desktopBackdrop)
                  ..._backdropControls(
                    desktop: true,
                    darken: context.settingsRead(SettingsService.darkenMobileBackdrop),
                    classic: context.settingsRead(SettingsService.useClassicMobileBackdrop),
                  ),
                if (showHoverEffects) ...[
                  SettingSwitchTile(
                    pref: SettingsService.cardHoverLift,
                    icon: Symbols.open_with_rounded,
                    title: t.settings.cardHoverLift,
                    subtitle: t.settings.cardHoverLiftDescription,
                  ),
                  _percentSliderTile(
                    sliderKey: const ValueKey('shelf_heading_hover_opacity'),
                    pref: SettingsService.shelfHeadingHoverOpacity,
                    icon: Symbols.title_rounded,
                    title: t.settings.shelfHeadingHoverOpacity,
                    description: t.settings.shelfHeadingHoverOpacityDescription,
                    min: 0.55,
                    max: 1.0,
                    divisions: 9,
                  ),
                ],
                if (PlatformDetector.isTV())
                  _percentSliderTile(
                    sliderKey: const ValueKey('spotlight_artwork_opacity'),
                    pref: SettingsService.spotlightArtworkOpacity,
                    icon: Symbols.brightness_6_rounded,
                    title: t.settings.spotlightArtworkOpacity,
                    description: t.settings.spotlightArtworkOpacityDescription,
                    min: 0.2,
                    max: 1.0,
                    divisions: 16,
                  ),
              ],
            ),
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

        SettingValueBuilder<bool>(
          pref: SettingsService.darkenMobileBackdrop,
          builder: (context, darkenMobileBackdrop, _) => SettingsGroup(
            title: t.settings.homeScreen,
            children: [
              if (!PlatformDetector.isTV())
                SettingSwitchTile(
                  pref: SettingsService.showHeroSection,
                  icon: Symbols.featured_play_list_rounded,
                  title: t.settings.showHeroSection,
                  subtitle: t.settings.showHeroSectionDescription,
                ),
              if (PlatformDetector.isMobile(context) && !PlatformDetector.isAutomotive())
                ..._backdropControls(desktop: false, darken: darkenMobileBackdrop, classic: false),
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
        ),

        SettingValueBuilder<bool>(
          pref: SettingsService.searchInTopBar,
          builder: (context, searchInTopBar, _) => SettingsGroup(
            title: t.settings.navigation,
            children: [
              if (hasExplore)
                SettingSwitchTile(
                  pref: SettingsService.showExploreTab,
                  icon: Symbols.explore_rounded,
                  title: t.settings.showExploreTab,
                  subtitle: t.settings.showExploreTabDescription,
                ),
              if (!PlatformDetector.shouldUseSideNavigation(context))
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
              if (!PlatformDetector.shouldUseSideNavigation(context)) ...[
                SettingSwitchTile(
                  pref: SettingsService.searchInTopBar,
                  icon: Symbols.search_rounded,
                  title: t.settings.searchInTopBar,
                  subtitle: t.settings.searchInTopBarDescription,
                ),
                if (!searchInTopBar)
                  SettingSwitchTile(
                    pref: SettingsService.separateBottomSearchButton,
                    icon: Symbols.dock_to_right_rounded,
                    title: t.settings.separateBottomSearchButton,
                    subtitle: t.settings.separateBottomSearchButtonDescription,
                  ),
              ],
              SettingSwitchTile(
                pref: SettingsService.showUnwatchedCount,
                icon: Symbols.counter_1_rounded,
                title: t.settings.showUnwatchedCount,
                subtitle: t.settings.showUnwatchedCountDescription,
              ),
            ],
          ),
        ),

        SettingsGroup(
          title: t.settings.liveTv,
          children: [
            if (PlatformDetector.isMobile(context) && !PlatformDetector.isAutomotive())
              SettingSwitchTile(
                pref: SettingsService.showMobileLiveTv,
                icon: Symbols.live_tv_rounded,
                title: t.settings.showMobileLiveTv,
                subtitle: t.settings.showMobileLiveTvDescription,
              ),
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
                key: const ValueKey('library_density'),
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
              Text(t.settings.cornerRounding, style: settingsOptionTitleStyle(context)),
              const Spacer(),
              Text('${radius.round()}'),
            ],
          ),
          const SizedBox(height: 8),
          Text(t.settings.cornerRoundingDescription),
          FocusableSlider(
            key: const ValueKey('pill_corner_radius'),
            value: radius,
            min: 0,
            max: 32,
            divisions: 32,
            onChanged: (value) => SettingsService.instance.write(SettingsService.pillCornerRadius, value),
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [Text(t.settings.cornerSquare), Text(t.settings.cornerRounded)],
          ),
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

  Widget _liquidGlassOpacitySlider() => _percentSliderTile(
    sliderKey: const ValueKey('liquid_glass_opacity'),
    pref: SettingsService.liquidGlassOpacity,
    icon: Symbols.opacity_rounded,
    title: t.settings.liquidGlassOpacity,
    description: t.settings.liquidGlassOpacityDescription,
    min: 0.0,
    max: 1.0,
    divisions: 20,
  );

  Widget _glassBlurAmountSlider() => _percentSliderTile(
    sliderKey: const ValueKey('glass_blur_amount'),
    pref: SettingsService.glassBlurAmount,
    icon: Symbols.blur_on_rounded,
    title: t.settings.glassBlurAmount,
    description: t.settings.glassBlurAmountDescription,
    min: 0.0,
    max: 2.0,
    divisions: 40,
  );

  Widget _glassBackgroundBrightnessSlider() => _percentSliderTile(
    sliderKey: const ValueKey('glass_background_brightness'),
    pref: SettingsService.glassBackgroundBrightness,
    icon: Symbols.brightness_6_rounded,
    title: t.settings.glassBackgroundBrightness,
    description: t.settings.glassBackgroundBrightnessDescription,
    min: 0.0,
    max: 2.0,
    divisions: 40,
  );

  List<Widget> _backdropControls({required bool desktop, required bool darken, required bool classic}) => [
    if (!classic) ...[
      SettingSwitchTile(
        pref: SettingsService.darkenMobileBackdrop,
        icon: Symbols.contrast_rounded,
        title: t.settings.darkenMobileBackdrop,
        subtitle: desktop ? t.settings.darkenDesktopBackdropDescription : t.settings.darkenMobileBackdropDescription,
      ),
      if (darken)
        _percentSliderTile(
          sliderKey: const ValueKey('mobile_backdrop_darkness'),
          pref: SettingsService.mobileBackdropDarkness,
          icon: Symbols.brightness_4_rounded,
          title: t.settings.darkenMobileBackdropAmount,
          description: t.settings.darkenMobileBackdropAmountDescription,
          min: 0.0,
          max: 1.0,
          divisions: 20,
        ),
    ],
    SettingSwitchTile(
      pref: SettingsService.useClassicMobileBackdrop,
      icon: Symbols.wallpaper_rounded,
      title: t.settings.useClassicMobileBackdrop,
      subtitle: desktop
          ? t.settings.useClassicDesktopBackdropDescription
          : t.settings.useClassicMobileBackdropDescription,
    ),
  ];

  Widget _percentSliderTile({
    required Key sliderKey,
    required Pref<double> pref,
    required IconData icon,
    required String title,
    required String description,
    required double min,
    required double max,
    required int divisions,
  }) => SettingValueBuilder<double>(
    pref: pref,
    builder: (context, rawValue, _) {
      final value = rawValue.clamp(min, max);
      final theme = Theme.of(context);
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                AppIcon(icon, fill: 1),
                const SizedBox(width: 16),
                Expanded(child: Text(title, style: settingsOptionTitleStyle(context))),
                Text('${(value * 100).round()}%', style: theme.textTheme.bodyMedium),
              ],
            ),
            const SizedBox(height: 4),
            Text(description, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
            const SizedBox(height: 6),
            FocusableSlider(
              key: sliderKey,
              value: value,
              min: min,
              max: max,
              divisions: divisions,
              onChanged: (next) => SettingsService.instance.write(pref, (next * 20).round() / 20.0),
            ),
          ],
        ),
      );
    },
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
