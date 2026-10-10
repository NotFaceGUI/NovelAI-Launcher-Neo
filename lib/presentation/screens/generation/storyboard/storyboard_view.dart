import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../providers/storyboard/storyboard_editor_bridge.dart';
import '../../../../core/utils/localization_extension.dart';
import '../../../providers/generation/generation_params_notifier.dart';
import '../../../providers/storyboard/storyboard_document_controller.dart';
import '../../../providers/storyboard/storyboard_interaction_provider.dart';
import '../../../providers/storyboard/storyboard_toolbar_actions.dart';
import '../../../themes/core/layered_surface_style.dart';
import 'storyboard_canvas.dart';
import 'storyboard_toolbar.dart';

/// 分镜模式：漫画分镜页编辑器。
///
/// 与无限画布同为生成页中央工作区的呈现方式，容器与切换动画由
/// `GenerationCenterWorkspace` 负责；这里只承载分镜自己的画布、工具条与属性栏。
///
/// 属性栏在宽屏停靠右侧、窄屏落到画布下方，两者都按内容取高并封顶，
/// 不会撑满整列把画布压扁。
class StoryboardView extends ConsumerStatefulWidget {
  const StoryboardView({super.key});

  static const double inspectorWidth = 320;

  /// 低于该宽度时属性栏改为底部停靠。
  static const double inspectorDockBreakpoint = 720;

  /// 属性栏的最大高度；内容超出时内部滚动。
  static const double inspectorMaxHeight = 420;

  /// 窄于该宽度时工具条占满整行，页面信息 chip 让到左下角。
  ///
  /// 触屏上工具条固定 48×48 命中区，十一项加分隔线约 600 逻辑像素：
  /// 只有比这更宽的视口才放得下「工具条 + chip」并排。
  static const double pageChipDockBreakpoint = 640;

  @override
  ConsumerState<StoryboardView> createState() => _StoryboardViewState();
}

class _StoryboardViewState extends ConsumerState<StoryboardView> {
  bool _leaving = false;

  /// 编辑器里当前承载的是哪一份快照。
  ///
  /// 只在真正完成切换后才更新：拖动期间会跳过切换，若此时就更新基准，之后
  /// 单击同一个分镜会被判成"没变化"而永远不载入。
  StoryboardInteractionState? _editorSelection;

  Future<void> _leave() async {
    if (_leaving) return;
    setState(() => _leaving = true);
    await ref.read(storyboardToolbarActionsProvider).leaveEditor();
    if (mounted) setState(() => _leaving = false);
  }

  /// 左侧参数面板跟随选中对象整体切换。
  ///
  /// 分镜之间是互相独立的：不只提示词，画幅、种子、角色、模型与采样参数、
  /// 图生图强度都是各分镜自己的。离开时把编辑器的当前内容写回上一个分镜，
  /// 进入时把新分镜的快照载入编辑器。放在 post-frame 里执行，避免在 build
  /// 阶段改另一个 provider。
  void _schedulePanelSwap(StoryboardInteractionState next) {
    // 拖动/缩放期间不做快照切换：那次切换会连写多次文档、每次提交都整树重建，
    // 而且写回分辨率可能改掉正在拖的分镜尺寸。松手后再补一次。
    if (next.gestureActive) return;

    final previous = _editorSelection;
    if (previous != null && _sameSelection(previous, next)) return;
    _editorSelection = next;
    // 首次选中也要载入：网格/拉框新建会自动选中新分镜，若编辑器还停在
    // 页面级参数不载入，下一次切换就会把旧参数写进这个新分镜。
    if (previous == null && !next.hasSelection) return;
    if (previous != null &&
        previous.selectedPanelId == next.selectedPanelId &&
        previous.backgroundSelected == next.backgroundSelected) {
      return;
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(_swapPanelState(previous, next));
    });
  }

  bool _sameSelection(
    StoryboardInteractionState a,
    StoryboardInteractionState b,
  ) =>
      a.selectedPanelId == b.selectedPanelId &&
      a.backgroundSelected == b.backgroundSelected;

  Future<void> _swapPanelState(
    StoryboardInteractionState? previous,
    StoryboardInteractionState next,
  ) async {
    final page = ref
        .read(storyboardDocumentControllerProvider)
        .valueOrNull
        ?.activePage;
    if (page == null) return;
    final bridge = ref.read(storyboardEditorBridgeProvider);

    // 写回：把编辑器当前状态存到刚离开的对象上；首次选中没有上一个对象，
    // 只载入不写回，避免把页面级旧参数写进分镜。
    final previousPanelId = previous?.selectedPanelId;
    if (previousPanelId != null && page.panelById(previousPanelId) != null) {
      await bridge.captureIntoPanel(previousPanelId);
    } else if (previous?.backgroundSelected == true) {
      await bridge.captureBackground();
    }

    // 载入：把新分镜的快照放进编辑器。
    final nextPanel = next.selectedPanelId == null
        ? null
        : page.panelById(next.selectedPanelId!);
    if (nextPanel != null) {
      await bridge.applyPanelToEditor(nextPanel);
    } else if (next.backgroundSelected) {
      bridge.clearBaseline();
      _setPrompt(ref, page.background.prompt, '');
    } else {
      bridge.clearBaseline();
      _setPrompt(ref, '', '');
    }
  }

  void _setPrompt(WidgetRef ref, String prompt, String negative) {
    final notifier = ref.read(generationParamsNotifierProvider.notifier);
    notifier.updatePrompt(prompt);
    notifier.updateNegativePrompt(negative);
  }

  @override
  Widget build(BuildContext context) {
    final document = ref.watch(storyboardDocumentControllerProvider);
    final page = document.valueOrNull?.activePage;
    final interaction = ref.watch(storyboardInteractionProvider);
    final isReady = document.hasValue;
    _schedulePanelSwap(interaction);

    // 选中分镜的自动画幅跟随版面：矩形被拖拽/网格/填充工具改动后，把新的
    // 请求尺寸实时同步进编辑器并刷新基准。只同步 auto 模式；用户在左侧
    // 手改过尺寸（参数与基准不符）时以手改值为准，不再覆盖。
    void syncAutoRequestSize() {
      final page = ref
          .read(storyboardDocumentControllerProvider)
          .valueOrNull
          ?.activePage;
      final interaction = ref.read(storyboardInteractionProvider);
      final panelId = interaction.selectedPanelId;
      if (page == null || panelId == null || interaction.gestureActive) {
        return;
      }
      final panel = page.panelById(panelId);
      if (panel == null || !panel.resolution.isAuto) return;
      final bridge = ref.read(storyboardEditorBridgeProvider);
      final plan = bridge.planFor(panel);
      final baseline = bridge.sizeBaseline;
      if (baseline == null) return;
      if (baseline.$1 == plan.requestWidth &&
          baseline.$2 == plan.requestHeight) {
        return;
      }
      final params = ref.read(generationParamsNotifierProvider);
      if (params.width != baseline.$1 || params.height != baseline.$2) {
        return;
      }
      ref
          .read(generationParamsNotifierProvider.notifier)
          .updateSize(plan.requestWidth, plan.requestHeight);
      bridge.markEditorSize(plan.requestWidth, plan.requestHeight);
    }

    // 网格/填充/拉框等不经手势的版面变化直接跟随。
    ref.listen(storyboardDocumentControllerProvider, (previous, next) {
      syncAutoRequestSize();
    });

    // 拖拽/缩放的文档提交发生在手势结束之前（画布先写回再清预览），提交时
    // 手势还开着会被上面跳过；松手事件在这里补一次同步。
    ref.listen(storyboardInteractionProvider, (previous, next) {
      if (previous?.gestureActive == true && !next.gestureActive) {
        syncAutoRequestSize();
      }
    });

    return LayoutBuilder(
      builder: (context, constraints) {
        final narrow = constraints.maxWidth < StoryboardView.pageChipDockBreakpoint;
        return Stack(
          children: [
            const Positioned.fill(child: StoryboardCanvas()),
            if (!isReady)
              const Positioned.fill(
                child: Center(child: CircularProgressIndicator()),
              ),
            if (isReady && page != null && page.isEmpty)
              const Positioned.fill(child: _StoryboardEmptyHint()),
            if (page != null)
              Positioned(
                left: 8,
                top: narrow ? null : 8,
                bottom: narrow ? 8 : null,
                child: _StoryboardPageChip(
                  key: const ValueKey('storyboard-page-chip'),
                  width: page.width,
                  height: page.height,
                  panelCount: page.panels.length,
                ),
              ),
            // 只给 top/right 时 Positioned 会用无界宽度量工具条：窄屏上它会按
            // 内容撑到视口左侧之外被裁掉，而且内部横向滚动失效（视口等于内容
            // 宽度，没有可滚动的余量）。用 left+right 给出有界宽度、再靠 Align
            // 贴右，工具条就始终留在视口内并保留滚动能力。
            Positioned(
              top: 8,
              left: 8,
              right: 8,
              child: Align(
                alignment: Alignment.centerRight,
                child: AbsorbPointer(
                  absorbing: _leaving,
                  child: StoryboardToolbar(onClose: _leave),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

/// 页面尺寸与分镜数量；页面坐标就是最终输出像素，这里让用户随时能看到它。
class _StoryboardPageChip extends StatelessWidget {
  const _StoryboardPageChip({
    super.key,
    required this.width,
    required this.height,
    required this.panelCount,
  });

  final int width;
  final int height;
  final int panelCount;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return IgnorePointer(
      child: Material(
        color: sectionSurfaceColor(theme.colorScheme),
        borderRadius: BorderRadius.circular(10),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.grid_view_rounded,
                size: 16,
                color: theme.colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: 6),
              Text(
                context.l10n.storyboard_pageSizeLabel(width, height),
                style: theme.textTheme.labelMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(width: 10),
              Text(
                context.l10n.storyboard_panelsLabel(panelCount),
                style: theme.textTheme.labelMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 没有分镜时的引导；不遮挡画布交互。
class _StoryboardEmptyHint extends StatelessWidget {
  const _StoryboardEmptyHint();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return IgnorePointer(
      child: Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.dashboard_customize_outlined,
                size: 40,
                color: theme.colorScheme.onSurfaceVariant,
              ),
              const SizedBox(height: 12),
              Text(
                context.l10n.storyboard_emptyTitle,
                textAlign: TextAlign.center,
                style: theme.textTheme.titleSmall,
              ),
              const SizedBox(height: 6),
              Text(
                context.l10n.storyboard_emptyHint,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
