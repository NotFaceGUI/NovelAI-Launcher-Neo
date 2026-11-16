import 'package:flutter_test/flutter_test.dart';
import 'package:nai_launcher/core/agent/agent_types.dart';
import 'package:nai_launcher/presentation/agent_chat/services/agent_context_pruner.dart';

List<Message> _messages(int count, {bool withImage = false}) => [
  UserMessage.text('hello'),
  for (var index = 0; index < count; index++)
    ToolResultMessage(
      toolCallId: 'call-$index',
      toolName: 'read',
      content: [
        ToolResultTextContent('x' * 4000),
        if (withImage)
          const ToolResultImageContent(
            ImageContent(
              source: ImageSource.base64(
                mimeType: 'image/png',
                base64Data: 'AAAA',
              ),
            ),
          ),
      ],
    ),
];

void main() {
  group('AgentContextPruner', () {
    test('keeps recent results and elides older ones', () {
      final pruner = AgentContextPruner();
      final messages = _messages(6);

      final pruned = pruner.prune(
        messages,
        contextWindow: 10000,
        keepRecentTokens: 2000,
        keepRecentResults: 3,
        requestTokens: 7000,
      );

      expect(pruned.length, messages.length);
      expect((pruned[1] as ToolResultMessage).text, contains('Elided'));
      expect((pruned[2] as ToolResultMessage).text, contains('Elided'));
      expect((pruned[3] as ToolResultMessage).text, contains('Elided'));
      for (var index = 4; index < pruned.length; index++) {
        expect(
          (pruned[index] as ToolResultMessage).text,
          isNot(contains('Elided')),
        );
      }
    });

    test('drops images from elided results only', () {
      final pruner = AgentContextPruner();
      final messages = _messages(6, withImage: true);

      final pruned = pruner.prune(
        messages,
        contextWindow: 10000,
        keepRecentTokens: 2000,
        keepRecentResults: 3,
        requestTokens: 7000,
      );

      for (var index = 1; index <= 3; index++) {
        expect(
          (pruned[index] as ToolResultMessage).content
              .whereType<ToolResultImageContent>(),
          isEmpty,
        );
      }
      for (var index = 4; index < pruned.length; index++) {
        expect(
          (pruned[index] as ToolResultMessage).content
              .whereType<ToolResultImageContent>(),
          isNotEmpty,
        );
      }
    });

    test('reuses the boundary until the next threshold', () {
      final pruner = AgentContextPruner();
      final messages = _messages(6);
      final first = pruner.prune(
        messages,
        contextWindow: 10000,
        keepRecentTokens: 2000,
        keepRecentResults: 3,
        requestTokens: 7000,
      );
      final second = pruner.prune(
        messages,
        contextWindow: 10000,
        keepRecentTokens: 2000,
        keepRecentResults: 3,
        requestTokens: 7500,
      );

      expect(
        (first[2] as ToolResultMessage).text,
        (second[2] as ToolResultMessage).text,
      );
      expect((second[3] as ToolResultMessage).text, contains('Elided'));
      expect((second[4] as ToolResultMessage).text, isNot(contains('Elided')));
    });

    test('moves the boundary when the context crosses the next threshold', () {
      final pruner = AgentContextPruner();
      final messages = _messages(7);
      pruner.prune(
        messages,
        contextWindow: 10000,
        keepRecentTokens: 2000,
        keepRecentResults: 3,
        requestTokens: 7000,
      );

      final moved = pruner.prune(
        messages,
        contextWindow: 10000,
        keepRecentTokens: 2000,
        keepRecentResults: 3,
        requestTokens: 9000,
      );

      expect((moved[4] as ToolResultMessage).text, contains('Elided'));
      expect((moved[5] as ToolResultMessage).text, isNot(contains('Elided')));
    });

    test('keeps the complete latest assistant tool batch', () {
      final pruner = AgentContextPruner();
      final messages = <Message>[
        UserMessage.text('hello'),
        for (var index = 0; index < 4; index++)
          ToolResultMessage(
            toolCallId: 'old-$index',
            toolName: 'read',
            content: [ToolResultTextContent('x' * 4000)],
          ),
        AssistantMessage(
          content: const [
            ToolCallContent(id: 'call-4', name: 'read', arguments: {}),
            ToolCallContent(id: 'call-5', name: 'read', arguments: {}),
          ],
          stopReason: StopReason.toolUse,
        ),
        ToolResultMessage(
          toolCallId: 'call-4',
          toolName: 'read',
          content: [ToolResultTextContent('x' * 4000)],
        ),
        ToolResultMessage(
          toolCallId: 'call-5',
          toolName: 'read',
          content: [ToolResultTextContent('x' * 4000)],
        ),
      ];

      final pruned = pruner.prune(
        messages,
        contextWindow: 10000,
        keepRecentTokens: 100,
        keepRecentResults: 1,
        requestTokens: 7000,
      );

      expect((pruned[4] as ToolResultMessage).text, contains('Elided'));
      expect((pruned[6] as ToolResultMessage).text, isNot(contains('Elided')));
      expect((pruned[7] as ToolResultMessage).text, isNot(contains('Elided')));
    });

    test('keeps a short error prefix instead of dropping it', () {
      final pruner = AgentContextPruner();
      final messages = <Message>[
        UserMessage.text('hello'),
        ToolResultMessage(
          toolCallId: 'call-0',
          toolName: 'read',
          isError: true,
          content: [ToolResultTextContent('e' * 1000)],
        ),
        for (var index = 1; index < 6; index++)
          ToolResultMessage(
            toolCallId: 'call-$index',
            toolName: 'read',
            content: [ToolResultTextContent('x' * 4000)],
          ),
      ];

      final pruned = pruner.prune(
        messages,
        contextWindow: 10000,
        keepRecentTokens: 2000,
        keepRecentResults: 3,
        requestTokens: 7000,
      );

      final error = (pruned[1] as ToolResultMessage).text;
      expect(error.length, lessThan(600));
      expect(error, contains('Error truncated'));
    });

    test('does nothing below the trigger or after reset', () {
      final pruner = AgentContextPruner();
      final messages = _messages(6);

      final untouched = pruner.prune(
        messages,
        contextWindow: 10000,
        keepRecentTokens: 2000,
        keepRecentResults: 3,
        requestTokens: 1000,
      );
      expect(identical(untouched, messages), isTrue);

      pruner.prune(
        messages,
        contextWindow: 10000,
        keepRecentTokens: 2000,
        keepRecentResults: 3,
        requestTokens: 7000,
      );
      pruner.reset();
      final afterReset = pruner.prune(
        messages,
        contextWindow: 10000,
        keepRecentTokens: 2000,
        keepRecentResults: 3,
        requestTokens: 1000,
      );
      expect(identical(afterReset, messages), isTrue);
    });
  });
}
