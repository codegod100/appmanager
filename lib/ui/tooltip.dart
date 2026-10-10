/// Overlays anchored to a widget: the positioning they share, and the
/// tooltip. Everything appears and disappears instantly.
library;

import 'dart:async';

import 'package:flutter/widgets.dart';

import 'theme.dart';

/// The rectangle [anchor] occupies in the coordinate space of its [Overlay].
Rect anchorRect(BuildContext anchor) {
  final box = anchor.findRenderObject() as RenderBox?;
  final overlay = Overlay.of(anchor).context.findRenderObject() as RenderBox?;
  if (box == null || !box.hasSize || overlay == null) return Rect.zero;
  final topLeft = box.localToGlobal(Offset.zero, ancestor: overlay);
  return topLeft & box.size;
}

/// Places a child below [anchor] (or above it when there is no room below),
/// aligned to its left edge or centred on it, and kept inside the overlay.
class AnchoredLayout extends SingleChildLayoutDelegate {
  final Rect anchor;
  final bool centered;
  final double gap;
  const AnchoredLayout(this.anchor, {this.centered = false, this.gap = 4});

  static const _margin = 8.0;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) =>
      BoxConstraints.loose(constraints.biggest).deflate(const EdgeInsets.all(_margin));

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    var x = centered ? anchor.center.dx - childSize.width / 2 : anchor.left;
    x = x.clamp(_margin, (size.width - childSize.width - _margin).clamp(_margin, double.infinity));
    var y = anchor.bottom + gap;
    if (y + childSize.height > size.height - _margin &&
        anchor.top - gap - childSize.height >= _margin) {
      y = anchor.top - gap - childSize.height;
    }
    y = y.clamp(
        _margin, (size.height - childSize.height - _margin).clamp(_margin, double.infinity));
    return Offset(x, y);
  }

  @override
  bool shouldRelayout(AnchoredLayout old) =>
      old.anchor != anchor || old.centered != centered || old.gap != gap;
}

/// Shows [message] under the pointer's target after a short hover, with no
/// fade.
class KitTooltip extends StatefulWidget {
  final String message;
  final Widget child;
  const KitTooltip({super.key, required this.message, required this.child});

  static const delay = Duration(milliseconds: 600);

  @override
  State<KitTooltip> createState() => _KitTooltipState();
}

class _KitTooltipState extends State<KitTooltip> {
  final _portal = OverlayPortalController();
  Timer? _timer;

  void _enter() {
    _timer?.cancel();
    _timer = Timer(KitTooltip.delay, () {
      if (mounted && widget.message.isNotEmpty) _portal.show();
    });
  }

  void _exit() {
    _timer?.cancel();
    if (_portal.isShowing) _portal.hide();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = KitTheme.of(context);
    return MouseRegion(
      onEnter: (_) => _enter(),
      onExit: (_) => _exit(),
      child: Listener(
        onPointerDown: (_) => _exit(),
        child: OverlayPortal(
          controller: _portal,
          overlayChildBuilder: (overlayContext) => IgnorePointer(
            child: CustomSingleChildLayout(
              delegate: AnchoredLayout(anchorRect(context), centered: true),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 420),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                  decoration: BoxDecoration(
                    color: c.text,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    widget.message,
                    style: KitText.body(context).copyWith(color: c.background, fontSize: 12),
                  ),
                ),
              ),
            ),
          ),
          child: widget.child,
        ),
      ),
    );
  }
}
