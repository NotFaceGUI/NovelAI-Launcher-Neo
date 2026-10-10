import 'dart:math' as math;

import 'package:flutter/material.dart';
import '../../themes/core/layered_surface_style.dart';

/// A thin boundary keeps the floating editor identifiable over similar neutral
/// surfaces without adding outlines to its individual controls.
class PromptActionSurface extends StatelessWidget {
  const PromptActionSurface({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Material(
      color: overlaySurfaceColor(colors),
      surfaceTintColor: Colors.transparent,
      elevation: 8,
      shadowColor: Colors.black.withValues(alpha: 0.4),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(color: colors.outline),
      ),
      child: child,
    );
  }
}

/// Measures the real action content before positioning it. Translation length,
/// text scaling and the keyboard therefore cannot invalidate a fixed height.
///
/// [preferBelow] 为真时优先放在锚点下方：触屏上系统选择工具栏会占住选区上方，
/// 两边压在一起就是"两个气泡"；下方放不下时翻回上方。鼠标端保持原来优先上方。
class PromptActionOverlay extends StatelessWidget {
  const PromptActionOverlay({
    super.key,
    required this.anchor,
    required this.overlaySize,
    required this.child,
    this.preferBelow = false,
  });
  final Rect anchor;
  final Size overlaySize;
  final Widget child;
  final bool preferBelow;

  @override
  Widget build(BuildContext context) {
    // Scaffold removes consumed keyboard insets from its body. The root overlay
    // still spans the full view, so use the metrics above that resize boundary.
    final media = MediaQuery.of(Scaffold.maybeOf(context)?.context ?? context);
    final left = media.padding.left + 8;
    final top = media.padding.top + 8;
    final right = math.max(left, overlaySize.width - media.padding.right - 8);
    final bottom = math.max(
      top,
      overlaySize.height -
          math.max(media.padding.bottom, media.viewInsets.bottom) -
          8,
    );
    return Positioned.fill(
      child: CustomSingleChildLayout(
        delegate: _PromptActionLayout(
          anchor,
          Rect.fromLTRB(left, top, right, bottom),
          preferBelow,
        ),
        child: SingleChildScrollView(
          key: const ValueKey('prompt-action-viewport'),
          child: child,
        ),
      ),
    );
  }
}

class _PromptActionLayout extends SingleChildLayoutDelegate {
  const _PromptActionLayout(this.anchor, this.bounds, this.preferBelow);
  final Rect anchor;
  final Rect bounds;
  final bool preferBelow;
  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) =>
      BoxConstraints(
        maxWidth: math.min(420, bounds.width),
        maxHeight: bounds.height,
      );
  @override
  Offset getPositionForChild(Size size, Size childSize) {
    final below = anchor.bottom + 6;
    final above = anchor.top - childSize.height - 6;
    final belowFits = below + childSize.height <= bounds.bottom;
    final aboveFits = above >= bounds.top;
    final y = preferBelow
        ? (belowFits ? below : above)
        : (aboveFits ? above : below);
    return Offset(
      anchor.left.clamp(
        bounds.left,
        math.max(bounds.left, bounds.right - childSize.width),
      ),
      y.clamp(
        bounds.top,
        math.max(bounds.top, bounds.bottom - childSize.height),
      ),
    );
  }

  @override
  bool shouldRelayout(_PromptActionLayout oldDelegate) =>
      anchor != oldDelegate.anchor ||
      bounds != oldDelegate.bounds ||
      preferBelow != oldDelegate.preferBelow;
}
