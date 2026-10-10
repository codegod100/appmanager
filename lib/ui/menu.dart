/// Popup menus and a select box built on them. Menus open and close in a
/// single frame; arrow keys move between items, Enter picks one and Escape
/// or a click outside closes the menu.
library;

import 'package:flutter/material.dart' show Icons;
import 'package:flutter/widgets.dart';

import 'controls.dart';
import 'theme.dart';
import 'tooltip.dart';

sealed class KitMenuEntry {
  const KitMenuEntry();
}

class KitMenuItem extends KitMenuEntry {
  final String label;
  final VoidCallback? onSelected;
  final bool danger;
  final bool checked;
  const KitMenuItem(this.label,
      {required this.onSelected, this.danger = false, this.checked = false});
}

class KitMenuDivider extends KitMenuEntry {
  const KitMenuDivider();
}

/// Wraps an anchor that opens a menu of [items] under itself. [builder]
/// receives a callback that toggles the menu.
class KitMenu extends StatefulWidget {
  final List<KitMenuEntry> Function() items;
  final Widget Function(BuildContext context, VoidCallback toggle, bool open) builder;
  final double minWidth;

  const KitMenu({super.key, required this.items, required this.builder, this.minWidth = 160});

  @override
  State<KitMenu> createState() => _KitMenuState();
}

class _KitMenuState extends State<KitMenu> {
  final _portal = OverlayPortalController();

  void _toggle() => setState(_portal.isShowing ? _portal.hide : _portal.show);

  void _close() {
    if (_portal.isShowing) setState(_portal.hide);
  }

  @override
  Widget build(BuildContext context) {
    return TapRegion(
      groupId: this,
      child: OverlayPortal(
        controller: _portal,
        overlayChildBuilder: (_) => CustomSingleChildLayout(
          delegate: AnchoredLayout(anchorRect(context)),
          child: TapRegion(
            groupId: this,
            onTapOutside: (_) => _close(),
            child: _MenuPanel(
              entries: widget.items(),
              minWidth: widget.minWidth,
              onClose: _close,
            ),
          ),
        ),
        child: widget.builder(context, _toggle, _portal.isShowing),
      ),
    );
  }
}

class _MenuPanel extends StatefulWidget {
  final List<KitMenuEntry> entries;
  final double minWidth;
  final VoidCallback onClose;

  const _MenuPanel({required this.entries, required this.minWidth, required this.onClose});

  @override
  State<_MenuPanel> createState() => _MenuPanelState();
}

class _MenuPanelState extends State<_MenuPanel> {
  /// Whether the keyboard, rather than the mouse, was used last: then the
  /// focused item is highlighted, otherwise the one under the pointer.
  bool _keyboard = false;

  @override
  Widget build(BuildContext context) {
    final c = KitTheme.of(context);
    final entries = widget.entries;
    final firstEnabled = entries.indexWhere((e) => e is KitMenuItem && e.onSelected != null);
    return Actions(
      actions: {
        DismissIntent: CallbackAction<DismissIntent>(onInvoke: (_) => widget.onClose()),
      },
      child: FocusScope(
        autofocus: true,
        onKeyEvent: (_, __) {
          if (!_keyboard) setState(() => _keyboard = true);
          return KeyEventResult.ignored;
        },
        child: MouseRegion(
          onHover: (_) {
            if (_keyboard) setState(() => _keyboard = false);
          },
          child: ConstrainedBox(
            constraints: BoxConstraints(minWidth: widget.minWidth),
            child: IntrinsicWidth(
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 4),
                decoration: BoxDecoration(
                  color: c.surface,
                  borderRadius: BorderRadius.circular(kitRadius + 2),
                  border: Border.all(color: c.border),
                  boxShadow: [
                    BoxShadow(color: c.shadow, blurRadius: 12, offset: const Offset(0, 4))
                  ],
                ),
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (final (i, e) in entries.indexed)
                        switch (e) {
                          KitMenuDivider() => Padding(
                              padding: const EdgeInsets.symmetric(vertical: 4),
                              child: Container(height: 1, color: c.border),
                            ),
                          KitMenuItem() => _MenuRow(
                              item: e,
                              autofocus: i == firstEnabled,
                              keyboard: _keyboard,
                              onClose: widget.onClose,
                            ),
                        },
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _MenuRow extends StatefulWidget {
  final KitMenuItem item;
  final bool autofocus;
  final bool keyboard;
  final VoidCallback onClose;

  const _MenuRow({
    required this.item,
    required this.autofocus,
    required this.keyboard,
    required this.onClose,
  });

  @override
  State<_MenuRow> createState() => _MenuRowState();
}

class _MenuRowState extends State<_MenuRow> {
  final _focus = FocusNode();

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = KitTheme.of(context);
    final item = widget.item;
    final onClose = widget.onClose;
    return MouseRegion(
      // Keyboard navigation carries on from wherever the pointer was.
      onEnter: (_) {
        if (item.onSelected != null) _focus.requestFocus();
      },
      child: Pressable(
        focusNode: _focus,
        autofocus: widget.autofocus,
        onPressed: item.onSelected == null
            ? null
            : () {
                onClose();
                item.onSelected!();
              },
        builder: (context, s) {
          final active = widget.keyboard ? s.focused : s.hovered;
          final fg = !s.enabled
              ? c.borderStrong
              : item.danger
                  ? (active ? c.onDanger : c.danger)
                  : (active ? c.onAccent : c.text);
          return Container(
            height: 28,
            margin: const EdgeInsets.symmetric(horizontal: 4),
            padding: const EdgeInsets.symmetric(horizontal: 8),
            decoration: BoxDecoration(
              color: active ? (item.danger ? c.danger : c.accent) : const Color(0x00000000),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Row(children: [
              SizedBox(
                width: 20,
                child: item.checked ? Icon(Icons.check, size: 14, color: fg) : null,
              ),
              Expanded(child: Text(item.label, style: KitText.body(context).copyWith(color: fg))),
            ]),
          );
        },
      ),
    );
  }
}

/// A button showing the current choice that opens a menu of [options].
class KitSelect<T> extends StatelessWidget {
  final T value;
  final List<(T, String)> options;
  final ValueChanged<T> onChanged;

  const KitSelect({
    super.key,
    required this.value,
    required this.options,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final c = KitTheme.of(context);
    final current = options.firstWhere((o) => o.$1 == value, orElse: () => options.first).$2;
    return KitMenu(
      items: () => [
        for (final (v, label) in options)
          KitMenuItem(label, checked: v == value, onSelected: () => onChanged(v)),
      ],
      builder: (context, toggle, open) => Pressable(
        onPressed: toggle,
        builder: (context, s) => Container(
          height: kitControlHeight,
          padding: const EdgeInsets.only(left: 10, right: 6),
          decoration: BoxDecoration(
            color: s.pressed || open ? c.pressed : (s.hovered ? c.hover : c.surface),
            borderRadius: BorderRadius.circular(kitRadius),
            border: Border.all(color: s.focused ? c.focus : c.border, width: s.focused ? 2 : 1),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Text(current, style: KitText.body(context)),
            const SizedBox(width: 6),
            Icon(Icons.expand_more, size: 16, color: c.textDim),
          ]),
        ),
      ),
    );
  }
}
