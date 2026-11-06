<h1>
  <img src="assets/satra.svg" alt="Satra Logo" height="24" style="vertical-align: middle;" />
  Satra
</h1>

A desktop-first client for **Plex**, **Jellyfin**, and **Emby**, built with Flutter.

Satra is a redesigned fork of [Plezy](https://github.com/edde746/plezy)

- **Full-Bleed Spotlight & Browse Rail**: Uses the cinematic spotlight backdrop and horizontal hub rails as the default layout, paired with full desktop mouse wheel scrolling, click-and-drag scrolling, and cross-row hover selection.
- **OLED Canvas & Frosted Surfaces**: True black `#000000` canvas, monochrome white ribbon branding (`assets/satra.svg`), translucent glass chrome, and artwork-driven ambient backgrounds.
- **Unified Desktop & D-Pad Navigation**: Expand-on-hover left navigation rail docked cleanly beneath the top toolbar, alongside full keyboard shortcut, mouse, and controller/D-pad support.

See [docs/visual-redesign.md](docs/visual-redesign.md) for architecture and redesign details.

<p>
  <a href="#features">Features</a> ·
  <a href="#building-from-source">Building from Source</a> ·
  <a href="docs/visual-redesign.md">Design Notes</a> ·
  <a href="CONTRIBUTING.md">Contributing</a> ·
  <a href="LICENSE">License</a>
</p>

## Features

### <img src="assets/readme_icons/browse.svg" height="20" alt="" align="center" /> Browse & Discover
- Full-bleed spotlight hero with clear-logo artwork, metadata, and instant cross-row hover updates
- Libraries, collections, and playlists — video and audio
- Shuffle a whole movie or TV library
- Discover hub — Continue Watching, Next Up, trending, and recommendations
- Continue Watching deduplicates titles held across multiple libraries or servers and prompts which copy to play
- Cross-server search across every connected Plex, Jellyfin, and Emby server, including actors and directors
- Filtering, sorting, folder browsing, and alphabetical jump navigation
- Resolution, HDR/Dolby Vision, and audio-format badges on cards and detail pages
- Extras — trailers, deleted scenes, behind-the-scenes

### <img src="assets/readme_icons/explore.svg" height="20" alt="" align="center" /> Explore & Requests
- Explore tab — watchlist, trending, popular, and recommendation rows from Plex Discover, Trakt, MyAnimeList, AniList, Simkl, and Seerr
- Search any connected catalog source and match titles back to your own libraries by external ID
- Seerr integration — request movies and shows with per-season, 4K, and destination options, and view request status inline
- Watchlist sync — add and remove titles on Plex, Trakt, MyAnimeList, AniList, and Simkl from anywhere in the app

### <img src="assets/readme_icons/playback.svg" height="20" alt="" align="center" /> Playback
- Powered by `mpv` / `libmpv` with wide codec support (HEVC, AV1, VP9, and more)
- HDR and Dolby Vision support
- Direct play, or transcode presets from 240p/320 kbps to 1080p/20 Mbps
- Multi-version switching with per-version file details
- Full ASS/SSA subtitles with customizable styling and online subtitle search/download
- Audio & subtitle choices remembered per title, or following the server's per-episode selections
- Auto-play next episode with skip intro / skip credits
- Chapter navigation with thumbnail scrub previews
- Playback speed from 0.25x to 8x, audio sync offset, and sleep timer
- Audio passthrough, output channel limit (5.1 or stereo, with center-channel boost), and loudness normalization
- Ambient lighting and GLSL shader presets (Anime4K, ArtCNN, NVScaler)
- External player launch (mpv, VLC, IINA, PotPlayer, Celluloid, etc.)

### <img src="assets/readme_icons/music.svg" height="20" alt="" align="center" /> Music
- Music libraries — artist, album, and track browsing with square artwork
- Album and artist screens with play, shuffle, and Instant Mix
- Gapless playback with a full play queue — reorder, remove, play next, add to queue
- Now Playing with synced lyrics, persistent mini-player, and media-key controls
- Offline playback of downloaded albums and tracks

### <img src="assets/readme_icons/live-tv.svg" height="20" alt="" align="center" /> Live TV & DVR
- Live TV channel browsing, tuning, and favorites
- EPG guide with What's On and per-show schedules
- DVR recording rules and scheduled recordings

### <img src="assets/readme_icons/downloads.svg" height="20" alt="" align="center" /> Downloads & Offline
- Download movies, shows, and music for offline playback
- Background queue with pause / resume
- Sync rules for automatic downloads, with per-show "Include Specials"
- Offline browsing with watch state sync-back on reconnect

### <img src="assets/readme_icons/watch-together.svg" height="20" alt="" align="center" /> Watch Together
- Rooms on [Open Watch Party](https://openwatch.party) — share a six-character code to watch together across Plex, Jellyfin, or Emby
- Synchronized play / pause / seek, host or shared control, room lock, and host handoff
- Public relays by default, or point Satra at your own self-hosted relay

### <img src="assets/readme_icons/integrations.svg" height="20" alt="" align="center" /> Integrations
- Discord Rich Presence
- Trakt, MyAnimeList, AniList, and Simkl — ratings, watched sync, and real-time scrobbling
- Scores from connected trackers and MDBList (Rotten Tomatoes, Metacritic, Letterboxd, IMDb, TMDB) on detail pages
- Companion Remote — control the desktop app from mobile
- Automatic HiDPI / 4K desktop UI scaling with manual scale override

## Building from Source

### Prerequisites
- Flutter SDK 3.47.0+
- Linux desktop build dependencies (`clang`, `cmake`, `ninja`, `pkg-config`, `gtk3`, `mpv`)
- A Plex account, or a Jellyfin or Emby server with user credentials

### Setup & Run

```bash
git clone https://github.com/rahhing/Satra.git
cd Satra
flutter pub get
scripts/codegen.sh
flutter run -d linux
```

### Build Linux Release & Install Desktop Launcher

To build a release bundle and install the user-local desktop launcher and icons (for KRunner / application menus):

```bash
flutter build linux --release
python3 linux/packaging/install-local-launcher.py build/linux/x64/release/bundle
```

<details>
<summary>Code generation & tests</summary>

After modifying model classes or other generated sources:

```bash
scripts/codegen.sh
```

After modifying translations:

```bash
dart run slang
```

Run static analysis and tests:

```bash
flutter analyze
flutter test
```

</details>

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for development workflow, formatting, tests, and translation guidelines.

## License

Satra is licensed under [GPL-3.0](LICENSE). Based on [Plezy](https://github.com/edde746/plezy); see [TRADEMARKS.md](TRADEMARKS.md).

## Acknowledgments

- Upstream [Plezy](https://github.com/edde746/plezy) project
- Visual and navigation inspiration from [Nuvio Desktop](https://github.com/NuvioMedia/NuvioDesktop)
- Built with [Flutter](https://flutter.dev)
- Supports [Plex Media Server](https://www.plex.tv), [Jellyfin](https://jellyfin.org), and [Emby](https://emby.media)
- Playback powered by [mpv](https://mpv.io) via [mpv-build](https://github.com/edde746/mpv-build)
