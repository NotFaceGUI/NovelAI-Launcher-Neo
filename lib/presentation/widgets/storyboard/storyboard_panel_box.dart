import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../../../core/utils/storyboard/storyboard_geometry.dart';
import '../../../data/models/storyboard/storyboard_panel.dart';
import 'storyboard_panel_image.dart';

/// 分镜的四个缩放角。
enum StoryboardPanelCorner { topLeft, topRight, bottomLeft, bottomRight }

/// 手柄在屏幕上的命中边长；触屏放大到不小于 44。
const double storyboardHandleHitExtentMouse = 28;
const double storyboardHandleHitExtentTouch = 48;

/// 顶点手柄的命中边长。
const double storyboardVertexHitExtent = 32;

/// 面板组件相对版面矩形的外扩量。
///
/// 必须同时容得下缩放角手柄与顶点手柄。RenderBox 只在自身尺寸内做命中测试，
/// 手柄一旦落到组件边界之外，露出去的那部分就点不到了——表现为"某个角编辑不了"。
double storyboardPanelBoxInset(double handleHitExtent) =>
    (handleHitExtent > storyboardVertexHitExtent
        ? handleHitExtent
        : storyboardVertexHitExtent) /
    2;

/// 把分镜的归一化顶点裁成组件本地坐标下的 [Path]。
class StoryboardPolygonClipper extends CustomClipper<Path> {
  const StoryboardPolygonClipper({required this.panel});

  final StoryboardPanel panel;

  @override
  Path getClip(Size size) => StoryboardGeometry.buildPanelPath(
    rect: Offset.zero & size,
    points: panel.points,
    polygon: panel.isPolygon,
  );

  @override
  bool shouldReclip(covariant StoryboardPolygonClipper oldClipper) =>
      oldClipper.panel.isPolygon != panel.isPolygon ||
      oldClipper.panel.points != panel.points ||
      oldClipper.panel.width != panel.width ||
      oldClipper.panel.height != panel.height;
}

/// 单个分镜在画布上的呈现与手势入口。
///
/// 组件被放在**屏幕坐标**里：外框由画布按视口缩放算好，组件内部再用
/// [scale] 把页面尺寸换算成屏幕尺寸。描边、手柄这类东西用固定屏幕像素，
/// 任何缩放下粗细与命中区都不变。
///
/// 组件自身不保存拖动状态：它只把屏幕位移交给画布，由画布记录手势起点、
/// 换算成页面坐标并写入文档。手柄区域需要超出面板边界，否则多边形与页边处的
/// 手柄会被裁掉，所以外层盒子按 [handleHitExtent] 向外扩张。
class StoryboardPanelBox extends StatelessWidget {
  const StoryboardPanelBox({
    super.key,
    required this.panel,
    required this.galleryRoot,
    required this.selected,
    required this.polygonEditing,
    required this.scale,
    required this.viewportSize,
    required this.handleHitExtent,
    required this.onBodyDragStart,
    required this.onBodyDragUpdate,
    required this.onDragEnd,
    required this.onResizeStart,
    required this.onResizeUpdate,
    required this.onVertexDragStart,
    required this.onVertexDragUpdate,
    required this.onVertexTap,
    required this.onEdgeTap,
    required this.onTap,
    required this.onContextMenu,
    this.previewBytes,
    this.previewMode = false,
  });

  final StoryboardPanel panel;
  final String? galleryRoot;
  final bool selected;
  final bool polygonEditing;

  /// 页面像素到屏幕像素的缩放。
  final double scale;

  /// 画布视口尺寸。
  ///
  /// 解码宽度要用它封顶：画布可以放大，放大后面板的组件尺寸会超过视口，按
  /// 组件尺寸解码等于把内存按缩放倍数成倍放大，而屏幕上最多只能看到一屏。
  final Size viewportSize;

  final double handleHitExtent;
  final VoidCallback onBodyDragStart;
  final ValueChanged<Offset> onBodyDragUpdate;
  final VoidCallback onDragEnd;
  final ValueChanged<StoryboardPanelCorner> onResizeStart;
  final ValueChanged<Offset> onResizeUpdate;
  final ValueChanged<int> onVertexDragStart;

  /// 顶点拖动给出的是**屏幕位移**：画布统一在页面像素空间里算，形状才会精确跟手。
  final void Function(int index, Offset screenDelta) onVertexDragUpdate;

  /// 点击顶点：删除它（顶点数不少于 3 时生效）。
  final ValueChanged<int> onVertexTap;

  /// 点击边中点：在该处插入一个顶点。
  final void Function(int insertIndex, Offset normalizedPoint) onEdgeTap;

  final VoidCallback onTap;

  /// 右键或长按：给出全局坐标，由画布就地弹出菜单。
  final ValueChanged<Offset> onContextMenu;

  final Uint8List? previewBytes;

  /// 导出观感预览：不显示序号、描边与手柄，也不响应编辑手势。
  final bool previewMode;

  /// 内容区的屏幕尺寸（不含手柄外扩）。
  Size get _contentSize => Size(panel.width * scale, panel.height * scale);

  bool get _interactive => selected && !panel.locked && !previewMode;

  @override
  Widget build(BuildContext context) {
    final contentSize = _contentSize;
    final inset = storyboardPanelBoxInset(handleHitExtent);
    final content = Positioned(
      left: inset,
      top: inset,
      width: contentSize.width,
      height: contentSize.height,
      child: previewMode
          ? _buildContent(context)
          : MouseRegion(
              cursor: SystemMouseCursors.move,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: onTap,
                onSecondaryTapDown: (details) =>
                    onContextMenu(details.globalPosition),
                onLongPressStart: (details) =>
                    onContextMenu(details.globalPosition),
                onPanStart: (_) => onBodyDragStart(),
                onPanUpdate: (details) => onBodyDragUpdate(details.delta),
                onPanEnd: (_) => onDragEnd(),
                onPanCancel: onDragEnd,
                child: _buildContent(context),
              ),
            ),
    );
    return Stack(
      clipBehavior: Clip.none,
      children: [
        content,
        if (!previewMode && polygonEditing) ..._buildVertexHandles(contentSize, inset),
        if (!previewMode && _interactive && !polygonEditing)
          ..._buildCornerHandles(contentSize, inset),
      ],
    );
  }

  Widget _buildContent(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Stack(
      fit: StackFit.expand,
      children: [
        // 停用的分镜保留在版面上但压暗，一眼看出它不参与生成；导出观感里
        // 恢复原样——导出器绘制全部分镜的成图。
        Opacity(
          opacity: panel.enabled || previewMode ? 1 : 0.35,
          child: ClipPath(
            clipper: StoryboardPolygonClipper(panel: panel),
            child: _buildImage(context),
          ),
        ),
        // 序号与描边是编辑辅助，不属于导出结果，预览时不绘制。
        if (!previewMode)
          IgnorePointer(
            child: CustomPaint(
              painter: StoryboardPanelOutlinePainter(
                panel: panel,
                selected: selected,
                outlineColor: selected
                    ? scheme.primary
                    : scheme.onSurfaceVariant,
                indexColor: scheme.onSurface,
                indexBackground: scheme.surface,
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildImage(BuildContext context) {
    final bytes = previewBytes;
    if (bytes != null && bytes.isNotEmpty) {
      return Image.memory(
        bytes,
        fit: BoxFit.contain,
        gaplessPlayback: true,
        filterQuality: FilterQuality.high,
      );
    }

    final provider = StoryboardPanelImage.providerFor(
      galleryRoot: galleryRoot,
      relativePath: panel.selectedImage,
      decodeWidth: _decodeWidthFor(context),
    );
    if (provider == null) {
      return const StoryboardPanelPlaceholder();
    }
    return Image(
      image: provider,
      fit: StoryboardPanelImage.boxFitOf(panel.fit),
      gaplessPlayback: true,
      // 高分辨率成图缩进小格时，双线性滤波会跳过大量像素，出现摩尔纹与
      // 破碎感；高质量重采样明显更干净。
      filterQuality: FilterQuality.high,
      errorBuilder: (context, error, stackTrace) =>
          const StoryboardPanelPlaceholder(missing: true),
    );
  }

  /// 解码宽度按面板在屏幕上的实际像素（含设备像素比）取：解码阶段就完成
  /// 降采样，屏幕端接近 1:1 呈现——大图缩进小格时的摩尔纹主要来自这里；
  /// 也避免在小面板上解码整张大图。
  int? _decodeWidthFor(BuildContext context) {
    final onScreen = panel.width * scale;
    final visible = onScreen.isFinite
        ? math.min(onScreen, viewportSize.width)
        : viewportSize.width;
    if (!visible.isFinite || visible <= 0) return null;
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final rounded = (visible * dpr).ceil().clamp(1, 1 << 14);
    return rounded;
  }

  /// 四个缩放角手柄；位置按内容区四角贴齐，命中区向外扩。
  List<Widget> _buildCornerHandles(Size contentSize, double inset) {
    final extent = handleHitExtent;
    return [
      for (final corner in StoryboardPanelCorner.values)
        _PanelHandle(
          key: ValueKey('${panel.id}-${corner.name}'),
          left: _cornerLeft(corner, contentSize, extent, inset),
          top: _cornerTop(corner, contentSize, extent, inset),
          extent: extent,
          cursor: switch (corner) {
            StoryboardPanelCorner.topLeft ||
            StoryboardPanelCorner.bottomRight =>
              SystemMouseCursors.resizeUpLeftDownRight,
            StoryboardPanelCorner.topRight ||
            StoryboardPanelCorner.bottomLeft =>
              SystemMouseCursors.resizeUpRightDownLeft,
          },
          onStart: () => onResizeStart(corner),
          onUpdate: onResizeUpdate,
          onEnd: onDragEnd,
        ),
    ];
  }

  double _cornerLeft(
    StoryboardPanelCorner corner,
    Size contentSize,
    double extent,
    double inset,
  ) {
    final isLeft =
        corner == StoryboardPanelCorner.topLeft ||
        corner == StoryboardPanelCorner.bottomLeft;
    return isLeft ? 0 : contentSize.width + inset * 2 - extent;
  }

  double _cornerTop(
    StoryboardPanelCorner corner,
    Size contentSize,
    double extent,
    double inset,
  ) {
    final isTop =
        corner == StoryboardPanelCorner.topLeft ||
        corner == StoryboardPanelCorner.topRight;
    return isTop ? 0 : contentSize.height + inset * 2 - extent;
  }

  /// 多边形顶点手柄与边中点手柄。
  ///
  /// 顶点可拖动改形状、点击删除；边中点可点击插入新顶点。两者都给出可见的
  /// 圆点，不依赖 hover 或右键，触屏同样可用。
  List<Widget> _buildVertexHandles(Size contentSize, double inset) {
    if (contentSize.width <= 0 || contentSize.height <= 0) return const [];
    final points = panel.effectivePoints;
    if (points.length < StoryboardPanel.minPolygonPoints) return const [];

    Offset toLocal(Offset normalized) =>
        Offset(normalized.dx * contentSize.width, normalized.dy * contentSize.height);

    final widgets = <Widget>[];
    for (var index = 0; index < points.length; index++) {
      final local = toLocal(points[index]);
      widgets.add(
        _VertexHandle(
          key: ValueKey('${panel.id}-vertex-$index'),
          left: local.dx + inset - storyboardVertexHitExtent / 2,
          top: local.dy + inset - storyboardVertexHitExtent / 2,
          onStart: () => onVertexDragStart(index),
          onUpdate: (delta) => onVertexDragUpdate(index, delta),
          onTap: () => onVertexTap(index),
          onEnd: onDragEnd,
        ),
      );
    }

    // 边中点手柄：几何中点即可作为插入位置，不必再做投影。
    for (var index = 0; index < points.length; index++) {
      final start = points[index];
      final end = points[(index + 1) % points.length];
      final midpoint = Offset(
        (start.dx + end.dx) / 2,
        (start.dy + end.dy) / 2,
      );
      final local = toLocal(midpoint);
      widgets.add(
        _EdgeHandle(
          key: ValueKey('${panel.id}-edge-$index'),
          left: local.dx + inset - storyboardVertexHitExtent / 2,
          top: local.dy + inset - storyboardVertexHitExtent / 2,
          onTap: () => onEdgeTap(index + 1, midpoint),
        ),
      );
    }
    return widgets;
  }
}

/// 顶点手柄：拖动改形状，点击删除。
class _VertexHandle extends StatelessWidget {
  const _VertexHandle({
    super.key,
    required this.left,
    required this.top,
    required this.onStart,
    required this.onUpdate,
    required this.onTap,
    required this.onEnd,
  });

  final double left;
  final double top;
  final VoidCallback onStart;
  final ValueChanged<Offset> onUpdate;
  final VoidCallback onTap;
  final VoidCallback onEnd;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Positioned(
      left: left,
      top: top,
      width: storyboardVertexHitExtent,
      height: storyboardVertexHitExtent,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        dragStartBehavior: DragStartBehavior.down,
        onTap: onTap,
        onPanStart: (_) => onStart(),
        onPanUpdate: (details) => onUpdate(details.delta),
        onPanEnd: (_) => onEnd(),
        onPanCancel: onEnd,
        child: Center(
          child: Container(
            width: 12,
            height: 12,
            decoration: BoxDecoration(
              color: scheme.primary,
              shape: BoxShape.circle,
              border: Border.all(color: scheme.onPrimary, width: 1.5),
            ),
          ),
        ),
      ),
    );
  }
}

/// 边中点手柄：点击插入一个顶点。
class _EdgeHandle extends StatelessWidget {
  const _EdgeHandle({
    super.key,
    required this.left,
    required this.top,
    required this.onTap,
  });

  final double left;
  final double top;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Positioned(
      left: left,
      top: top,
      width: storyboardVertexHitExtent,
      height: storyboardVertexHitExtent,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Center(
          child: Container(
            width: 9,
            height: 9,
            decoration: BoxDecoration(
              color: scheme.surface,
              shape: BoxShape.circle,
              border: Border.all(color: scheme.primary, width: 1.5),
            ),
          ),
        ),
      ),
    );
  }
}

/// 缩放角手柄。
class _PanelHandle extends StatelessWidget {
  const _PanelHandle({
    super.key,
    required this.left,
    required this.top,
    required this.extent,
    required this.cursor,
    required this.onStart,
    required this.onUpdate,
    required this.onEnd,
  });

  final double left;
  final double top;
  final double extent;
  final MouseCursor cursor;
  final VoidCallback onStart;
  final ValueChanged<Offset> onUpdate;
  final VoidCallback onEnd;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Positioned(
      left: left,
      top: top,
      width: extent,
      height: extent,
      child: MouseRegion(
        cursor: cursor,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          dragStartBehavior: DragStartBehavior.down,
          onPanStart: (_) => onStart(),
          onPanUpdate: (details) => onUpdate(details.delta),
          onPanEnd: (_) => onEnd(),
          onPanCancel: onEnd,
          child: Center(
            child: Container(
              width: 10,
              height: 10,
              decoration: BoxDecoration(
                color: scheme.primary,
                borderRadius: BorderRadius.circular(2),
                border: Border.all(color: scheme.onPrimary, width: 1),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 没有图时的占位：分镜可能是刚建好还没生成，也可能是文件被移走了。
class StoryboardPanelPlaceholder extends StatelessWidget {
  const StoryboardPanelPlaceholder({super.key, this.missing = false});

  final bool missing;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ColoredBox(
      color: scheme.surfaceContainerHighest,
      child: Center(
        child: Icon(
          missing
              ? Icons.broken_image_outlined
              : Icons.add_photo_alternate_outlined,
          color: scheme.onSurfaceVariant,
          size: 22,
        ),
      ),
    );
  }
}

/// 分镜边框与阅读序号。
///
/// 组件位于屏幕坐标，因此描边与角标都用固定的屏幕像素，任何缩放级别下
/// 都保持同样的可见粗细。
class StoryboardPanelOutlinePainter extends CustomPainter {
  const StoryboardPanelOutlinePainter({
    required this.panel,
    required this.selected,
    required this.outlineColor,
    required this.indexColor,
    required this.indexBackground,
  });

  final StoryboardPanel panel;
  final bool selected;
  final Color outlineColor;
  final Color indexColor;
  final Color indexBackground;

  @override
  void paint(Canvas canvas, Size size) {
    final path = StoryboardGeometry.buildPanelPath(
      rect: Offset.zero & size,
      points: panel.points,
      polygon: panel.isPolygon,
    );
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = selected ? 2.0 : 1.0
        ..color = outlineColor
        ..isAntiAlias = true,
    );
    _paintOrderBadge(canvas, size);
  }

  /// 阅读序号画在左上角，随面板大小收敛，避免小面板上盖满角标。
  void _paintOrderBadge(Canvas canvas, Size size) {
    final badgeSize = 18.0.clamp(0.0, size.shortestSide / 2);
    if (badgeSize < 10) return;

    final textPainter = TextPainter(
      text: TextSpan(
        text: '${panel.order}',
        style: TextStyle(
          color: indexColor,
          fontSize: badgeSize * 0.62,
          fontWeight: FontWeight.w600,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();

    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(0, 0, badgeSize, badgeSize),
        Radius.circular(badgeSize * 0.22),
      ),
      Paint()..color = indexBackground.withValues(alpha: 0.86),
    );
    textPainter.paint(
      canvas,
      Offset(
        (badgeSize - textPainter.width) / 2,
        (badgeSize - textPainter.height) / 2,
      ),
    );
  }

  @override
  bool shouldRepaint(covariant StoryboardPanelOutlinePainter oldDelegate) =>
      oldDelegate.panel.order != panel.order ||
      oldDelegate.panel.points != panel.points ||
      oldDelegate.panel.width != panel.width ||
      oldDelegate.panel.height != panel.height ||
      oldDelegate.panel.isPolygon != panel.isPolygon ||
      oldDelegate.selected != selected ||
      oldDelegate.outlineColor != outlineColor;
}
