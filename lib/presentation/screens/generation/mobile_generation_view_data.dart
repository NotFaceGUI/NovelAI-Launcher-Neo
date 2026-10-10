import '../../providers/image_generation_provider.dart';

class MobileGenerationViewData {
  const MobileGenerationViewData({
    required this.generationState,
    required this.cooldownRemainingSeconds,
    required this.isPromptMaximized,
    required this.isStoryboardMode,
    required this.isPreviewMode,
    required this.keyboardVisible,
    required this.isGenerating,
    required this.isLauncherGenerating,
    required this.requiresLogin,
    required this.showRandomTools,
    required this.isUpscaleMode,
    required this.randomModeEnabled,
    required this.promptSummary,
    required this.enabledCharacterCount,
    required this.qualityEnabled,
    required this.negativePresetLabel,
    required this.fixedTagCount,
  });

  final ImageGenerationState generationState;
  final int cooldownRemainingSeconds;
  final bool isPromptMaximized;

  /// 中央工作区停在分镜编辑器：返回键要先退出分镜，而不是退回上一级路由。
  final bool isStoryboardMode;

  /// 中央工作区停在图像预览。
  ///
  /// 画布与分镜自己消费拖拽，工作区的上下滑快捷手势与手势提示都只在这个模式
  /// 下成立。
  final bool isPreviewMode;

  final bool keyboardVisible;
  final bool isGenerating;
  final bool isLauncherGenerating;
  final bool requiresLogin;
  final bool showRandomTools;
  final bool isUpscaleMode;
  final bool randomModeEnabled;
  final String promptSummary;
  final int enabledCharacterCount;
  final bool qualityEnabled;
  final String? negativePresetLabel;
  final int fixedTagCount;
}
