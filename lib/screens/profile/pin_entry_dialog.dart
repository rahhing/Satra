import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../focus/dpad_navigator.dart';
import '../../focus/input_mode_tracker.dart';
import '../../focus/key_event_utils.dart';
import '../../i18n/strings.g.dart';
import '../../mixins/controller_disposer_mixin.dart';
import '../../profiles/plex_home_switch.dart';
import '../../theme/app_motion.dart';
import '../../utils/dialogs.dart';
import '../../utils/platform_detector.dart';
import '../../widgets/app_icon.dart';
import '../../widgets/clickable_cursor.dart';
import '../../widgets/glass_surface.dart';

/// Dialog for entering a 4-digit PIN to access a protected profile.
///
/// Renders a unified Liquid Glass passcode pad with clickable 0–9 circular keys
/// across mobile, tablet, desktop, and TV while also supporting hardware
/// keyboard entry and D-pad navigation.
class PinEntryDialog extends StatefulWidget {
  final String userName;
  final String? errorMessage;

  const PinEntryDialog({super.key, required this.userName, this.errorMessage});

  @override
  State<PinEntryDialog> createState() => _PinEntryDialogState();
}

class _PinEntryDialogState extends State<PinEntryDialog> with SingleTickerProviderStateMixin {
  late AnimationController _shakeController;
  late Animation<double> _shakeAnimation;
  final _pinInputKey = GlobalKey<_TvPinInputState>();
  bool _completed = false;

  @override
  void initState() {
    super.initState();

    _shakeController = AnimationController(duration: const Duration(milliseconds: 520), vsync: this);
    _shakeAnimation = TweenSequence<double>([
      TweenSequenceItem(tween: Tween(begin: 0.0, end: 11.0), weight: 1),
      TweenSequenceItem(tween: Tween(begin: 11.0, end: -11.0), weight: 1),
      TweenSequenceItem(tween: Tween(begin: -11.0, end: 8.0), weight: 1),
      TweenSequenceItem(tween: Tween(begin: 8.0, end: -8.0), weight: 1),
      TweenSequenceItem(tween: Tween(begin: -8.0, end: 0.0), weight: 1),
    ]).animate(CurvedAnimation(parent: _shakeController, curve: Curves.easeInOut));

    if (widget.errorMessage != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _shakeController.forward(from: 0);
      });
    }
  }

  @override
  void dispose() {
    _shakeController.dispose();
    super.dispose();
  }

  bool get _isCurrentRoute => mounted && ModalRoute.of(context)?.isCurrent == true;

  void _submit(String pin) {
    if (_completed || !_isCurrentRoute) return;
    _completed = true;
    Navigator.of(context).pop<String>(pin);
  }

  void _cancel() {
    if (_completed || !_isCurrentRoute) return;
    _completed = true;
    Navigator.of(context).pop<String>();
  }

  @override
  Widget build(BuildContext context) {
    if (_shouldUseNativeIOSPinKeypad(context)) {
      return _IOSNativePinKeypad(
        userName: widget.userName,
        errorMessage: widget.errorMessage,
        onSubmit: _submit,
        onCancel: _cancel,
      );
    }

    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;
    final isTV = PlatformDetector.isTV();
    final isMobile = PlatformDetector.isMobile(context) && !isTV;
    final useGlass = !PlatformDetector.isTVDevice();
    const cardRadius = BorderRadius.all(Radius.circular(32));

    return AnimatedBuilder(
      animation: _shakeAnimation,
      builder: (context, child) {
        return Transform.translate(offset: Offset(_shakeAnimation.value, 0), child: child);
      },
      child: Dialog(
        insetPadding: EdgeInsets.symmetric(horizontal: isMobile ? 28 : 48, vertical: 24),
        backgroundColor: Colors.transparent,
        elevation: 0,
        shape: const RoundedRectangleBorder(borderRadius: cardRadius),
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: isMobile ? 316 : 308),
          child: GlassSurface(
            enabled: useGlass,
            tint: isDark ? const Color(0xFF07080C) : colorScheme.surface,
            opacity: isDark ? 0.90 : 0.92,
            sigma: 34,
            borderRadius: cardRadius,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: useGlass ? Colors.transparent : colorScheme.surface.withValues(alpha: 0.96),
                borderRadius: cardRadius,
              ),
              child: SingleChildScrollView(
                padding: EdgeInsets.fromLTRB(24, isMobile ? 20 : 22, 24, isMobile ? 16 : 22),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _buildHeader(theme, isDark),
                    const SizedBox(height: 16),
                    _TvPinInput(
                      key: _pinInputKey,
                      onSubmit: _submit,
                      onCancel: _cancel,
                      hasError: widget.errorMessage != null,
                      isMobile: isMobile,
                    ),
                    if (widget.errorMessage != null) ...[
                      const SizedBox(height: 12),
                      Text(
                        widget.errorMessage!,
                        textAlign: TextAlign.center,
                        style: TextStyle(color: colorScheme.error, fontSize: 12.5, fontWeight: FontWeight.w500),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                    if (isMobile) ...[
                      const SizedBox(height: 8),
                      TextButton(
                        onPressed: _cancel,
                        style: TextButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                          foregroundColor: colorScheme.onSurface.withValues(alpha: 0.68),
                        ),
                        child: Text(t.common.cancel),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildHeader(ThemeData theme, bool isDark) {
    final colorScheme = theme.colorScheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: colorScheme.onSurface.withValues(alpha: isDark ? 0.10 : 0.07),
            border: Border.all(width: 0.75, color: colorScheme.onSurface.withValues(alpha: isDark ? 0.14 : 0.10)),
          ),
          child: Center(child: AppIcon(Symbols.lock_rounded, fill: 1, size: 21, color: colorScheme.primary)),
        ),
        const SizedBox(height: 12),
        Text(
          widget.userName,
          textAlign: TextAlign.center,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700, letterSpacing: -0.25),
        ),
      ],
    );
  }
}

class _TvPinInput extends StatefulWidget {
  final ValueChanged<String> onSubmit;
  final VoidCallback onCancel;
  final bool hasError;
  final bool isMobile;

  const _TvPinInput({
    super.key,
    required this.onSubmit,
    required this.onCancel,
    required this.hasError,
    required this.isMobile,
  });

  @override
  State<_TvPinInput> createState() => _TvPinInputState();
}

class _TvPinInputState extends State<_TvPinInput> with ControllerDisposerMixin {
  static const _keypadColumns = 3;
  static const _rows = <List<_PinKey>>[
    [_PinKey.digit(1), _PinKey.digit(2), _PinKey.digit(3)],
    [_PinKey.digit(4), _PinKey.digit(5), _PinKey.digit(6)],
    [_PinKey.digit(7), _PinKey.digit(8), _PinKey.digit(9)],
    [_PinKey.close(), _PinKey.digit(0), _PinKey.backspace()],
  ];

  final List<int?> _digits = [null, null, null, null];
  int _activeIndex = 0;
  int _row = 0;
  int _column = 0;

  // Keep a single hidden text input client on mobile so hardware keyboards and
  // automated text input work seamlessly without raising the system soft
  // keyboard over the on-screen circular PIN pad.
  final FocusNode _mobileFocusNode = FocusNode(debugLabel: 'PinInputMobile');
  late final TextEditingController _mobileController = createTextEditingController();
  final FocusNode _keypadFocusNode = FocusNode(debugLabel: 'PinKeypad');
  bool _keypadRefocusScheduled = false;

  @override
  void initState() {
    super.initState();
    _mobileFocusNode.addListener(_handleMobileFocusChanged);
    _keypadFocusNode.addListener(_handleKeypadFocusChanged);

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (widget.hasError) _reset();
      if (widget.isMobile) {
        _requestMobileKeyboardFocus();
      } else {
        _requestKeypadFocus();
      }
    });
  }

  @override
  void dispose() {
    _keypadFocusNode.removeListener(_handleKeypadFocusChanged);
    _keypadFocusNode.dispose();
    _mobileFocusNode.removeListener(_handleMobileFocusChanged);
    _mobileFocusNode.dispose();
    super.dispose();
  }

  void _handleMobileFocusChanged() {
    if (mounted) setState(() {});
  }

  void _handleKeypadFocusChanged() {
    if (!mounted || widget.isMobile || _keypadFocusNode.hasFocus) return;
    _scheduleKeypadRefocus();
  }

  void _scheduleKeypadRefocus() {
    if (_keypadRefocusScheduled) return;
    _keypadRefocusScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _keypadRefocusScheduled = false;
      if (!mounted || widget.isMobile || _keypadFocusNode.hasFocus) return;
      _requestKeypadFocus();
    });
  }

  void _reset() {
    setState(() {
      for (int i = 0; i < 4; i++) {
        _digits[i] = null;
      }
      if (widget.isMobile) _mobileController.clear();
      _activeIndex = 0;
    });
    if (widget.isMobile) {
      _requestMobileKeyboardFocus();
    } else {
      _row = 0;
      _column = 0;
      _requestKeypadFocus();
    }
  }

  int get _pinLength {
    for (int i = 0; i < _digits.length; i++) {
      if (_digits[i] == null) return i;
    }
    return _digits.length;
  }

  String? _getPin() {
    if (_digits.any((d) => d == null)) return null;
    return _digits.map((d) => d.toString()).join();
  }

  void _syncMobileControllerFromDigits() {
    if (!widget.isMobile) return;
    final text = _digits.whereType<int>().map((d) => d.toString()).join();
    if (_mobileController.text != text) {
      _mobileController.value = TextEditingValue(
        text: text,
        selection: TextSelection.collapsed(offset: text.length),
      );
    }
  }

  void _trySubmit() {
    final pin = _getPin();
    if (pin != null) widget.onSubmit(pin);
  }

  void _requestKeypadFocus() {
    if (widget.isMobile) return;
    _keypadFocusNode.requestFocus();
  }

  void _requestMobileKeyboardFocus() {
    _mobileFocusNode.requestFocus();
    final offset = _mobileController.text.length;
    _mobileController.selection = TextSelection.collapsed(offset: offset);
  }

  void _setPinFromString(String pin) {
    setState(() {
      for (int i = 0; i < 4; i++) {
        _digits[i] = i < pin.length ? int.parse(pin[i]) : null;
      }
      _activeIndex = pin.length >= 4 ? 3 : pin.length;
    });

    if (pin.length == 4) _submitWhenCompleteAfterFrame();
  }

  void _appendDigit(int digit) {
    final length = _pinLength;
    if (length >= _digits.length) return;

    HapticFeedback.lightImpact();
    setState(() {
      _digits[length] = digit;
      final nextLength = length + 1;
      _activeIndex = nextLength >= _digits.length ? _digits.length - 1 : nextLength;
    });
    _syncMobileControllerFromDigits();

    if (length + 1 == _digits.length) _submitWhenCompleteAfterFrame();
  }

  void _deleteLastDigit() {
    final length = _pinLength;
    if (length == 0) return;

    HapticFeedback.selectionClick();
    setState(() {
      _digits[length - 1] = null;
      _activeIndex = length - 1;
    });
    _syncMobileControllerFromDigits();
  }

  void _submitWhenCompleteAfterFrame() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final pin = _getPin();
      if (pin != null) widget.onSubmit(pin);
    });
  }

  static final _digitKeyMap = <LogicalKeyboardKey, int>{
    LogicalKeyboardKey.digit0: 0,
    LogicalKeyboardKey.digit1: 1,
    LogicalKeyboardKey.digit2: 2,
    LogicalKeyboardKey.digit3: 3,
    LogicalKeyboardKey.digit4: 4,
    LogicalKeyboardKey.digit5: 5,
    LogicalKeyboardKey.digit6: 6,
    LogicalKeyboardKey.digit7: 7,
    LogicalKeyboardKey.digit8: 8,
    LogicalKeyboardKey.digit9: 9,
    LogicalKeyboardKey.numpad0: 0,
    LogicalKeyboardKey.numpad1: 1,
    LogicalKeyboardKey.numpad2: 2,
    LogicalKeyboardKey.numpad3: 3,
    LogicalKeyboardKey.numpad4: 4,
    LogicalKeyboardKey.numpad5: 5,
    LogicalKeyboardKey.numpad6: 6,
    LogicalKeyboardKey.numpad7: 7,
    LogicalKeyboardKey.numpad8: 8,
    LogicalKeyboardKey.numpad9: 9,
  };

  KeyEventResult _handleKey(FocusNode _, KeyEvent event) {
    final key = event.logicalKey;

    final backResult = handleBackKeyAction(event, widget.onCancel);
    if (backResult != KeyEventResult.ignored) return backResult;
    if (event.isTvSelectEvent || (PlatformDetector.isTV() && event.isPhysicalKeyboardEnter)) {
      return handleOneShotSelect(event, () => _activate(_rows[_row][_column]));
    }

    if (event is KeyDownEvent || event is KeyRepeatEvent) {
      if (key == LogicalKeyboardKey.backspace || key == LogicalKeyboardKey.delete) {
        _deleteLastDigit();
        return KeyEventResult.handled;
      }

      if (event.isPhysicalKeyboardEnter) {
        _trySubmit();
        return KeyEventResult.handled;
      }

      if (key.isUpKey) {
        _moveVertical(-1);
        return KeyEventResult.handled;
      }
      if (key.isDownKey) {
        _moveVertical(1);
        return KeyEventResult.handled;
      }
      if (key.isLeftKey) {
        _moveHorizontal(-1);
        return KeyEventResult.handled;
      }
      if (key.isRightKey) {
        _moveHorizontal(1);
        return KeyEventResult.handled;
      }

      if (event is! KeyDownEvent) return KeyEventResult.handled;

      final digit = _digitKeyMap[key];
      if (digit != null) {
        _appendDigit(digit);
        return KeyEventResult.handled;
      }
    }

    return KeyEventResult.ignored;
  }

  KeyEventResult _handleMobileHardwareKey(FocusNode _, KeyEvent event) {
    final backResult = handleBackKeyAction(event, widget.onCancel);
    if (backResult != KeyEventResult.ignored) return backResult;

    if (event is KeyDownEvent) {
      final key = event.logicalKey;
      if (key == LogicalKeyboardKey.backspace || key == LogicalKeyboardKey.delete) {
        _deleteLastDigit();
        return KeyEventResult.handled;
      }
      final digit = _digitKeyMap[key];
      if (digit != null) {
        _appendDigit(digit);
        return KeyEventResult.handled;
      }
      if (event.isPhysicalKeyboardEnter) {
        _trySubmit();
        return KeyEventResult.handled;
      }
    }
    return KeyEventResult.ignored;
  }

  void _onMobilePinChanged(String value) {
    final digitsOnly = value.replaceAll(RegExp(r'\D'), '');
    final pin = switch (digitsOnly.length) {
      <= 4 => digitsOnly,
      _ => digitsOnly.substring(0, expandToGraphemeRange(digitsOnly, const TextRange(start: 0, end: 4)).end),
    };
    if (pin != value) {
      _mobileController.value = TextEditingValue(
        text: pin,
        selection: TextSelection.collapsed(offset: pin.length),
      );
    }

    _setPinFromString(pin);
  }

  void _activate(_PinKey key) {
    switch (key.type) {
      case _PinKeyType.digit:
        _appendDigit(key.digit!);
        return;
      case _PinKeyType.backspace:
        _deleteLastDigit();
        return;
      case _PinKeyType.close:
        HapticFeedback.selectionClick();
        widget.onCancel();
        return;
    }
  }

  void _moveHorizontal(int delta) {
    setState(() {
      _column = (_column + delta).clamp(0, _keypadColumns - 1).toInt();
    });
  }

  void _moveVertical(int delta) {
    setState(() {
      _row = (_row + delta).clamp(0, _rows.length - 1).toInt();
    });
  }

  @override
  Widget build(BuildContext context) {
    if (widget.isMobile) {
      return Focus(
        onKeyEvent: _handleMobileHardwareKey,
        child: Stack(
          alignment: Alignment.center,
          children: [
            SizedBox(
              width: 1,
              height: 1,
              child: IgnorePointer(
                child: TextField(
                  controller: _mobileController,
                  focusNode: _mobileFocusNode,
                  keyboardType: TextInputType.none,
                  textInputAction: TextInputAction.done,
                  maxLength: 4,
                  obscureText: true,
                  autocorrect: false,
                  enableSuggestions: false,
                  enableInteractiveSelection: false,
                  showCursor: false,
                  cursorColor: Colors.transparent,
                  style: const TextStyle(color: Colors.transparent, fontSize: 1, height: 1),
                  decoration: const InputDecoration(counterText: '', border: InputBorder.none, contentPadding: .zero),
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(4)],
                  onChanged: _onMobilePinChanged,
                  onSubmitted: (_) => _trySubmit(),
                ),
              ),
            ),
            _buildKeypadLayout(context),
          ],
        ),
      );
    }

    return Focus(
      focusNode: _keypadFocusNode,
      autofocus: true,
      onKeyEvent: _handleKey,
      child: _buildKeypadLayout(context),
    );
  }

  Widget _buildKeypadLayout(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [_buildDigitRow(context), const SizedBox(height: 24), _buildKeypad(context)],
    );
  }

  Widget _buildKeypad(BuildContext context) {
    final keyGap = widget.isMobile ? 16.0 : 12.0;
    final rowGap = widget.isMobile ? 12.0 : 10.0;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (int row = 0; row < _rows.length; row++) ...[
          if (row > 0) SizedBox(height: rowGap),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            mainAxisSize: MainAxisSize.min,
            children: [
              for (int col = 0; col < _keypadColumns; col++) ...[
                if (col > 0) SizedBox(width: keyGap),
                _buildKey(context, _rows[row][col], row, col),
              ],
            ],
          ),
        ],
      ],
    );
  }

  Widget _buildKey(BuildContext context, _PinKey key, int row, int column) {
    final selected =
        !widget.isMobile &&
        row == _row &&
        column == _column &&
        (PlatformDetector.isTVDevice() || (InputModeTracker.isKeyboardMode(context) && _keypadFocusNode.hasFocus));

    final shortViewport = MediaQuery.sizeOf(context).height < 680;
    final double keyDiameter = shortViewport
        ? 50.0
        : (widget.isMobile ? 64.0 : (PlatformDetector.isDesktopOS() && !PlatformDetector.isTVDevice() ? 58.0 : 62.0));

    return _PinPadCircleButton(
      pinKey: key,
      diameter: keyDiameter,
      selected: selected,
      onTap: () {
        setState(() {
          _row = row;
          _column = column;
        });
        if (widget.isMobile) _requestMobileKeyboardFocus();
        _activate(key);
      },
    );
  }

  Widget _buildDigitRow(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        for (int i = 0; i < 4; i++) ...[
          if (i > 0) const SizedBox(width: 16),
          _PasscodeDot(filled: _digits[i] != null, isActive: _activeIndex == i && _digits[i] == null),
        ],
      ],
    );
  }
}

class _PinPadCircleButton extends StatefulWidget {
  const _PinPadCircleButton({
    required this.pinKey,
    required this.diameter,
    required this.selected,
    required this.onTap,
  });

  final _PinKey pinKey;
  final double diameter;
  final bool selected;
  final VoidCallback onTap;

  @override
  State<_PinPadCircleButton> createState() => _PinPadCircleButtonState();
}

class _PinPadCircleButtonState extends State<_PinPadCircleButton> {
  bool _hovered = false;
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;
    final isUtilityKey = widget.pinKey.type != _PinKeyType.digit;

    final Color background;
    final Color borderColor;
    final Color foreground;
    if (widget.selected) {
      background = colorScheme.primary;
      borderColor = colorScheme.primary;
      foreground = colorScheme.onPrimary;
    } else if (_pressed) {
      background = colorScheme.onSurface.withValues(alpha: isDark ? 0.24 : 0.18);
      borderColor = colorScheme.onSurface.withValues(alpha: isDark ? 0.30 : 0.22);
      foreground = colorScheme.onSurface;
    } else if (_hovered) {
      background = colorScheme.onSurface.withValues(alpha: isDark ? 0.15 : 0.11);
      borderColor = colorScheme.onSurface.withValues(alpha: isDark ? 0.20 : 0.14);
      foreground = colorScheme.onSurface;
    } else if (isUtilityKey) {
      background = colorScheme.onSurface.withValues(alpha: isDark ? 0.04 : 0.03);
      borderColor = colorScheme.onSurface.withValues(alpha: isDark ? 0.08 : 0.06);
      foreground = colorScheme.onSurface.withValues(alpha: 0.78);
    } else {
      background = colorScheme.onSurface.withValues(alpha: isDark ? 0.10 : 0.07);
      borderColor = colorScheme.onSurface.withValues(alpha: isDark ? 0.14 : 0.10);
      foreground = colorScheme.onSurface;
    }

    final icon = widget.pinKey.icon;

    return ClickableCursor(
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (_) => setState(() => _pressed = true),
          onTapUp: (_) => setState(() => _pressed = false),
          onTapCancel: () => setState(() => _pressed = false),
          onTap: widget.onTap,
          child: AnimatedScale(
            scale: _pressed ? 0.93 : 1.0,
            duration: const Duration(milliseconds: 110),
            curve: Curves.easeOutCubic,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 120),
              width: widget.diameter,
              height: widget.diameter,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: background,
                border: Border.all(width: 0.85, color: borderColor),
              ),
              child: icon != null
                  ? AppIcon(icon, color: foreground, size: 23)
                  : Text(
                      widget.pinKey.label,
                      maxLines: 1,
                      style: TextStyle(
                        color: foreground,
                        fontSize: 25,
                        fontWeight: FontWeight.w500,
                        height: 1.0,
                        letterSpacing: -0.3,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
            ),
          ),
        ),
      ),
    );
  }
}

class _PasscodeDot extends StatelessWidget {
  final bool filled;
  final bool isActive;

  const _PasscodeDot({required this.filled, required this.isActive});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;

    return AnimatedScale(
      scale: filled ? 1.12 : 1.0,
      duration: const Duration(milliseconds: 150),
      curve: Curves.easeOutBack,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        width: 14,
        height: 14,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: filled ? colorScheme.onSurface : Colors.transparent,
          border: Border.all(
            width: filled ? 0 : (isActive ? 1.8 : 1.5),
            color: filled
                ? colorScheme.onSurface
                : (isActive
                      ? colorScheme.primary.withValues(alpha: 0.85)
                      : colorScheme.onSurface.withValues(alpha: isDark ? 0.28 : 0.24)),
          ),
          boxShadow: filled
              ? [BoxShadow(color: colorScheme.onSurface.withValues(alpha: isDark ? 0.28 : 0.14), blurRadius: 8)]
              : null,
        ),
      ),
    );
  }
}

enum _PinKeyType { digit, backspace, close }

class _PinKey {
  final _PinKeyType type;
  final int? digit;

  const _PinKey.digit(this.digit) : type = _PinKeyType.digit;
  const _PinKey.backspace() : type = _PinKeyType.backspace, digit = null;
  const _PinKey.close() : type = _PinKeyType.close, digit = null;

  String get label => digit.toString();

  IconData? get icon {
    switch (type) {
      case _PinKeyType.digit:
        return null;
      case _PinKeyType.backspace:
        return Symbols.backspace_rounded;
      case _PinKeyType.close:
        return Symbols.close_rounded;
    }
  }
}

bool _shouldUseNativeIOSPinKeypad(BuildContext context) =>
    PlatformDetector.isHandheldIOS(context) && GlassSurface.supportsNativeIOSSwiftUISurfaces;

/// Native SwiftUI Lock Screen circular passcode unlock view for handheld iOS.
class _IOSNativePinKeypad extends StatefulWidget {
  const _IOSNativePinKeypad({
    required this.userName,
    required this.errorMessage,
    required this.onSubmit,
    required this.onCancel,
  });

  final String userName;
  final String? errorMessage;
  final ValueChanged<String> onSubmit;
  final VoidCallback onCancel;

  @override
  State<_IOSNativePinKeypad> createState() => _IOSNativePinKeypadState();
}

class _IOSNativePinKeypadState extends State<_IOSNativePinKeypad> {
  static const _viewType = 'com.satra/ios_pin_keypad';
  static const _equality = DeepCollectionEquality();
  static final _gestures = <Factory<OneSequenceGestureRecognizer>>{
    Factory<EagerGestureRecognizer>(EagerGestureRecognizer.new),
  };

  MethodChannel? _channel;
  Map<String, Object>? _lastParams;

  Map<String, Object> _params(BuildContext context) {
    final theme = Theme.of(context);
    return <String, Object>{
      'userName': widget.userName,
      'subtitle': '',
      if (widget.errorMessage != null) 'errorMessage': widget.errorMessage!,
      'cancelLabel': t.common.cancel,
      'deleteLabel': t.common.delete,
      'dark': theme.brightness == Brightness.dark,
      'accentArgb': theme.colorScheme.primary.toARGB32(),
    };
  }

  void _sendUpdate(Map<String, Object> params) {
    final channel = _channel;
    if (channel == null || _equality.equals(params, _lastParams)) return;
    _lastParams = params;
    channel.invokeMethod<void>('update', params).ignore();
  }

  KeyEventResult _handleHardwareKey(FocusNode _, KeyEvent event) {
    final backResult = handleBackKeyAction(event, widget.onCancel);
    if (backResult != KeyEventResult.ignored) return backResult;

    if (event is KeyDownEvent) {
      final key = event.logicalKey;
      if (key == LogicalKeyboardKey.backspace || key == LogicalKeyboardKey.delete) {
        _channel?.invokeMethod<void>('hardwareBackspace').ignore();
        return KeyEventResult.handled;
      }
      final digit = _TvPinInputState._digitKeyMap[key];
      if (digit != null) {
        _channel?.invokeMethod<void>('hardwareDigit', digit).ignore();
        return KeyEventResult.handled;
      }
    }
    return KeyEventResult.ignored;
  }

  @override
  void dispose() {
    _channel?.setMethodCallHandler(null);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final params = _params(context);
    _sendUpdate(params);
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) widget.onCancel();
      },
      child: Focus(
        autofocus: true,
        onKeyEvent: _handleHardwareKey,
        child: SizedBox.expand(
          child: UiKitView(
            key: const ValueKey('ios_native_pin_keypad'),
            viewType: _viewType,
            layoutDirection: Directionality.of(context),
            creationParams: params,
            creationParamsCodec: const StandardMessageCodec(),
            gestureRecognizers: _gestures,
            onPlatformViewCreated: (id) {
              if (!mounted) return;
              final channel = MethodChannel('$_viewType/$id');
              _channel = channel;
              channel.setMethodCallHandler((call) async {
                if (!mounted) return;
                if (call.method == 'submit' && call.arguments is String) {
                  widget.onSubmit(call.arguments as String);
                } else if (call.method == 'cancel') {
                  widget.onCancel();
                }
              });
              _lastParams = params;
              _sendUpdate(_params(context));
            },
          ),
        ),
      ),
    );
  }
}

/// Shows the PIN entry dialog and returns the entered PIN, or null if cancelled
Future<String?> showPinEntryDialog(BuildContext context, String userName, {String? errorMessage}) {
  if (_shouldUseNativeIOSPinKeypad(context)) {
    return Navigator.of(context, rootNavigator: true).push<String>(
      PageRouteBuilder<String>(
        opaque: false,
        barrierDismissible: false,
        barrierColor: Colors.transparent,
        transitionDuration: AppMotion.systemDuration(const Duration(milliseconds: 220)),
        reverseTransitionDuration: AppMotion.systemDuration(const Duration(milliseconds: 180)),
        pageBuilder: (routeContext, animation, secondaryAnimation) =>
            PinEntryDialog(userName: userName, errorMessage: errorMessage),
        transitionsBuilder: (context, animation, _, child) {
          if (AppMotion.duration(context) == Duration.zero) return child;
          return FadeTransition(
            opacity: CurvedAnimation(parent: animation, curve: Curves.easeOutCubic, reverseCurve: Curves.easeInCubic),
            child: child,
          );
        },
      ),
    );
  }
  return showAnimatedRootDialog<String>(
    context: context,
    barrierDismissible: false,
    builder: (context) => PinEntryDialog(userName: userName, errorMessage: errorMessage),
  );
}

/// The [PlexHomeSwitchPinPrompt] every UI-side `mintPlexHomeUserToken` caller
/// needs: show [showPinEntryDialog] for [displayName], or cancel the switch
/// once [context] is gone. Only the *use* is guarded — build it before the
/// caller's first await, while [context] is still live.
PlexHomeSwitchPinPrompt dialogPinPrompt(BuildContext context, String displayName) =>
    ({String? errorMessage}) async =>
        context.mounted ? showPinEntryDialog(context, displayName, errorMessage: errorMessage) : null;

/// Two-step "set + confirm" PIN entry. Returns the matching PIN, or null
/// when the user cancels. On mismatch, surfaces a snackbar via [onMismatch]
/// (or no-op if not provided) and returns null — the helper keeps the UX
/// in one place so multiple call sites don't drift.
Future<String?> captureAndConfirmPin(
  BuildContext context, {
  String? setLabel,
  String? confirmLabel,
  void Function(BuildContext)? onMismatch,
}) async {
  final pin = await showPinEntryDialog(context, setLabel ?? t.profiles.setPinTitle);
  if (pin == null || !context.mounted) return null;
  final confirm = await showPinEntryDialog(context, confirmLabel ?? t.profiles.confirmPinTitle);
  if (confirm == null || !context.mounted) return null;
  if (pin == confirm) return pin;
  onMismatch?.call(context);
  return null;
}
