import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nai_launcher/core/storage/local_storage_service.dart';
import 'package:nai_launcher/l10n/app_localizations.dart';
import 'package:nai_launcher/presentation/widgets/prompt/unified/unified_prompt_config.dart';
import 'package:nai_launcher/presentation/widgets/prompt/unified/unified_prompt_input.dart';

import '../../../../helpers/memory_local_storage.dart';

void main() {
  Future<void> pressToggleShortcut(WidgetTester tester) async {
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.slash);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
  }

  Future<TextEditingController> pumpPrompt(WidgetTester tester) async {
    final source = TextEditingController(text: 'cat, dog, bird');
    final focus = FocusNode();
    addTearDown(source.dispose);
    addTearDown(focus.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          localStorageServiceProvider.overrideWith(
            (ref) => MemoryLocalStorage(),
          ),
        ],
        child: MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: SizedBox(
              height: 300,
              child: UnifiedPromptInput(
                controller: source,
                focusNode: focus,
                enableAssistant: false,
                expands: true,
                config: const UnifiedPromptConfig(
                  enableTagMode: true,
                  enableAutocomplete: false,
                  enableSyntaxHighlight: false,
                  enableAutoFormat: false,
                ),
              ),
            ),
          ),
        ),
      ),
    );
    focus.requestFocus();
    await tester.pumpAndSettle();
    return source;
  }

  testWidgets('Ctrl+/ 禁用并恢复选中的提示词片段', (tester) async {
    final source = await pumpPrompt(tester);
    final editable = tester.state<EditableTextState>(find.byType(EditableText));
    editable.widget.controller.selection = const TextSelection(
      baseOffset: 0,
      extentOffset: 8,
    );
    await tester.pumpAndSettle();

    const disabled = '/*disabled:cat*/, /*disabled:dog*/, bird';
    await pressToggleShortcut(tester);
    expect(source.text, disabled);

    // 再次按下恢复启用，选区保留以便连续切换。
    await pressToggleShortcut(tester);
    expect(source.text, 'cat, dog, bird');
    expect(
      editable.widget.controller.selection,
      const TextSelection(baseOffset: 0, extentOffset: 8),
    );

    // 没有选中片段时按键不改动文本。
    editable.widget.controller.selection = const TextSelection.collapsed(
      offset: 0,
    );
    await tester.pumpAndSettle();
    await pressToggleShortcut(tester);
    expect(source.text, 'cat, dog, bird');
    expect(tester.takeException(), isNull);
  });
}
