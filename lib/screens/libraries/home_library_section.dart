import 'dart:async';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../i18n/strings.g.dart';
import '../../media/library_genre.dart';
import '../../media/media_library.dart';
import '../../utils/provider_extensions.dart';
import '../../media/ids.dart';
import '../../widgets/app_icon.dart';
import '../../widgets/app_menu.dart';
import '../../widgets/retained_tab_view.dart';
import '../../widgets/toolbar_scrim.dart';
import 'libraries_screen.dart';
import 'state_messages.dart';
import 'tabs/base_library_tab.dart';
import 'tabs/library_browse_tab.dart';
import 'tabs/library_collections_tab.dart';
import 'tabs/library_genres_tab.dart';
import 'tabs/library_playlists_tab.dart';

/// Home reuses the full library browsers, loading only sections the user opens.
/// Recommended remains the combined feed; the other sections share this picker.
class HomeLibrarySection extends StatefulWidget {
  const HomeLibrarySection({
    super.key,
    required this.section,
    required this.libraries,
    required this.isActive,
    required this.onSectionChanged,
    required this.onNavigateUp,
  });

  final LibraryTabType section;
  final List<MediaLibrary> libraries;
  final bool isActive;
  final ValueChanged<LibraryTabType> onSectionChanged;
  final VoidCallback onNavigateUp;

  @override
  State<HomeLibrarySection> createState() => HomeLibrarySectionState();
}

class HomeLibrarySectionState extends State<HomeLibrarySection> {
  String? _libraryKey;
  final _outerScroll = ScrollController();
  final _keys = {for (final section in LibraryTabType.values.skip(1)) section: GlobalKey()};
  final _visited = <LibraryTabType>{};
  bool _focusWhenLoaded = false;

  List<MediaLibrary> get _eligibleLibraries =>
      widget.libraries.where((library) => visibleLibraryTabs(library).contains(widget.section)).toList();

  MediaLibrary? get selectedLibrary {
    final libraries = _eligibleLibraries;
    return libraries.where((library) => library.globalKey == _libraryKey).firstOrNull ?? libraries.firstOrNull;
  }

  BaseLibraryTabState? get _activeTab {
    final state = _keys[widget.section]?.currentState;
    return state is BaseLibraryTabState ? state : null;
  }

  void focusContent() {
    _focusWhenLoaded = true;
    _focusLoadedContent();
  }

  void _focusLoadedContent() {
    if (!widget.isActive || !_focusWhenLoaded) return;
    final tab = _activeTab;
    if (tab == null || tab.isLoading) return;
    _focusWhenLoaded = false;
    tab.focusContentOrChrome();
  }

  void refresh() => _activeTab?.refresh();

  void _resetScroll() {
    for (final position in _outerScroll.positions) {
      if (position.hasPixels && position.pixels != 0) position.jumpTo(0);
    }
  }

  @override
  void didUpdateWidget(HomeLibrarySection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.section != widget.section) _focusWhenLoaded = false;
  }

  @override
  void dispose() {
    _outerScroll.dispose();
    super.dispose();
  }

  Future<void> _openGenre(MediaLibrary library, LibraryGenre genre, bool canGroupByFolders) async {
    await saveGenreBrowseSelection(library, genre, canGroupByFolders: canGroupByFolders);
    if (!mounted || selectedLibrary?.globalKey != library.globalKey) return;
    final browse = _keys[LibraryTabType.browse]!.currentState;
    if (browse is BaseLibraryTabState) browse.refresh();
    widget.onSectionChanged(LibraryTabType.browse);
  }

  Widget _page(LibraryTabType section, MediaLibrary library, bool canGroupByFolders) {
    final key = _keys[section];
    final active = widget.isActive && widget.section == section;
    void loaded() => WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && widget.section == section) _focusLoadedContent();
    });
    return switch (section) {
      LibraryTabType.browse => LibraryBrowseTab(
        key: key,
        library: library,
        canGroupByFolders: canGroupByFolders,
        isActive: active,
        suppressAutoFocus: true,
        onBack: widget.onNavigateUp,
        onDataLoaded: loaded,
        onResetScroll: _resetScroll,
      ),
      LibraryTabType.collections => LibraryCollectionsTab(
        key: key,
        library: library,
        isActive: active,
        suppressAutoFocus: true,
        onBack: widget.onNavigateUp,
        onDataLoaded: loaded,
      ),
      LibraryTabType.playlists => LibraryPlaylistsTab(
        key: key,
        library: library,
        isActive: active,
        suppressAutoFocus: true,
        onBack: widget.onNavigateUp,
        onDataLoaded: loaded,
      ),
      LibraryTabType.genres => LibraryGenresTab(
        key: key,
        library: library,
        isActive: active,
        suppressAutoFocus: true,
        onBack: widget.onNavigateUp,
        onDataLoaded: loaded,
        onGenreSelected: (genre) => unawaited(_openGenre(library, genre, canGroupByFolders)),
      ),
      LibraryTabType.recommended => throw StateError('Home owns the Recommended feed'),
    };
  }

  @override
  Widget build(BuildContext context) {
    final library = selectedLibrary;
    if (library == null) {
      return Center(
        child: EmptyStateWidget(message: t.libraries.noLibrariesFound, icon: Symbols.video_library_rounded),
      );
    }
    _libraryKey = library.globalKey;
    _visited.add(widget.section);
    final client = context.tryGetMediaClientForServer(serverIdOrNull(library.serverId));
    final canGroupByFolders = !library.isShared && (client?.capabilities.folderGrouping ?? false);
    return ScrollConfiguration(
      behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
      child: NestedScrollView(
        controller: _outerScroll,
        headerSliverBuilder: (context, _) => [
          SliverOverlapAbsorber(
            handle: NestedScrollView.sliverOverlapAbsorberHandleFor(context),
            sliver: SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.fromLTRB(16, ToolbarScrim.layoutHeight(context), 16, 8),
                child: Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: AppMenuButton<String>(
                    tooltip: t.libraries.selectLibrary,
                    adaptiveSheet: true,
                    onSelected: (key) {
                      if (key == library.globalKey) return;
                      setState(() {
                        _libraryKey = key;
                        _focusWhenLoaded = false;
                      });
                      _resetScroll();
                    },
                    entriesBuilder: (_) => [
                      for (final candidate in _eligibleLibraries)
                        AppMenuItem(
                          value: candidate.globalKey,
                          label: candidate.title,
                          subtitle: candidate.serverName,
                          selected: candidate.globalKey == library.globalKey,
                        ),
                    ],
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(library.title, style: Theme.of(context).textTheme.titleMedium),
                        const SizedBox(width: 8),
                        const AppIcon(Symbols.expand_more_rounded, fill: 1),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
        body: RetainedTabView(
          index: widget.section.index - 1,
          children: [
            for (final section in LibraryTabType.values.skip(1))
              if (_visited.contains(section) && visibleLibraryTabs(library).contains(section))
                _page(section, library, canGroupByFolders)
              else
                const SizedBox.shrink(),
          ],
        ),
      ),
    );
  }
}
