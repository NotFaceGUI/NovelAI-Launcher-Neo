import 'package:nai_launcher/data/models/image/image_postprocess_phase.dart';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/models/image/image_stream_chunk.dart';
import '../../providers/mosaic_settings_provider.dart';
import '../../providers/watermark_settings_provider.dart';
import 'image_card_actions.dart';
import 'image_card_context_menu.dart';
import 'image_card_controller.dart';
import 'image_card_generating.dart';
import 'image_card_models.dart';
import 'image_card_surface.dart';
import 'image_card_action_region.dart';
import 'image_card_batch_scope.dart';
import '../../selection/card_selection_scope.dart';

export 'image_card_actions.dart'
    show ImageClipboardWriter, imageClipboardWriterProvider;

/// 可选择的图像卡片。构造契约保持兼容，内部状态与视图由专属组件协作。
class SelectableImageCard extends ConsumerStatefulWidget {
  const SelectableImageCard({
    super.key,
    this.imageBytes,
    this.index,
    this.isSelected = false,
    this.showIndex = true,
    this.onTap,
    this.onDoubleTap,
    this.onLongPress,
    this.onSelectionChanged,
    this.onFullscreen,
    this.isPreviewActive = false,
    this.imageIdentity,
    this.allowRepeatedModifierTaps = false,
    this.enableContextMenu = true,
    this.enableHoverScale = true,
    this.enableGlossEffect = false,
    this.hoverEffectsEnabled = true,
    this.shareWarmupEnabled = true,
    this.enableSaveAction = true,
    this.enableCopyAction = true,
    this.statusBadgeLabel,
    this.statusBadgeTooltip,
    this.dragPreparationReady = true,
    this.completionPreview,
    this.enableSelection = true,
    this.selectionMode = false,
    this.showSelectionOnHover = true,
    this.onUpscale,
    this.onReversePrompt,
    this.onImageToImage,
    this.onVibeTransfer,
    this.onPreciseReference,
    this.onSaveToPreciseRefLibrary,
    this.onEditImage,
    this.onInpaint,
    this.onGenerateVariations,
    this.onDirectorTools,
    this.onEnhance,
    this.onSendToKrita,
    this.onShareToDiscord,
    this.onOpenInExplorer,
    this.sourceFilePath,
    this.onSaveToLibrary,
    this.isFavorite = false,
    this.onFavoriteToggle,
    this.underlay,
    this.imageContent,
    this.isGenerating = false,
    this.progress,
    this.postprocessPhase,
    this.currentImage,
    this.totalImages,
    this.streamPreview,
    this.focusedPreviewPlacement,
    this.imageWidth,
    this.imageHeight,
    this.footer,
    this.surfaceWrapper,
    this.showTouchMoreButton = true,
  }) : assert(
         !isGenerating || (imageWidth != null && imageHeight != null),
         'imageWidth and imageHeight are required when isGenerating is true',
       );

  final Uint8List? imageBytes;
  final int? index;
  final bool isSelected;
  final bool showIndex;
  final VoidCallback? onTap;
  final VoidCallback? onDoubleTap;
  final VoidCallback? onLongPress;
  final ValueChanged<bool>? onSelectionChanged;
  final ImageCardCallback? onFullscreen;
  final bool isPreviewActive;
  final Object? imageIdentity;
  final bool allowRepeatedModifierTaps;
  final bool enableContextMenu;
  final bool enableHoverScale;
  final bool enableGlossEffect;
  final bool hoverEffectsEnabled;
  final bool shareWarmupEnabled;
  final bool enableSaveAction;
  final bool enableCopyAction;
  final String? statusBadgeLabel;
  final String? statusBadgeTooltip;
  final bool dragPreparationReady;
  final StreamPreviewFrame? completionPreview;
  final bool enableSelection;
  final bool selectionMode;
  final bool showSelectionOnHover;
  final ImageCardCallback? onUpscale;
  final ImageCardCallback? onReversePrompt;
  final ImageCardCallback? onImageToImage;
  final ImageCardCallback? onVibeTransfer;
  final ImageCardCallback? onPreciseReference;
  final ImageCardCallback? onSaveToPreciseRefLibrary;
  final ImageCardCallback? onEditImage;
  final ImageCardCallback? onInpaint;
  final ImageCardCallback? onGenerateVariations;
  final ImageCardCallback? onDirectorTools;
  final ImageCardCallback? onEnhance;
  final ImageCardCallback? onSendToKrita;
  final ImageCardCallback? onShareToDiscord;
  final ImageCardCallback? onOpenInExplorer;
  final String? sourceFilePath;
  final void Function(Uint8List imageBytes, String prompt)? onSaveToLibrary;
  final bool isFavorite;
  final ImageCardCallback? onFavoriteToggle;
  final Widget? underlay;
  final Widget? imageContent;
  final bool isGenerating;
  final double? progress;
  final ImagePostprocessPhase? postprocessPhase;
  final int? currentImage;
  final int? totalImages;
  final Uint8List? streamPreview;
  final FocusedStreamPreviewPlacement? focusedPreviewPlacement;
  final int? imageWidth;
  final int? imageHeight;

  /// 图片下方固定呈现的页脚（预览页用来放信息条）。
  ///
  /// 页脚留在卡片的动作作用域内，页脚上的入口与图片浮层按钮打开同一份动作列表；
  /// 给出页脚时卡片按「图片占剩余高度 + 页脚自身高度」分配，调用方需要给卡片
  /// 一个有界高度。
  final Widget? footer;

  /// 只包裹图片表面的包装器（预览页用它挂拖拽反馈）。
  ///
  /// 页脚不参与包裹：从信息条上拖动不应被当成拖出图片。
  final Widget Function(Widget child)? surfaceWrapper;

  /// 触屏端是否保留浮在图片上的「更多操作」按钮。
  final bool showTouchMoreButton;

  @override
  ConsumerState<SelectableImageCard> createState() =>
      _SelectableImageCardState();
}

class _SelectableImageCardState extends ConsumerState<SelectableImageCard>
    with TickerProviderStateMixin {
  late final ImageCardController _controller;

  ImageCardViewData get _data => ImageCardViewData(
    imageBytes: widget.imageBytes,
    index: widget.index,
    isSelected: widget.isSelected,
    showIndex: widget.showIndex,
    isPreviewActive: widget.isPreviewActive,
    imageIdentity: widget.imageIdentity,
    statusBadgeLabel: widget.statusBadgeLabel,
    statusBadgeTooltip: widget.statusBadgeTooltip,
    dragPreparationReady: widget.dragPreparationReady,
    completionPreview: widget.completionPreview,
    isFavorite: widget.isFavorite,
    underlay: widget.underlay,
    imageContent: widget.imageContent,
    isGenerating: widget.isGenerating,
    progress: widget.progress,
    postprocessPhase: widget.postprocessPhase,
    currentImage: widget.currentImage,
    totalImages: widget.totalImages,
    streamPreview: widget.streamPreview,
    focusedPreviewPlacement: widget.focusedPreviewPlacement,
    imageWidth: widget.imageWidth,
    imageHeight: widget.imageHeight,
    sourceFilePath: widget.sourceFilePath,
  );

  ImageCardCapabilities get _capabilities => ImageCardCapabilities(
    allowRepeatedModifierTaps: widget.allowRepeatedModifierTaps,
    enableContextMenu: widget.enableContextMenu,
    enableHoverScale: widget.enableHoverScale,
    enableGlossEffect: widget.enableGlossEffect,
    hoverEffectsEnabled: widget.hoverEffectsEnabled,
    shareWarmupEnabled: widget.shareWarmupEnabled,
    enableSaveAction: widget.enableSaveAction,
    enableCopyAction: widget.enableCopyAction,
    enableSelection: widget.enableSelection,
    selectionMode: widget.selectionMode,
    showSelectionOnHover: widget.showSelectionOnHover,
    onTap: _handleTap,
    onDoubleTap: widget.onDoubleTap,
    onLongPress: widget.onLongPress,
    onSelectionChanged: widget.onSelectionChanged,
    onFullscreen: widget.onFullscreen,
    onUpscale: widget.onUpscale,
    onReversePrompt: widget.onReversePrompt,
    onImageToImage: widget.onImageToImage,
    onVibeTransfer: widget.onVibeTransfer,
    onPreciseReference: widget.onPreciseReference,
    onSaveToPreciseRefLibrary: widget.onSaveToPreciseRefLibrary,
    onEditImage: widget.onEditImage,
    onInpaint: widget.onInpaint,
    onGenerateVariations: widget.onGenerateVariations,
    onDirectorTools: widget.onDirectorTools,
    onEnhance: widget.onEnhance,
    onSendToKrita: widget.onSendToKrita,
    onShareToDiscord: widget.onShareToDiscord,
    onOpenInExplorer: widget.onOpenInExplorer,
    onSaveToLibrary: widget.onSaveToLibrary,
    onFavoriteToggle: widget.onFavoriteToggle,
  );

  @override
  void initState() {
    super.initState();
    _controller = ImageCardController(
      vsync: this,
      data: _data,
      capabilities: _capabilities,
    );
  }

  void _handleTap() {
    final identity = widget.imageIdentity;
    if (widget.enableSelection &&
        identity is String &&
        CardSelectionScope.handleTap(context, identity)) {
      return;
    }
    (widget.onTap ?? widget.onFullscreen)?.call();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _controller.setReducedMotion(MediaQuery.disableAnimationsOf(context));
  }

  @override
  void didUpdateWidget(covariant SelectableImageCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    _controller.update(vsync: this, data: _data, capabilities: _capabilities);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final data = _data;
    if (data.isGenerating) {
      return ImageCardGenerating(data: data, controller: _controller);
    }
    final capabilities = _capabilities;
    ref.watch(
      watermarkSettingsProvider.select((state) => state.configuration.enabled),
    );
    ref.watch(
      mosaicSettingsProvider.select((state) => state.configuration.enabled),
    );
    final coordinator = ImageCardActionCoordinator(
      context: context,
      ref: ref,
      controller: _controller,
    );
    final actions =
        capabilities.hoverEffectsEnabled || capabilities.enableContextMenu
        ? ImageCardActionCatalog.build(
            context: context,
            data: data,
            capabilities: capabilities,
            coordinator: coordinator,
            onAddToAgent: ImageCardActionScope.maybeOf(context)?.onAddToAgent,
          )
        : const <ImageCardAction>[];
    return ImageCardActionRegion(
      resourceId: widget.imageIdentity is String
          ? widget.imageIdentity as String
          : null,
      actions: actions,
      enabled: false,
      builder: (context, boundActions) {
        final surface = ImageCardSurface(
          data: data,
          capabilities: capabilities,
          controller: _controller,
          actions: boundActions,
          showTouchMoreButton: widget.showTouchMoreButton,
          onWarmShareCache: coordinator.warmShareTransferCache,
          onShowContextMenu: (position) {
            final batch = ImageCardBatchScope.maybeOf(context);
            final useBatch =
                batch?.targetIds.contains(widget.imageIdentity) ?? false;
            return ImageCardContextMenu.show(
              context: context,
              position: position,
              actions: useBatch ? batch!.actions : boundActions,
              title: useBatch ? batch!.title(context) : null,
              listenable: useBatch ? batch!.runner : null,
            );
          },
        );
        final wrapped = widget.surfaceWrapper?.call(surface) ?? surface;
        final footer = widget.footer;
        // 页脚与图片共用一个动作作用域：信息条里的入口与浮层按钮打开的是同一份
        // 动作列表。Expanded 让图片吃掉除页脚之外的高度，调用方只要给卡片一个
        // 有界高度即可。
        if (footer == null) return wrapped;
        return Column(
          children: [Expanded(child: wrapped), footer],
        );
      },
    );
  }
}
