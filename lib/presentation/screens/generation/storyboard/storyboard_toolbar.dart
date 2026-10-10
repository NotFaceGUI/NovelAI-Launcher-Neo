import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/platform/platform_capabilities.dart';
import '../../../../core/utils/app_logger.dart';
import '../../../../core/utils/image_save_utils.dart';
import '../../../../core/utils/localization_extension.dart';
import '../../../../data/models/storyboard/storyboard_page.dart';
import '../../../../data/models/storyboard/storyboard_panel.dart';
import '../../../../data/services/storyboard/storyboard_page_exporter.dart';
import '../../../../data/services/storyboard/storyboard_psd_exporter.dart';
import '../../../adaptive/interaction_policy.dart';
import '../../../providers/local_gallery_provider.dart';
import '../../../providers/storyboard/storyboard_document_controller.dart';
import '../../../providers/storyboard/storyboard_generation_runner.dart';
import '../../../providers/storyboard/storyboard_history_provider.dart';
import '../../../providers/storyboard/storyboard_interaction_provider.dart';
import '../../../providers/storyboard/storyboard_repository_provider.dart';
import '../../../providers/storyboard/storyboard_toolbar_actions.dart';
import '../../../themes/core/layered_surface_style.dart';
import 'storyboard_grid_dialog.dart';
import 'storyboard_page_settings_dialog.dart';

/// 预设的统一间距：页边距与分镜间距都是 15px。
const double kStoryboardPresetMargin = 15;
const double kStoryboardPresetGutter = 15;

/// 「导出」菜单里的动作；菜单项按平台增减，用枚举代替下标更不容易错位。
enum _StoryboardExportAction { page, panel, psd }

/// 画幅 + 版式的漫画分镜预设。
///
/// 版式用归一化单元格（0..1，顺序即阅读顺序）描述：均匀网格与「上通栏 +
/// 分割行」「强调大格」这类不规则版式共用一条路径。页面尺寸取常用生成画幅，
/// 不放大画布。
class _StoryboardLayoutPreset {
  const _StoryboardLayoutPreset({
    required this.width,
    required this.height,
    required this.cells,
    required this.label,
  });

  final int width;
  final int height;
  final List<Rect> cells;
  final String label;
}

/// 以百分比整数写单元格，模板一目了然。
Rect _cell(int left, int top, int right, int bottom) =>
    Rect.fromLTRB(left / 100, top / 100, right / 100, bottom / 100);

Rect _quad(int left, int top) =>
    _cell(left, top, left + 50, top + 50);

/// 分镜工具条：工具、预设、撤销、页面操作与退出。
///
/// 生成入口统一在左侧参数面板的生成按钮（分镜模式下自动生成选中对象），
/// 工具条不再重复放置。分镜页默认固定适应视口（触屏双指缩放、双击复位），
/// 因此这里没有缩放与平移控件——页面默认始终完整可见。与画布工具条同样是
/// 浮在画布上的 Section 色面胶囊；窄屏整条横向滚动，不压缩命中区、也不把
/// 操作藏进二级菜单。
class StoryboardToolbar extends ConsumerWidget {
  const StoryboardToolbar({super.key, required this.onClose});

  final VoidCallback onClose;

  /// 「填充最大空白」放置工具仍在打磨，先从工具条隐藏；画布里的预览与
  /// 落位逻辑保留，恢复入口改回 true 即可。
  static const bool showPlacementTool = false;

  List<_StoryboardLayoutPreset> _presets(BuildContext context) {
    final l10n = context.l10n;
    return [
      _StoryboardLayoutPreset(
        width: 1024,
        height: 1536,
        cells: [
          _quad(0, 0),
          _quad(50, 0),
          _quad(0, 50),
          _quad(50, 50),
        ],
        label: l10n.storyboard_presetFourPortrait,
      ),
      _StoryboardLayoutPreset(
        width: 1536,
        height: 1024,
        cells: [
          _quad(0, 0),
          _quad(50, 0),
          _quad(0, 50),
          _quad(50, 50),
        ],
        label: l10n.storyboard_presetFourLandscape,
      ),
      _StoryboardLayoutPreset(
        width: 1024,
        height: 1536,
        cells: [
          _cell(0, 0, 100, 33),
          _cell(0, 33, 100, 66),
          _cell(0, 66, 100, 100),
        ],
        label: l10n.storyboard_presetThreeStrip,
      ),
      _StoryboardLayoutPreset(
        width: 1024,
        height: 1536,
        cells: [
          _cell(0, 0, 50, 33),
          _cell(50, 0, 100, 33),
          _cell(0, 33, 50, 66),
          _cell(50, 33, 100, 66),
          _cell(0, 66, 50, 100),
          _cell(50, 66, 100, 100),
        ],
        label: l10n.storyboard_presetSixGrid,
      ),
      // 不规则版式：通栏混排行与强调大格，是漫画页里最常见的两种变化。
      _StoryboardLayoutPreset(
        width: 1024,
        height: 1536,
        cells: [
          _cell(0, 0, 100, 33),
          _cell(0, 33, 50, 66),
          _cell(50, 33, 100, 66),
          _cell(0, 66, 100, 100),
        ],
        label: l10n.storyboard_presetClassicTop,
      ),
      _StoryboardLayoutPreset(
        width: 1024,
        height: 1536,
        cells: [
          _cell(0, 0, 62, 100),
          _cell(62, 0, 100, 50),
          _cell(62, 50, 100, 100),
        ],
        label: l10n.storyboard_presetLeftTall,
      ),
      _StoryboardLayoutPreset(
        width: 1024,
        height: 1536,
        cells: [
          _cell(0, 0, 100, 50),
          _cell(0, 50, 33, 100),
          _cell(33, 50, 66, 100),
          _cell(66, 50, 100, 100),
        ],
        label: l10n.storyboard_presetTopBig,
      ),
      _StoryboardLayoutPreset(
        width: 1024,
        height: 1024,
        cells: [
          _cell(0, 0, 100, 42),
          _cell(0, 42, 55, 72),
          _cell(55, 42, 100, 72),
          _cell(0, 72, 100, 100),
        ],
        label: l10n.storyboard_presetSquareMixed,
      ),
    ];
  }

  /// 归一化单元格 → 页面像素矩形：内容区按 15px 页边距收缩，内部边缘各收
  /// 半格间距，相邻分镜之间正好留出 15px。
  List<Rect> _presetRects(_StoryboardLayoutPreset preset) {
    final innerWidth = preset.width - kStoryboardPresetMargin * 2;
    final innerHeight = preset.height - kStoryboardPresetMargin * 2;
    const half = kStoryboardPresetGutter / 2;
    return [
      for (final cell in preset.cells)
        Rect.fromLTRB(
          kStoryboardPresetMargin +
              cell.left * innerWidth +
              (cell.left > 0.001 ? half : 0),
          kStoryboardPresetMargin +
              cell.top * innerHeight +
              (cell.top > 0.001 ? half : 0),
          kStoryboardPresetMargin +
              cell.right * innerWidth -
              (cell.right < 0.999 ? half : 0),
          kStoryboardPresetMargin +
              cell.bottom * innerHeight -
              (cell.bottom < 0.999 ? half : 0),
        ),
    ];
  }

  /// 应用预设：改画幅与间距，再按版式重排整页（替换现有分镜）。
  Future<void> _applyPreset(
    BuildContext context,
    WidgetRef ref,
    StoryboardPage page,
    _StoryboardLayoutPreset preset,
  ) async {
    // 跨异步间隙使用的是 await 前捕获的 messenger 与文案。
    final messenger = ScaffoldMessenger.maybeOf(context);
    final tooSmallText = context.l10n.storyboard_gridTooSmall;
    final document = ref.read(storyboardDocumentControllerProvider.notifier);
    document.beginGesture();
    await document.setPageSize(width: preset.width, height: preset.height);
    await document.setPageSpacing(
      margin: kStoryboardPresetMargin,
      gutter: kStoryboardPresetGutter,
    );
    final created = await document.applyPanelLayout(
      [
        for (final rect in _presetRects(preset))
          StoryboardLayoutCell(rect: rect),
      ],
      replace: true,
    );
    if (created == 0) {
      messenger?.showSnackBar(SnackBar(content: Text(tooSmallText)));
    }
  }

  /// 导出整页合成图：按页面像素渲染并落进图库。
  Future<void> _exportPage(
    BuildContext context,
    WidgetRef ref,
    StoryboardPage page,
    String galleryRoot,
  ) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    final doneText = context.l10n.storyboard_exportDone;
    final failedText = context.l10n.storyboard_exportFailed;
    try {
      final bytes = await StoryboardPageExporter.renderPage(
        page: page,
        galleryRoot: galleryRoot,
      );
      await _saveToGallery(ref, bytes, galleryRoot, 'storyboard-page');
      messenger?.showSnackBar(SnackBar(content: Text(doneText)));
    } catch (error, stackTrace) {
      AppLogger.e('导出整页分镜失败', error, stackTrace, 'StoryboardExport');
      messenger?.showSnackBar(SnackBar(content: Text(failedText)));
    }
  }

  /// 导出单个分镜（含多边形裁剪）。
  Future<void> _exportPanel(
    BuildContext context,
    WidgetRef ref,
    StoryboardPage page,
    StoryboardPanel panel,
    String galleryRoot,
  ) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    final doneText = context.l10n.storyboard_exportDone;
    final failedText = context.l10n.storyboard_exportFailed;
    try {
      final bytes = await StoryboardPageExporter.renderPanel(
        page: page,
        panel: panel,
        galleryRoot: galleryRoot,
      );
      await _saveToGallery(ref, bytes, galleryRoot, 'storyboard-panel');
      messenger?.showSnackBar(SnackBar(content: Text(doneText)));
    } catch (error, stackTrace) {
      AppLogger.e('导出分镜失败', error, stackTrace, 'StoryboardExport');
      messenger?.showSnackBar(SnackBar(content: Text(failedText)));
    }
  }

  /// 导出分层 PSD：一个分镜页一个文件，背景与每个分镜各自成层。
  ///
  /// PSD 不是图库能显示的图片格式，因此只落盘，不进入图库即时列表。
  Future<void> _exportPsd(
    BuildContext context,
    WidgetRef ref,
    StoryboardPage page,
    String galleryRoot,
  ) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    final doneText = context.l10n.storyboard_exportDone;
    final failedText = context.l10n.storyboard_exportFailed;
    final tooLargeText = context.l10n.storyboard_exportPsdTooLarge;
    final canvasTooLargeText = context.l10n.storyboard_exportPsdCanvasTooLarge;
    final labels = StoryboardPsdLabels(
      background: context.l10n.storyboard_exportPsdLayerBackground,
      maskSuffix: context.l10n.storyboard_exportPsdLayerMask,
      imageSuffix: context.l10n.storyboard_exportPsdLayerImage,
    );
    try {
      final bytes = await StoryboardPsdExporter.exportPage(
        page: page,
        galleryRoot: galleryRoot,
        labels: labels,
      );
      await ImageSaveUtils.saveBytesToDatedPath(
        rootPath: galleryRoot,
        bytes: bytes,
        preferredFileName: 'storyboard-page',
        extension: 'psd',
      );
      messenger?.showSnackBar(SnackBar(content: Text(doneText)));
    } on StoryboardPsdCanvasTooLargeException {
      messenger?.showSnackBar(SnackBar(content: Text(canvasTooLargeText)));
    } on StoryboardPsdTooLargeException {
      messenger?.showSnackBar(SnackBar(content: Text(tooLargeText)));
    } catch (error, stackTrace) {
      AppLogger.e('导出分层 PSD 失败', error, stackTrace, 'StoryboardExport');
      messenger?.showSnackBar(SnackBar(content: Text(failedText)));
    }
  }

  Future<void> _saveToGallery(
    WidgetRef ref,
    List<int> bytes,
    String galleryRoot,
    String fileName,
  ) async {
    final path = await ImageSaveUtils.saveBytesToDatedPath(
      rootPath: galleryRoot,
      bytes: Uint8List.fromList(bytes),
      preferredFileName: fileName,
    );
    final gallery = ref.read(localGalleryNotifierProvider.notifier);
    await gallery.addNewlySavedImages([path]);
    unawaited(gallery.refresh());
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final page = ref
        .watch(storyboardDocumentControllerProvider)
        .valueOrNull
        ?.activePage;
    final tool = ref.watch(
      storyboardInteractionProvider.select((state) => state.tool),
    );
    final selectedPanelId = ref.watch(
      storyboardInteractionProvider.select((state) => state.selectedPanelId),
    );
    final generation = ref.watch(storyboardGenerationRunnerProvider);
    final placingFillLargest = ref.watch(
      storyboardInteractionProvider.select((s) => s.placingFillLargest),
    );
    final galleryRoot = ref
        .watch(storyboardGalleryRootPathProvider)
        .valueOrNull;
    final previewMode = ref.watch(
      storyboardInteractionProvider.select((s) => s.previewMode),
    );

    final history = ref.watch(storyboardHistoryProvider);
    final document = ref.read(storyboardDocumentControllerProvider.notifier);
    final presets = _presets(context);

    // 入口隐藏后放置模式不能再被关闭；热重载残留的开启态在这里兜底退出。
    if (!showPlacementTool && placingFillLargest) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        ref
            .read(storyboardInteractionProvider.notifier)
            .setPlacingFillLargest(false);
      });
    }

    return Material(
      color: sectionSurfaceColor(theme.colorScheme),
      borderRadius: BorderRadius.circular(14),
      clipBehavior: Clip.antiAlias,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            ToolbarButton(
              icon: Icons.near_me_outlined,
              tooltip: context.l10n.storyboard_toolSelect,
              selected: tool == StoryboardTool.select,
              onPressed: () => ref
                  .read(storyboardInteractionProvider.notifier)
                  .setTool(StoryboardTool.select),
            ),
            ToolbarButton(
              icon: Icons.crop_free_rounded,
              tooltip: context.l10n.storyboard_toolDraw,
              selected: tool == StoryboardTool.drawRect,
              onPressed: () => ref
                  .read(storyboardInteractionProvider.notifier)
                  .setTool(StoryboardTool.drawRect),
            ),
            const ToolbarDivider(),
            ToolbarButton(
              icon: Icons.expand_rounded,
              tooltip: context.l10n.storyboard_fillRemaining,
              onPressed: page == null ||
                      selectedPanelId == null ||
                      generation.isRunning
                  ? null
                  : () {
                      ref
                          .read(storyboardToolbarActionsProvider)
                          .fillRemaining(selectedPanelId);
                    },
            ),
            const ToolbarDivider(),
            PopupMenuButton<int>(
              tooltip: context.l10n.storyboard_presetMenu,
              enabled: page != null && !generation.isRunning,
              icon: Icon(
                Icons.auto_awesome_motion_outlined,
                size: 20,
                color: generation.isRunning || page == null
                    ? theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.38)
                    : theme.colorScheme.onSurfaceVariant,
              ),
              color: overlaySurfaceColor(theme.colorScheme),
              onSelected: (index) {
                final target = page;
                if (target == null || generation.isRunning) return;
                unawaited(
                  _applyPreset(context, ref, target, presets[index]),
                );
              },
              itemBuilder: (context) => [
                for (
                  var index = 0;
                  index < presets.length;
                  index++
                )
                  PopupMenuItem(
                    value: index,
                    height: 40,
                    child: Text(presets[index].label),
                  ),
              ],
            ),
            const ToolbarDivider(),
            PopupMenuButton<_StoryboardExportAction>(
              tooltip: context.l10n.storyboard_export,
              enabled: page != null && !generation.isRunning,
              icon: Icon(
                Icons.save_alt_rounded,
                size: 20,
                color: generation.isRunning || page == null
                    ? theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.38)
                    : theme.colorScheme.onSurfaceVariant,
              ),
              color: overlaySurfaceColor(theme.colorScheme),
              onSelected: (action) {
                final target = page;
                final root = galleryRoot;
                if (target == null || generation.isRunning) return;
                if (root == null || root.isEmpty) {
                  ScaffoldMessenger.maybeOf(context)?.showSnackBar(
                    SnackBar(
                      content: Text(context.l10n.storyboard_exportFailed),
                    ),
                  );
                  return;
                }
                switch (action) {
                  case _StoryboardExportAction.page:
                    unawaited(_exportPage(context, ref, target, root));
                  case _StoryboardExportAction.psd:
                    unawaited(_exportPsd(context, ref, target, root));
                  case _StoryboardExportAction.panel:
                    final selected = selectedPanelId == null
                        ? null
                        : target.panelById(selectedPanelId);
                    if (selected == null ||
                        selected.selectedImage == null ||
                        selected.selectedImage!.isEmpty) {
                      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
                        SnackBar(
                          content: Text(context.l10n.storyboard_exportEmpty),
                        ),
                      );
                      return;
                    }
                    unawaited(
                      _exportPanel(context, ref, target, selected, root),
                    );
                }
              },
              itemBuilder: (context) => [
                PopupMenuItem(
                  value: _StoryboardExportAction.page,
                  height: 40,
                  child: Text(context.l10n.storyboard_exportPage),
                ),
                PopupMenuItem(
                  value: _StoryboardExportAction.panel,
                  height: 40,
                  child: Text(context.l10n.storyboard_exportPanel),
                ),
                // PSD 需要在桌面端用 Photoshop / Krita 继续编辑，移动端不提供。
                if (PlatformCapabilities.current.isDesktop)
                  PopupMenuItem(
                    value: _StoryboardExportAction.psd,
                    height: 40,
                    child: Text(context.l10n.storyboard_exportPsd),
                  ),
              ],
            ),
            const ToolbarDivider(),
            ToolbarButton(
              icon: previewMode
                  ? Icons.visibility_rounded
                  : Icons.visibility_outlined,
              tooltip: context.l10n.storyboard_preview,
              selected: previewMode,
              onPressed: () => ref
                  .read(storyboardInteractionProvider.notifier)
                  .setPreviewMode(!previewMode),
            ),
            const ToolbarDivider(),
            ToolbarButton(
              icon: Icons.undo_rounded,
              tooltip: context.l10n.storyboard_undo,
              onPressed: history.undoDepth > 0 ? document.undo : null,
            ),
            ToolbarButton(
              icon: Icons.redo_rounded,
              tooltip: context.l10n.storyboard_redo,
              onPressed: history.redoDepth > 0 ? document.redo : null,
            ),
            const ToolbarDivider(),
            ToolbarButton(
              icon: Icons.grid_view_rounded,
              tooltip: context.l10n.storyboard_gridTitle,
              onPressed: page == null
                  ? null
                  : () => showStoryboardGridDialog(context, ref, page),
            ),
            ToolbarButton(
              icon: Icons.tune_rounded,
              tooltip: context.l10n.storyboard_pageSettings,
              onPressed: page == null
                  ? null
                  : () => showStoryboardPageSettingsDialog(context, page),
            ),
            const ToolbarDivider(),
            ToolbarButton(
              icon: Icons.close_fullscreen_rounded,
              tooltip: context.l10n.storyboard_close,
              onPressed: onClose,
            ),
          ],
        ),
      ),
    );
  }
}

/// 工具条按钮；选中态用 primary 容器色，禁用态降低前景不透明度。
class ToolbarButton extends StatelessWidget {
  const ToolbarButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.selected = false,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final enabled = onPressed != null;
    final extent = context.interactionPolicy.minimumControlExtent.clamp(
      36.0,
      48.0,
    );
    return Tooltip(
      message: tooltip,
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onPressed,
        child: Container(
          width: extent,
          height: extent,
          decoration: selected
              ? BoxDecoration(
                  color: scheme.primaryContainer,
                  borderRadius: BorderRadius.circular(10),
                )
              : null,
          child: Icon(
            icon,
            size: 20,
            color: !enabled
                ? scheme.onSurfaceVariant.withValues(alpha: 0.38)
                : selected
                ? scheme.onPrimaryContainer
                : scheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}

class ToolbarDivider extends StatelessWidget {
  const ToolbarDivider({super.key});

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 4),
    child: SizedBox(
      height: 20,
      child: VerticalDivider(
        width: 1,
        thickness: 1,
        // 与画布工具条同一分割线颜色，两个工作区的观感保持一致。
        color: Theme.of(context).dividerColor,
      ),
    ),
  );
}
