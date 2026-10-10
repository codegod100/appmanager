/// Modal dialogs that appear and close without any transition.
library;

import 'package:flutter/widgets.dart';

import 'theme.dart';

/// Shows [builder] as a modal dialog over a dimmed window. Clicking outside
/// or pressing Escape closes it with a null result.
Future<T?> showKitDialog<T>(BuildContext context, WidgetBuilder builder) {
  return Navigator.of(context).push<T>(PageRouteBuilder<T>(
    opaque: false,
    barrierDismissible: true,
    barrierLabel: 'Close',
    barrierColor: const Color(0x66000000),
    transitionDuration: Duration.zero,
    reverseTransitionDuration: Duration.zero,
    pageBuilder: (context, _, __) => builder(context),
  ));
}

class KitDialog extends StatelessWidget {
  final String title;
  final Widget content;
  final List<Widget> actions;
  final double width;

  const KitDialog({
    super.key,
    required this.title,
    required this.content,
    this.actions = const [],
    this.width = 420,
  });

  @override
  Widget build(BuildContext context) {
    final c = KitTheme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Container(
          width: width + 40,
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: c.surface,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: c.border),
            boxShadow: [BoxShadow(color: c.shadow, blurRadius: 24, offset: const Offset(0, 8))],
          ),
          child: FocusScope(
            autofocus: true,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(title, style: KitText.heading(context).copyWith(fontSize: 16)),
                const SizedBox(height: 12),
                Flexible(child: SingleChildScrollView(child: content)),
                if (actions.isNotEmpty) ...[
                  const SizedBox(height: 20),
                  Wrap(
                    alignment: WrapAlignment.end,
                    spacing: 8,
                    runSpacing: 8,
                    children: actions,
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
