import 'package:flutter_test/flutter_test.dart';
import 'package:nai_launcher/data/models/agent/agent_settings.dart';
import 'package:nai_launcher/data/models/agent/agent_tool_pack.dart';

void main() {
  group('AgentToolPack', () {
    test('core and web are not user configurable', () {
      expect(AgentToolPack.core.isUserConfigurable, isFalse);
      expect(AgentToolPack.web.isUserConfigurable, isFalse);
      for (final pack in const [
        AgentToolPack.generation,
        AgentToolPack.generationActions,
        AgentToolPack.queue,
        AgentToolPack.inpaint,
        AgentToolPack.tagLibrary,
        AgentToolPack.gallery,
        AgentToolPack.references,
        AgentToolPack.storyboard,
      ]) {
        expect(pack.isUserConfigurable, isTrue, reason: pack.name);
      }
    });

    test('defaults keep the core workflows and hide advanced packs', () {
      for (final pack in const [
        AgentToolPack.core,
        AgentToolPack.generation,
        AgentToolPack.generationActions,
        AgentToolPack.queue,
        AgentToolPack.inpaint,
        AgentToolPack.tagLibrary,
        AgentToolPack.web,
      ]) {
        expect(pack.defaultEnabled, isTrue, reason: pack.name);
      }
      for (final pack in const [
        AgentToolPack.gallery,
        AgentToolPack.references,
        AgentToolPack.storyboard,
      ]) {
        expect(pack.defaultEnabled, isFalse, reason: pack.name);
      }
    });

    test('storage keys round-trip', () {
      for (final pack in AgentToolPack.values) {
        expect(AgentToolPack.fromStorageKey(pack.name), pack);
      }
      expect(AgentToolPack.fromStorageKey('unknown'), isNull);
    });

    test('settings only override the selected pack', () {
      const config = AgentChatConfig(
        toolPackOverrides: {'gallery': true, 'queue': false},
      );
      expect(config.isToolPackEnabled(AgentToolPack.gallery), isTrue);
      expect(config.isToolPackEnabled(AgentToolPack.queue), isFalse);
      expect(config.isToolPackEnabled(AgentToolPack.inpaint), isTrue);
      expect(config.isToolPackEnabled(AgentToolPack.tagLibrary), isTrue);
      expect(config.isToolPackEnabled(AgentToolPack.references), isFalse);
      expect(config.isToolPackEnabled(AgentToolPack.core), isTrue);
      expect(config.isToolPackEnabled(AgentToolPack.web), isTrue);
    });
  });
}
