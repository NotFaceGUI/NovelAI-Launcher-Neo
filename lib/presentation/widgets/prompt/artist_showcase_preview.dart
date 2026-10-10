import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/utils/app_logger.dart';
import '../../../data/models/danbooru/artist_showcase.dart';
import '../../providers/artist_showcase_provider.dart';
import '../../screens/online_gallery/online_gallery_detail_launcher.dart';
import 'artist_showcase_card.dart';
import 'prompt_text_projection.dart';
import 'tag_editor_session.dart';

/// 提示词里画师标签的代表作预览。
///
/// 选中一个标签时（文本模式框选，标签模式选中胶囊），先贴着该标签弹出卡片
/// 并显示加载动画，再换成该作者在 Danbooru 上的最高分作品。标签不是画师、
/// Danbooru 没有收录或取不到图片时卡片直接收起，不留占位。
class ArtistShowcasePreview extends ConsumerStatefulWidget {
  const ArtistShowcasePreview({
    super.key,
    required this.session,
    required this.child,
  });

  /// 标签会话提供标签切分与当前选中项。
  final TagEditorSession session;

  final Widget child;

  /// 选中稳定多久后才开始查询，避免拖动选区时反复打接口。
  static const Duration settleDelay = Duration(milliseconds: 160);

  @override
  ConsumerState<ArtistShowcasePreview> createState() =>
      _ArtistShowcasePreviewState();
}

class _ArtistShowcasePreviewState extends ConsumerState<ArtistShowcasePreview> {
  final _layerLink = LayerLink();
  final _targetKey = GlobalKey();
  final _portal = OverlayPortalController();

  Timer? _settleTimer;
  String? _candidateTag;
  ArtistShowcase? _showcase;
  Offset _anchor = Offset.zero;
  Offset? _lastPointer;

  @override
  void initState() {
    super.initState();
    widget.session.controller.addListener(_handleSelectionChanged);
    widget.session.addListener(_handleSelectionChanged);
  }

  @override
  void dispose() {
    widget.session.controller.removeListener(_handleSelectionChanged);
    widget.session.removeListener(_handleSelectionChanged);
    _settleTimer?.cancel();
    super.dispose();
  }

  void _handlePointerHover(PointerHoverEvent event) {
    _lastPointer = event.position;
  }

  void _handleSelectionChanged() {
    if (!mounted) return;
    final tag = _selectedTagLabel();
    if (tag == _candidateTag) return;

    AppLogger.d('Artist showcase candidate: $tag', 'ArtistShowcase');
    _candidateTag = tag;
    _settleTimer?.cancel();
    _dismiss();
    if (tag == null) return;

    _settleTimer = Timer(ArtistShowcasePreview.settleDelay, () {
      unawaited(_reveal(tag));
    });
  }

  /// 选中的唯一标签文案；跨多个标签或没有选中时返回 null。
  String? _selectedTagLabel() {
    final session = widget.session;
    final textSelection = session.textSelectionTags;
    final selected = textSelection.length == 1
        ? textSelection.single
        : (session.tagMode && session.selectedTags.length == 1
              ? session.selectedTags.single
              : null);
    if (selected == null) return null;
    final label = selected.span.label.trim();
    return label.isEmpty ? null : label;
  }

  /// 选中画师标签后先弹出加载中的卡片，再填上代表作。
  Future<void> _reveal(String tagName) async {
    final isArtist = await ref.read(artistTagProvider(tagName).future);
    if (!mounted || !isArtist || _candidateTag != tagName) return;

    _showLoadingCard(tagName);

    final showcase = await ref.read(artistShowcaseProvider(tagName).future);
    AppLogger.d(
      'Artist showcase result for $tagName: post ${showcase?.postId}',
      'ArtistShowcase',
    );
    if (!mounted || _candidateTag != tagName) return;
    if (showcase == null) {
      // 没收录代表作就收起卡片，不留占位。
      _dismiss();
      return;
    }

    AppLogger.d(
      'Artist showcase card for $tagName: ${showcase.imageUrl}',
      'ArtistShowcase',
    );
    setState(() {
      _showcase = showcase;
      _anchor = _resolveAnchor();
    });
    _portal.show();
  }

  /// 加载态卡片：标签名立即出现，图片位置用加载动画占位。
  void _showLoadingCard(String tagName) {
    setState(() {
      _showcase = ArtistShowcase(
        artistTag: tagName,
        postId: 0,
        imageUrl: '',
        previewUrl: '',
        postUrl: '',
        width: 4,
        height: 3,
      );
      _anchor = _resolveAnchor();
    });
    _portal.show();
  }

  /// 点击卡片打开该作品详情：复用在线画廊的详情弹窗。
  void _openDetail(ArtistShowcase showcase) {
    final post = showcase.post;
    if (post == null) return;
    _dismiss();
    unawaited(
      OnlineGalleryDetailLauncher(
        context: context,
        ref: ref,
      ).show(context, post),
    );
  }

  void _dismiss() {
    if (!mounted || !_portal.isShowing) return;
    _portal.hide();
    setState(() => _showcase = null);
  }

  /// 卡片锚点：贴着选中标签，取不到几何信息时退回指针位置。
  ///
  /// 摆放按全局坐标算，只在软键盘弹起时把可用区域换成"键盘之上、安全区以内"：
  /// 编辑器可以很高，按它自身范围判断会让卡片落进键盘占住的那一段。没有键盘
  /// 遮挡时（桌面端、键盘收起）沿用编辑器自身范围，摆放与原来一致。
  Offset _resolveAnchor() {
    final targetBox = _targetKey.currentContext?.findRenderObject();
    if (targetBox is! RenderBox) return Offset.zero;

    // 编辑器拿到的 MediaQuery 已经消费掉键盘高度，这里取上层那一份。
    final media = MediaQuery.of(Scaffold.maybeOf(context)?.context ?? context);
    final keyboardUp = media.viewInsets.bottom > 0;
    final bounds = keyboardUp
        ? Rect.fromLTRB(
            media.padding.left,
            media.padding.top,
            media.size.width - media.padding.right,
            media.size.height -
                math.max(media.padding.bottom, media.viewInsets.bottom),
          )
        : (targetBox.localToGlobal(Offset.zero) & targetBox.size);
    final cardHeight = keyboardUp
        ? ArtistShowcaseCard.estimatedHeightFor(_showcase)
        : 210.0;

    final selection = _selectionAnchor() ?? _lastPointer;
    if (selection == null) return targetBox.globalToLocal(bounds.topLeft + const Offset(24, 24));

    const gap = 14.0;
    const cardWidth = ArtistShowcaseCard.cardWidth;

    final fitsRight = selection.dx + gap + cardWidth <= bounds.right;
    final preferredX = fitsRight
        ? selection.dx + gap
        : selection.dx - cardWidth - gap;

    final below = selection.dy + 18;
    final above = selection.dy - cardHeight - 10;
    final y = below + cardHeight <= bounds.bottom
        ? below
        : math.max(bounds.top, above);

    return targetBox.globalToLocal(
      Offset(
        preferredX.clamp(
          bounds.left,
          math.max(bounds.left, bounds.right - cardWidth),
        ),
        y,
      ),
    );
  }

  /// 选中范围的右下角全局坐标，用于把卡片贴在标签旁边。
  Offset? _selectionAnchor() {
    final targetContext = _targetKey.currentContext;
    if (targetContext == null) return null;
    final renderEditable = _findRenderEditable(targetContext);
    if (renderEditable == null) return null;

    final range = _selectionDisplayRange();
    if (range == null) return null;
    final boxes = renderEditable.getBoxesForSelection(
      TextSelection(baseOffset: range.$1, extentOffset: range.$2),
    );
    if (boxes.isEmpty) return null;
    final box = boxes.first;
    return renderEditable.localToGlobal(Offset(box.right, box.bottom));
  }

  /// 源文本选区换算成编辑器里的显示区间。
  (int, int)? _selectionDisplayRange() {
    final controller = widget.session.controller;
    final selection = controller.selection;
    if (!selection.isValid || selection.isCollapsed) return null;
    final projection = PromptTextProjection(controller.text);
    final start = projection.toDisplay(selection.start);
    final end = projection.toDisplay(selection.end);
    if (start < 0 || end < start) return null;
    return (start, end);
  }

  static RenderEditable? _findRenderEditable(BuildContext context) {
    RenderEditable? result;
    void visit(Element element) {
      if (result != null) return;
      final renderObject = element.renderObject;
      if (renderObject is RenderEditable) {
        result = renderObject;
        return;
      }
      element.visitChildren(visit);
    }

    (context as Element).visitChildren(visit);
    return result;
  }

  @override
  Widget build(BuildContext context) {
    return CompositedTransformTarget(
      link: _layerLink,
      child: OverlayPortal(
        controller: _portal,
        overlayChildBuilder: (context) {
          final showcase = _showcase;
          if (showcase == null) return const SizedBox.shrink();
          return Positioned(
            left: 0,
            top: 0,
            child: CompositedTransformFollower(
              link: _layerLink,
              targetAnchor: Alignment.topLeft,
              followerAnchor: Alignment.topLeft,
              child: Padding(
                padding: EdgeInsets.only(left: _anchor.dx, top: _anchor.dy),
                child: ArtistShowcaseCard(
                  showcase: showcase,
                  loading: showcase.imageUrl.isEmpty,
                  onTap: showcase.post == null
                      ? null
                      : () => _openDetail(showcase),
                ),
              ),
            ),
          );
        },
        child: MouseRegion(
          // 只记录指针位置用于兜底摆放卡片，不改变编辑器原有的命中行为。
          opaque: false,
          onHover: _handlePointerHover,
          child: KeyedSubtree(key: _targetKey, child: widget.child),
        ),
      ),
    );
  }
}
