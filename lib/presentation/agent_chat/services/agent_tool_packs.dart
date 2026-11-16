import '../../../core/agent/agent_types.dart';
import '../../../data/models/agent/agent_settings.dart';
import '../../../data/models/agent/agent_tool_pack.dart';

/// 某个工具包在当前设置下是否下发。
bool isToolPackEnabled(
  AgentToolPack pack,
  AgentChatConfig config, {
  required bool webAccessEnabled,
}) => switch (pack) {
  AgentToolPack.core => true,
  AgentToolPack.web => webAccessEnabled,
  _ => config.isToolPackEnabled(pack),
};

/// 按固定包顺序展开启用工具，保证工具 schema 序列化稳定。
List<AgentTool> filterToolsForPacks(
  Map<AgentToolPack, List<AgentTool>> groups,
  AgentChatConfig config, {
  required bool webAccessEnabled,
}) => [
  for (final pack in AgentToolPack.values)
    if (isToolPackEnabled(pack, config, webAccessEnabled: webAccessEnabled))
      ...?groups[pack],
];
