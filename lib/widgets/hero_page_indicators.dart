import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../theme/app_motion.dart';

/// One marker per rotating hero, with a softly expanding active capsule.
class HeroPageIndicators extends StatelessWidget {
  const HeroPageIndicators({
    super.key,
    required this.itemCount,
    required this.currentIndex,
    required this.onSelected,
    required this.paused,
    required this.onTogglePaused,
    required this.pauseLabel,
  });

  final int itemCount;
  final int currentIndex;
  final ValueChanged<int> onSelected;
  final bool paused;
  final VoidCallback onTogglePaused;
  final String pauseLabel;

  @override
  Widget build(BuildContext context) {
    if (itemCount < 2) return const SizedBox.shrink();
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          tooltip: pauseLabel,
          onPressed: onTogglePaused,
          visualDensity: VisualDensity.compact,
          iconSize: 16,
          color: Colors.white.withValues(alpha: 0.85),
          icon: Icon(paused ? Symbols.play_arrow_rounded : Symbols.pause_rounded),
        ),
        Flexible(
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: List.generate(itemCount, (index) {
                final selected = currentIndex == index;
                return Semantics(
                  label: '${index + 1} / $itemCount',
                  selected: selected,
                  button: true,
                  child: Tooltip(
                    message: '${index + 1} / $itemCount',
                    child: InkResponse(
                      onTap: () => onSelected(index),
                      radius: 20,
                      child: AnimatedContainer(
                        key: ValueKey('hero_page_$index'),
                        duration: AppMotion.duration(context),
                        curve: AppMotion.curve,
                        width: selected ? 42 : 24,
                        height: 36,
                        alignment: Alignment.center,
                        child: AnimatedContainer(
                          duration: AppMotion.duration(context),
                          curve: AppMotion.curve,
                          width: selected ? 30 : 7,
                          height: 7,
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(8),
                            color: Colors.white.withValues(alpha: selected ? 1 : 0.65),
                            boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.25), blurRadius: 6)],
                          ),
                        ),
                      ),
                    ),
                  ),
                );
              }),
            ),
          ),
        ),
      ],
    );
  }
}
