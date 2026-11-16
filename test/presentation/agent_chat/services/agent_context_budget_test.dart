import 'package:flutter_test/flutter_test.dart';
import 'package:nai_launcher/core/agent/agent_types.dart';
import 'package:nai_launcher/core/agent/harness/harness_messages.dart';
import 'package:nai_launcher/presentation/agent_chat/services/agent_context_budget.dart';

void main() {
  group('AgentContextBudget', () {
    test('adds system and tool overhead when there is no usage anchor', () {
      final messages = [UserMessage.text('x' * 4000)];
      final budget = AgentContextBudget.forRequest(
        contextWindow: 128000,
        systemPrompt: 's' * 400,
        tools: const [
          Tool(
            name: 'read',
            description: 'Read a file',
            parameters: {'type': 'object'},
          ),
        ],
      );

      expect(budget.overheadTokens, greaterThan(100));
      expect(
        budget.estimateRequestTokens(messages),
        budget.overheadTokens + 1000,
      );
    });

    test('uses the provider anchor without double-counting overhead', () {
      final messages = [
        UserMessage.text('x' * 4000),
        AssistantMessage(
          content: [const AssistantTextContent('done')],
          stopReason: StopReason.stop,
          usage: const Usage(input: 9000, output: 100, totalTokens: 9100),
        ),
      ];
      final budget = AgentContextBudget.forRequest(
        contextWindow: 128000,
        systemPrompt: 's' * 4000,
        tools: const [
          Tool(
            name: 'read',
            description: 'Read a file',
            parameters: {'type': 'object'},
          ),
        ],
      );

      expect(budget.estimateRequestTokens(messages), 9100);
    });

    test('ignores a stale anchor before the compaction boundary', () {
      final messages = [
        const CompactionSummaryMessage(
          summary: 'summary',
          tokensBefore: 50000,
          timestamp: 1,
          retainedTailLength: 1,
        ),
        AssistantMessage(
          content: [const AssistantTextContent('tail')],
          stopReason: StopReason.stop,
          usage: const Usage(input: 40000, output: 100, totalTokens: 40100),
        ),
      ];
      final budget = AgentContextBudget.forRequest(
        contextWindow: 128000,
        systemPrompt: 's' * 400,
        tools: const [],
      );

      // 旧锚点来自压缩前，不能直接沿用；回退到本地估算。
      expect(budget.estimateRequestTokens(messages), lessThan(1000));
    });
  });

  group('resolveCompactionSettings', () {
    test('keeps the default reserve for very large windows', () {
      final settings = resolveCompactionSettings(128000);
      expect(settings.enabled, isTrue);
      expect(settings.reserveTokens, 16384);
      expect(settings.keepRecentTokens, 20000);
    });

    test('scales down for small windows instead of always compacting', () {
      final settings = resolveCompactionSettings(8000);
      expect(settings.reserveTokens, lessThan(16384));
      expect(
        settings.reserveTokens + settings.keepRecentTokens,
        lessThanOrEqualTo(6800),
      );
    });

    test('uses conservative bounds below 4k windows', () {
      final settings = resolveCompactionSettings(2000);
      expect(settings.reserveTokens, 300);
      expect(settings.keepRecentTokens, 700);
      expect(
        settings.reserveTokens + settings.keepRecentTokens,
        lessThan(2000),
      );
    });

    test('never reserves more than a tiny window', () {
      final settings = resolveCompactionSettings(100);
      expect(settings.reserveTokens + settings.keepRecentTokens, lessThan(100));
    });

    test('output safety margin scales with the window', () {
      expect(resolveOutputSafetyTokens(1000), 256);
      expect(resolveOutputSafetyTokens(8000), 800);
      expect(resolveOutputSafetyTokens(200000), 4096);
    });
  });
}
