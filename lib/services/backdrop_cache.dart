import 'package:flutter/widgets.dart';

import '../media/media_item.dart';
import 'image_cache_service.dart';

/// Profile-owned LRU of backdrops already displayed. No prefetching: listeners
/// attach only after a frame is painted, keeping recent decodes reusable while
/// posters compete for Flutter's shared image cache.
class BackdropCache with WidgetsBindingObserver {
  BackdropCache({this.maximumBytes = 64 << 20, this.maximumEntries = 8})
    : assert(maximumBytes >= 0),
      assert(maximumEntries >= 0) {
    WidgetsBinding.instance.addObserver(this);
    artworkCacheRevision.addListener(_releaseImages);
  }

  final int maximumBytes;
  final int maximumEntries;
  final _images = <ImageProvider, _BackdropEntry>{};
  final _selections = <String, MediaItem>{};
  int _bytes = 0;
  bool _disposed = false;

  MediaItem? selectionFor(String libraryKey) {
    final item = _selections.remove(libraryKey);
    if (item != null) _selections[libraryKey] = item;
    return item;
  }

  void rememberSelection(String libraryKey, MediaItem item) {
    if (_disposed) return;
    _selections.remove(libraryKey);
    _selections[libraryKey] = item;
    while (_selections.length > maximumEntries) {
      _selections.remove(_selections.keys.first);
    }
  }

  void retain(ImageProvider provider, ImageConfiguration configuration) {
    if (_disposed) return;
    final existing = _images.remove(provider);
    if (existing != null) {
      _images[provider] = existing;
      return;
    }
    final stream = provider.resolve(configuration);
    late final _BackdropEntry entry;
    final listener = ImageStreamListener(
      (info, _) {
        final bytes = info.sizeBytes;
        info.dispose();
        if (_images[provider] != entry) return;
        _bytes += bytes - entry.bytes;
        entry.bytes = bytes;
        _trim();
      },
      onError: (Object error, StackTrace? stack) {
        if (_images[provider] == entry) _remove(provider);
      },
    );
    entry = _BackdropEntry(stream, listener);
    _images[provider] = entry;
    stream.addListener(listener);
    _trim();
  }

  void _trim() {
    while (_images.length > maximumEntries || _bytes > maximumBytes) {
      _remove(_images.keys.first);
    }
  }

  void _remove(ImageProvider provider) {
    final entry = _images.remove(provider);
    if (entry == null) return;
    _bytes -= entry.bytes;
    entry.stream.removeListener(entry.listener);
  }

  void _releaseImages() {
    for (final provider in _images.keys.toList()) {
      _remove(provider);
    }
  }

  void clear() {
    _releaseImages();
    _selections.clear();
  }

  @override
  void didHaveMemoryPressure() => clear();

  void dispose() {
    _disposed = true;
    WidgetsBinding.instance.removeObserver(this);
    artworkCacheRevision.removeListener(_releaseImages);
    clear();
  }
}

class _BackdropEntry {
  _BackdropEntry(this.stream, this.listener);

  final ImageStream stream;
  final ImageStreamListener listener;
  int bytes = 0;
}
