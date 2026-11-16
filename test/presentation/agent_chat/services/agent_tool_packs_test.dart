import 'package:flutter_test/flutter_test.dart';
import 'package:nai_launcher/core/agent/agent_types.dart';
import 'package:nai_launcher/data/models/agent/agent_settings.dart';
import 'package:nai_launcher/data/models/agent/agent_tool_pack.dart';
import 'package:nai_launcher/presentation/agent_chat/services/agent_tool_packs.dart';

class _FakeTool extends AgentTool {
  _FakeTool(String name)
    : super(
        name: name,
        description: name,
        parameters: const {'type': 'object'},
        label: name,
      );

  @override
  Future<AgentToolResult> execute(
    String toolCallId,
    Map<String, dynamic> params, [
    AbortSignal? signal,
    AgentToolUpdateCallback? onUpdate,
  ]) async => AgentToolResult(content: const [], details: null);
}

Map<AgentToolPack, List<AgentTool>> _groups() => {
  AgentToolPack.core: [_FakeTool('core')],
  AgentToolPack.generation: [_FakeTool('generation')],
  AgentToolPack.generationActions: [_FakeTool('actions')],
  AgentToolPack.queue: [_FakeTool('queue')],
  AgentToolPack.inpaint: [_FakeTool('inpaint')],
  AgentToolPack.tagLibrary: [_FakeTool('tagLibrary')],
  AgentToolPack.gallery: [_FakeTool('gallery')],
  AgentToolPack.references: [_FakeTool('references')],
  AgentToolPack.storyboard: [_FakeTool('storyboard')],
  AgentToolPack.web: [_FakeTool('web')],
};

void main() {
  test(
    'compact defaults include core workflows and exclude advanced packs',
    () {
      final tools = filterToolsForPacks(
        _groups(),
        const AgentChatConfig(),
        webAccessEnabled: false,
      );

      expect(tools.map((tool) => tool.name), [
        'core',
        'generation',
        'actions',
        'queue',
        'inpaint',
        'tagLibrary',
      ]);
    },
  );

  test('overrides enable advanced packs and web follows its own switch', () {
    final tools = filterToolsForPacks(
      _groups(),
      const AgentChatConfig(
        toolPackOverrides: {'gallery': true, 'queue': false},
      ),
      webAccessEnabled: true,
    );

    expect(tools.map((tool) => tool.name), [
      'core',
      'generation',
      'actions',
      'inpaint',
      'tagLibrary',
      'gallery',
      'web',
    ]);
  });

  test('missing groups are skipped without breaking order', () {
    final groups = _groups()..remove(AgentToolPack.generation);

    final tools = filterToolsForPacks(
      groups,
      const AgentChatConfig(),
      webAccessEnabled: false,
    );

    expect(tools.map((tool) => tool.name), [
      'core',
      'actions',
      'queue',
      'inpaint',
      'tagLibrary',
    ]);
  });
}
