import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/utils/localization_extension.dart';
import '../../../adaptive/interaction_policy.dart';
import '../../../providers/generation/generation_center_mode_provider.dart';
import '../../../themes/core/layered_surface_style.dart';
import '../../../themes/theme_extension.dart';
import '../canvas/infinite_canvas_view.dart';
import '../storyboard/storyboard_view.dart';
import 'image_preview.dart';

/// 生成页中央工作区：图像预览、无限画布与分镜在此切换。
///
/// 切换是"当前视图向左退出、目标视图自右进入"，两端都保持子树存活
/// （`Offstage + TickerMode`），因此视口、选中、滚动与提示词编辑状态都不会
/// 因为来回切换而丢失。桌面经典布局、官网式布局与移动端共用这一个容器。
///
/// 非预览模式各自的工具条里带退出入口，所以这里的入口控件只在预览时出现。
class GenerationCenterWorkspace extends ConsumerStatefulWidget {
  const GenerationCenterWorkspace({super.key, this.showModeSwitch = true});

  /// 是否在预览区左上角浮出模式入口。
  ///
  /// 移动端把这两个入口放进顶栏（与参数、Agent、历史同排），浮层按钮会压住画布，
  /// 因此由布局方关掉它；桌面经典布局与官网式布局仍用浮层入口。
  final bool showModeSwitch;

  @override
  ConsumerState<GenerationCenterWorkspace> createState() =>
      _GenerationCenterWorkspaceState();
}

class _GenerationCenterWorkspaceState
    extends ConsumerState<GenerationCenterWorkspace>
    with SingleTickerProviderStateMixin {
  /// 0 → 1 表示从 [_from] 渡过到 [_to]；稳定在某个模式时为 1。
  late final AnimationController _transition;

  late GenerationCenterMode _from;
  late GenerationCenterMode _to;

  /// 进入过一次的子树保持挂载，避免切回来时重建视图状态。
  final Set<GenerationCenterMode> _mounted = <GenerationCenterMode>{};

  @override
  void initState() {
    super.initState();
    final mode = ref.read(generationCenterModeControllerProvider);
    _from = mode;
    _to = mode;
    _mounted.add(mode);
    _transition = AnimationController(vsync: this, value: 1);
  }

  @override
  void dispose() {
    _transition.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final reduceMotion = MediaQuery.disableAnimationsOf(context);

    ref.listen<GenerationCenterMode>(generationCenterModeControllerProvider, (
      previous,
      next,
    ) {
      if (!mounted || previous == next) return;
      _beginTransition(next, reduceMotion: reduceMotion, theme: theme);
    });

    // 子树只在 widget 重建时构造一次，切换动画不会逐帧重建它们。
    final modes = <GenerationCenterMode, Widget>{
      GenerationCenterMode.preview: const ImagePreviewWidget(),
      GenerationCenterMode.canvas: const InfiniteCanvasView(),
      GenerationCenterMode.storyboard: const StoryboardView(),
    };

    return AnimatedBuilder(
      animation: _transition,
      builder: (context, _) {
        final progress = _transition.value;
        final switchOpacity = _switchOpacity(progress);
        return Stack(
          children: [
            for (final entry in modes.entries)
              if (_mounted.contains(entry.key))
                _buildSlotted(
                  child: entry.value,
                  horizontalOffset: _offsetFor(entry.key, progress),
                  visibility: _visibilityFor(entry.key, progress),
                ),
            if (switchOpacity > 0.001 && widget.showModeSwitch)
              Positioned(
                top: 12,
                left: 12,
                child: _CenterModeSwitch(opacity: switchOpacity),
              ),
          ],
        );
      },
    );
  }

  /// 动画途中改切第三个模式时先把上一段落到终态。
  ///
  /// 否则会出现"上一段还没走完、下一段已经开始"的三视图半透明叠加。
  void _beginTransition(
    GenerationCenterMode next, {
    required bool reduceMotion,
    required ThemeData theme,
  }) {
    _mounted.add(next);
    setState(() {
      _from = _to;
      _to = next;
    });

    if (_from == _to || reduceMotion) {
      _transition.value = 1;
      return;
    }
    _transition.value = 0;
    _transition.duration = theme.appTheme.normalDuration;
    _transition.animateTo(1, curve: theme.appTheme.enterCurve);
  }

  /// 目标视图之外的其它模式一律不可见，因此只有两端参与滑动。
  double _visibilityFor(GenerationCenterMode mode, double progress) {
    if (_from == _to) return mode == _to ? 1 : 0;
    if (mode == _from) return 1 - progress;
    if (mode == _to) return progress;
    return 0;
  }

  double _offsetFor(GenerationCenterMode mode, double progress) {
    if (_from == _to) return 0;
    if (mode == _from) return -progress;
    if (mode == _to) return 1 - progress;
    return 0;
  }

  /// 入口控件只在停留在预览时完整可见，离开预览的瞬间淡出。
  double _switchOpacity(double progress) {
    if (_to != GenerationCenterMode.preview) return 0;
    return (1 - (1 - progress) * 2).clamp(0.0, 1.0);
  }

  Widget _buildSlotted({
    required Widget child,
    required double horizontalOffset,
    required double visibility,
  }) {
    final visible = visibility > 0.001;
    return Offstage(
      offstage: !visible,
      child: TickerMode(
        enabled: visible,
        child: IgnorePointer(
          ignoring: !visible,
          child: FractionalTranslation(
            translation: Offset(horizontalOffset, 0),
            child: Opacity(
              opacity: visibility.clamp(0.0, 1.0),
              child: SizedBox.expand(child: child),
            ),
          ),
        ),
      ),
    );
  }
}

/// 预览态左上角的入口：进入无限画布或分镜。
///
/// 浮在中央工作区之上，不参与布局；两个入口都是显式按钮，不依赖 hover。
class _CenterModeSwitch extends ConsumerWidget {
  const _CenterModeSwitch({required this.opacity});

  final double opacity;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final extent = context.interactionPolicy.minimumControlExtent.clamp(
      36.0,
      48.0,
    );
    return Opacity(
      opacity: opacity,
      child: Material(
        color: sectionSurfaceColor(theme.colorScheme),
        borderRadius: BorderRadius.circular(10),
        clipBehavior: Clip.antiAlias,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _CenterModeButton(
              icon: Icons.auto_awesome_motion_outlined,
              tooltip: context.l10n.infinite_canvas_open,
              extent: extent,
              onTap: () => ref
                  .read(generationCenterModeControllerProvider.notifier)
                  .show(GenerationCenterMode.canvas),
            ),
            _CenterModeButton(
              icon: Icons.dashboard_customize_outlined,
              tooltip: context.l10n.storyboard_open,
              extent: extent,
              onTap: () => ref
                  .read(generationCenterModeControllerProvider.notifier)
                  .show(GenerationCenterMode.storyboard),
            ),
          ],
        ),
      ),
    );
  }
}

class _CenterModeButton extends StatelessWidget {
  const _CenterModeButton({
    required this.icon,
    required this.tooltip,
    required this.extent,
    required this.onTap,
  });

  final IconData icon;
  final String tooltip;
  final double extent;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        child: SizedBox(
          width: extent,
          height: extent,
          child: Icon(
            icon,
            size: 20,
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}
