# Satra visual design

Satra builds on Satra's existing screens, providers, navigation destinations,
and playback services. The visual reference is Nuvio Desktop's compact hover
sidebar and floating navigation, reinterpreted with stronger frosted surfaces.

## Appearance and artwork

The default appearance is black with white controls and an original white ribbon
S. Explicit System, Light, OLED, presets, and custom palette choices remain
available. Inter supplies consistent UI typography with the existing CJK fallback.

Hovering or focusing a title settles for 160ms before changing the shared
background. This avoids artwork requests while simply crossing a row. The real
server artwork becomes a blurred wash behind the browsing UI and glass rail.
Detail pages retain their sharp hero artwork and carry its colour down the page
through a separate low-resolution atmosphere. The image component keeps the
settled frame visible while replacement artwork loads. Offline details resolve
downloaded artwork locally, and spoiler protection and high contrast suppress
the atmosphere where appropriate.

Glass surfaces are bounded to navigation, toolbars, sheets, menus, and the music
mini-player. Cards never allocate individual backdrop filters. Reduced effects
use opaque panes, and reduced motion skips the new motion and wheel smoothing.

## Navigation and motion

Desktop and TV browsing run full-bleed without a side rail: primary Home and
library pills live on the left of the floating top toolbar, while utility
controls (`Downloads`, `Settings`, `Fullscreen`, `Profile`) sit in the top-right
action cluster. Pressing `Ctrl + Space` anywhere while the app is focused opens
the floating glassmorphic Universal Spotlight bubble to search movies, shows,
episodes, music, libraries, people, quick actions, and settings. Existing
server grouping, hidden libraries, reconnect, fullscreen, and TV focus hand-offs
retain their owners and stable identifiers. Mobile navigation floats in a safe
area and retains its library long-press picker, portrait/landscape layouts, and
mini-player inset reporting.

Tab changes retain mounted screen state, scroll offsets, and form values. Hidden
tabs are offstage, excluded from focus and semantics, and have disabled tickers.
Desktop routes fade and settle vertically; touch routes retain their native back
gestures. Pointer card feedback uses paint transforms without moving grid cells.

Wheel scrolling retargets a short ease-out and accumulates steps. Direction changes
reverse unfinished travel immediately. The scroll behavior inserts a signal
handler immediately before each scrollable's native handler, preserving the
priority of nested shelves and native page views. Touch/trackpad gestures retain
Flutter's native scrolling, and Shift-wheel retains horizontal navigation.

## Branding assets

`assets/satra.svg` is the editable logo. Regenerate default platform assets with:

```sh
python3 scripts/codegen/generate_satra_branding.py
```

The script requires `rsvg-convert` and ImageMagick. It generates the in-app mark,
Android launcher/notification/TV resources, Apple Icon Composer artwork, tvOS
layers and shelf images, default picker thumbnails, and the Windows icon.
Existing packaging filenames, application identifiers, and alternate icon IDs
remain stable. Inter's license is bundled and registered in the app license list.

On Linux, the native window supplies the bundled icon for X11. Wayland uses the
desktop entry. To launch a local release with the new name and icon, run:

```sh
python3 linux/packaging/install-local-launcher.py build/linux/x64/release/bundle
```

This installs a user-level override for the existing GTK application ID and keeps
profile paths stable. System files are untouched; existing user customizations
are backed up as `com.rahhing.satra.desktop.before-satra`. Removing the user
override (or restoring that backup) returns to the previous launcher. Keep the
referenced bundle directory in place after installation.

## Desktop sizing

Desktop scale defaults to Automatic. It compensates when a 4K monitor reports
1× density, while leaving a 4K monitor reporting 2× at its native size. Viewport,
pixel density, insets, painting, and pointer coordinates use the same scale.
Small windows cap the scale around a 480×360 logical layout so the navigation
rail and the selected tab's toolbar keep breathing room together. Appearance
settings also offer 75–250% manual scaling. Phone, TV, and automotive scaling
keep their existing paths.

The sign-in layout has a larger brand and readable controls, a wide two-column
composition, and a scrollable compact layout for phones and short windows.

## Verification

```sh
flutter pub get
flutter analyze
scripts/run_tests.sh --no-pub
flutter build linux --debug --no-pub
flutter test --dart-define=CAPTURE_REDESIGN=true test/screens/auth_redesign_test.dart
```

The optional capture writes desktop and phone renders to `build/visual-review`.
The tests cover existing app features as well as wheel accumulation, reversals,
Shift-wheel, nested page-view priority, touch input, retained tab state, hidden-tab
semantics, and artwork selection debouncing. A server-connected playback session
and native builds on other operating systems require those environments. Linux
debug and release builds pass. The full Flutter suite passes 8,415 tests with
seven skips; analysis reports no issues. Additional native review uses an
isolated local Jellyfin fixture library, separate from the user's profiles.
