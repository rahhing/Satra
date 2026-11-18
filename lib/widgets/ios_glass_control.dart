import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/settings_service.dart';
import '../theme/app_motion.dart';
import '../utils/platform_detector.dart';
import 'glass_surface.dart';
import 'settings_builder.dart';

/// Keeps the shared Flutter layout while letting UIKit own the control's paint,
/// touch handling, and accessibility on iOS 26 and later.
class IOSGlassControl extends StatefulWidget {
  const IOSGlassControl({super.key, required this.configuration, required this.onAction});

  final Map<String, Object> configuration;
  final void Function(String action, String? value) onAction;

  static const _channelName = 'com.satra/ios_glass_control';

  static Widget adaptive({required Widget child, required WidgetBuilder native}) =>
      _AdaptiveIOSGlassControl(native: native, child: child);

  @override
  State<IOSGlassControl> createState() => _IOSGlassControlState();
}

class _AdaptiveIOSGlassControl extends StatelessWidget {
  const _AdaptiveIOSGlassControl({required this.native, required this.child});

  final WidgetBuilder native;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (!PlatformDetector.isHandheldIOS(context) ||
        !GlassSurface.supportsNativeIOSGlass ||
        !AppMotion.effectsEnabled(context)) {
      return child;
    }
    return SettingValueBuilder<bool>(
      pref: SettingsService.liquidGlass,
      child: child,
      builder: (context, enabled, fallback) => enabled ? native(context) : fallback!,
    );
  }
}

class _IOSGlassControlState extends State<IOSGlassControl> {
  static const _equality = DeepCollectionEquality();
  static final _gestures = <Factory<OneSequenceGestureRecognizer>>{
    Factory<EagerGestureRecognizer>(EagerGestureRecognizer.new),
  };

  MethodChannel? _channel;
  Map<String, Object>? _lastConfiguration;

  Map<String, Object> _configuration(BuildContext context) => {
    ...widget.configuration,
    'dark': Theme.of(context).brightness == Brightness.dark,
    'rtl': Directionality.of(context) == TextDirection.rtl,
  };

  void _sendUpdate(Map<String, Object> configuration) {
    final channel = _channel;
    if (channel == null || _equality.equals(configuration, _lastConfiguration)) return;
    _lastConfiguration = configuration;
    channel.invokeMethod<void>('update', configuration).ignore();
  }

  @override
  void dispose() {
    _channel?.setMethodCallHandler(null);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final configuration = _configuration(context);
    _sendUpdate(configuration);
    return UiKitView(
      viewType: IOSGlassControl._channelName,
      layoutDirection: Directionality.of(context),
      creationParams: configuration,
      creationParamsCodec: const StandardMessageCodec(),
      gestureRecognizers: _gestures,
      onPlatformViewCreated: (id) {
        if (!mounted) return;
        final channel = MethodChannel('${IOSGlassControl._channelName}/$id');
        _channel = channel;
        channel.setMethodCallHandler((call) async {
          if (mounted) widget.onAction(call.method, call.arguments as String?);
        });
        _lastConfiguration = configuration;
        _sendUpdate(_configuration(context));
      },
    );
  }
}

class IOSGlassButton extends StatelessWidget {
  const IOSGlassButton({
    super.key,
    required this.label,
    required this.onPressed,
    required this.child,
    this.symbol,
    this.symbolSize,
    this.regularSymbolWeight = false,
    this.chromeless = false,
    this.nativeOffset = Offset.zero,
    this.title,
    this.titleSize,
    this.foregroundColor,
    this.progress,
    this.showsActivity = false,
    this.menuItems = const [],
    this.onMenuSelected,
  });

  final String label;
  final String? symbol;
  final double? symbolSize;
  final bool regularSymbolWeight;

  /// When true, renders the native UIKit symbol/menu trigger without its own
  /// standalone Liquid Glass capsule so it sits flush inside a parent pill.
  final bool chromeless;
  final Offset nativeOffset;
  final String? title;
  final double? titleSize;
  final Color? foregroundColor;
  final double? progress;
  final bool showsActivity;
  final List<Map<String, Object>> menuItems;
  final ValueChanged<String>? onMenuSelected;
  final VoidCallback? onPressed;

  /// Supplies the Flutter fallback and defines the native control's bounds.
  final Widget child;

  @override
  Widget build(BuildContext context) => IOSGlassControl.adaptive(
    child: child,
    native: (context) {
      final stack = Stack(
        children: [
          Visibility(visible: false, maintainState: true, maintainAnimation: true, maintainSize: true, child: child),
          Positioned.fill(
            child: IOSGlassControl(
              configuration: {
                'kind': 'button',
                'label': label,
                'enabled': onPressed != null,
                if (chromeless) 'chromeless': true,
                'symbol': ?symbol,
                'symbolSize': ?symbolSize,
                if (regularSymbolWeight) 'regularSymbolWeight': true,
                'title': ?title,
                if (titleSize != null) 'titleSize': MediaQuery.textScalerOf(context).scale(titleSize!),
                if (foregroundColor != null) 'foreground': foregroundColor!.toARGB32(),
                'progress': ?progress,
                'activity': showsActivity,
                if (menuItems.isNotEmpty) 'menu': menuItems,
              },
              onAction: (action, value) {
                if (action == 'pressed') onPressed?.call();
                if (action == 'menuSelected' && value != null) onMenuSelected?.call(value);
              },
            ),
          ),
        ],
      );
      final Widget framed = chromeless
          ? stack
          : ConstrainedBox(constraints: const BoxConstraints(minWidth: 44, minHeight: 44), child: stack);
      if (nativeOffset == Offset.zero) return framed;
      return Transform.translate(offset: nativeOffset, child: framed);
    },
  );
}
