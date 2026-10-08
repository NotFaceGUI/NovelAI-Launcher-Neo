import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nai_launcher/l10n/app_localizations.dart';
import 'package:nai_launcher/presentation/agent_chat/providers/agent_chat_state.dart';
import 'package:nai_launcher/presentation/agent_chat/widgets/agent_chat_panel_controller.dart';
import 'package:nai_launcher/presentation/agent_chat/widgets/agent_chat_panel_coordinator.dart';
import 'package:nai_launcher/presentation/utils/dropped_file_reader.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('剪贴板里的图片贴成待上传附件', (tester) async {
    final harness = await _pumpCoordinator(
      tester,
      readClipboardImage: () async =>
          DroppedFileData(fileName: 'clip.png', bytes: _pngBytes),
    );

    await harness.paste(fallback: null);

    final images = harness.controller.pendingImages;
    expect(images, hasLength(1));
    expect(images.single.name, 'clip.png');
    expect(images.single.mimeType, 'image/png');
    expect(harness.controller.inputController.text, contains('[image1]'));
    expect(find.text('No image in clipboard'), findsNothing);
  });

  testWidgets('剪贴板没有图片时键盘粘贴回退到文本', (tester) async {
    final harness = await _pumpCoordinator(
      tester,
      readClipboardImage: () async => null,
    );
    var fallbacks = 0;

    await harness.paste(fallback: () => fallbacks++);

    expect(fallbacks, 1);
    expect(harness.controller.pendingImages, isEmpty);
    expect(find.text('No image in clipboard'), findsNothing);
  });

  testWidgets('附件菜单发起粘贴时提示剪贴板没有图片', (tester) async {
    final harness = await _pumpCoordinator(
      tester,
      readClipboardImage: () async => null,
    );

    await harness.paste(fallback: null);
    await tester.pump();

    expect(harness.controller.pendingImages, isEmpty);
    expect(find.text('No image in clipboard'), findsOneWidget);

    await tester.pump(const Duration(seconds: 4));
    await tester.pumpAndSettle();
  });

  testWidgets('剪贴板内容不是图片时不入列', (tester) async {
    final harness = await _pumpCoordinator(
      tester,
      readClipboardImage: () async => DroppedFileData(
        fileName: 'clip.bin',
        bytes: Uint8List.fromList([1, 2, 3, 4]),
      ),
    );

    await harness.paste(fallback: null);
    await tester.pump();

    expect(harness.controller.pendingImages, isEmpty);
    expect(find.text('Unsupported image format: clip.bin'), findsOneWidget);

    await tester.pump(const Duration(seconds: 4));
    await tester.pumpAndSettle();
  });
}

final _pngBytes = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
);

const _state = AgentChatState(
  initialized: true,
  routeReady: true,
  routeLabel: 'Test model',
);

Future<_CoordinatorHarness> _pumpCoordinator(
  WidgetTester tester, {
  required Future<DroppedFileData?> Function() readClipboardImage,
}) async {
  final controller = AgentChatPanelController();
  addTearDown(controller.dispose);
  late _CoordinatorHarness harness;
  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Consumer(
            builder: (context, ref, _) {
              harness = _CoordinatorHarness(
                context: context,
                controller: controller,
                coordinator: AgentChatPanelCoordinator(
                  ref: ref,
                  controller: controller,
                  isMounted: () => true,
                  readClipboardImage: readClipboardImage,
                ),
              );
              return const SizedBox.shrink();
            },
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  return harness;
}

class _CoordinatorHarness {
  _CoordinatorHarness({
    required this.context,
    required this.controller,
    required this.coordinator,
  });

  final BuildContext context;
  final AgentChatPanelController controller;
  final AgentChatPanelCoordinator coordinator;

  Future<void> paste({required VoidCallback? fallback}) {
    final commands = coordinator.commands(context, _state);
    return commands.pasteClipboardImage(fallback);
  }
}
