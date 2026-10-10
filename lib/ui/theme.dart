/// Colours and text styles for the kit, light and dark.
library;

import 'package:flutter/material.dart';

class KitColors {
  final Brightness brightness;
  final Color background;
  final Color surface;
  final Color hover;
  final Color pressed;
  final Color border;
  final Color borderStrong;
  final Color text;
  final Color textDim;
  final Color accent;
  final Color accentHover;
  final Color accentPressed;
  final Color onAccent;
  final Color danger;
  final Color dangerHover;
  final Color onDanger;
  final Color success;
  final Color focus;
  final Color shadow;

  const KitColors({
    required this.brightness,
    required this.background,
    required this.surface,
    required this.hover,
    required this.pressed,
    required this.border,
    required this.borderStrong,
    required this.text,
    required this.textDim,
    required this.accent,
    required this.accentHover,
    required this.accentPressed,
    required this.onAccent,
    required this.danger,
    required this.dangerHover,
    required this.onDanger,
    required this.success,
    required this.focus,
    required this.shadow,
  });

  static const light = KitColors(
    brightness: Brightness.light,
    background: Color(0xFFF6F6F7),
    surface: Color(0xFFFFFFFF),
    hover: Color(0xFFEDEDEF),
    pressed: Color(0xFFDEDEE2),
    border: Color(0xFFDADADE),
    borderStrong: Color(0xFFB8B8BF),
    text: Color(0xFF1E1E22),
    textDim: Color(0xFF66666E),
    accent: Color(0xFF3584E4),
    accentHover: Color(0xFF2A76D3),
    accentPressed: Color(0xFF1F63B8),
    onAccent: Color(0xFFFFFFFF),
    danger: Color(0xFFD12D3A),
    dangerHover: Color(0xFFB8232F),
    onDanger: Color(0xFFFFFFFF),
    success: Color(0xFF26A269),
    focus: Color(0xFF3584E4),
    shadow: Color(0x22000000),
  );

  static const dark = KitColors(
    brightness: Brightness.dark,
    background: Color(0xFF1C1C1F),
    surface: Color(0xFF26262A),
    hover: Color(0xFF323237),
    pressed: Color(0xFF3C3C42),
    border: Color(0xFF3A3A40),
    borderStrong: Color(0xFF55555D),
    text: Color(0xFFEDEDF0),
    textDim: Color(0xFFA0A0A8),
    accent: Color(0xFF4A90E8),
    accentHover: Color(0xFF5C9DEC),
    accentPressed: Color(0xFF3F80D4),
    onAccent: Color(0xFFFFFFFF),
    danger: Color(0xFFE5484D),
    dangerHover: Color(0xFFEC5F63),
    onDanger: Color(0xFFFFFFFF),
    success: Color(0xFF3DBE7F),
    focus: Color(0xFF6AA6F0),
    shadow: Color(0x66000000),
  );
}

const kitRadius = 6.0;
const kitControlHeight = 30.0;

/// Makes [KitColors] available below it.
class KitTheme extends InheritedWidget {
  final KitColors colors;
  const KitTheme({super.key, required this.colors, required super.child});

  static KitColors of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<KitTheme>()?.colors ?? KitColors.light;

  @override
  bool updateShouldNotify(KitTheme old) => old.colors != colors;

  /// A Material theme with every splash, highlight, hover overlay and page
  /// transition turned off, for whatever Material pieces remain (text
  /// fields, scrollbars).
  static ThemeData material(KitColors c) => ThemeData(
        brightness: c.brightness,
        colorScheme: ColorScheme.fromSeed(
          seedColor: c.accent,
          brightness: c.brightness,
          primary: c.accent,
          error: c.danger,
          surface: c.surface,
        ),
        scaffoldBackgroundColor: c.background,
        canvasColor: c.background,
        visualDensity: VisualDensity.compact,
        splashFactory: NoSplash.splashFactory,
        splashColor: Colors.transparent,
        highlightColor: Colors.transparent,
        hoverColor: Colors.transparent,
        focusColor: Colors.transparent,
        textSelectionTheme: TextSelectionThemeData(
          cursorColor: c.accent,
          selectionColor: c.accent.withValues(alpha: 0.3),
        ),
        pageTransitionsTheme: const PageTransitionsTheme(builders: {
          TargetPlatform.linux: _NoTransition(),
          TargetPlatform.macOS: _NoTransition(),
          TargetPlatform.windows: _NoTransition(),
          TargetPlatform.android: _NoTransition(),
          TargetPlatform.iOS: _NoTransition(),
          TargetPlatform.fuchsia: _NoTransition(),
        }),
      );
}

class _NoTransition extends PageTransitionsBuilder {
  const _NoTransition();

  @override
  Widget buildTransitions<T>(PageRoute<T> route, BuildContext context, Animation<double> a,
          Animation<double> b, Widget child) =>
      child;
}

/// Text styles derived from the ambient [DefaultTextStyle] and [KitTheme].
class KitText {
  static TextStyle body(BuildContext context) => DefaultTextStyle.of(context).style;

  static TextStyle dim(BuildContext context, {bool small = false}) => body(context).copyWith(
        color: KitTheme.of(context).textDim,
        fontSize: small ? 12 : null,
      );

  static TextStyle heading(BuildContext context) =>
      body(context).copyWith(fontWeight: FontWeight.w600);

  static TextStyle small(BuildContext context, {Color? color}) =>
      body(context).copyWith(fontSize: 12, color: color);
}
