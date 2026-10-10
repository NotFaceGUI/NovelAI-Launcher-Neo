import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/utils/localization_extension.dart';
import '../../../../core/utils/storyboard/storyboard_geometry.dart';
import '../../../../data/models/storyboard/storyboard_fit_mode.dart';
import '../../../../data/models/storyboard/storyboard_page.dart';
import '../../../../data/models/storyboard/storyboard_page_background.dart';
import '../../../../data/models/storyboard/storyboard_panel.dart';
import '../../../../data/models/storyboard/storyboard_panel_shape.dart';
import '../../../../data/services/storyboard/storyboard_generation_planner.dart';
import '../../../adaptive/interaction_policy.dart';
import '../../../providers/storyboard/storyboard_document_controller.dart';
import '../../../providers/storyboard/storyboard_interaction_provider.dart';
import '../../../providers/storyboard/storyboard_preview_provider.dart';
import '../../../providers/storyboard/storyboard_repository_provider.dart';
import '../../../widgets/storyboard/storyboard_panel_box.dart';
import '../../../widgets/storyboard/storyboard_panel_image.dart';

/// 页面到屏幕的变换。
///
/// 基准是"整页等比例适配视口"，再叠加用户的双指缩放与平移。点击、拖动与
/// 拉框都只经过这一层换算，不存在缩放中心与视口偏移带来的锚点漂移。
class _PageFit {
  const _PageFit({required this.scale, required this.offset});

  /// 页面像素到屏幕像素的缩放。
  final double scale;

  /// 页面原点在屏幕上的位置。
  final Offset offset;

  /// 页面四周的留白。
  ///
  /// 顶部留得更多：生成页的 tab 与分镜工具条浮在画布上方，页面若贴到顶边会被
  /// 它们盖住，而画布不滚动，被盖住的部分用户拿不到。
  static const EdgeInsets defaultInset = EdgeInsets.fromLTRB(12, 60, 12, 12);

  static _PageFit of({
    required Size pageSize,
    required Size viewportSize,
    EdgeInsets inset = defaultInset,
  }) {
    if (pageSize.width <= 0 ||
        pageSize.height <= 0 ||
        viewportSize.width <= 0 ||
        viewportSize.height <= 0) {
      return const _PageFit(scale: 1, offset: Offset.zero);
    }
    final availableWidth = (viewportSize.width - inset.horizontal).clamp(
      1.0,
      double.infinity,
    );
    final availableHeight = (viewportSize.height - inset.vertical).clamp(
      1.0,
      double.infinity,
    );
    final scale = (availableWidth / pageSize.width).clamp(
      0.0,
      availableHeight / pageSize.height,
    );
    final safeScale = scale <= 0 ? 1.0 : scale;
    return _PageFit(
      scale: safeScale,
      offset: Offset(
        inset.left + (availableWidth - pageSize.width * safeScale) / 2,
        inset.top + (availableHeight - pageSize.height * safeScale) / 2,
      ),
    );
  }

  Offset toScreen(Offset point) => point * scale + offset;

  Offset toPage(Offset screenPoint) => (screenPoint - offset) / scale;

  Rect rectToScreen(Rect rect) => Rect.fromPoints(
    toScreen(rect.topLeft),
    toScreen(rect.bottomRight),
  );
}

/// 正在进行的拖动会话。
enum _DragKind { body, resize, vertex, draft }

class _DragSession {
  _DragSession({
    required this.kind,
    this.panelId = '',
    this.startRect = Rect.zero,
    this.corner,
    this.vertexIndex = -1,
  });

  final _DragKind kind;
  final String panelId;
  final Rect startRect;
  final StoryboardPanelCorner? corner;
  final int vertexIndex;

  /// 从手势开始累计的屏幕位移。
  ///
  /// `onPanUpdate` 只给单帧增量；如果直接拿它去偏移 [startRect]，面板每一帧都会
  /// 从原位挪一帧的距离，看起来就是完全不动。所以这里累计后再一次性应用。
  Offset accumulated = Offset.zero;
}

/// 分镜页画布：页面背景、分镜图、选中与版面编辑。
class StoryboardCanvas extends ConsumerStatefulWidget {
  const StoryboardCanvas({super.key});

  @override
  ConsumerState<StoryboardCanvas> createState() => _StoryboardCanvasState();
}

class _StoryboardCanvasState extends ConsumerState<StoryboardCanvas> {
  final FocusNode _focusNode = FocusNode(debugLabel: 'storyboard-canvas');

  /// 指针按下位置；用于区分"点选"与"拖动"。
  final Map<int, Offset> _pointerOrigin = <int, Offset>{};
  bool _pointerMoved = false;

  _DragSession? _session;
  Rect? _draftRect;

  /// 「填充最大空白」放置模式的预览矩形（页面坐标）。
  Rect? _fillLargestPreview;

  /// 拖动中的预览几何；手势结束才写入文档。
  ///
  /// 逐帧写文档会连带触发 provider 通知与防抖落盘，拖起来发涩；这里只改画布
  /// 自己的状态，重建范围限制在本组件内。这套做法与无限画布共用同一约定。
  String? _previewPanelId;
  Rect? _previewRect;

  /// 顶点编辑的预览顶点（页面像素）。用页面像素而不是归一化值：拖动时外接
  /// 矩形会跟着变，归一化值在参照系变化后会跳，形状就不跟手了。
  List<Offset>? _previewPixelPoints;

  /// 最近一个满足间距约束的位置，越界时退回到它。
  Rect? _lastValidRect;

  /// 本帧的页面适配结果；手势回调里要用同一个值。
  _PageFit _fit = const _PageFit(scale: 1, offset: Offset.zero);

  /// 本帧 zoom 为 1 的基准变换；双指换算要由它反推平移。
  _PageFit _baseFit = const _PageFit(scale: 1, offset: Offset.zero);

  /// 用户缩放倍数，1 表示整页适应视口。
  double _zoom = 1;

  /// 相对基准变换的屏幕平移；每帧都会被钳回页面范围内。
  Offset _pan = Offset.zero;

  /// 各指针的当前位置。
  ///
  /// 与 [_pointerOrigin] 分开：那张表是点选判定的起点基准，这张表每帧更新，
  /// 双指手势要用两个指针的实时位置换算缩放与平移。
  final Map<int, Offset> _pointerPosition = <int, Offset>{};

  /// 双指手势的起始距离；0 表示当前没有双指手势。
  double _gestureStartDistance = 0;

  /// 双指手势开始时的缩放倍数。
  double _gestureStartZoom = 1;

  /// 双指手势开始时焦点下的页面坐标；整个手势期间它都跟住焦点。
  Offset _gestureAnchorPage = Offset.zero;

  /// 双指视口手势进行中；分镜的拖动、缩放与拉框此时一律不接受。
  ///
  /// 第二根手指落下时，第一根手指可能已经被分镜的拖动识别器认领，之后越过
  /// 手势阈值才触发 `onPanStart`。没有这道闸门，捏合的过程中会顺带把分镜拖动
  /// 写进文档。
  bool _viewportGesture = false;

  /// 上一次干净点选的时间与位置，用于识别双击复位。
  Duration? _lastTapTime;
  Offset? _lastTapPosition;

  /// 缩放上下限；上限足够把 1024 宽的页面放到手机屏幕上画细节。
  static const double _minZoom = 1;
  static const double _maxZoom = 8;

  /// 双击复位的判定窗口。
  static const Duration _doubleTapWindow = Duration(milliseconds: 300);
  static const double _doubleTapSlop = 40;

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final document = ref.watch(storyboardDocumentControllerProvider);
    final interaction = ref.watch(storyboardInteractionProvider);
    final galleryRoot = ref.watch(storyboardGalleryRootPathProvider).valueOrNull;
    // 生成中的流式预览：只有匹配 id 的分镜/背景会拿到字节并重建。
    final preview = ref.watch(storyboardPreviewProvider);
    final page = document.valueOrNull?.activePage;

    return LayoutBuilder(
      builder: (context, constraints) {
        if (page == null) return const SizedBox.expand();
        final pageSize = Size(page.width.toDouble(), page.height.toDouble());
        final viewportSize = Size(constraints.maxWidth, constraints.maxHeight);
        _resolveFit(pageSize: pageSize, viewportSize: viewportSize);

        final touch = context.interactionPolicy.touchAvailable;
        final handleExtent = touch
            ? storyboardHandleHitExtentTouch
            : storyboardHandleHitExtentMouse;
        final drawing = interaction.tool == StoryboardTool.drawRect;
    final placing = interaction.placingFillLargest;

        return Focus(
          focusNode: _focusNode,
          onKeyEvent: (node, event) => _handleKey(event),
          child: Listener(
            behavior: HitTestBehavior.opaque,
            onPointerDown: _onPointerDown,
            onPointerMove: _onPointerMove,
            onPointerUp: (event) => _onPointerUp(event, page),
            onPointerCancel: _onPointerCancel,
            child: ClipRect(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => _focusNode.requestFocus(),
                    child: ColoredBox(
                      color: Theme.of(context).colorScheme.surface,
                    ),
                  ),
                  Positioned.fromRect(
                    rect: _fit.rectToScreen(
                      Rect.fromLTWH(0, 0, pageSize.width, pageSize.height),
                    ),
                    child: StoryboardPageBackgroundView(
                      page: page,
                      galleryRoot: galleryRoot,
                      viewportSize: viewportSize,
                      previewBytes:
                          preview.matches(
                            StoryboardGenerationPlanner.backgroundRequestId,
                          )
                          ? preview.bytes
                          : null,
                    ),
                  ),
                  // 拉框层默认垫在分镜下面：空白处拖拽就是新建，拖到分镜上就是
                  // 移动它。切到"拉框"工具后改到上层，可以在已有分镜上继续画。
                  if (placing) ..._buildFillLargestLayer(page),
                  if (!drawing) ..._buildDraftLayer(),
                  ..._buildPanelLayer(
                    page,
                    interaction,
                    galleryRoot,
                    handleExtent,
                    drawing,
                    preview,
                    viewportSize,
                  ),
                  if (drawing) ..._buildDraftLayer(),
                  if (placing) ..._buildFillLargestLayer(page),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  /// 组合本帧的页面变换：先整页适应视口，再叠加用户缩放与平移。
  ///
  /// 平移每帧都会被钳回页面范围内——页面比视口小的一轴居中，比视口大的一轴
  /// 不允许拖出视野留白。因此缩放为 1 时平移恒为零，与"整页恒定显示"的旧行为
  /// 完全一致，双指以外的手势（点选、拖动、拉框）换算也都不变。
  void _resolveFit({required Size pageSize, required Size viewportSize}) {
    final base = _PageFit.of(pageSize: pageSize, viewportSize: viewportSize);
    _baseFit = base;
    if (_zoom <= _minZoom || base.scale <= 0) {
      _zoom = _minZoom;
      _pan = Offset.zero;
      _fit = base;
      return;
    }
    final scale = base.scale * _zoom;
    final pageExtent = Size(pageSize.width * scale, pageSize.height * scale);
    _pan = Offset(
      _clampAxis(
        value: _pan.dx,
        pageExtent: pageExtent.width,
        viewportExtent: viewportSize.width,
        baseOffset: base.offset.dx,
      ),
      _clampAxis(
        value: _pan.dy,
        pageExtent: pageExtent.height,
        viewportExtent: viewportSize.height,
        baseOffset: base.offset.dy,
      ),
    );
    _fit = _PageFit(scale: scale, offset: base.offset + _pan);
  }

  /// 单轴钳制：页面比视口小就居中，比视口大就只允许在页面范围内移动。
  static double _clampAxis({
    required double value,
    required double pageExtent,
    required double viewportExtent,
    required double baseOffset,
  }) {
    if (pageExtent <= viewportExtent) {
      return (viewportExtent - pageExtent) / 2 - baseOffset;
    }
    return value.clamp(
      viewportExtent - pageExtent - baseOffset,
      -baseOffset,
    );
  }

  List<Widget> _buildPanelLayer(
    StoryboardPage page,
    StoryboardInteractionState interaction,
    String? galleryRoot,
    double handleExtent,
    bool drawing,
    StoryboardPreviewState preview,
    Size viewportSize,
  ) {
    final inset = storyboardPanelBoxInset(handleExtent);
    final children = <Widget>[];
    for (final panel in page.panelsByZOrder) {
      final display = _displayFor(panel);
      children.add(
        Positioned.fromRect(
          rect: _fit.rectToScreen(display.rect).inflate(inset),
          child: StoryboardPanelBox(
            key: ValueKey(panel.id),
            panel: display,
            galleryRoot: galleryRoot,
            previewBytes: preview.matches(panel.id) ? preview.bytes : null,
            previewMode: interaction.previewMode,
            selected: interaction.isSelected(panel.id),
            // 锁定的分镜不进入顶点编辑：锁的作用就是不再改版面。
            polygonEditing:
                interaction.polygonEditing &&
                interaction.isSelected(panel.id) &&
                !panel.locked,
            scale: _scale,
            viewportSize: viewportSize,
            handleHitExtent: handleExtent,
            onTap: () => _ensureSelected(panel.id),
            onContextMenu: (position) => _showPanelMenu(panel, position),
            onBodyDragStart: () => _beginBodyDrag(panel),
            onBodyDragUpdate: _updateBodyDrag,
            onDragEnd: _endDrag,
            onResizeStart: (corner) => _beginResize(panel, corner),
            onResizeUpdate: _updateResize,
            onVertexDragStart: (index) => _beginVertexDrag(panel, index),
            onVertexDragUpdate: _updateVertexDrag,
            onVertexTap: (index) => _removeVertex(panel, index),
            onEdgeTap: (index, point) => _insertVertex(panel, index, point),
          ),
        ),
      );
    }
    // 拉框模式下分镜不接受指针，保证在整页范围内都能画出新分镜。
    return [IgnorePointer(ignoring: drawing, child: Stack(children: children))];
  }

  /// 拖动中的分镜用预览几何渲染，其余分镜直接用文档里的值。
  ///
  /// 顶点预览先把页面像素顶点重新拟合外接矩形，所以拖动时外接框会实时跟着长大
  /// 或收缩，所见即最终结果。
  StoryboardPanel _displayFor(StoryboardPanel panel) {
    if (_previewPanelId != panel.id) return panel;

    final pixels = _previewPixelPoints;
    if (pixels != null && pixels.isNotEmpty) {
      final fitted = StoryboardGeometry.fitPolygonToPixelBounds(pixels);
      return panel.copyWith(
        x: fitted.rect.left,
        y: fitted.rect.top,
        width: fitted.rect.width,
        height: fitted.rect.height,
        points: fitted.points,
        shape: StoryboardPanelShape.polygon,
      );
    }

    final rect = _previewRect ?? panel.rect;
    return panel.copyWith(
      x: rect.left,
      y: rect.top,
      width: rect.width,
      height: rect.height,
    );
  }

  /// 拉框层铺满整个视口，手势的 `localPosition` 就是屏幕坐标。
  List<Widget> _buildDraftLayer() {
    final draft = _draftRect;
    return [
      Positioned.fill(
        child: MouseRegion(
          cursor: SystemMouseCursors.precise,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            dragStartBehavior: DragStartBehavior.down,
            onPanStart: (details) => _beginDraft(details.localPosition),
            onPanUpdate: (details) => _updateDraft(details.localPosition),
            onPanEnd: (_) => _commitDraft(),
            onPanCancel: _cancelDraft,
            onTap: () => _focusNode.requestFocus(),
            child: draft == null
                ? const SizedBox.expand()
                : CustomPaint(
                    painter: _DraftRectPainter(draft: _fit.rectToScreen(draft)),
                  ),
          ),
        ),
      ),
    ];
  }

  // ==================== 指针 ====================

  void _onPointerDown(PointerDownEvent event) {
    _pointerPosition[event.pointer] = event.localPosition;
    _pointerOrigin[event.pointer] = event.localPosition;
    if (_pointerOrigin.length == 1) _pointerMoved = false;
    // 第二根手指落下：这段手势改判为视口缩放/平移，第一根手指带起来的编辑
    // 就地取消。桌面鼠标只有一个指针，永远不会走到这里。
    if (_pointerPosition.length == 2) _beginViewportGesture();
  }

  void _onPointerMove(PointerMoveEvent event) {
    _pointerPosition[event.pointer] = event.localPosition;
    if (_pointerPosition.length >= 2) {
      if (_gestureStartDistance <= 0) _beginViewportGesture();
      _pointerMoved = true;
      _updateViewportGesture();
      return;
    }
    if (ref.read(storyboardInteractionProvider).placingFillLargest) {
      final pagePoint = _fit.toPage(event.localPosition);
      if (mounted) setState(() {});
      _updateFillLargestPreview(pagePoint);
      return;
    }
    final origin = _pointerOrigin[event.pointer];
    if (origin == null) return;
    if (!_pointerMoved &&
        (event.localPosition - origin).distance > kTouchSlop) {
      _pointerMoved = true;
    }
  }

  void _onPointerUp(PointerUpEvent event, StoryboardPage page) {
    final wasTracked = _pointerOrigin.remove(event.pointer) != null;
    _pointerPosition.remove(event.pointer);
    _notifyPointerReleased();
    if (_pointerOrigin.isNotEmpty) return;
    // 只有干净的单击才改变选择；拖动由各手势自行处理。
    if (!wasTracked || _pointerMoved || _session != null) {
      _forgetTap();
      return;
    }
    if (ref.read(storyboardInteractionProvider).placingFillLargest) {
      _commitFillLargest();
      return;
    }
    // 双击复位：放大以后最快的"整页可见"动作。先于点选判定，第二次抬手不再
    // 改变选中对象。
    if (_isDoubleTap(event)) {
      _forgetTap();
      _resetViewport();
      return;
    }
    _rememberTap(event);
    _selectAt(event.localPosition, page);
  }

  void _onPointerCancel(PointerCancelEvent event) {
    _pointerOrigin.remove(event.pointer);
    _pointerPosition.remove(event.pointer);
    _notifyPointerReleased();
    if (_pointerOrigin.isEmpty) _pointerMoved = false;
  }

  /// 有指针离开：视口手势要么重新锚定剩下的两根手指，要么就此结束。
  void _notifyPointerReleased() {
    if (_pointerPosition.length < 2) {
      _endViewportGesture();
    } else if (_viewportGesture) {
      _anchorViewportGesture();
    }
  }

  // ==================== 视口缩放与平移 ====================

  /// 两个指针对应的屏幕位置；不足两个指针时返回 null。
  ///
  /// 固定取指针 id 最小的两个：中间有手指抬起时，剩下的这一对在两次换算之间
  /// 保持稳定，不会因为顺序变化把平移抖一下。
  (Offset, Offset)? _twoPointers() {
    if (_pointerPosition.length < 2) return null;
    final ids = _pointerPosition.keys.toList()..sort();
    return (_pointerPosition[ids[0]]!, _pointerPosition[ids[1]]!);
  }

  /// 双指手势开始：接管这段手势，并把焦点下的页面点当作整个手势的锚点。
  void _beginViewportGesture() {
    if (_twoPointers() == null) return;
    _viewportGesture = true;
    _abortPointerEdit();
    _pointerMoved = true;
    _forgetTap();
    _anchorViewportGesture();
  }

  /// 以当前两指位置与当前视口重新锚定。
  ///
  /// 起步时调用；参与换算的指针换了一对（例如中途抬起一根手指）时也要调用，
  /// 否则剩下的手指一动，视口就会按旧锚点跳一下。
  void _anchorViewportGesture() {
    final points = _twoPointers();
    if (points == null) return;
    final (first, second) = points;
    _gestureStartDistance = (first - second).distance;
    _gestureStartZoom = _zoom;
    _gestureAnchorPage = _fit.toPage((first + second) / 2);
  }

  /// 双指更新：两指距离决定缩放，焦点位移决定平移。
  ///
  /// 由锚点反推平移（而不是直接累加位移），这样缩放与平移同时发生时焦点下的
  /// 页面点始终贴着手指，不会朝视口中心漂移。
  void _updateViewportGesture() {
    final points = _twoPointers();
    if (points == null || _gestureStartDistance <= 0) return;
    final (first, second) = points;
    final distance = (first - second).distance;
    if (distance <= 0) return;
    final focal = (first + second) / 2;
    final zoom = (_gestureStartZoom * distance / _gestureStartDistance).clamp(
      _minZoom,
      _maxZoom,
    );
    final base = _baseFit;
    setState(() {
      _zoom = zoom;
      _pan = focal - base.offset - _gestureAnchorPage * (base.scale * zoom);
    });
  }

  /// 双指手势结束（指针少于两个）：解除闸门，后续手势恢复正常的编辑语义。
  void _endViewportGesture() {
    _gestureStartDistance = 0;
    _viewportGesture = false;
  }

  /// 取消进行中的拖动、拉框与放置预览。
  ///
  /// 预览几何只存在于画布状态里，原样丢弃即可；已经压入撤销栈的快照留在栈里，
  /// 撤销时回到同一份文档，不产生额外改动。
  void _abortPointerEdit() {
    final session = _session;
    if (session != null && session.kind == _DragKind.draft) {
      _cancelDraft();
    } else if (session != null || _previewPanelId != null) {
      _session = null;
      _clearPreview();
    }
    if (_fillLargestPreview != null) {
      setState(() => _fillLargestPreview = null);
    }
  }

  void _rememberTap(PointerUpEvent event) {
    _lastTapTime = event.timeStamp;
    _lastTapPosition = event.localPosition;
  }

  void _forgetTap() {
    _lastTapTime = null;
    _lastTapPosition = null;
  }

  /// 与原地点选同址、且间隔在 [_doubleTapWindow] 内的第二次抬手才算双击。
  bool _isDoubleTap(PointerUpEvent event) {
    final time = _lastTapTime;
    final position = _lastTapPosition;
    if (time == null || position == null) return false;
    final elapsed = event.timeStamp - time;
    if (elapsed < Duration.zero || elapsed > _doubleTapWindow) return false;
    return (event.localPosition - position).distance <= _doubleTapSlop;
  }

  /// 回到整页适应视口。
  void _resetViewport() {
    if (_zoom <= _minZoom && _pan == Offset.zero) return;
    setState(() {
      _zoom = _minZoom;
      _pan = Offset.zero;
    });
  }

  /// 点选：先命中分镜；没命中但落在页面内则选中背景；页面之外取消选择。
  void _selectAt(Offset screenPoint, StoryboardPage page) {
    final pagePoint = _fit.toPage(screenPoint);
    final hitOrder = page.panelsByZOrder.reversed.toList(growable: false);
    final hitId = StoryboardGeometry.hitTestPanels(hitOrder, pagePoint);
    final interaction = ref.read(storyboardInteractionProvider.notifier);
    if (hitId != null) {
      interaction.select(hitId);
      return;
    }
    final pageRect = Rect.fromLTWH(
      0,
      0,
      page.width.toDouble(),
      page.height.toDouble(),
    );
    if (pageRect.contains(pagePoint)) {
      interaction.selectBackground();
    } else {
      interaction.clear();
    }
  }

  /// 点击顶点删除它；已到三个顶点时会被忽略并给出提示。
  Future<void> _removeVertex(StoryboardPanel panel, int index) async {
    final count = panel.effectivePoints.length;
    if (count <= StoryboardPanel.minPolygonPoints) {
      _showHint(context.l10n.storyboard_polygonMinPoints);
      return;
    }
    _document.beginGesture();
    await _document.removePanelVertex(panel.id, index);
  }

  /// 点击边中点插入一个顶点。
  Future<void> _insertVertex(
    StoryboardPanel panel,
    int insertIndex,
    Offset normalizedPoint,
  ) async {
    _document.beginGesture();
    await _document.insertPanelVertex(
      panel.id,
      insertIndex,
      StoryboardGeometry.toPixelPoints([normalizedPoint], panel.rect).first,
    );
  }

  void _showHint(String message) {
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 2)),
    );
  }

  // ==================== 拖动会话 ====================

  double get _scale => _fit.scale <= 0 ? 1 : _fit.scale;

  StoryboardDocumentController get _document =>
      ref.read(storyboardDocumentControllerProvider.notifier);

  void _beginBodyDrag(StoryboardPanel panel) {
    if (_viewportGesture || panel.locked) return;
    ref.read(storyboardInteractionProvider.notifier).setGestureActive(true);
    _document.beginGesture();
    _focusNode.requestFocus();
    _session = _DragSession(
      kind: _DragKind.body,
      panelId: panel.id,
      startRect: panel.rect,
    );
    _previewPanelId = panel.id;
    _previewRect = panel.rect;
    _lastValidRect = panel.rect;
    _ensureSelected(panel.id);
  }

  void _updateBodyDrag(Offset screenDelta) {
    final session = _session;
    if (session == null || session.kind != _DragKind.body) return;
    session.accumulated += screenDelta;
    final candidate = session.startRect.shift(session.accumulated / _scale);
    // 页边距与分镜间距是拖拽限制：越界的位置不会被采用。
    final resolved = _constrained(
      panelId: session.panelId,
      candidate: candidate,
      lastValid: _lastValidRect ?? session.startRect,
    );
    setState(() {
      _previewRect = resolved;
      _lastValidRect = resolved;
    });
  }

  void _beginResize(StoryboardPanel panel, StoryboardPanelCorner corner) {
    if (_viewportGesture || panel.locked) return;
    ref.read(storyboardInteractionProvider.notifier).setGestureActive(true);
    _document.beginGesture();
    _focusNode.requestFocus();
    _session = _DragSession(
      kind: _DragKind.resize,
      panelId: panel.id,
      startRect: panel.rect,
      corner: corner,
    );
    _previewPanelId = panel.id;
    _previewRect = panel.rect;
    _lastValidRect = panel.rect;
    _ensureSelected(panel.id);
  }

  void _updateResize(Offset screenDelta) {
    final session = _session;
    if (session == null || session.kind != _DragKind.resize) return;
    final corner = session.corner;
    if (corner == null) return;

    session.accumulated += screenDelta;
    final delta = session.accumulated / _scale;
    final start = session.startRect;
    var left = start.left;
    var top = start.top;
    var right = start.right;
    var bottom = start.bottom;
    switch (corner) {
      case StoryboardPanelCorner.topLeft:
        left += delta.dx;
        top += delta.dy;
      case StoryboardPanelCorner.topRight:
        right += delta.dx;
        top += delta.dy;
      case StoryboardPanelCorner.bottomLeft:
        left += delta.dx;
        bottom += delta.dy;
      case StoryboardPanelCorner.bottomRight:
        right += delta.dx;
        bottom += delta.dy;
    }

    // 越过对边时把被拖的一侧停在最小边长处，而不是翻转矩形。
    const minSide = StoryboardPanel.minSide;
    final isLeftEdge =
        corner == StoryboardPanelCorner.topLeft ||
        corner == StoryboardPanelCorner.bottomLeft;
    final isTopEdge =
        corner == StoryboardPanelCorner.topLeft ||
        corner == StoryboardPanelCorner.topRight;
    if (right - left < minSide) {
      if (isLeftEdge) {
        left = right - minSide;
      } else {
        right = left + minSide;
      }
    }
    if (bottom - top < minSide) {
      if (isTopEdge) {
        top = bottom - minSide;
      } else {
        bottom = top + minSide;
      }
    }

    final candidate = Rect.fromLTRB(left, top, right, bottom);
    final rules = _resizeRules(session.panelId);
    final resolved = rules == null
        ? candidate
        : rules.clampResize(
      candidate: candidate,
      reference: _lastValidRect ?? session.startRect,
      movingLeft:
          corner == StoryboardPanelCorner.topLeft ||
          corner == StoryboardPanelCorner.bottomLeft,
      movingTop:
          corner == StoryboardPanelCorner.topLeft ||
          corner == StoryboardPanelCorner.topRight,
    );
    setState(() {
      _previewRect = resolved;
      _lastValidRect = resolved;
    });
  }

  void _beginVertexDrag(StoryboardPanel panel, int index) {
    if (_viewportGesture || panel.locked) return;
    _document.beginGesture();
    _focusNode.requestFocus();
    _session = _DragSession(
      kind: _DragKind.vertex,
      panelId: panel.id,
      startRect: panel.rect,
      vertexIndex: index,
    );
    _previewPanelId = panel.id;
    _previewRect = panel.rect;
    _previewPixelPoints = StoryboardGeometry.toPixelPoints(
      panel.effectivePoints,
      panel.rect,
    );
    _ensureSelected(panel.id);
  }

  /// 顶点拖动：在页面像素空间里累加屏幕位移，再交给预览层重新拟合外接矩形。
  void _updateVertexDrag(int index, Offset screenDelta) {
    final session = _session;
    if (session == null ||
        session.kind != _DragKind.vertex ||
        session.vertexIndex != index) {
      return;
    }
    final pixels = List<Offset>.of(_previewPixelPoints ?? const <Offset>[]);
    if (index < 0 || index >= pixels.length) return;

    // 顶点不参与间距钳制：多边形按外接矩形约束等于禁止斜边贴边。
    pixels[index] = pixels[index] + screenDelta / _scale;
    setState(() => _previewPixelPoints = pixels);
  }

  /// 手势结束：把预览几何一次性写入文档。
  ///
  /// 拖动过程中不碰文档，避免逐帧触发 provider 通知与防抖落盘。
  /// 手势结束：先把预览几何写进文档，**写完之后**才撤掉预览。
  ///
  /// 反过来（先撤预览再异步写）会让面板回到手势开始时的位置停留若干帧再跳到
  /// 终点，看起来就是松手瞬间闪一下。
  Future<void> _endDrag() async {
    final session = _session;
    final panelId = _previewPanelId;
    final rect = _previewRect;
    final pixels = _previewPixelPoints;
    _session = null;
    if (session == null || panelId == null) {
      _clearPreview();
      return;
    }

    switch (session.kind) {
      case _DragKind.body:
      case _DragKind.resize:
        if (rect != null) await _document.setPanelRect(panelId, rect);
      case _DragKind.vertex:
        if (pixels != null && pixels.isNotEmpty) {
          await _document.setPanelPolygon(panelId, pixels);
        }
      case _DragKind.draft:
        break;
    }
    if (!mounted) return;
    _clearPreview();
  }

  void _clearPreview() {
    setState(() {
      _previewPanelId = null;
      _previewRect = null;
      _previewPixelPoints = null;
      _lastValidRect = null;
    });
    ref.read(storyboardInteractionProvider.notifier).setGestureActive(false);
  }

  /// 缩放用的约束；多边形与关闭约束的分镜**完全不收敛**。
  ///
  /// 返回 null 表示跳过：之前在这里回一个 pageSize 为零的空规则，结果
  /// clamp 把矩形收成了零尺寸，缩放直接失效。
  StoryboardSpacingRules? _resizeRules(String panelId) {
    final panel = _activePage?.panelById(panelId);
    if (panel == null || panel.isPolygon || panel.ignoreSpacing) return null;
    return _spacingRules(excludeId: panelId);
  }

  /// 分镜的快捷菜单：启用/停用与删除。
  ///
  /// 右键与长按走同一条路径，触屏不依赖外接鼠标；菜单只放最高频的两件事，
  /// 其余属性仍走左侧「分镜设置」。
  Future<void> _showPanelMenu(
    StoryboardPanel panel,
    Offset globalPosition,
  ) async {
    _ensureSelected(panel.id);
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox?;
    if (overlay == null) return;

    final selected = await showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(
        globalPosition & Size.zero,
        Offset.zero & overlay.size,
      ),
      items: [
        PopupMenuItem<String>(
          value: 'toggle',
          child: Text(
            panel.enabled
                ? context.l10n.storyboard_disablePanel
                : context.l10n.storyboard_enablePanel,
          ),
        ),
        const PopupMenuDivider(),
        PopupMenuItem<String>(
          value: 'spacing',
          child: Text(
            panel.ignoreSpacing
                ? context.l10n.storyboard_restoreSpacing
                : context.l10n.storyboard_ignoreSpacing,
          ),
        ),
        PopupMenuItem<String>(
          value: 'lock',
          child: Text(
            panel.locked
                ? context.l10n.storyboard_unlock
                : context.l10n.storyboard_lock,
          ),
        ),
        const PopupMenuDivider(),
        // 适配方式是每次调整都要改的，放在菜单里比再点开左侧分组快得多。
        PopupMenuItem<String>(
          value: 'fitCover',
          child: _menuCheck(
            context,
            label: context.l10n.storyboard_fitCover,
            checked: panel.fit == StoryboardFitMode.cover,
          ),
        ),
        PopupMenuItem<String>(
          value: 'fitContain',
          child: _menuCheck(
            context,
            label: context.l10n.storyboard_fitContain,
            checked: panel.fit == StoryboardFitMode.contain,
          ),
        ),
        PopupMenuItem<String>(
          value: 'fitStretch',
          child: _menuCheck(
            context,
            label: context.l10n.storyboard_fitStretch,
            checked: panel.fit == StoryboardFitMode.stretch,
          ),
        ),
        const PopupMenuDivider(),
        PopupMenuItem<String>(
          value: 'delete',
          child: Text(context.l10n.common_delete),
        ),
      ],
    );
    if (!mounted || selected == null) return;

    final document = ref.read(storyboardDocumentControllerProvider.notifier);
    switch (selected) {
      case 'toggle':
        await document.setPanelEnabled(panel.id, !panel.enabled);
      case 'spacing':
        await document.setPanelIgnoreSpacing(panel.id, !panel.ignoreSpacing);
      case 'lock':
        await document.setPanelLocked(panel.id, !panel.locked);
      case 'fitCover':
        await document.setPanelFit(panel.id, StoryboardFitMode.cover);
      case 'fitContain':
        await document.setPanelFit(panel.id, StoryboardFitMode.contain);
      case 'fitStretch':
        await document.setPanelFit(panel.id, StoryboardFitMode.stretch);
      case 'delete':
        document.beginGesture();
        await document.removePanel(panel.id);
        if (mounted) ref.read(storyboardInteractionProvider.notifier).clear();
    }
  }

  /// 菜单里的单选项：选中项前置对勾，未选中留同宽占位，避免文字左右跳动。
  static Widget _menuCheck(
    BuildContext context, {
    required String label,
    required bool checked,
  }) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      children: [
        SizedBox(
          width: 24,
          child: checked
              ? Icon(Icons.check_rounded, size: 16, color: scheme.primary)
              : null,
        ),
        Text(label),
      ],
    );
  }

  /// 施加间距约束；多边形与显式关闭约束的面镜不受限制。
  ///
  /// 多边形分镜的外接矩形只是包裹形状的盒子，按它就等于禁止斜边贴边或出血；
  /// 「不受钳制」则给需要刻意压边的情况一个显式出口。
  Rect _constrained({
    required String panelId,
    required Rect candidate,
    required Rect lastValid,
  }) {
    final panel = _activePage?.panelById(panelId);
    if (panel == null || panel.isPolygon || panel.ignoreSpacing) return candidate;
    return _spacingRules(
      excludeId: panelId,
    ).clamp(candidate, reference: lastValid);
  }

  StoryboardPage? get _activePage =>
      ref.read(storyboardDocumentControllerProvider).valueOrNull?.activePage;

  /// 当前页面的间距约束；[excludeId] 排除正在拖动的分镜本身。
  StoryboardSpacingRules _spacingRules({required String? excludeId}) {
    final page = _activePage;
    if (page == null) {
      return const StoryboardSpacingRules(
        pageSize: Size.zero,
        margin: 0,
        gutter: 0,
        occupied: [],
      );
    }
    return StoryboardSpacingRules.forPage(page: page, excludeId: excludeId);
  }

  void _ensureSelected(String panelId) {
    final interaction = ref.read(storyboardInteractionProvider);
    if (interaction.isSelected(panelId)) return;
    ref.read(storyboardInteractionProvider.notifier).select(panelId);
  }

  // ==================== 填充最大空白 ====================

  /// 计算当前最大空白矩形并更新预览。
  void _updateFillLargestPreview(Offset pagePoint) {
    final page = _activePage;
    if (page == null) return;
    final rect = StoryboardGeometry.largestEmptyRect(
      pageSize: Size(page.width.toDouble(), page.height.toDouble()),
      margin: page.margin,
      gutter: page.gutter,
      occupied: [for (final p in page.panels) p.rect],
    );
    if (rect.width < StoryboardPanel.minSide ||
        rect.height < StoryboardPanel.minSide) {
      setState(() => _fillLargestPreview = null);
      return;
    }
    setState(() => _fillLargestPreview = rect);
  }

  /// 点击落位：在预览的空白矩形处新建分镜，退出放置模式。
  Future<void> _commitFillLargest() async {
    final rect = _fillLargestPreview;
    if (rect == null) return;
    setState(() => _fillLargestPreview = null);
    _document.beginGesture();
    final id = await _document.addPanel(rect);
    if (!mounted || id.isEmpty) return;
    final interaction = ref.read(storyboardInteractionProvider.notifier);
    interaction.select(id);
    interaction.setPlacingFillLargest(false);
  }

  /// 放置模式的预览层：半透明高亮 + 虚线边框，随鼠标呼吸。
  List<Widget> _buildFillLargestLayer(StoryboardPage page) {
    final pageRect = _fit.rectToScreen(
      Rect.fromLTWH(0, 0, page.width.toDouble(), page.height.toDouble()),
    );
    return [
      Positioned.fromRect(
        rect: pageRect,
        child: MouseRegion(
          cursor: SystemMouseCursors.precise,
          onHover: (event) {
            final pagePoint = _fit.toPage(event.localPosition);
            _updateFillLargestPreview(pagePoint);
          },
          child: _FillLargestPreview(
            rect: _fillLargestPreview == null
                ? Rect.zero
                : _fit.rectToScreen(_fillLargestPreview!),
          ),
        ),
      ),
    ];
  }

  // ==================== 拉框新建 ====================

  void _beginDraft(Offset localPosition) {
    if (_viewportGesture) return;
    final start = _fit.toPage(localPosition);
    setState(() {
      _draftRect = Rect.fromPoints(start, start);
      _session = _DragSession(kind: _DragKind.draft);
    });
  }

  void _updateDraft(Offset localPosition) {
    final session = _session;
    if (session == null || session.kind != _DragKind.draft) return;
    final page = _activePage;
    if (page == null) return;
    final current = _fit.toPage(localPosition);
    final anchor = _draftRect?.topLeft ?? current;
    // 新建时同样受页边距约束：拉框不会拉进页边留白里。
    setState(() {
      _draftRect = _clampToMargins(Rect.fromPoints(anchor, current), page);
    });
  }

  /// 把矩形收进页边距以内；页面太窄时原样返回，避免退化成空矩形。
  static Rect _clampToMargins(Rect rect, StoryboardPage page) {
    final maxX = page.width.toDouble() - page.margin;
    final maxY = page.height.toDouble() - page.margin;
    if (maxX <= page.margin || maxY <= page.margin) return rect;
    return Rect.fromLTRB(
      rect.left.clamp(page.margin, maxX),
      rect.top.clamp(page.margin, maxY),
      rect.right.clamp(page.margin, maxX),
      rect.bottom.clamp(page.margin, maxY),
    );
  }

  void _commitDraft() {
    final draft = _draftRect;
    final session = _session;
    setState(() {
      _draftRect = null;
      _session = null;
    });
    if (session == null || session.kind != _DragKind.draft || draft == null) {
      return;
    }
    if (draft.width < StoryboardPanel.minSide ||
        draft.height < StoryboardPanel.minSide) {
      return;
    }
    unawaited(_addPanelAndSelect(draft));
  }

  void _cancelDraft() {
    if (_draftRect == null && _session?.kind != _DragKind.draft) return;
    setState(() {
      _draftRect = null;
      if (_session?.kind == _DragKind.draft) _session = null;
    });
  }

  /// 新建分镜后选中它并回到选择工具，避免连续误画。
  Future<void> _addPanelAndSelect(Rect rect) async {
    _document.beginGesture();
    final id = await _document.addPanel(rect);
    if (!mounted || id.isEmpty) return;
    final interaction = ref.read(storyboardInteractionProvider.notifier);
    interaction.select(id);
    interaction.setTool(StoryboardTool.select);
  }

  // ==================== 键盘 ====================

  /// 键盘只作桌面加速器：所有操作在工具条与设置面板里都有等价入口。
  KeyEventResult _handleKey(KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final keyboard = HardwareKeyboard.instance;
    final primary = keyboard.isControlPressed || keyboard.isMetaPressed;
    final shift = keyboard.isShiftPressed;

    if (primary && event.logicalKey == LogicalKeyboardKey.keyZ) {
      if (shift) {
        _document.redo();
      } else {
        _document.undo();
      }
      return KeyEventResult.handled;
    }
    if (primary && event.logicalKey == LogicalKeyboardKey.keyY) {
      _document.redo();
      return KeyEventResult.handled;
    }

    final selected = ref.read(storyboardInteractionProvider).selectedPanelId;
    if (selected == null) return KeyEventResult.ignored;

    if (event.logicalKey == LogicalKeyboardKey.delete ||
        event.logicalKey == LogicalKeyboardKey.backspace) {
      _document.beginGesture();
      _document.removePanel(selected);
      ref.read(storyboardInteractionProvider.notifier).select(null);
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      ref.read(storyboardInteractionProvider.notifier).select(null);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }
}

/// 拉框草稿的预览矩形（屏幕坐标）。
class _DraftRectPainter extends CustomPainter {
  const _DraftRectPainter({required this.draft});

  final Rect draft;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(
      draft,
      Paint()
        ..color = const Color(0x332196F3)
        ..style = PaintingStyle.fill,
    );
    canvas.drawRect(
      draft,
      Paint()
        ..color = const Color(0xFF2196F3)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5,
    );
  }

  @override
  bool shouldRepaint(covariant _DraftRectPainter oldDelegate) =>
      oldDelegate.draft != draft;
}

/// 页面背景：纯色、图片或不绘制。
///
/// 背景图的路径已经在模型层校验过，这里只负责呈现与解码失败兜底。
/// 生成中的流式预览通过 [previewBytes] 传入，盖在现有底图上实时刷新。
class StoryboardPageBackgroundView extends StatelessWidget {
  const StoryboardPageBackgroundView({
    super.key,
    required this.page,
    required this.galleryRoot,
    required this.viewportSize,
    this.previewBytes,
  });

  final StoryboardPage page;
  final String? galleryRoot;

  /// 画布视口尺寸；解码宽度按它封顶，放大画布不会成倍增加解码内存。
  final Size viewportSize;

  /// 正在生成的背景流式预览帧；为空时只显示已有底图。
  final Uint8List? previewBytes;

  @override
  Widget build(BuildContext context) {
    final background = page.background;
    final color = Color(background.colorArgb);
    if (!background.hasImage) {
      if (background.kind == StoryboardBackgroundKind.none) {
        return _decorate(const _StoryboardTransparencyBoard());
      }
      return _decorate(ColoredBox(color: color));
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        // 按屏幕上的实际像素解码：解码阶段完成降采样，避免大背景图缩到
        // 视口尺寸时的摩尔纹；也省内存。放大画布时组件的实际尺寸会超过视口，
        // 因此按视口宽度封顶——屏幕上一屏之内仍是一比一采样。
        final dpr = MediaQuery.devicePixelRatioOf(context);
        final visible =
            math.min(constraints.maxWidth, viewportSize.width) * dpr;
        final provider = StoryboardPanelImage.providerFor(
          galleryRoot: galleryRoot,
          relativePath: background.imagePath,
          decodeWidth: visible.isFinite && visible > 1
              ? visible.ceil().clamp(1, 1 << 14)
              : page.width,
        );
        if (provider == null) return _decorate(ColoredBox(color: color));
        return _decorate(
          ColoredBox(
            color: color,
            child: Image(
              image: provider,
              fit: StoryboardPanelImage.boxFitOf(background.fit),
              gaplessPlayback: true,
              filterQuality: FilterQuality.high,
              errorBuilder: (context, error, stackTrace) =>
                  ColoredBox(color: color),
            ),
          ),
        );
      },
    );
  }

  /// 预览帧存在时整页替换显示；预览是完整构图，直接盖住底图最直观。
  Widget _decorate(Widget child) {
    final bytes = previewBytes;
    if (bytes == null || bytes.isEmpty) return child;
    return Stack(
      fit: StackFit.expand,
      children: [
        child,
        Image.memory(
          bytes,
          fit: StoryboardPanelImage.boxFitOf(page.background.fit),
          gaplessPlayback: true,
        ),
      ],
    );
  }
}

/// 无背景时的透明棋盘格，提示这一块在导出后是透明的。
class _StoryboardTransparencyBoard extends StatelessWidget {
  const _StoryboardTransparencyBoard();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return CustomPaint(
      painter: _CheckerPainter(
        light: scheme.surfaceContainerHigh,
        dark: scheme.surfaceContainerHighest,
      ),
    );
  }
}

class _CheckerPainter extends CustomPainter {
  const _CheckerPainter({required this.light, required this.dark});

  final Color light;
  final Color dark;

  static const double _cell = 16;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = light);
    final paint = Paint()..color = dark;
    final columns = (size.width / _cell).ceil();
    final rows = (size.height / _cell).ceil();
    for (var row = 0; row < rows; row++) {
      for (var column = 0; column < columns; column++) {
        if ((row + column).isEven) continue;
        canvas.drawRect(
          Rect.fromLTWH(column * _cell, row * _cell, _cell, _cell),
          paint,
        );
      }
    }
  }

  @override
  bool shouldRepaint(covariant _CheckerPainter oldDelegate) =>
      oldDelegate.light != light || oldDelegate.dark != dark;
}

/// 「填充最大空白」的预览矩形：半透明高亮 + 虚线边框。
class _FillLargestPreview extends StatelessWidget {
  const _FillLargestPreview({required this.rect});

  final Rect rect;

  @override
  Widget build(BuildContext context) {
    if (rect.isEmpty) return const SizedBox.expand();
    return CustomPaint(
      painter: _FillLargestPreviewPainter(rect: rect),
    );
  }
}

class _FillLargestPreviewPainter extends CustomPainter {
  const _FillLargestPreviewPainter({required this.rect});

  final Rect rect;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(
      rect,
      Paint()
        ..color = const Color(0x219C27B0)
        ..style = PaintingStyle.fill,
    );
    canvas.drawRect(
      rect.deflate(1),
      Paint()
        ..color = const Color(0xFF9C27B0)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..isAntiAlias = true,
    );
  }

  @override
  bool shouldRepaint(covariant _FillLargestPreviewPainter oldDelegate) =>
      oldDelegate.rect != rect;
}
