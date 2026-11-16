import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../../core/utils/localization_extension.dart';
import '../../../../../data/models/agent/agent_settings.dart';
import '../../../../../data/models/agent/agent_tool_pack.dart';
import '../../../../agent_settings/providers/agent_settings_provider.dart';
import '../../widgets/settings_card.dart';
import 'agent_settings_feedback.dart';

/// 控制每轮下发给模型的工具集，减少工具 schema 的固定 token 开销。
class AgentToolPacksCard extends ConsumerWidget {
  const AgentToolPacksCard({super.key, required this.settings});

  final AgentSettings settings;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final chat = settings.chat;

    Widget tile(AgentToolPack pack, String title, String subtitle) {
      return SwitchListTile(
        key: ValueKey('agent-tool-pack-${pack.name}'),
        contentPadding: EdgeInsets.zero,
        value: chat.isToolPackEnabled(pack),
        title: Text(title),
        subtitle: Text(subtitle),
        onChanged: (value) => reportAgentSettingFailure(
          context,
          ref
              .read(agentSettingsProvider.notifier)
              .setToolPackEnabled(pack, value),
        ),
      );
    }

    return SettingsCard(
      title: context.l10n.agentSettings_toolPacks,
      icon: Icons.widgets_outlined,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            context.l10n.agentSettings_toolPacksDescription,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            context.l10n.agentSettings_toolPacksCoreNote,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const Divider(height: 24),
          tile(
            AgentToolPack.generation,
            context.l10n.agentSettings_toolPackGeneration,
            context.l10n.agentSettings_toolPackGenerationDescription,
          ),
          tile(
            AgentToolPack.generationActions,
            context.l10n.agentSettings_toolPackGenerationActions,
            context.l10n.agentSettings_toolPackGenerationActionsDescription,
          ),
          tile(
            AgentToolPack.queue,
            context.l10n.agentSettings_toolPackQueue,
            context.l10n.agentSettings_toolPackQueueDescription,
          ),
          tile(
            AgentToolPack.inpaint,
            context.l10n.agentSettings_toolPackInpaint,
            context.l10n.agentSettings_toolPackInpaintDescription,
          ),
          tile(
            AgentToolPack.tagLibrary,
            context.l10n.agentSettings_toolPackTagLibrary,
            context.l10n.agentSettings_toolPackTagLibraryDescription,
          ),
          const Divider(height: 24),
          tile(
            AgentToolPack.gallery,
            context.l10n.agentSettings_toolPackGallery,
            context.l10n.agentSettings_toolPackGalleryDescription,
          ),
          tile(
            AgentToolPack.references,
            context.l10n.agentSettings_toolPackReferences,
            context.l10n.agentSettings_toolPackReferencesDescription,
          ),
          tile(
            AgentToolPack.storyboard,
            context.l10n.agentSettings_toolPackStoryboard,
            context.l10n.agentSettings_toolPackStoryboardDescription,
          ),
        ],
      ),
    );
  }
}
