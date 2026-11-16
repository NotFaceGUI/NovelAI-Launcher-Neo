import '../../../core/agent/harness/compaction/compaction.dart';
import '../../../core/agent/llm_types.dart';

/// 在请求前清理已消费的旧工具结果，降低长会话的上下文增长。
///
/// 只返回本次请求使用的视图：Agent 状态、JSONL 与 UI 历史保持不变。
/// 边界按 toolCallId 记忆，只有上下文再次跨过更高阈值时才向前移动，
/// 避免每轮重写前缀破坏 provider 的前缀缓存。
class AgentContextPruner {
  String? _boundaryToolCallId;
  int _nextPruneThreshold = 0;

  void reset() {
    _boundaryToolCallId = null;
    _nextPruneThreshold = 0;
  }

  List<Message> prune(
    List<Message> messages, {
    required int contextWindow,
    required int keepRecentTokens,
    required int requestTokens,
    int keepRecentResults = 4,
  }) {
    if (contextWindow <= 0 || messages.isEmpty) return messages;

    final boundary = _boundaryToolCallId;
    if (boundary != null) {
      if (requestTokens < _nextPruneThreshold) {
        return _applyBoundary(messages, boundary);
      }
    } else {
      final trigger = (contextWindow * 0.6).floor();
      if (requestTokens < trigger) return messages;
    }

    final toolResults = <ToolResultMessage>[
      for (final message in messages)
        if (message is ToolResultMessage) message,
    ];
    if (toolResults.length <= keepRecentResults) return messages;

    var tailTokens = 0;
    var firstKept = toolResults.length;
    while (firstKept > 0) {
      final result = toolResults[firstKept - 1];
      final tokens = estimateTokens(result);
      final count = toolResults.length - firstKept;
      if (count >= keepRecentResults &&
          tailTokens + tokens > keepRecentTokens) {
        break;
      }
      tailTokens += tokens;
      firstKept--;
    }
    // 当前轮次的工具结果必须完整保留，否则模型无法继续同一批工具调用。
    final latestBatchIds = _latestToolCallIds(messages);
    if (latestBatchIds.isNotEmpty) {
      final firstBatchIndex = toolResults.indexWhere(
        (result) => latestBatchIds.contains(result.toolCallId),
      );
      if (firstBatchIndex >= 0 && firstBatchIndex < firstKept) {
        firstKept = firstBatchIndex;
      }
    }
    if (firstKept <= 0) return messages;

    final newBoundary = toolResults[firstKept].toolCallId;
    _boundaryToolCallId = newBoundary;
    _nextPruneThreshold = (requestTokens + contextWindow * 0.12).floor().clamp(
      (contextWindow * 0.65).floor(),
      contextWindow - 1,
    );
    return _applyBoundary(messages, newBoundary);
  }

  Set<String> _latestToolCallIds(List<Message> messages) {
    for (var index = messages.length - 1; index >= 0; index--) {
      final message = messages[index];
      if (message is! AssistantMessage) continue;
      if (message.toolCalls.isEmpty) return const {};
      return {for (final call in message.toolCalls) call.id};
    }
    return const {};
  }

  List<Message> _applyBoundary(List<Message> messages, String boundaryId) {
    final boundaryIndex = messages.indexWhere(
      (message) =>
          message is ToolResultMessage && message.toolCallId == boundaryId,
    );
    if (boundaryIndex < 0) {
      reset();
      return messages;
    }
    return [
      for (var index = 0; index < messages.length; index++)
        if (index < boundaryIndex && messages[index] is ToolResultMessage)
          _elide(messages[index] as ToolResultMessage)
        else
          messages[index],
    ];
  }

  ToolResultMessage _elide(ToolResultMessage message) {
    final text = message.text;
    final content = <ToolResultContent>[
      ToolResultTextContent(
        message.isError
            ? _elideError(text)
            : '[Elided tool result: ${message.toolName}, '
                  '~${estimateTokens(message)} tokens. Re-query with narrower '
                  'arguments only if the tool is safe to repeat.]',
      ),
    ];
    return ToolResultMessage(
      toolCallId: message.toolCallId,
      toolName: message.toolName,
      content: content,
      details: message.details,
      usage: message.usage,
      addedToolNames: message.addedToolNames,
      isError: message.isError,
      timestamp: message.timestamp,
    );
  }

  String _elideError(String text) {
    const maxErrorChars = 500;
    if (text.length <= maxErrorChars) return text;
    return '${text.substring(0, maxErrorChars)}\n\n'
        '[Error truncated to save context; the full error remains in the '
        'conversation UI.]';
  }
}
