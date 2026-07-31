import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm2/src/ui/custom_text_edit.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('resets its local editing state after committed input', (
    tester,
  ) async {
    final key = GlobalKey<CustomTextEditState>();
    final inserted = <String>[];
    final focusNode = FocusNode();
    addTearDown(focusNode.dispose);

    await tester.pumpWidget(MaterialApp(
      home: CustomTextEdit(
        key: key,
        autofocus: true,
        focusNode: focusNode,
        onInsert: inserted.add,
        onDelete: () {},
        onComposing: (_) {},
        onAction: (_) {},
        onKeyEvent: (node, event) => KeyEventResult.ignored,
        child: const SizedBox.expand(),
      ),
    ));
    await tester.pump();

    binding.testTextInput.enterText('한글');
    await binding.idle();

    expect(inserted, ['한글']);
    expect(
      key.currentState?.currentTextEditingValue,
      const TextEditingValue(
        selection: TextSelection.collapsed(offset: 0),
      ),
    );
  });

  testWidgets('ignores late editing updates after the connection closes', (
    tester,
  ) async {
    final key = GlobalKey<CustomTextEditState>();
    final inserted = <String>[];
    String? composingText;
    final focusNode = FocusNode();
    addTearDown(focusNode.dispose);

    await tester.pumpWidget(MaterialApp(
      home: CustomTextEdit(
        key: key,
        autofocus: true,
        focusNode: focusNode,
        onInsert: inserted.add,
        onDelete: () {},
        onComposing: (text) => composingText = text,
        onAction: (_) {},
        onKeyEvent: (node, event) => KeyEventResult.ignored,
        child: const SizedBox.expand(),
      ),
    ));
    await tester.pump();

    binding.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: 'ㅎ',
        selection: TextSelection.collapsed(offset: 1),
        composing: TextRange(start: 0, end: 1),
      ),
    );
    await binding.idle();
    expect(composingText, 'ㅎ');

    key.currentState?.closeKeyboard();
    key.currentState?.updateEditingValue(
      const TextEditingValue(
        text: '한',
        selection: TextSelection.collapsed(offset: 1),
      ),
    );

    expect(inserted, isEmpty);
    expect(composingText, isNull);
    expect(
      key.currentState?.currentTextEditingValue,
      const TextEditingValue(
        selection: TextSelection.collapsed(offset: 0),
      ),
    );
  });
}
