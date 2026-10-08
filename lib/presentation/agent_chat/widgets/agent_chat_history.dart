import 'package:flutter/gestures.dart' show PointerScrollEvent;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart'
    show
        RenderBox,
        RenderProxyBox,
        RenderProxySliver,
        RenderSliver,
        ScrollCacheExtent,
        SliverGeometry,
        SliverMultiBoxAdaptorParentData;

import '../../../core/utils/localization_extension.dart';
import 'agent_chat_panel_controller.dart';
import 'agent_chat_turn.dart';

typedef AgentChatTurnBuilder =
    Widget Function(
      BuildContext context,
      AgentChatTurnModel turn,
      bool current,
    );

/// Turn-virtualized transcript viewport.
///
/// SliverList owns variable-height geometry and only asks for visible turns
/// plus [cacheExtent] overscan. Collapsed history and item transcripts are not
/// inserted into the element tree until explicitly requested.
class AgentChatThreadViewport extends StatefulWidget {
  const AgentChatThreadViewport({
    super.key,
    required this.sessionId,
    required this.turns,
    required this.controller,
    required this.horizontalPadding,
    required this.maxWidth,
    required this.compactLayout,
    required this.hasEarlier,
    required this.historyLoading,
    required this.prependAnchorEntryId,
    required this.geometryRevision,
    required this.onLoadEarlier,
    required this.live,
    required this.turnBuilder,
  });

  final String sessionId;
  final List<AgentChatTurnModel> turns;
  final AgentChatPanelController controller;
  final double horizontalPadding;
  final double maxWidth;
  final bool compactLayout;
  final bool hasEarlier;
  final bool historyLoading;
  final String? prependAnchorEntryId;
  final Object geometryRevision;
  final Future<void> Function()? onLoadEarlier;
  final Widget live;
  final AgentChatTurnBuilder turnBuilder;

  @override
  State<AgentChatThreadViewport> createState() =>
      _AgentChatThreadViewportState();
}

class _AgentChatThreadViewportState extends State<AgentChatThreadViewport> {
  static const _retainedTurnCount = 6;
  static const _historyPageSize = 8;
  static const _overscanExtent = 900.0;
  static const _estimatedTurnHeight = 180.0;
  static const _fullMeasureExtent = 100000.0;

  final Map<Object, GlobalKey> _turnKeys = {};
  final Map<Object, double> _measuredHeights = {};
  late int _visibleTurnCount;
  int _anchorRestoreGeneration = 0;
  _PausedViewportReference? _pausedReference;
  bool _pausedReferenceScheduled = false;
  double? _liveExtent;
  double? _earlierButtonExtent;
  bool _measureWholeWindow = true;
  late final _PausedDriftCorrection _pausedDrift = _PausedDriftCorrection(
    isEnabled: () =>
        !widget.controller.followingLatest && !widget.controller.userScrolling,
    readMetric: _anchorMetricOf,
  );

  @override
  void initState() {
    super.initState();
    _visibleTurnCount = _initialVisibleCount;
    WidgetsBinding.instance.addPostFrameCallback((_) => _restoreOffset());
  }

  @override
  void didUpdateWidget(covariant AgentChatThreadViewport oldWidget) {
    final sameSession = oldWidget.sessionId == widget.sessionId;
    final geometryChanged =
        oldWidget.geometryRevision != widget.geometryRevision ||
        oldWidget.maxWidth != widget.maxWidth ||
        oldWidget.horizontalPadding != widget.horizontalPadding ||
        oldWidget.compactLayout != widget.compactLayout ||
        oldWidget.prependAnchorEntryId != widget.prependAnchorEntryId;
    final reference =
        sameSession &&
            geometryChanged &&
            oldWidget.maxWidth > 0 &&
            widget.maxWidth > 0 &&
            !widget.controller.followingLatest
        ? _pausedReference
        : null;
    super.didUpdateWidget(oldWidget);
    if (!sameSession) {
      _anchorRestoreGeneration++;
      _visibleTurnCount = _initialVisibleCount;
      _turnKeys.clear();
      _measuredHeights.clear();
      _pausedReference = null;
      _measureWholeWindow = true;
      WidgetsBinding.instance.addPostFrameCallback((_) => _restoreOffset());
    } else {
      final previousVisibleTurnCount = _visibleTurnCount;
      if (widget.turns.length < _visibleTurnCount) {
        _visibleTurnCount = widget.turns.length;
      } else if (widget.turns.length > oldWidget.turns.length &&
          _visibleTurnCount >= oldWidget.turns.length) {
        final added = widget.turns.length - oldWidget.turns.length;
        final prepended =
            widget.prependAnchorEntryId != null &&
            widget.prependAnchorEntryId != oldWidget.prependAnchorEntryId;
        final revealCount = prepended && added > _historyPageSize
            ? _historyPageSize
            : added;
        _visibleTurnCount = (_visibleTurnCount + revealCount).clamp(
          0,
          widget.turns.length,
        );
      }
      // 保留窗口变了就有新的未测量项，先整体量一遍再回到正常缓存范围。
      if (widget.turns.length != oldWidget.turns.length ||
          _visibleTurnCount != previousVisibleTurnCount) {
        _measureWholeWindow = true;
      }
      if (reference != null &&
          reference.sessionId == widget.sessionId &&
          reference.anchors.isNotEmpty) {
        _scheduleAnchorRestore(reference);
      }
    }
  }

  int get _initialVisibleCount =>
      widget.turns.length.clamp(0, _retainedTurnCount);

  int get _hiddenCount => widget.turns.length - _visibleTurnCount;

  void _saveOffset(String sessionId) {
    widget.controller.saveSessionOffset(sessionId);
  }

  void _restoreOffset() {
    if (!mounted) return;
    widget.controller.restoreSessionOffset(widget.sessionId);
  }

  Object _identityFor(AgentChatTurnModel turn) =>
      turn.timeline?.id ?? turn.ordinal;

  GlobalKey _keyFor(AgentChatTurnModel turn) =>
      _turnKeys.putIfAbsent(_identityFor(turn), GlobalKey.new);

  /// 每帧结束后保存暂停视图参考点。
  ///
  /// 参考点必须在布局结束、滚动位置已落到渲染树之后采集：流式帧的 build 阶段
  /// 里，用户滚动已经改了 offsets，但布局还是上一帧的，此时量出来的位置差会正好
  /// 等于用户刚滚过的距离，补偿就会把用户滚出来的位置顶回去，表现为来回抽搐。
  void _scheduleReferenceRefresh() {
    if (_pausedReferenceScheduled) return;
    _pausedReferenceScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _pausedReferenceScheduled = false;
      if (!mounted) return;
      final controller = widget.controller;
      final scroll = controller.scrollController;
      if (controller.followingLatest || !scroll.hasClients) {
        _pausedReference = null;
        return;
      }
      final anchors = _captureVisibleAnchors();
      _pausedReference = _PausedViewportReference(
        sessionId: widget.sessionId,
        offset: scroll.offset,
        interactionRevision: controller.viewportInteractionRevision,
        anchors: anchors,
      );
      // 漂移参考取最近的可见回合（含当前回合：它的顶边同样反映内容长高）。
      final driftAnchors = _captureVisibleAnchors(includeCurrentTurn: true);
      final driftAnchor = driftAnchors.isEmpty ? null : driftAnchors.first;
      final driftMetric = driftAnchor == null
          ? null
          : _anchorMetricOf(driftAnchor.key, driftAnchor.identity);
      _pausedDrift
        ..anchorKey = driftMetric == null ? null : driftAnchor!.key
        ..anchorIdentity = driftMetric == null ? null : driftAnchor!.identity
        ..anchorMetric = driftMetric;
    });
  }

  /// 量完这一帧就回到正常缓存范围：只多量一帧，避免长期全量布局。
  void _scheduleMeasureWindowReset() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_measureWholeWindow) return;
      setState(() => _measureWholeWindow = false);
    });
  }

  /// 锚点的滚动坐标度量：回合**顶边** = layoutOffset + 实测高度。
  ///
  /// 逆序列表里顶边就是"这段内容离实时边缘多远"，下方内容长高会把它顶上去，
  /// 当前回合自己长高也会把它顶上去（layoutOffset 不变、高度变大），所以两种
  /// 情况都能量到漂移；只看 layoutOffset 会漏掉当前回合。
  double? _anchorMetricOf(GlobalKey key, Object identity) {
    final layoutOffset = _layoutOffsetOf(key);
    final height = _measuredHeights[identity];
    if (layoutOffset == null || height == null) return null;
    return layoutOffset + height;
  }

  double? _layoutOffsetOf(GlobalKey key) {
    final renderObject = key.currentContext?.findRenderObject();
    if (renderObject == null) return null;
    final parentData = renderObject.parentData;
    if (parentData is SliverMultiBoxAdaptorParentData) {
      return parentData.layoutOffset;
    }
    // 锚点回合外面还套了保活/测量层，往上找到 sliver 的直接子节点。
    RenderObject? node = renderObject;
    while (node != null && node.parent is! RenderSliver) {
      node = node.parent;
    }
    final sliverChildData = node?.parentData;
    return sliverChildData is SliverMultiBoxAdaptorParentData
        ? sliverChildData.layoutOffset
        : null;
  }

  List<_ViewportAnchor> _captureVisibleAnchors({
    bool includeCurrentTurn = false,
  }) {
    final viewport = context.findRenderObject();
    if (viewport is! RenderBox || !viewport.attached || !viewport.hasSize) {
      return const [];
    }
    final viewportTop = viewport.localToGlobal(Offset.zero).dy;
    final viewportBottom = viewportTop + viewport.size.height;
    // 默认排除当前回合：它自己就在长高，不能当"上方内容是否移动"的参考。
    final candidates = includeCurrentTurn || widget.turns.length <= 1
        ? widget.turns
        : widget.turns.take(widget.turns.length - 1);
    final stableHistoricalKeys = <(Object, GlobalKey)>[];
    for (final turn in candidates) {
      final identity = _identityFor(turn);
      final key = _turnKeys[identity];
      if (key != null) stableHistoricalKeys.add((identity, key));
    }
    final anchors = <_ViewportAnchor>[];
    for (final (identity, key) in stableHistoricalKeys) {
      final anchorContext = key.currentContext;
      final renderObject = anchorContext?.findRenderObject();
      if (renderObject is! RenderBox ||
          !renderObject.attached ||
          !renderObject.hasSize) {
        continue;
      }
      final top = renderObject.localToGlobal(Offset.zero).dy;
      final bottom = top + renderObject.size.height;
      if (bottom <= viewportTop || top >= viewportBottom) continue;
      anchors.add(_ViewportAnchor(key: key, identity: identity, top: top));
    }
    anchors.sort((a, b) {
      final aDistance = (a.top - viewportTop).abs();
      final bDistance = (b.top - viewportTop).abs();
      return aDistance.compareTo(bDistance);
    });
    return anchors;
  }

  void _scheduleAnchorRestore(_PausedViewportReference reference) {
    final generation = ++_anchorRestoreGeneration;
    final sessionId = widget.sessionId;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          generation != _anchorRestoreGeneration ||
          widget.sessionId != sessionId ||
          widget.controller.followingLatest) {
        return;
      }
      final scroll = widget.controller.scrollController;
      // 参考点之后滚动位置动过：这一帧的位移来自滚动本身（用户滚动或程序化
      // 跳转），再补偿就会把用户刚滚出来的位置顶回去，表现为来回抽搐。
      if (!scroll.hasClients ||
          (scroll.offset - reference.offset).abs() > 0.5) {
        return;
      }
      for (final anchor in reference.anchors) {
        final anchorContext = anchor.key.currentContext;
        final renderObject = anchorContext?.findRenderObject();
        if (renderObject is! RenderBox ||
            !renderObject.attached ||
            !renderObject.hasSize) {
          continue;
        }
        final currentTop = renderObject.localToGlobal(Offset.zero).dy;
        widget.controller.restorePausedViewportAnchor(
          visualDelta: currentTop - anchor.top,
          expectedInteractionRevision: reference.interactionRevision,
        );
        return;
      }
    });
  }

  Future<void> _jumpTo(AgentChatTurnModel turn) async {
    final index = widget.turns.indexOf(turn);
    if (index < 0) return;
    if (index == widget.turns.length - 1) {
      widget.controller.followLatest();
      return;
    }
    final disableAnimations = MediaQuery.disableAnimationsOf(context);
    widget.controller.pauseFollowingLatest();
    final targetContext = _keyFor(turn).currentContext;
    if (targetContext != null) {
      await Scrollable.ensureVisible(
        targetContext,
        duration: disableAnimations
            ? Duration.zero
            : const Duration(milliseconds: 180),
        curve: Curves.easeOutCubic,
        alignment: 0.18,
      );
      return;
    }
    final scroll = widget.controller.scrollController;
    if (!scroll.hasClients) return;
    var estimatedOffset = 0.0;
    for (var later = widget.turns.length - 1; later > index; later--) {
      estimatedOffset +=
          _measuredHeights[_identityFor(widget.turns[later])] ??
          _estimatedTurnHeight;
    }
    final targetOffset = estimatedOffset
        .clamp(0, scroll.position.maxScrollExtent)
        .toDouble();
    if (disableAnimations) {
      scroll.jumpTo(targetOffset);
      return;
    }
    await scroll.animateTo(
      targetOffset,
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOutCubic,
    );
  }

  Future<void> _showEarlier() async {
    if (_hiddenCount == 0) {
      if (!widget.historyLoading) await widget.onLoadEarlier?.call();
      return;
    }
    final scroll = widget.controller.scrollController;
    final before = scroll.hasClients ? scroll.offset : null;
    setState(() {
      _visibleTurnCount = (_visibleTurnCount + _historyPageSize).clamp(
        0,
        widget.turns.length,
      );
    });
    // In reverse geometry older turns are appended beyond the current anchor.
    // Keep the exact pixel anchor if the framework performs any correction.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (before == null || !scroll.hasClients) return;
      widget.controller.jumpToPreservingFollow(before);
    });
  }

  @override
  void dispose() {
    _saveOffset(widget.sessionId);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    _scheduleReferenceRefresh();
    if (_measureWholeWindow) _scheduleMeasureWindowReset();
    final visibleStart = widget.turns.length - _visibleTurnCount;
    final showEarlier = _hiddenCount > 0 || widget.hasEarlier;
    final itemCount = 1 + _visibleTurnCount + (showEarlier ? 1 : 0);
    final visibleTurns = widget.turns
        .skip(visibleStart)
        .toList(growable: false);
    return Stack(
      children: [
        NotificationListener<ScrollMetricsNotification>(
          onNotification: (notification) {
            final handled = widget.controller.handleScrollMetricsNotification(
              notification,
            );
            // 布局改变了可见几何：等这一帧结束再重采暂停视图参考点。
            _scheduleReferenceRefresh();
            return handled;
          },
          child: NotificationListener<ScrollNotification>(
            onNotification: (notification) {
              final handled = widget.controller.handleScrollNotification(
                notification,
              );
              _scheduleReferenceRefresh();
              return handled;
            },
            // Keyboard and scrollbar track moves are driven scroll activities,
            // so arm their user intent before notifications change the offset.
            child: Focus(
              onKeyEvent: widget.controller.handleViewportKeyEvent,
              child: Listener(
                onPointerDown: (_) =>
                    widget.controller.beginPotentialUserScroll(),
                onPointerSignal: (event) {
                  if (event is PointerScrollEvent) {
                    widget.controller.beginPotentialUserScroll();
                  }
                },
                onPointerUp: (_) =>
                    widget.controller.cancelPotentialUserScroll(),
                onPointerCancel: (_) =>
                    widget.controller.cancelPotentialUserScroll(),
                child: CustomScrollView(
                  key: ValueKey('agent-chat-thread-${widget.sessionId}'),
                  controller: widget.controller.scrollController,
                  reverse: true,
                  scrollCacheExtent: _measureWholeWindow
                      ? const ScrollCacheExtent.pixels(_fullMeasureExtent)
                      : const ScrollCacheExtent.pixels(_overscanExtent),
                  slivers: [
                    SliverPadding(
                      padding: EdgeInsets.symmetric(
                        horizontal: widget.horizontalPadding,
                        vertical: 12,
                      ),
                      sliver: _DriftCorrectingSliver(
                        drift: _pausedDrift,
                        child: SliverList(
                          delegate: _TranscriptChildDelegate(
                            _buildItem,
                            childCount: itemCount,
                            fallbackExtent: _unmeasuredItemExtent,
                            extentForIndex: _measuredExtentForIndex,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        if (!widget.compactLayout &&
            widget.horizontalPadding >= 24 &&
            visibleTurns.length > 1)
          Positioned(
            left: 2,
            top: 16,
            bottom: 16,
            child: _TurnGutter(turns: visibleTurns, onSelected: _jumpTo),
          ),
      ],
    );
  }

  Widget _buildItem(BuildContext context, int index) {
    if (index == 0) {
      return _MeasureSize(
        onChange: (size) => _liveExtent = size.height,
        child: _bounded(widget.live),
      );
    }
    final reverseTurnIndex = index - 1;
    if (reverseTurnIndex < _visibleTurnCount) {
      final turnIndex = widget.turns.length - 1 - reverseTurnIndex;
      final turn = widget.turns[turnIndex];
      final identity = _identityFor(turn);
      return _RetainedTurn(
        child: _MeasureSize(
          key: _keyFor(turn),
          onChange: (size) => _measuredHeights[identity] = size.height,
          child: RepaintBoundary(
            key: ValueKey('agent-turn-${turn.timeline?.id ?? turn.ordinal}'),
            child: _bounded(
              widget.turnBuilder(
                context,
                turn,
                turnIndex == widget.turns.length - 1,
              ),
            ),
          ),
        ),
      );
    }
    return _MeasureSize(
      onChange: (size) => _earlierButtonExtent = size.height,
      child: _bounded(
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: TextButton.icon(
            key: const ValueKey('agent-chat-earlier-messages'),
            onPressed: widget.historyLoading ? null : _showEarlier,
            icon: widget.historyLoading
                ? SizedBox.square(
                    dimension: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 1.7,
                      value: MediaQuery.disableAnimationsOf(context)
                          ? 0.75
                          : null,
                    ),
                  )
                : const Icon(Icons.history_rounded, size: 17),
            label: Text(
              widget.historyLoading
                  ? context.l10n.common_loading
                  : _hiddenCount > 0
                  ? context.l10n.agentChat_earlierMessages(_hiddenCount)
                  : context.l10n.agentChat_loadEarlierMessages,
            ),
          ),
        ),
      ),
    );
  }

  /// 已量到的子项高度；null 表示还没量过，交给 delegate 用标称高度兜底。
  double? _measuredExtentForIndex(int index) {
    if (index == 0) return _liveExtent;
    final reverseTurnIndex = index - 1;
    if (reverseTurnIndex < _visibleTurnCount) {
      final turnIndex = widget.turns.length - 1 - reverseTurnIndex;
      if (turnIndex < 0 || turnIndex >= widget.turns.length) return null;
      return _measuredHeights[_identityFor(widget.turns[turnIndex])];
    }
    return _earlierButtonExtent;
  }

  /// 部署未量到的子项时用的高度：已量到的历史回合高度中位数。
  ///
  /// 用中位数而不是平均值或固定标称值：合成长文回合一屏就有数千像素，当前正在
  /// 流式输出的那个回合更会持续变高，把它们的值带进估算会让"还没量到的项"按一个
  /// 虚高的高度计入，滚动范围随"哪些项量过没有"漂移。中位数对这类离群值不敏感。
  double get _unmeasuredItemExtent {
    final heights = <double>[];
    for (final turn in widget.turns) {
      final height = _measuredHeights[_identityFor(turn)];
      if (height == null || height <= 0) continue;
      heights.add(height);
    }
    if (heights.isEmpty) return _estimatedTurnHeight;
    heights.sort();
    return heights[heights.length ~/ 2];
  }

  Widget _bounded(Widget child) => Align(
    alignment: Alignment.center,
    child: ConstrainedBox(
      constraints: BoxConstraints(maxWidth: widget.maxWidth),
      child: child,
    ),
  );
}

/// 让滚动范围只随内容变化，不随当前布局窗口变化。
///
/// [SliverChildBuilderDelegate] 默认按已布局子节点的平均高度外推剩余项
/// （`SliverChildDelegate.estimateMaxScrollOffset`）。本视口的子项高度差异极大：
/// 合成长文回合动辄数千像素，普通气泡只有百来像素，于是外推值会随巨大的回合进出
/// 布局窗口在几千像素之间反复跳：滚动条高度跟着变，滚动位置还会被夹到收缩后的
/// 范围里，表现为抽搐。这里改为用实测高度求和，没量到的项用标称高度，滚动过程中
/// 保持恒定，只有内容真的变了才变。
class _TranscriptChildDelegate extends SliverChildBuilderDelegate {
  _TranscriptChildDelegate(
    super.builder, {
    required super.childCount,
    required this.extentForIndex,
    required this.fallbackExtent,
  });

  final double? Function(int index) extentForIndex;
  final double fallbackExtent;

  @override
  double? estimateMaxScrollOffset(
    int firstIndex,
    int lastIndex,
    double leadingScrollOffset,
    double trailingScrollOffset,
  ) {
    final childCount = estimatedChildCount;
    if (childCount == null) return null;
    var extent = 0.0;
    for (var index = 0; index < childCount; index++) {
      extent += extentForIndex(index) ?? fallbackExtent;
    }
    return extent;
  }
}

class _TurnGutter extends StatelessWidget {
  const _TurnGutter({required this.turns, required this.onSelected});

  final List<AgentChatTurnModel> turns;
  final ValueChanged<AgentChatTurnModel> onSelected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.surface.withValues(alpha: 0.9),
      borderRadius: BorderRadius.circular(12),
      child: SizedBox(
        width: 38,
        child: ListView.builder(
          shrinkWrap: true,
          padding: const EdgeInsets.symmetric(vertical: 4),
          itemCount: turns.length,
          itemBuilder: (context, index) => Tooltip(
            message: context.l10n.agentChat_turnNavigation(
              index + 1,
              _preview(turns[index].preview),
            ),
            child: InkResponse(
              key: ValueKey('agent-turn-gutter-${turns[index].ordinal}'),
              onTap: () => onSelected(turns[index]),
              radius: 18,
              child: SizedBox.square(
                dimension: 32,
                child: Center(
                  child: Container(
                    width: index == turns.length - 1 ? 8 : 6,
                    height: index == turns.length - 1 ? 8 : 6,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: index == turns.length - 1
                          ? theme.colorScheme.primary
                          : theme.colorScheme.onSurfaceVariant.withValues(
                              alpha: 0.5,
                            ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  String _preview(String text) {
    if (text.isEmpty) return '…';
    return text.length <= 36 ? text : '${text.substring(0, 36)}…';
  }
}

class _RetainedTurn extends StatefulWidget {
  const _RetainedTurn({required this.child});

  final Widget child;

  @override
  State<_RetainedTurn> createState() => _RetainedTurnState();
}

class _RetainedTurnState extends State<_RetainedTurn>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return widget.child;
  }
}

class _ViewportAnchor {
  const _ViewportAnchor({
    required this.key,
    required this.identity,
    required this.top,
  });

  final GlobalKey key;
  final Object identity;
  final double top;
}

/// 暂停视图的参考点：某一帧布局结束后的滚动位置与可见回合位置。
class _PausedViewportReference {
  _PausedViewportReference({
    required this.sessionId,
    required this.offset,
    required this.interactionRevision,
    required this.anchors,
  });

  final String sessionId;
  double offset;
  final int interactionRevision;
  final List<_ViewportAnchor> anchors;
}

/// 暂停视口的漂移校正：sliver 在布局阶段读取，State 在帧末刷新参考点。
///
/// 逆序列表里锚点回合的 layoutOffset 就是"它下方所有内容的总高度"，正在吐字的
/// 回合长高多少，上方内容就被顶起多少。这个补偿必须发生在同一帧的布局阶段，
/// 否则这一帧先画在漂移位置、下一帧才被拉回，每来一批 token 画面就抖一下。
class _PausedDriftCorrection {
  _PausedDriftCorrection({required this.isEnabled, required this.readMetric});

  GlobalKey? anchorKey;
  Object? anchorIdentity;
  double? anchorMetric;
  final bool Function() isEnabled;
  final double? Function(GlobalKey key, Object identity) readMetric;

  /// 需要在同一帧布局内施加的偏移校正量；返回 null 表示不用校正。
  double? pendingCorrection() {
    if (!isEnabled()) return null;
    final key = anchorKey;
    final identity = anchorIdentity;
    final reference = anchorMetric;
    if (key == null || identity == null || reference == null) return null;
    if (key.currentContext == null) return null;
    final current = readMetric(key, identity);
    if (current == null) return null;
    final drift = current - reference;
    return drift.abs() < 0.5 ? null : drift;
  }

  /// 校正已经提出：参考点前移，框架重排时不会再报一次。
  void acceptCorrection(double drift) {
    final reference = anchorMetric;
    if (reference != null) anchorMetric = reference + drift;
  }
}

/// 布局阶段上报暂停视口漂移的 sliver 包装层。
///
/// 把"上方内容被顶起了多少"作为 [SliverGeometry.scrollOffsetCorrection] 交给
/// viewport：框架会在同一次布局里 `correctBy` 并重新布局，paint 用的就是校正后的
/// 偏移，所以画面不会先画偏再被拉回。（`ScrollMetricsNotification` 是 microtask
/// 派发的，晚于 paint，来不及。）
class _DriftCorrectingSliver extends SingleChildRenderObjectWidget {
  const _DriftCorrectingSliver({required this.drift, required super.child});

  final _PausedDriftCorrection drift;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderDriftCorrectingSliver(drift);

  @override
  void updateRenderObject(
    BuildContext context,
    covariant _RenderDriftCorrectingSliver renderObject,
  ) {
    renderObject.drift = drift;
  }
}

class _RenderDriftCorrectingSliver extends RenderProxySliver {
  _RenderDriftCorrectingSliver(this.drift);

  _PausedDriftCorrection drift;

  @override
  void performLayout() {
    super.performLayout();
    final current = geometry;
    // 子 sliver 自己报了校正就先按它的来，下一轮布局再看漂移。
    if (current == null || current.scrollOffsetCorrection != null) return;
    final correction = drift.pendingCorrection();
    if (correction == null) return;
    drift.acceptCorrection(correction);
    geometry = SliverGeometry(
      scrollExtent: current.scrollExtent,
      paintExtent: current.paintExtent,
      paintOrigin: current.paintOrigin,
      layoutExtent: current.layoutExtent,
      maxPaintExtent: current.maxPaintExtent,
      maxScrollObstructionExtent: current.maxScrollObstructionExtent,
      crossAxisExtent: current.crossAxisExtent,
      hasVisualOverflow: current.hasVisualOverflow,
      visible: current.visible,
      cacheExtent: current.cacheExtent,
      hitTestExtent: current.hitTestExtent,
      scrollOffsetCorrection: correction,
    );
  }
}

class _MeasureSize extends SingleChildRenderObjectWidget {
  const _MeasureSize({super.key, required this.onChange, required super.child});

  final ValueChanged<Size> onChange;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _MeasureSizeRenderObject(onChange);

  @override
  void updateRenderObject(
    BuildContext context,
    covariant _MeasureSizeRenderObject renderObject,
  ) {
    renderObject.onChange = onChange;
  }
}

class _MeasureSizeRenderObject extends RenderProxyBox {
  _MeasureSizeRenderObject(this._onChange);

  ValueChanged<Size> _onChange;
  Size? _reportedSize;

  set onChange(ValueChanged<Size> value) => _onChange = value;

  @override
  void performLayout() {
    super.performLayout();
    if (size == _reportedSize) return;
    _reportedSize = size;
    _onChange(size);
  }
}
