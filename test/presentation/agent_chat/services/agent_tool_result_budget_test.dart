import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:nai_launcher/core/agent/agent_types.dart';
import 'package:nai_launcher/presentation/agent_chat/services/agent_tool_result_budget.dart';

const _image = ToolResultImageContent(
  ImageContent(
    source: ImageSource.base64(mimeType: 'image/png', base64Data: 'AAAA'),
  ),
);

ToolResultMessage _message(List<ToolResultContent> content) =>
    ToolResultMessage(
      toolCallId: 'call-1',
      toolName: 'read',
      content: content,
      details: const {'ok': true},
    );

void main() {
  group('budgetToolResultContent', () {
    test('truncates oversized text with a clear marker', () {
      final content = budgetToolResultContent([
        ToolResultTextContent('x' * 40000),
      ]);
      final text = (content.single as ToolResultTextContent).text;

      expect(text.length, maxToolResultTextChars);
      expect(text, contains('characters omitted'));
    });

    test('keeps oversized JSON valid and explains the truncation', () {
      final original = jsonEncode({
        'items': List.generate(2000, (index) => 'item-$index-${'x' * 20}'),
      });

      final content = budgetToolResultContent([
        ToolResultTextContent(original),
      ]);
      final decoded =
          jsonDecode((content.single as ToolResultTextContent).text)
              as Map<String, dynamic>;

      expect(decoded['truncated'], isTrue);
      expect(decoded['originalChars'], original.length);
      expect(decoded['preview'], isA<String>());
      expect(decoded['preview'] as String, isNotEmpty);
    });

    test('caps images per result and reports the omitted count', () {
      final content = budgetToolResultContent([
        const ToolResultTextContent('images'),
        _image,
        _image,
        _image,
      ]);

      expect(content.whereType<ToolResultImageContent>().length, 2);
      expect(
        content.whereType<ToolResultTextContent>().map((item) => item.text),
        contains(contains('1 image(s) omitted')),
      );
    });

    test('returns the original list when nothing needs trimming', () {
      final original = <ToolResultContent>[
        const ToolResultTextContent('small'),
        _image,
      ];

      expect(identical(budgetToolResultContent(original), original), isTrue);
    });
  });

  group('budgetToolResultMessages', () {
    test('preserves message metadata and leaves small messages untouched', () {
      final small = _message([const ToolResultTextContent('small')]);
      final large = _message([ToolResultTextContent('x' * 40000)]);

      final budgeted = budgetToolResultMessages([small, large]);

      expect(identical(budgeted[0], small), isTrue);
      final rewritten = budgeted[1] as ToolResultMessage;
      expect(identical(rewritten, large), isFalse);
      expect(rewritten.toolCallId, 'call-1');
      expect(rewritten.toolName, 'read');
      expect(rewritten.details, {'ok': true});
      expect(
        (rewritten.content.single as ToolResultTextContent).text.length,
        maxToolResultTextChars,
      );
    });

    test('returns the original list when every result fits', () {
      final messages = <AgentMessage>[
        UserMessage.text('hello'),
        _message([const ToolResultTextContent('small')]),
      ];

      expect(identical(budgetToolResultMessages(messages), messages), isTrue);
    });
  });
}
