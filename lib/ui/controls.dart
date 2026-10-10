/// Flat controls: buttons, segmented tabs, text fields, panels and progress
/// bars. Hover and press change colour on the spot; nothing ripples, fades
/// or slides.
library;

import 'package:flutter/material.dart'
    show CircularProgressIndicator, InputBorder, InputDecoration, TextField;
import 'package:flutter/widgets.dart';

import 'theme.dart';
import 'tooltip.dart';

/// Interaction state a [Pressable] hands its builder.
class PressState {
  final bool hovered;
  final bool pressed;
  final bool focused;
  final bool enabled;
  const PressState({
    this.hovered = false,
    this.pressed = false,
    this.focused = false,
    this.enabled = true,
  });
}

/// The kit's single interaction primitive: mouse, tap and keyboard
/// (Enter/Space) activation with hover, press and focus state, and no
/// visual effect of its own.
class Pressable extends StatefulWidget {
  final VoidCallback? onPressed;
  final Widget Function(BuildContext context, PressState state) builder;
  final bool autofocus;
  final FocusNode? focusNode;
  final MouseCursor? cursor;

  const Pressable({
    super.key,
    required this.onPressed,
    required this.builder,
    this.autofocus = false,
    this.focusNode,
    this.cursor,
  });

  @override
  State<Pressable> createState() => _PressableState();
}

class _PressableState extends State<Pressable> {
  bool _hovered = false;
  bool _pressed = false;
  bool _focused = false;

  bool get _enabled => widget.onPressed != null;

  @override
  void didUpdateWidget(Pressable old) {
    super.didUpdateWidget(old);
    if (!_enabled) _pressed = false;
  }

  void _activate() {
    if (_enabled) widget.onPressed!();
  }

  @override
  Widget build(BuildContext context) {
    return FocusableActionDetector(
      enabled: _enabled,
      autofocus: widget.autofocus,
      focusNode: widget.focusNode,
      mouseCursor: _enabled ? (widget.cursor ?? SystemMouseCursors.click) : MouseCursor.defer,
      onShowHoverHighlight: (v) => setState(() => _hovered = v),
      onShowFocusHighlight: (v) => setState(() => _focused = v),
      actions: {
        ActivateIntent: CallbackAction<ActivateIntent>(onInvoke: (_) => _activate()),
        ButtonActivateIntent: CallbackAction<ButtonActivateIntent>(onInvoke: (_) => _activate()),
      },
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: _enabled ? (_) => setState(() => _pressed = true) : null,
        onTapCancel: _enabled ? () => setState(() => _pressed = false) : null,
        onTapUp: _enabled ? (_) => setState(() => _pressed = false) : null,
        onTap: _enabled ? _activate : null,
        child: widget.builder(
          context,
          PressState(
            hovered: _hovered && _enabled,
            pressed: _pressed && _enabled,
            focused: _focused && _enabled,
            enabled: _enabled,
          ),
        ),
      ),
    );
  }
}

enum KitButtonKind { primary, secondary, ghost, danger }

class KitButton extends StatelessWidget {
  final String label;
  final VoidCallback? onPressed;
  final KitButtonKind kind;
  final IconData? icon;
  final String? tooltip;
  final bool autofocus;

  const KitButton(
    this.label, {
    super.key,
    required this.onPressed,
    this.kind = KitButtonKind.secondary,
    this.icon,
    this.tooltip,
    this.autofocus = false,
  });

  const KitButton.primary(this.label,
      {super.key, required this.onPressed, this.icon, this.tooltip, this.autofocus = false})
      : kind = KitButtonKind.primary;

  const KitButton.ghost(this.label,
      {super.key, required this.onPressed, this.icon, this.tooltip, this.autofocus = false})
      : kind = KitButtonKind.ghost;

  const KitButton.danger(this.label,
      {super.key, required this.onPressed, this.icon, this.tooltip, this.autofocus = false})
      : kind = KitButtonKind.danger;

  @override
  Widget build(BuildContext context) {
    final c = KitTheme.of(context);
    final button = Pressable(
      onPressed: onPressed,
      autofocus: autofocus,
      builder: (context, s) {
        late Color bg, fg, border;
        switch (kind) {
          case KitButtonKind.primary:
            bg = s.pressed ? c.accentPressed : (s.hovered ? c.accentHover : c.accent);
            fg = c.onAccent;
            border = bg;
          case KitButtonKind.danger:
            bg = s.pressed || s.hovered ? c.dangerHover : c.danger;
            fg = c.onDanger;
            border = bg;
          case KitButtonKind.secondary:
            bg = s.pressed ? c.pressed : (s.hovered ? c.hover : c.surface);
            fg = c.text;
            border = c.border;
          case KitButtonKind.ghost:
            bg = s.pressed ? c.pressed : (s.hovered ? c.hover : const Color(0x00000000));
            fg = c.accent;
            border = bg;
        }
        if (!s.enabled) {
          bg = kind == KitButtonKind.ghost ? const Color(0x00000000) : c.hover;
          fg = c.textDim;
          border = kind == KitButtonKind.secondary ? c.border : bg;
        }
        if (s.focused) border = c.focus;
        return Container(
          height: kitControlHeight,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(kitRadius),
            border: Border.all(color: border, width: s.focused ? 2 : 1),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            if (icon != null) ...[
              Icon(icon, size: 16, color: fg),
              const SizedBox(width: 6),
            ],
            Text(label,
                style: KitText.body(context).copyWith(color: fg, fontWeight: FontWeight.w500)),
          ]),
        );
      },
    );
    return tooltip == null ? button : KitTooltip(message: tooltip!, child: button);
  }
}

class KitIconButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback? onPressed;
  final String? tooltip;
  final double size;
  final Color? color;

  const KitIconButton(
    this.icon, {
    super.key,
    required this.onPressed,
    this.tooltip,
    this.size = 18,
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    final c = KitTheme.of(context);
    final button = Pressable(
      onPressed: onPressed,
      builder: (context, s) => Container(
        width: kitControlHeight,
        height: kitControlHeight,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: s.pressed ? c.pressed : (s.hovered ? c.hover : const Color(0x00000000)),
          borderRadius: BorderRadius.circular(kitRadius),
          border: s.focused ? Border.all(color: c.focus, width: 2) : null,
        ),
        child: Icon(icon, size: size, color: s.enabled ? (color ?? c.text) : c.borderStrong),
      ),
    );
    return tooltip == null ? button : KitTooltip(message: tooltip!, child: button);
  }
}

/// A row of joined toggle buttons, one of which is selected.
class KitSegmented<T> extends StatelessWidget {
  final List<(T, String)> segments;
  final T selected;
  final ValueChanged<T> onChanged;

  const KitSegmented({
    super.key,
    required this.segments,
    required this.selected,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final c = KitTheme.of(context);
    return Container(
      height: kitControlHeight,
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        color: c.hover,
        borderRadius: BorderRadius.circular(kitRadius),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        for (final (value, label) in segments)
          Pressable(
            onPressed: () => onChanged(value),
            builder: (context, s) {
              final on = value == selected;
              return Container(
                padding: const EdgeInsets.symmetric(horizontal: 14),
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: on ? c.surface : (s.hovered ? c.pressed : const Color(0x00000000)),
                  borderRadius: BorderRadius.circular(kitRadius - 2),
                  border: s.focused ? Border.all(color: c.focus, width: 2) : null,
                ),
                child: Text(label,
                    style: KitText.body(context).copyWith(
                      fontWeight: on ? FontWeight.w600 : FontWeight.w500,
                      color: on ? c.text : c.textDim,
                    )),
              );
            },
          ),
      ]),
    );
  }
}

/// A single-line text field with a flat border that changes colour on
/// focus. Wraps Material's [TextField] for editing, selection and IME, but
/// draws nothing of Material's.
class KitTextField extends StatefulWidget {
  final TextEditingController controller;
  final String? hint;
  final IconData? prefixIcon;
  final bool autofocus;
  final bool error;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;

  const KitTextField({
    super.key,
    required this.controller,
    this.hint,
    this.prefixIcon,
    this.autofocus = false,
    this.error = false,
    this.onChanged,
    this.onSubmitted,
  });

  @override
  State<KitTextField> createState() => _KitTextFieldState();
}

class _KitTextFieldState extends State<KitTextField> {
  final _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    _focus.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = KitTheme.of(context);
    final focused = _focus.hasFocus;
    final border = widget.error ? c.danger : (focused ? c.focus : c.border);
    return GestureDetector(
      onTap: _focus.requestFocus,
      child: MouseRegion(
        cursor: SystemMouseCursors.text,
        child: Container(
          height: kitControlHeight + 2,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          decoration: BoxDecoration(
            color: c.surface,
            borderRadius: BorderRadius.circular(kitRadius),
            border: Border.all(color: border, width: focused || widget.error ? 2 : 1),
          ),
          child: Row(children: [
            if (widget.prefixIcon != null) ...[
              Icon(widget.prefixIcon, size: 16, color: c.textDim),
              const SizedBox(width: 6),
            ],
            Expanded(
              child: TextField(
                controller: widget.controller,
                focusNode: _focus,
                autofocus: widget.autofocus,
                style: KitText.body(context),
                cursorColor: c.accent,
                cursorWidth: 1.5,
                decoration: InputDecoration(
                  isCollapsed: true,
                  border: InputBorder.none,
                  hintText: widget.hint,
                  hintStyle: KitText.body(context).copyWith(color: c.textDim),
                  hintFadeDuration: Duration.zero,
                ),
                onChanged: widget.onChanged,
                onSubmitted: widget.onSubmitted,
              ),
            ),
          ]),
        ),
      ),
    );
  }
}

/// A bordered surface for grouping content.
class KitPanel extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  final EdgeInsetsGeometry margin;

  const KitPanel({
    super.key,
    required this.child,
    this.padding = EdgeInsets.zero,
    this.margin = EdgeInsets.zero,
  });

  @override
  Widget build(BuildContext context) {
    final c = KitTheme.of(context);
    return Container(
      margin: margin,
      padding: padding,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(kitRadius + 2),
        border: Border.all(color: c.border),
      ),
      child: child,
    );
  }
}

class KitDivider extends StatelessWidget {
  const KitDivider({super.key});

  @override
  Widget build(BuildContext context) => Container(height: 1, color: KitTheme.of(context).border);
}

/// A determinate progress bar that jumps straight to [value].
class KitProgressBar extends StatelessWidget {
  final double value;
  const KitProgressBar({super.key, required this.value});

  @override
  Widget build(BuildContext context) {
    final c = KitTheme.of(context);
    return Container(
      height: 4,
      decoration: BoxDecoration(color: c.hover, borderRadius: BorderRadius.circular(2)),
      alignment: Alignment.centerLeft,
      child: FractionallySizedBox(
        widthFactor: value.clamp(0.0, 1.0),
        child: Container(
          decoration: BoxDecoration(color: c.accent, borderRadius: BorderRadius.circular(2)),
        ),
      ),
    );
  }
}

/// An indeterminate spinner, for work with no known length.
class KitSpinner extends StatelessWidget {
  final double size;
  const KitSpinner({super.key, this.size = 16});

  @override
  Widget build(BuildContext context) => SizedBox(
        width: size,
        height: size,
        child: CircularProgressIndicator(strokeWidth: 2, color: KitTheme.of(context).accent),
      );
}
