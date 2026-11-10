import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../i18n/strings.g.dart';
import '../media/media_item.dart';
import '../media/media_kind.dart';
import '../media/media_person.dart';

/// Filter categories shown in the Universal Spotlight bubble.
enum SpotlightCategory {
  all,
  movies,
  shows,
  episodes,
  music,
  libraries,
  settings,
  actions,
  people;

  String get label => switch (this) {
    SpotlightCategory.all => t.spotlight.categories.all,
    SpotlightCategory.movies => t.spotlight.categories.movies,
    SpotlightCategory.shows => t.spotlight.categories.shows,
    SpotlightCategory.episodes => t.spotlight.categories.episodes,
    SpotlightCategory.music => t.spotlight.categories.music,
    SpotlightCategory.libraries => t.spotlight.categories.libraries,
    SpotlightCategory.settings => t.spotlight.categories.settings,
    SpotlightCategory.actions => t.spotlight.categories.actions,
    SpotlightCategory.people => t.spotlight.categories.people,
  };

  IconData get icon => switch (this) {
    SpotlightCategory.all => Symbols.apps_rounded,
    SpotlightCategory.movies => Symbols.movie_rounded,
    SpotlightCategory.shows => Symbols.tv_rounded,
    SpotlightCategory.episodes => Symbols.subscriptions_rounded,
    SpotlightCategory.music => Symbols.music_note_rounded,
    SpotlightCategory.libraries => Symbols.video_library_rounded,
    SpotlightCategory.settings => Symbols.settings_rounded,
    SpotlightCategory.actions => Symbols.bolt_rounded,
    SpotlightCategory.people => Symbols.person_rounded,
  };
}

/// Specific result kind for badges, thumbnails, and grouping.
enum SpotlightEntryType {
  movie,
  show,
  season,
  episode,
  artist,
  album,
  track,
  collection,
  playlist,
  library,
  setting,
  action,
  person,
}

/// A single actionable result inside the Universal Spotlight bubble.
class SpotlightEntry {
  const SpotlightEntry({
    required this.id,
    required this.title,
    this.subtitle,
    this.badge,
    required this.icon,
    required this.category,
    required this.type,
    required this.onActivate,
    this.keywords = const [],
    this.mediaItem,
    this.person,
    this.basePriority = 0,
  });

  final String id;
  final String title;
  final String? subtitle;
  final String? badge;
  final IconData icon;
  final SpotlightCategory category;
  final SpotlightEntryType type;
  final VoidCallback onActivate;
  final List<String> keywords;
  final MediaItem? mediaItem;
  final MediaPerson? person;
  final int basePriority;

  static SpotlightCategory categoryForMediaKind(MediaKind kind) => switch (kind) {
    MediaKind.movie || MediaKind.collection => SpotlightCategory.movies,
    MediaKind.show || MediaKind.season => SpotlightCategory.shows,
    MediaKind.episode || MediaKind.clip => SpotlightCategory.episodes,
    MediaKind.artist || MediaKind.album || MediaKind.track || MediaKind.playlist => SpotlightCategory.music,
    MediaKind.photo || MediaKind.folder || MediaKind.unknown => SpotlightCategory.all,
  };

  static SpotlightEntryType entryTypeForMediaKind(MediaKind kind) => switch (kind) {
    MediaKind.movie => SpotlightEntryType.movie,
    MediaKind.show => SpotlightEntryType.show,
    MediaKind.season => SpotlightEntryType.season,
    MediaKind.episode || MediaKind.clip => SpotlightEntryType.episode,
    MediaKind.artist => SpotlightEntryType.artist,
    MediaKind.album => SpotlightEntryType.album,
    MediaKind.track => SpotlightEntryType.track,
    MediaKind.collection => SpotlightEntryType.collection,
    MediaKind.playlist => SpotlightEntryType.playlist,
    MediaKind.photo || MediaKind.folder || MediaKind.unknown => SpotlightEntryType.movie,
  };

  static IconData iconForMediaKind(MediaKind kind) => switch (kind) {
    MediaKind.movie => Symbols.movie_rounded,
    MediaKind.show => Symbols.tv_rounded,
    MediaKind.season => Symbols.layers_rounded,
    MediaKind.episode || MediaKind.clip => Symbols.play_circle_rounded,
    MediaKind.artist => Symbols.mic_rounded,
    MediaKind.album => Symbols.album_rounded,
    MediaKind.track => Symbols.music_note_rounded,
    MediaKind.collection => Symbols.collections_bookmark_rounded,
    MediaKind.playlist => Symbols.queue_music_rounded,
    MediaKind.photo => Symbols.photo_rounded,
    MediaKind.folder || MediaKind.unknown => Symbols.folder_rounded,
  };

  static String badgeForMediaKind(MediaKind kind) => switch (kind) {
    MediaKind.movie => t.common.mediaKind.movie,
    MediaKind.show => t.common.mediaKind.show,
    MediaKind.season => t.common.mediaKind.season,
    MediaKind.episode => t.common.mediaKind.episode,
    MediaKind.artist => t.common.mediaKind.artist,
    MediaKind.album => t.common.mediaKind.album,
    MediaKind.track => t.common.mediaKind.track,
    MediaKind.collection => t.common.mediaKind.collection,
    MediaKind.playlist => t.common.mediaKind.playlist,
    MediaKind.clip => t.common.mediaKind.clip,
    MediaKind.photo => t.common.mediaKind.photo,
    MediaKind.folder || MediaKind.unknown => t.common.mediaKind.folder,
  };
}

/// Scores [entry] against [rawQuery]. Returns `-1` when the entry does not
/// match every whitespace-separated query token.
int scoreSpotlightQuery(SpotlightEntry entry, String rawQuery) {
  final normalized = rawQuery.trim().toLowerCase();
  if (normalized.isEmpty) return entry.basePriority;

  final tokens = normalized.split(RegExp(r'\s+')).where((t) => t.isNotEmpty).toList(growable: false);
  if (tokens.isEmpty) return entry.basePriority;

  final titleLower = entry.title.toLowerCase();
  final subtitleLower = entry.subtitle?.toLowerCase() ?? '';
  final badgeLower = entry.badge?.toLowerCase() ?? '';
  final keywordLowers = [for (final k in entry.keywords) k.toLowerCase()];

  if (titleLower == normalized) {
    return 1200 + entry.basePriority;
  }
  if (titleLower.startsWith(normalized)) {
    return 900 + entry.basePriority;
  }

  var total = entry.basePriority;
  final titleWords = titleLower.split(RegExp(r'[\s\-_:./()]+'));

  for (final token in tokens) {
    if (titleLower == token) {
      total += 500;
    } else if (titleLower.startsWith(token)) {
      total += 360;
    } else if (titleWords.any((word) => word.startsWith(token))) {
      total += 280;
    } else if (titleLower.contains(token)) {
      total += 200;
    } else if (keywordLowers.any((k) => k == token || k.startsWith(token))) {
      total += 170;
    } else if (subtitleLower.contains(token) || badgeLower.contains(token)) {
      total += 120;
    } else if (keywordLowers.any((k) => k.contains(token))) {
      total += 90;
    } else {
      return -1;
    }
  }

  return total;
}
