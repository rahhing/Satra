import '../media/media_library.dart';

typedef LibraryServerGroups = ({List<String> serverOrder, Map<String, List<MediaLibrary>> byServer});

/// Groups libraries by server while preserving each server's first appearance in
/// the provided list. Libraries without a server id are placed in the empty-key
/// bucket at their first occurrence.
LibraryServerGroups groupLibrariesByFirstAppearance(List<MediaLibrary> libraries) {
  final order = <String>[];
  final byServer = <String, List<MediaLibrary>>{};
  for (final lib in libraries) {
    final key = lib.serverId ?? '';
    if (!byServer.containsKey(key)) {
      order.add(key);
      byServer[key] = [];
    }
    byServer[key]!.add(lib);
  }
  return (serverOrder: order, byServer: byServer);
}

/// Returns the visible libraries belonging to the "main" server.
///
/// Defaults to the first server group with visible libraries (matching the
/// first server added / first server group in the sidebar), or
/// [preferredServerId] if configured and present.
List<MediaLibrary> resolveMainServerLibraries(
  List<MediaLibrary> visibleLibraries, {
  Iterable<String>? orderedServerIds,
  String? preferredServerId,
}) {
  if (visibleLibraries.isEmpty) return const [];
  final grouped = groupLibrariesByFirstAppearance(visibleLibraries);
  if (grouped.serverOrder.isEmpty) return const [];

  if (preferredServerId != null && preferredServerId.isNotEmpty) {
    final preferred = grouped.byServer[preferredServerId];
    if (preferred != null && preferred.isNotEmpty) {
      return preferred;
    }
  }

  final firstGroupKey = grouped.serverOrder.first;
  if (firstGroupKey.isNotEmpty) {
    return grouped.byServer[firstGroupKey] ?? const [];
  }

  if (orderedServerIds != null) {
    for (final serverId in orderedServerIds) {
      final bucket = grouped.byServer[serverId];
      if (bucket != null && bucket.isNotEmpty) {
        return bucket;
      }
    }
  }

  return grouped.byServer[firstGroupKey] ?? const [];
}
