import 'dart:convert';

import '../../../core/agent/agent_types.dart';
import '../../../core/agent/harness/compaction/compaction.dart';
import '../../../core/agent/harness/harness_messages.dart';

/// 估算一次 LLM 请求的实际上下文预算。
///
/// [estimateContextTokens] 的 provider usage 锚点已经包含系统提示词和工具
/// schema；只有在没有有效锚点（首个请求，或 compaction 后尚未产生新响应）
/// 时才需要补上 [overheadTokens]。
class AgentContextBudget {
  const AgentContextBudget({
    required this.contextWindow,
    required this.overheadTokens,
  });

  final int contextWindow;
  final int overheadTokens;

  factory AgentContextBudget.forRequest({
    required int contextWindow,
    required String systemPrompt,
    required List<Tool>? tools,
  }) {
    return AgentContextBudget(
      contextWindow: contextWindow,
      overheadTokens:
          estimateTextTokens(systemPrompt) + estimateToolSchemaTokens(tools),
    );
  }

  int estimateRequestTokens(List<AgentMessage> messages) {
    final estimate = estimateContextTokens(messages);
    if (_hasValidUsageAnchor(messages, estimate.lastUsageIndex)) {
      return estimate.tokens;
    }
    return estimateFullRequestTokens(messages);
  }

  /// 忽略 provider 锚点的全量本地估算。
  ///
  /// 清理旧工具结果后，锚点对应的是清理前的请求，必须重新按实际发送的
  /// 消息计算，否则会把已移除的内容继续计入。
  int estimateFullRequestTokens(List<AgentMessage> messages) {
    var tokens = overheadTokens;
    for (final message in messages) {
      tokens += estimateTokens(message);
    }
    return tokens;
  }
}

/// 与现有字符启发式保持一致，供预算和日志复用。
int estimateTextTokens(String text) => (text.length / 4).ceil();

int estimateToolSchemaTokens(List<Tool>? tools) {
  if (tools == null || tools.isEmpty) return 0;
  var chars = 0;
  for (final tool in tools) {
    chars += tool.name.length + tool.description.length;
    chars += jsonEncode(tool.parameters).length;
  }
  return (chars / 4).ceil();
}

bool _hasValidUsageAnchor(List<AgentMessage> messages, int? anchorIndex) {
  if (anchorIndex == null) return false;
  final compactionIndex = messages.lastIndexWhere(
    (message) => message is CompactionSummaryMessage,
  );
  if (compactionIndex < 0) return true;
  final summary = messages[compactionIndex] as CompactionSummaryMessage;
  final boundary = compactionIndex + summary.retainedTailLength;
  return anchorIndex > boundary;
}

/// 按窗口缩放 compaction 参数，避免 8k/16k 模型因固定 16384 reserve
/// 而每轮都触发压缩。
CompactionSettings resolveCompactionSettings(int contextWindow) {
  if (contextWindow <= 0) {
    return const CompactionSettings(
      enabled: false,
      reserveTokens: 0,
      keepRecentTokens: 0,
    );
  }
  if (contextWindow < 4096) {
    var reserve = (contextWindow * 0.15).round().clamp(256, 1024).toInt();
    var keep = (contextWindow * 0.35).round().clamp(512, 2048).toInt();
    final maxBudget = contextWindow > 1 ? contextWindow - 1 : 1;
    if (reserve + keep > maxBudget) {
      final scale = maxBudget / (reserve + keep);
      reserve = (reserve * scale).floor().clamp(1, reserve).toInt();
      keep = (keep * scale).floor().clamp(1, keep).toInt();
    }
    return CompactionSettings(
      enabled: true,
      reserveTokens: reserve,
      keepRecentTokens: keep,
    );
  }

  var reserve = (contextWindow * 0.18).round().clamp(1024, 16384).toInt();
  var keep = (contextWindow * 0.35).round().clamp(2048, 20000).toInt();
  final budget = (contextWindow * 0.85).floor();
  if (reserve + keep > budget) {
    final scale = budget / (reserve + keep);
    reserve = (reserve * scale).floor().clamp(256, reserve).toInt();
    keep = (keep * scale).floor().clamp(512, keep).toInt();
  }
  return CompactionSettings(
    enabled: true,
    reserveTokens: reserve,
    keepRecentTokens: keep,
  );
}

/// 输出 token 的上下文安全余量；小窗口不能继续使用固定 4096。
int resolveOutputSafetyTokens(int contextWindow) {
  if (contextWindow <= 0) return 0;
  return (contextWindow * 0.1).round().clamp(256, 4096).toInt();
}
