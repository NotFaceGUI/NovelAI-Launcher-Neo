import 'dart:async';
import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter_riverpod/flutter_riverpod.dart';


import '../../../core/utils/storyboard/storyboard_geometry.dart';
import '../../../data/models/storyboard/storyboard_page.dart';
import '../../../data/models/storyboard/storyboard_panel.dart';
import '../generation/generation_center_mode_provider.dart';
import 'storyboard_document_controller.dart';

/// 分镜编辑器上的整体动作：版面几何的自动排版，以及退出编辑器。
///
/// 退出是工具条按钮与 Android 返回键共用的同一条路径，放在这里避免两处各写
/// 一遍「先落盘再回预览」，任何一处漏了落盘都会丢掉防抖窗口内的修改。
class StoryboardToolbarActions {
  StoryboardToolbarActions(this._ref);

  final Ref _ref;

  StoryboardDocumentController get _document =>
      _ref.read(storyboardDocumentControllerProvider.notifier);

  StoryboardPage? get _page =>
      _ref.read(storyboardDocumentControllerProvider).valueOrNull?.activePage;

  /// 在页面最大空白处新增一个分镜。
  ///
  /// 没有可用空白（页面已被分镜铺满）时返回 null，由调用方提示。
  Rect? fillLargest() {
    final page = _page;
    if (page == null) return null;
    if (page.panels.length >= StoryboardPage.maxPanels) return null;

    final rect = StoryboardGeometry.largestEmptyRect(
      pageSize: Size(page.width.toDouble(), page.height.toDouble()),
      margin: page.margin,
      gutter: page.gutter,
      occupied: [for (final panel in page.panels) panel.rect],
    );
    if (rect.width < StoryboardPanel.minSide ||
        rect.height < StoryboardPanel.minSide) {
      return null;
    }

    _document.beginGesture();
    unawaited(_document.addPanel(rect));
    return rect;
  }

  /// 让指定分镜延伸到最近的邻居或页边距，占满它四周的剩余空间。
  Rect? fillRemaining(String panelId) {
    final page = _page;
    final panel = page?.panelById(panelId);
    if (page == null || panel == null || panel.locked) return null;

    final size = Size(page.width.toDouble(), page.height.toDouble());
    final margin = page.margin;
    final gutter = page.gutter;

    var left = margin;
    var top = margin;
    var right = size.width - margin;
    var bottom = size.height - margin;

    // 逐个邻居把锚边推到它旁边（减去间距）。
    for (final other in page.panels) {
      if (other.id == panelId) continue;
      final otherRect = other.rect;
      // 右侧延伸会被左侧的邻居挡住
      if (otherRect.right + gutter <= panel.rect.right &&
          otherRect.bottom + gutter > panel.rect.top &&
          otherRect.top - gutter < panel.rect.bottom) {
        left = math.max(left, otherRect.right + gutter);
      }
      // 左侧延伸会被右侧的邻居挡住
      if (otherRect.left - gutter >= panel.rect.left &&
          otherRect.bottom + gutter > panel.rect.top &&
          otherRect.top - gutter < panel.rect.bottom) {
        right = math.min(right, otherRect.left - gutter);
      }
      // 向下延伸会被上方的邻居挡住
      if (otherRect.bottom + gutter <= panel.rect.bottom &&
          otherRect.right + gutter > panel.rect.left &&
          otherRect.left - gutter < panel.rect.right) {
        top = math.max(top, otherRect.bottom + gutter);
      }
      // 向上延伸会被下方的邻居挡住
      if (otherRect.top - gutter >= panel.rect.top &&
          otherRect.right + gutter > panel.rect.left &&
          otherRect.left - gutter < panel.rect.right) {
        bottom = math.min(bottom, otherRect.top - gutter);
      }
    }

    final newRect = Rect.fromLTRB(left, top, right, bottom);
    if (newRect.width < StoryboardPanel.minSide ||
        newRect.height < StoryboardPanel.minSide) {
      return null;
    }
    _document.beginGesture();
    _document.setPanelRect(panelId, newRect);
    return newRect;
  }

  /// 退出分镜编辑器：先把防抖窗口内的修改落盘，再回到图像预览。
  Future<void> leaveEditor() async {
    await _document.flush();
    _ref.read(generationCenterModeControllerProvider.notifier).showPreview();
  }
}

final storyboardToolbarActionsProvider = Provider<StoryboardToolbarActions>(
  (ref) => StoryboardToolbarActions(ref),
);
