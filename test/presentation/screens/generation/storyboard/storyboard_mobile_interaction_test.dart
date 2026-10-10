import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nai_launcher/core/constants/storage_keys.dart';
import 'package:nai_launcher/core/storage/local_storage_service.dart';
import 'package:nai_launcher/data/models/storyboard/storyboard_document.dart';
import 'package:nai_launcher/data/models/storyboard/storyboard_page.dart';
import 'package:nai_launcher/data/models/storyboard/storyboard_panel.dart';
import 'package:nai_launcher/data/services/storyboard/storyboard_repository.dart';
import 'package:nai_launcher/l10n/app_localizations.dart';
import 'package:nai_launcher/presentation/providers/generation/generation_center_mode_provider.dart';
import 'package:nai_launcher/presentation/providers/storyboard/storyboard_document_controller.dart';
import 'package:nai_launcher/presentation/providers/storyboard/storyboard_generation_runner.dart';
import 'package:nai_launcher/presentation/providers/storyboard/storyboard_interaction_provider.dart';
import 'package:nai_launcher/presentation/providers/storyboard/storyboard_repository_provider.dart';
import 'package:nai_launcher/presentation/screens/generation/mobile_generation_controller.dart';
import 'package:nai_launcher/presentation/screens/generation/storyboard/storyboard_canvas.dart';
import 'package:nai_launcher/presentation/screens/generation/storyboard/storyboard_toolbar.dart';
import 'package:nai_launcher/presentation/screens/generation/storyboard/storyboard_view.dart';

/// 手机竖屏常用宽度；工具条在触屏上的命中边长是 48，总宽远超这些值。
const List<double> _phoneWidths = [320.0, 390.0];

const Size _phoneViewport = Size(390, 700);

const String _panelId = 'panel-a';

/// 工具条上全部按钮的图标；每个都必须落在视口内且可点。
const List<IconData> _toolbarIcons = [
  Icons.near_me_outlined,
  Icons.crop_free_rounded,
  Icons.expand_rounded,
  Icons.auto_awesome_motion_outlined,
  Icons.save_alt_rounded,
  Icons.visibility_outlined,
  Icons.undo_rounded,
  Icons.redo_rounded,
  Icons.grid_view_rounded,
  Icons.tune_rounded,
  Icons.close_fullscreen_rounded,
];

StoryboardDocument _fixtureDocument() {
  final stamp = DateTime.fromMillisecondsSinceEpoch(1700000000000);
  return StoryboardDocument.singlePage(
    StoryboardPage(
      id: 'page-1',
      name: 'page',
      width: 1024,
      height: 1536,
      margin: 15,
      gutter: 15,
      createdAt: stamp,
      updatedAt: stamp,
      panels: [
        StoryboardPanel(
          id: _panelId,
          order: 1,
          x: 100,
          y: 100,
          width: 400,
          height: 500,
          createdAt: stamp,
          updatedAt: stamp,
        ),
      ],
    ),
  );
}

/// 只替换磁盘存取，其余走真实实现。
class _FakeStoryboardRepository extends StoryboardRepository {
  _FakeStoryboardRepository(this._document);

  StoryboardDocument _document;
  int saveCount = 0;

  @override
  Future<String?> rootPath() async => null;

  @override
  Future<StoryboardDocument?> load() async => _document;

  @override
  Future<bool> save(StoryboardDocument document) async {
    _document = document;
    saveCount++;
    return true;
  }
}

/// 移动端返回键的最小壳层：只拿到 controller，不拖进整页生成 UI。
class _BackHarness extends ConsumerStatefulWidget {
  const _BackHarness();

  @override
  ConsumerState<_BackHarness> createState() => _BackHarnessState();
}

class _BackHarnessState extends ConsumerState<_BackHarness> {
  late final MobileGenerationController controller;

  @override
  void initState() {
    super.initState();
    controller = MobileGenerationController(ref);
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

/// 生成链路与画布交互无关，测试里固定为空闲态。
class _IdleGenerationRunner extends StoryboardGenerationRunner {
  @override
  StoryboardGenerationState build() => const StoryboardGenerationState();
}

class _FakeLocalStorage extends LocalStorageService {
  final Map<String, Object?> values = <String, Object?>{};

  @override
  T? getSetting<T>(String key, {T? defaultValue}) =>
      values.containsKey(key) ? values[key] as T? : defaultValue;

  @override
  Future<void> setSetting<T>(String key, T value) async => values[key] = value;
}

ProviderContainer _container() => ProviderContainer(
  overrides: [
    storyboardRepositoryProvider.overrideWith(
      (ref) => _FakeStoryboardRepository(_fixtureDocument()),
    ),
    storyboardGenerationRunnerProvider.overrideWith(_IdleGenerationRunner.new),
    localStorageServiceProvider.overrideWith((ref) => _FakeLocalStorage()),
  ],
);

Widget _app(ProviderContainer container, Widget child) =>
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(body: child),
      ),
    );

Future<void> _pumpView(
  WidgetTester tester,
  ProviderContainer container,
  Size size,
) async {
  await tester.binding.setSurfaceSize(size);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(_app(container, const StoryboardView()));
  // 文档是异步加载的，等它就绪。
  await tester.pump();
  await tester.pump();
}

Future<void> _pumpCanvas(
  WidgetTester tester,
  ProviderContainer container,
  Size size,
) async {
  await tester.binding.setSurfaceSize(size);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(_app(container, const StoryboardCanvas()));
  await tester.pump();
  await tester.pump();
}

Rect _panelRect(WidgetTester tester) =>
    tester.getRect(find.byKey(const ValueKey<String>(_panelId)));

/// 双指捏合：两指从 [spread] 移到 [target]，焦点保持不动。
Future<void> _pinch(
  WidgetTester tester,
  Offset center, {
  required double spread,
  required double target,
}) async {
  final first = await tester.startGesture(center - Offset(spread, 0), pointer: 7);
  final second = await tester.startGesture(center + Offset(spread, 0), pointer: 8);
  await tester.pump();
  await first.moveTo(center - Offset(target, 0));
  await second.moveTo(center + Offset(target, 0));
  await tester.pump();
  await first.up();
  await second.up();
  await tester.pump();
}

Future<void> _tapAtTime(
  WidgetTester tester,
  Offset position, {
  required int pointer,
  required Duration timeStamp,
}) async {
  final gesture = await tester.startGesture(position, pointer: pointer);
  await gesture.up(timeStamp: timeStamp);
  await tester.pump();
}

Finder _toolbarIcon(IconData icon) => find.descendant(
  of: find.byType(StoryboardToolbar),
  matching: find.byIcon(icon),
);

bool _withinViewport(Rect rect, double width) =>
    rect.left >= 0 && rect.right <= width;

/// 让文档控制的落盘防抖跑完，测试结束时不留 pending timer。
Future<void> _settleDocument(
  WidgetTester tester,
  ProviderContainer container,
) async {
  await container.read(storyboardDocumentControllerProvider.notifier).flush();
  await tester.pump();
}

/// 版面矩形是否仍是初始值（视口手势与取消的编辑都不该改动它）。
void _expectPanelUntouched(ProviderContainer container) {
  final page = container
      .read(storyboardDocumentControllerProvider)
      .valueOrNull!
      .activePage!;
  expect(
    page.panelById(_panelId)!.rect,
    const Rect.fromLTWH(100, 100, 400, 500),
    reason: '分镜版面不该被这段手势改动',
  );
}

void main() {
  group('窄屏工具条', () {
    for (final width in _phoneWidths) {
      testWidgets('${width.toInt()}px 宽时工具条留在视口内且首尾按钮都够得着', (tester) async {
        final container = _container();
        addTearDown(container.dispose);
        await _pumpView(tester, container, Size(width, _phoneViewport.height));

        final toolbar = tester.getRect(find.byType(StoryboardToolbar));
        expect(
          _withinViewport(toolbar, width),
          isTrue,
          reason: '工具条越出视口：$toolbar',
        );

        // 工具集合的护栏：增减工具时同步复核这里的宽度预期。
        for (final icon in _toolbarIcons) {
          expect(_toolbarIcon(icon), findsOneWidget, reason: '$icon 不在工具条里');
        }

        // 前面的工具按初始滚动位置就该在视口内。
        final draw = _toolbarIcon(Icons.crop_free_rounded);
        expect(draw, findsOneWidget);
        expect(_withinViewport(tester.getRect(draw), width), isTrue);

        // 末尾的退出按钮要靠横向滚动进入视口：滚动可用即说明内容没有被裁掉。
        final close = _toolbarIcon(Icons.close_fullscreen_rounded);
        expect(close, findsOneWidget);
        expect(
          _withinViewport(tester.getRect(close), width),
          isFalse,
          reason: '这一段本来就是靠滚动够到的',
        );
        await tester.drag(find.byType(StoryboardToolbar), Offset(-width * 2, 0));
        await tester.pumpAndSettle();
        expect(
          _withinViewport(tester.getRect(close), width),
          isTrue,
          reason: '横向滚动后退出按钮应进入视口',
        );
        expect(tester.takeException(), isNull);
        await _settleDocument(tester, container);
      });
    }

    testWidgets('窄屏选择工具按钮可点，工具真的切换', (tester) async {
      final container = _container();
      addTearDown(container.dispose);
      await _pumpView(tester, container, const Size(390, 700));

      await tester.tap(
        find.descendant(
          of: find.byType(StoryboardToolbar),
          matching: find.byIcon(Icons.crop_free_rounded),
        ),
      );
      await tester.pump();

      expect(
        container.read(storyboardInteractionProvider).tool,
        StoryboardTool.drawRect,
      );
    });

    testWidgets('窄屏页面信息 chip 不被工具条覆盖', (tester) async {
      final container = _container();
      addTearDown(container.dispose);
      await _pumpView(tester, container, const Size(390, 700));

      final chip = tester.getRect(
        find.byKey(const ValueKey<String>('storyboard-page-chip')),
      );
      final toolbar = tester.getRect(find.byType(StoryboardToolbar));
      expect(chip.overlaps(toolbar), isFalse, reason: 'chip $chip 被工具条 $toolbar 盖住');
    });
  });

  group('画布视口手势', () {
    testWidgets('双指张开放大画布，且不改动文档版面', (tester) async {
      final container = _container();
      addTearDown(container.dispose);
      await _pumpCanvas(tester, container, _phoneViewport);

      final before = _panelRect(tester);
      await _pinch(
        tester,
        before.center,
        spread: 30,
        target: 90,
      );

      final after = _panelRect(tester);
      expect(
        after.width,
        greaterThan(before.width * 1.5),
        reason: '捏合放大后分镜应该明显变大：$before → $after',
      );
      // 双指对称张开、焦点不动：焦点下的页面点必须留在原地。
      expect(
        (after.center - before.center).distance,
        lessThan(2),
        reason: '焦点不动时捏合不该让画面整体平移：$before → $after',
      );
      // 视口手势只是呈现，不能写进分镜版面。
      _expectPanelUntouched(container);
      await _settleDocument(tester, container);
    });

    testWidgets('双击空白处复位到适应视口', (tester) async {
      final container = _container();
      addTearDown(container.dispose);
      await _pumpCanvas(tester, container, _phoneViewport);

      final before = _panelRect(tester);
      await _pinch(tester, before.center, spread: 30, target: 90);
      expect(_panelRect(tester).width, greaterThan(before.width));

      // 页面之外的空白角，避免点中分镜自身的双击语义。
      final blank =
          tester.getRect(find.byType(StoryboardCanvas)).bottomRight -
          const Offset(6, 6);
      await _tapAtTime(
        tester,
        blank,
        pointer: 11,
        timeStamp: const Duration(milliseconds: 1000),
      );
      await _tapAtTime(
        tester,
        blank,
        pointer: 12,
        timeStamp: const Duration(milliseconds: 1120),
      );

      expect(
        _panelRect(tester).width,
        closeTo(before.width, 0.5),
        reason: '双击后应回到适应视口的比例',
      );
      _expectPanelUntouched(container);
      await _settleDocument(tester, container);
    });

    testWidgets('相隔很久的两次点击只算点选，不复位視口', (tester) async {
      final container = _container();
      addTearDown(container.dispose);
      await _pumpCanvas(tester, container, _phoneViewport);

      final before = _panelRect(tester);
      await _pinch(tester, before.center, spread: 30, target: 90);
      final zoomed = _panelRect(tester).width;

      final blank =
          tester.getRect(find.byType(StoryboardCanvas)).bottomRight -
          const Offset(6, 6);
      await _tapAtTime(
        tester,
        blank,
        pointer: 13,
        timeStamp: const Duration(milliseconds: 2000),
      );
      await _tapAtTime(
        tester,
        blank,
        pointer: 14,
        timeStamp: const Duration(milliseconds: 2900),
      );

      expect(_panelRect(tester).width, closeTo(zoomed, 0.5));
      await _settleDocument(tester, container);
    });

    testWidgets('两指按下会取消进行中的分镜拖动，不写坏版面', (tester) async {
      final container = _container();
      addTearDown(container.dispose);
      await _pumpCanvas(tester, container, _phoneViewport);

      final start = _panelRect(tester).center;
      final finger = await tester.startGesture(start, pointer: 3);
      await finger.moveBy(const Offset(0, -40));
      await tester.pump();
      // 第二根手指落下：整段手势改判为视口操作。
      final second = await tester.startGesture(
        start + const Offset(60, 0),
        pointer: 4,
      );
      await tester.pump();
      await finger.moveBy(const Offset(0, -60));
      await second.moveBy(const Offset(60, 0));
      await finger.up();
      await second.up();
      await tester.pump();

      _expectPanelUntouched(container);
      await _settleDocument(tester, container);
    });
  });

  group('移动端返回键', () {
    testWidgets('分镜模式下返回键先落盘再回预览', (tester) async {
      final storage = _FakeLocalStorage()
        ..values[StorageKeys.mobileGenerationGestureHintCompleted] = true
        ..values[StorageKeys.generationCenterMode] =
            GenerationCenterMode.storyboard.name;
      final repository = _FakeStoryboardRepository(_fixtureDocument());
      final container = ProviderContainer(
        overrides: [
          storyboardRepositoryProvider.overrideWith((ref) => repository),
          localStorageServiceProvider.overrideWith((ref) => storage),
        ],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(
            locale: Locale('zh'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: _BackHarness(),
          ),
        ),
      );
      await tester.pump();
      // 文档要先加载完，flush 才有东西可落盘。
      await container.read(storyboardDocumentControllerProvider.future);

      expect(
        container.read(generationCenterModeControllerProvider),
        GenerationCenterMode.storyboard,
      );

      tester
          .state<_BackHarnessState>(find.byType(_BackHarness))
          .controller
          .handleBack(isPromptMaximized: false, isStoryboardMode: true);
      await tester.pumpAndSettle();

      expect(
        container.read(generationCenterModeControllerProvider),
        GenerationCenterMode.preview,
      );
      expect(repository.saveCount, greaterThan(0), reason: '退出前必须先落盘');
    });
  });
}
