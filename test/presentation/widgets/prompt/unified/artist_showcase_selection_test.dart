import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nai_launcher/core/storage/local_storage_service.dart';
import 'package:nai_launcher/data/models/danbooru/artist_showcase.dart';
import 'package:nai_launcher/l10n/app_localizations.dart';
import 'package:nai_launcher/presentation/providers/artist_showcase_provider.dart';
import 'package:nai_launcher/presentation/widgets/prompt/artist_showcase_card.dart';
import 'package:nai_launcher/presentation/widgets/prompt/artist_showcase_preview.dart';
import 'package:nai_launcher/presentation/widgets/prompt/unified/unified_prompt_config.dart';
import 'package:nai_launcher/presentation/widgets/prompt/unified/unified_prompt_input.dart';

import '../../../../helpers/memory_local_storage.dart';

void main() {
  const wlopShowcase = ArtistShowcase(
    artistTag: 'wlop',
    postId: 777,
    imageUrl: 'https://cdn.test/sample.jpg',
    previewUrl: 'https://cdn.test/preview.jpg',
    postUrl: 'https://danbooru.donmai.us/posts/777',
    width: 800,
    height: 1200,
    score: 4321,
  );

  /// 挂载提示词输入，返回编辑器控制器。
  ///
  /// 选中权重标签后会额外弹出权重面板（里面也有输入框），后续操作必须复用
  /// 同一个控制器，不能按类型再查一次。
  Future<TextEditingController> pumpPrompt(
    WidgetTester tester,
    String text, {
    Future<ArtistShowcase?> Function()? showcaseLoader,
  }) async {
    final controller = TextEditingController(text: text);
    final focus = FocusNode();
    addTearDown(controller.dispose);
    addTearDown(focus.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          localStorageServiceProvider.overrideWith(
            (ref) => MemoryLocalStorage(),
          ),
          // 只把带 `wlop` 的标签当成画师，测试不依赖 Danbooru 与本地标签库。
          artistTagProvider.overrideWith(
            (ref, tag) => tag.toLowerCase().contains('wlop'),
          ),
          artistShowcaseProvider.overrideWith((ref, tag) {
            if (!tag.toLowerCase().contains('wlop')) return null;
            return showcaseLoader?.call() ?? wlopShowcase;
          }),
        ],
        child: MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: SizedBox(
              width: 600,
              height: 320,
              child: UnifiedPromptInput(
                controller: controller,
                focusNode: focus,
                enableAssistant: false,
                expands: true,
                config: const UnifiedPromptConfig(
                  enableTagMode: true,
                  enableAutocomplete: false,
                  enableSyntaxHighlight: false,
                  enableAutoFormat: false,
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    return tester
        .state<EditableTextState>(find.byType(EditableText).first)
        .widget
        .controller;
  }

  /// 框选 [start, end) 后等预览层完成查询。
  Future<void> selectText(
    WidgetTester tester,
    TextEditingController editor,
    int start,
    int end, {
    bool settle = true,
  }) async {
    editor.selection = TextSelection(baseOffset: start, extentOffset: end);
    await tester.pump();
    if (!settle) return;
    await tester.pump(
      ArtistShowcasePreview.settleDelay + const Duration(milliseconds: 50),
    );
    await tester.pump();
  }

  testWidgets('选中画师标签后显示代表作卡片', (tester) async {
    final editor = await pumpPrompt(tester, 'wlop, 1girl');

    await selectText(tester, editor, 0, 4);

    expect(find.byType(ArtistShowcaseCard), findsOneWidget);
    expect(find.text('wlop'), findsOneWidget);
    expect(find.text('Score 4321'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('先出加载中的卡片，再换成代表作', (tester) async {
    final completer = Completer<ArtistShowcase?>();
    final editor = await pumpPrompt(
      tester,
      'wlop, 1girl',
      showcaseLoader: () => completer.future,
    );

    await selectText(tester, editor, 0, 4);

    // 代表作还没回来：卡片已经出现，带加载动画和标签名。
    expect(find.byType(ArtistShowcaseCard), findsOneWidget);
    expect(find.text('wlop'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    completer.complete(wlopShowcase);
    await tester.pump();
    await tester.pump();

    expect(find.text('Score 4321'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('选中非画师标签时不显示卡片', (tester) async {
    final editor = await pumpPrompt(tester, 'wlop, 1girl');

    await selectText(tester, editor, 6, 11);

    expect(find.byType(ArtistShowcaseCard), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('带 artist: 前缀与权重壳的写法也能命中', (tester) async {
    final editor = await pumpPrompt(tester, '1.2::artist: wlop::, 1girl');

    await selectText(tester, editor, 0, 20);

    expect(find.byType(ArtistShowcaseCard), findsOneWidget);
    expect(find.textContaining('wlop'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('取消选中后卡片收起', (tester) async {
    final editor = await pumpPrompt(tester, 'wlop, 1girl');

    await selectText(tester, editor, 0, 4);
    expect(find.byType(ArtistShowcaseCard), findsOneWidget);

    await selectText(tester, editor, 0, 0);
    expect(find.byType(ArtistShowcaseCard), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
