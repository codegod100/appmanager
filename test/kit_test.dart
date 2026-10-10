import 'package:appmanager/ui/kit.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Hosts [child] the way the app does: MaterialApp for the navigator and
/// text editing, the kit theme for everything visible.
Widget host(Widget child) => MaterialApp(
      theme: KitTheme.material(KitColors.light),
      builder: (context, c) => KitTheme(
        colors: KitColors.light,
        child: Material(child: DefaultTextStyle(style: const TextStyle(), child: c!)),
      ),
      home: Align(alignment: Alignment.topLeft, child: child),
    );

/// Kit overlays and dialogs must be fully drawn after a single frame, with
/// no ticker left running an animation.
void expectSettled(WidgetTester tester) {
  expect(tester.binding.transientCallbackCount, 0, reason: 'something is still animating');
}

void main() {
  testWidgets('buttons fire on tap and keyboard, not when disabled', (tester) async {
    var taps = 0;
    await tester.pumpWidget(host(Column(children: [
      KitButton.primary('Go', autofocus: true, onPressed: () => taps++),
      const KitButton('Off', onPressed: null),
    ])));
    await tester.tap(find.text('Go'));
    await tester.pump();
    expect(taps, 1);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(taps, 2);
    await tester.tap(find.text('Off'));
    expect(taps, 2);
    expect(find.byType(InkWell), findsNothing);
    expect(find.byType(InkResponse), findsNothing);
  });

  testWidgets('menu opens and closes in one frame', (tester) async {
    String? picked;
    await tester.pumpWidget(host(KitMenu(
      items: () => [
        KitMenuItem('Run', onSelected: () => picked = 'run'),
        const KitMenuItem('Disabled', onSelected: null),
        const KitMenuDivider(),
        KitMenuItem('Delete…', danger: true, onSelected: () => picked = 'delete'),
      ],
      builder: (context, toggle, _) => KitIconButton(Icons.more_horiz, onPressed: toggle),
    )));

    await tester.tap(find.byIcon(Icons.more_horiz));
    await tester.pump();
    expect(find.text('Run'), findsOneWidget);
    expectSettled(tester);

    await tester.tap(find.text('Disabled'));
    await tester.pump();
    expect(picked, isNull);
    expect(find.text('Run'), findsOneWidget);

    await tester.tap(find.text('Delete…'));
    await tester.pump();
    expect(picked, 'delete');
    expect(find.text('Run'), findsNothing);
    expectSettled(tester);
  });

  testWidgets('menu closes on Escape, outside click and anchor click', (tester) async {
    await tester.pumpWidget(host(SizedBox(
      width: 600,
      height: 400,
      child: KitMenu(
        items: () => [KitMenuItem('Run', onSelected: () {})],
        builder: (context, toggle, _) => KitIconButton(Icons.more_horiz, onPressed: toggle),
      ),
    )));
    Future<void> open() async {
      await tester.tap(find.byIcon(Icons.more_horiz));
      await tester.pump();
      expect(find.text('Run'), findsOneWidget);
    }

    await open();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(find.text('Run'), findsNothing);

    await open();
    await tester.tapAt(const Offset(500, 350));
    await tester.pump();
    expect(find.text('Run'), findsNothing);

    await open();
    await tester.tap(find.byIcon(Icons.more_horiz));
    await tester.pump();
    expect(find.text('Run'), findsNothing);
  });

  testWidgets('arrow keys and Enter pick menu items', (tester) async {
    String? picked;
    await tester.pumpWidget(host(KitMenu(
      items: () => [
        KitMenuItem('One', onSelected: () => picked = 'one'),
        KitMenuItem('Two', onSelected: () => picked = 'two'),
      ],
      builder: (context, toggle, _) => KitIconButton(Icons.more_horiz, onPressed: toggle),
    )));
    await tester.tap(find.byIcon(Icons.more_horiz));
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(picked, 'two');
  });

  testWidgets('select shows the value and changes it', (tester) async {
    var value = 1;
    await tester.pumpWidget(host(StatefulBuilder(
      builder: (context, setState) => KitSelect<int>(
        value: value,
        options: const [(1, 'One'), (2, 'Two')],
        onChanged: (v) => setState(() => value = v),
      ),
    )));
    expect(find.text('One'), findsOneWidget);
    await tester.tap(find.text('One'));
    await tester.pump();
    await tester.tap(find.text('Two'));
    await tester.pump();
    expect(value, 2);
    expect(find.text('One'), findsNothing);
    expect(find.text('Two'), findsOneWidget);
  });

  testWidgets('segmented control switches', (tester) async {
    var page = 'a';
    await tester.pumpWidget(host(StatefulBuilder(
      builder: (context, setState) => KitSegmented<String>(
        segments: const [('a', 'Installed'), ('b', 'Browse')],
        selected: page,
        onChanged: (v) => setState(() => page = v),
      ),
    )));
    await tester.tap(find.text('Browse'));
    await tester.pump();
    expect(page, 'b');
  });

  testWidgets('dialogs appear and close instantly with a result', (tester) async {
    bool? result;
    await tester.pumpWidget(host(Builder(
      builder: (context) => KitButton('Ask', onPressed: () async {
        result = await showKitDialog<bool>(
          context,
          (context) => KitDialog(
            title: 'Delete it?',
            content: const Text('Really?'),
            actions: [
              KitButton('Cancel', onPressed: () => Navigator.pop(context, false)),
              KitButton.danger('Delete', onPressed: () => Navigator.pop(context, true)),
            ],
          ),
        );
      }),
    )));
    await tester.tap(find.text('Ask'));
    await tester.pump();
    expect(find.text('Delete it?'), findsOneWidget);
    expectSettled(tester);
    await tester.tap(find.text('Delete'));
    await tester.pump();
    expect(find.text('Delete it?'), findsNothing);
    expect(result, isTrue);
    expectSettled(tester);
  });

  testWidgets('text field edits and submits', (tester) async {
    final controller = TextEditingController();
    String? submitted;
    await tester.pumpWidget(host(SizedBox(
      width: 200,
      child: KitTextField(controller: controller, hint: 'alias', onSubmitted: (v) => submitted = v),
    )));
    expect(find.text('alias'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'krita');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    expect(submitted, 'krita');
  });

  testWidgets('tooltip shows after hovering, without a fade', (tester) async {
    await tester.pumpWidget(host(const KitTooltip(message: 'Hello', child: Text('Target'))));
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(tester.getCenter(find.text('Target')));
    await tester.pump();
    expect(find.text('Hello'), findsNothing);
    await tester.pump(KitTooltip.delay);
    expect(find.text('Hello'), findsOneWidget);
    expectSettled(tester);
    await mouse.moveTo(const Offset(700, 500));
    await tester.pump();
    expect(find.text('Hello'), findsNothing);
    await mouse.removePointer();
  });
}
