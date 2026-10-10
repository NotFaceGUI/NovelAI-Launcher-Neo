import 'dart:async';

import 'package:nai_launcher/presentation/widgets/common/horizontal_action_strip.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/utils/localization_extension.dart';
import '../../../../data/models/canvas/canvas_node.dart';
import '../../../../data/models/canvas/canvas_node_params.dart';
import '../../../../data/models/gallery/nai_image_metadata.dart';
import '../../../adaptive/interaction_policy.dart';
import '../../../providers/generation/generated_image_metadata_provider.dart';
import '../../../providers/image_generation_provider.dart';
import '../../../providers/preview_transparency_provider.dart';
import '../../../widgets/common/image_card_action_region.dart';
import '../../../widgets/common/image_card_context_menu.dart';
import '../../../widgets/common/transparency_background.dart';
import '../../../widgets/image_editor/widgets/color_picker.dart';
import '../canvas/canvas_actions.dart';

/// 预览图下方的信息条（对齐官网结果区底部的 display/save 工具条）
///
/// 自左向右：分辨率胶囊 → 透明底色入口 → 可选对比开关 → 种子胶囊。
/// 透明底色入口向上弹出档位浮层；触屏设备把「更多操作」放在最右侧，与图片浮层
/// 按钮共用同一份动作列表，浮层按钮因此不再压在画面上。
class PreviewInfoBar extends ConsumerWidget {
  final GeneratedImage image;
  final bool comparisonEnabled;
  final ValueChanged<bool>? onComparisonChanged;

  const PreviewInfoBar({
    super.key,
    required this.image,
    this.comparisonEnabled = false,
    this.onComparisonChanged,
  });

  static const double barHeight = 44;

  static double heightFor(BuildContext context) {
    final scaledLine = MediaQuery.textScalerOf(context).scale(14) + 20;
    return scaledLine < barHeight ? barHeight : scaledLine;
  }

  /// 低于该宽度就收起分辨率胶囊（官网在窄容器下同样隐藏它）
  static const double _resolutionMinWidth = 300;
  static const double _comparisonResolutionMinWidth = 400;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 种子要等 PNG 元数据解析完才知道，解析期间先不占位
    final metadata = ref
        .watch(generatedImageMetadataProvider(image))
        .valueOrNull;
    final seed = metadata?.seed;
    final showMoreActions = context.interactionPolicy.usesTouchActionMenu;

    return SizedBox(
      height: heightFor(context),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final resolutionMinWidth = onComparisonChanged == null
              ? _resolutionMinWidth
              : _comparisonResolutionMinWidth;
          final showResolution =
              !constraints.maxWidth.isFinite ||
              constraints.maxWidth >= resolutionMinWidth;

          final compactInfo = !showResolution && onComparisonChanged == null;
          final info = compactInfo
              ? Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const _TransparencyBackgroundButton(),
                    if (seed != null && seed >= 0)
                      Flexible(child: _SeedPill(seed: seed, compact: true)),
                  ],
                )
              : HorizontalActionStrip(
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (showResolution) ...[
                        _InfoPill(
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text('${image.width}'),
                              const Padding(
                                padding: EdgeInsets.symmetric(horizontal: 6),
                                child: Icon(Icons.close_rounded, size: 11),
                              ),
                              Text('${image.height}'),
                            ],
                          ),
                        ),
                        const _PillDivider(),
                      ],
                      const _TransparencyBackgroundButton(),
                      if (onComparisonChanged != null) ...[
                        const _PillDivider(),
                        _ComparisonToggle(
                          enabled: comparisonEnabled,
                          onChanged: onComparisonChanged!,
                        ),
                      ],
                      if (seed != null && seed >= 0) ...[
                        const SizedBox(width: 6),
                        _SeedPill(seed: seed),
                      ],
                      const SizedBox(width: 6),
                      _AddToCanvasButton(image: image, metadata: metadata),
                    ],
                  ),
                );
          if (!showMoreActions) return info;

          return Row(
            children: [
              Expanded(child: info),
              const SizedBox(width: 6),
              const _MoreActionsButton(),
            ],
          );
        },
      ),
    );
  }
}

/// 「更多操作」入口。
///
/// 动作取自卡片动作作用域，与长按/右键路径是同一份已绑定列表，因此菜单内容与
/// 卡片完全一致；入口放在信息条里，图片上不再有浮层按钮压住画面。
class _MoreActionsButton extends StatelessWidget {
  const _MoreActionsButton();

  @override
  Widget build(BuildContext context) {
    final scope = ImageCardActionPresentationScope.maybeOf(context);
    final actions = scope?.menuActions;
    if (scope == null || actions == null || actions.isEmpty) {
      return const SizedBox.shrink();
    }
    return Semantics(
      button: true,
      label: context.l10n.common_moreActions,
      child: _InfoPill(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        tooltip: context.l10n.common_moreActions,
        onTap: () => unawaited(
          ImageCardContextMenu.show(
            context: context,
            position: Offset.zero,
            actions: actions,
            title: scope.menuTitle,
            listenable: scope.menuRunner,
          ),
        ),
        child: const Icon(Icons.more_horiz_rounded, size: 16),
      ),
    );
  }
}

/// 只读信息胶囊
class _InfoPill extends StatelessWidget {
  final Widget child;
  final VoidCallback? onTap;
  final String? tooltip;
  final bool selected;
  final EdgeInsetsGeometry padding;

  const _InfoPill({
    required this.child,
    this.onTap,
    this.tooltip,
    this.selected = false,
    this.padding = const EdgeInsets.symmetric(horizontal: 10),
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    Widget pill = Material(
      color: selected ? theme.colorScheme.primaryContainer : Colors.transparent,
      borderRadius: BorderRadius.circular(6),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(
            minHeight: PreviewInfoBar.barHeight,
          ),
          child: Padding(
            padding: padding,
            // widthFactor 让胶囊按内容收窄：种子胶囊在 Flexible 里拿到的是有界宽度，
            // 普通 Center 会撑满剩余空间，把胶囊拉成一条长条
            child: Align(
              alignment: Alignment.center,
              widthFactor: 1,
              child: DefaultTextStyle.merge(
                style: theme.textTheme.bodySmall?.copyWith(
                  color: selected
                      ? theme.colorScheme.onPrimaryContainer
                      : theme.colorScheme.onSurface.withValues(alpha: 0.85),
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
                child: IconTheme.merge(
                  data: IconThemeData(
                    color: selected
                        ? theme.colorScheme.onPrimaryContainer
                        : theme.colorScheme.onSurface.withValues(alpha: 0.6),
                  ),
                  child: child,
                ),
              ),
            ),
          ),
        ),
      ),
    );

    if (tooltip != null) {
      pill = Tooltip(
        message: tooltip!,
        waitDuration: const Duration(milliseconds: 400),
        child: pill,
      );
    }
    return pill;
  }
}

class _ComparisonToggle extends StatelessWidget {
  const _ComparisonToggle({required this.enabled, required this.onChanged});

  final bool enabled;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final label = context.l10n.generation_imageComparison;
    return Semantics(
      button: true,
      toggled: enabled,
      label: label,
      child: _InfoPill(
        selected: enabled,
        tooltip: context.l10n.generation_imageComparisonHint,
        onTap: () => onChanged(!enabled),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.compare_rounded, size: 14),
            const SizedBox(width: 6),
            Text(label),
          ],
        ),
      ),
    );
  }
}

class _PillDivider extends StatelessWidget {
  const _PillDivider();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: 1,
      height: 14,
      margin: const EdgeInsets.symmetric(horizontal: 8),
      color: theme.dividerColor,
    );
  }
}

/// 种子胶囊：点击把这张图的种子写回生成参数
class _SeedPill extends ConsumerWidget {
  final int seed;
  final bool compact;

  const _SeedPill({required this.seed, this.compact = false});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return _InfoPill(
      padding: EdgeInsets.symmetric(horizontal: compact ? 2 : 10),
      tooltip: context.l10n.generation_previewApplySeed,
      onTap: () =>
          ref.read(generationParamsNotifierProvider.notifier).updateSeed(seed),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.eco_outlined, size: 13),
          SizedBox(width: compact ? 4 : 6),
          Flexible(
            child: Text('$seed', maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
        ],
      ),
    );
  }
}

/// 把当前预览图加入无限画布。
///
/// 放在种子胶囊右侧，是「加入画布」最直接的入口：不必打开右键菜单。
/// 图片尚未落盘时由导入器先保存到图库再以相对路径引用。
class _AddToCanvasButton extends ConsumerWidget {
  const _AddToCanvasButton({required this.image, required this.metadata});

  final GeneratedImage image;
  final NaiImageMetadata? metadata;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final filePath = image.filePath;
    final hasPath = filePath != null && filePath.isNotEmpty;
    return _InfoPill(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      tooltip: context.l10n.infinite_canvas_addCurrentImage,
      onTap: () => addImageToCanvas(
        context: context,
        ref: ref,
        filePath: hasPath ? filePath : null,
        bytes: hasPath ? null : image.bytes,
        seed: metadata?.seed,
        params: metadata == null
            ? null
            : CanvasNodeParams.fromImageMetadata(metadata!),
        aspectRatio: CanvasNode.resolveAspectRatio(
          width: metadata?.width,
          height: metadata?.height,
          fallback: image.aspectRatio,
        ),
      ),
      child: const Icon(Icons.push_pin_outlined, size: 14),
    );
  }
}

/// 透明底色入口：向上弹出档位浮层
class _TransparencyBackgroundButton extends StatefulWidget {
  const _TransparencyBackgroundButton();

  @override
  State<_TransparencyBackgroundButton> createState() =>
      _TransparencyBackgroundButtonState();
}

class _TransparencyBackgroundButtonState
    extends State<_TransparencyBackgroundButton> {
  final OverlayPortalController _controller = OverlayPortalController();
  final LayerLink _link = LayerLink();
  bool _alignPanelToLeft = false;

  void _close() {
    if (_controller.isShowing) _controller.hide();
  }

  void _togglePanel() {
    if (!_controller.isShowing) {
      final targetBox = context.findRenderObject() as RenderBox?;
      final overlayBox =
          Overlay.of(context).context.findRenderObject() as RenderBox?;
      if (targetBox != null && overlayBox != null) {
        final targetOrigin = targetBox.localToGlobal(
          Offset.zero,
          ancestor: overlayBox,
        );
        final fitsOnRight =
            targetOrigin.dx + _TransparencyBackgroundPanel.width <=
            overlayBox.size.width;
        _alignPanelToLeft = fitsOnRight;
      }
    }

    setState(_controller.toggle);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // 浮层打开时保留状态高亮，常态透明不影响 InkWell 的交互反馈。
    final selected = _controller.isShowing;

    return CompositedTransformTarget(
      link: _link,
      child: OverlayPortal(
        controller: _controller,
        overlayChildBuilder: (context) {
          return Stack(
            children: [
              // 点击浮层外部关闭
              Positioned.fill(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: _close,
                ),
              ),
              CompositedTransformFollower(
                link: _link,
                targetAnchor: _alignPanelToLeft
                    ? Alignment.topLeft
                    : Alignment.topRight,
                followerAnchor: _alignPanelToLeft
                    ? Alignment.bottomLeft
                    : Alignment.bottomRight,
                offset: const Offset(0, -5),
                child: const _TransparencyBackgroundPanel(),
              ),
            ],
          );
        },
        child: Tooltip(
          message: context.l10n.generation_transparencyBackgroundTitle,
          waitDuration: const Duration(milliseconds: 400),
          child: Material(
            color: selected
                ? theme.colorScheme.primary.withValues(alpha: 0.18)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(6),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: _togglePanel,
              child: ConstrainedBox(
                constraints: const BoxConstraints(
                  minWidth: PreviewInfoBar.barHeight,
                  minHeight: PreviewInfoBar.barHeight,
                ),
                child: Center(
                  child: TransparencyBackgroundIcon(
                    size: 16,
                    color: selected
                        ? theme.colorScheme.primary
                        : theme.colorScheme.onSurface.withValues(alpha: 0.7),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 透明底色档位浮层
class _TransparencyBackgroundPanel extends ConsumerStatefulWidget {
  const _TransparencyBackgroundPanel();

  static const double width = 232;

  @override
  ConsumerState<_TransparencyBackgroundPanel> createState() =>
      _TransparencyBackgroundPanelState();
}

class _TransparencyBackgroundPanelState
    extends ConsumerState<_TransparencyBackgroundPanel> {
  bool _customExpanded = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;
    final style = ref.watch(previewTransparencyNotifierProvider);
    final notifier = ref.read(previewTransparencyNotifierProvider.notifier);
    final isCustom = TransparencyBackgrounds.isCustomColor(style);

    final checkerSwatches = <_SwatchSpec>[
      _SwatchSpec(
        value: TransparencyBackgrounds.checker,
        label: l10n.generation_transparencyChecker,
      ),
      _SwatchSpec(
        value: TransparencyBackgrounds.checkerLight,
        label: l10n.generation_transparencyCheckerLight,
      ),
      _SwatchSpec(
        value: TransparencyBackgrounds.checkerDark,
        label: l10n.generation_transparencyCheckerDark,
      ),
      _SwatchSpec(
        value: TransparencyBackgrounds.none,
        label: l10n.generation_transparencyNone,
      ),
    ];

    final solidLabels = <String, String>{
      'black': l10n.generation_transparencyBlack,
      'white': l10n.generation_transparencyWhite,
      'gray': l10n.generation_transparencyGray,
      'red': l10n.generation_transparencyRed,
      'green': l10n.generation_transparencyGreen,
      'blue': l10n.generation_transparencyBlue,
    };

    return Material(
      key: const ValueKey('generation_transparency_background_panel'),
      elevation: 8,
      borderRadius: BorderRadius.circular(6),
      clipBehavior: Clip.antiAlias,
      color: theme.colorScheme.surfaceContainerHigh,
      child: Container(
        width: _TransparencyBackgroundPanel.width,
        padding: const EdgeInsets.all(10),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              l10n.generation_transparencyBackgroundTitle,
              style: theme.textTheme.labelMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final swatch in checkerSwatches)
                  _Swatch(
                    tooltip: swatch.label,
                    selected: style == swatch.value,
                    onTap: () => notifier.setStyle(swatch.value),
                    child: _SwatchPreview(style: swatch.value),
                  ),
              ],
            ),
            const SizedBox(height: 6),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final entry in TransparencyBackgrounds.solidColors.entries)
                  _Swatch(
                    tooltip: solidLabels[entry.key] ?? entry.key,
                    selected: style == entry.key,
                    onTap: () => notifier.setStyle(entry.key),
                    child: ColoredBox(color: entry.value),
                  ),
                _Swatch(
                  tooltip: l10n.generation_transparencyCustom,
                  selected: isCustom,
                  onTap: () =>
                      setState(() => _customExpanded = !_customExpanded),
                  child: isCustom
                      ? ColoredBox(
                          color: TransparencyBackgrounds.parseCustomColor(
                            style,
                          )!,
                        )
                      : Icon(
                          Icons.colorize_rounded,
                          size: 13,
                          color: theme.colorScheme.onSurface.withValues(
                            alpha: 0.7,
                          ),
                        ),
                ),
              ],
            ),
            if (_customExpanded) ...[
              const SizedBox(height: 10),
              SizedBox(
                height: 150,
                child: HSVColorPicker(
                  color:
                      TransparencyBackgrounds.parseCustomColor(style) ??
                      const Color(0xFF808080),
                  hexLabel: context.l10n.editor_colorHex,
                  saturationBrightnessLabel:
                      context.l10n.editor_colorSaturationBrightness,
                  hueLabel: context.l10n.editor_colorHue,
                  onColorChanged: (color) => notifier.setStyle(
                    TransparencyBackgrounds.encodeCustomColor(color),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _SwatchSpec {
  final String value;
  final String label;

  const _SwatchSpec({required this.value, required this.label});
}

/// 色板格子：24×24，选中时描主题色边框
class _Swatch extends StatelessWidget {
  final Widget child;
  final bool selected;
  final String tooltip;
  final VoidCallback onTap;

  const _Swatch({
    required this.child,
    required this.selected,
    required this.tooltip,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Tooltip(
      message: tooltip,
      waitDuration: const Duration(milliseconds: 400),
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          width: 24,
          height: 24,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(4),
            border: Border.all(
              color: selected ? theme.colorScheme.primary : theme.dividerColor,
              width: selected ? 2 : 1,
            ),
          ),
          clipBehavior: Clip.antiAlias,
          child: Center(child: SizedBox.expand(child: child)),
        ),
      ),
    );
  }
}

/// 棋盘格/无 档位的格子预览
class _SwatchPreview extends StatelessWidget {
  final String style;

  const _SwatchPreview({required this.style});

  @override
  Widget build(BuildContext context) {
    if (style == TransparencyBackgrounds.none) {
      final theme = Theme.of(context);
      // 官网用一条对角线表示"不铺底色"
      return CustomPaint(
        painter: _DiagonalSlashPainter(color: theme.colorScheme.onSurface),
      );
    }
    return TransparencyBackgroundLayer(style: style);
  }
}

class _DiagonalSlashPainter extends CustomPainter {
  final Color color;

  const _DiagonalSlashPainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawLine(
      Offset(0, size.height),
      Offset(size.width, 0),
      Paint()
        ..color = color
        ..strokeWidth = 2,
    );
  }

  @override
  bool shouldRepaint(_DiagonalSlashPainter oldDelegate) =>
      oldDelegate.color != color;
}
