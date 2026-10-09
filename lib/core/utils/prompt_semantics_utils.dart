import '../constants/api_constants.dart';
import '../constants/model_capabilities.dart';
import '../enums/model_mode.dart';
import 'novelai_auto_text.dart';
import 'prompt_edit_document.dart';

/// 提示词语义快照
///
/// - basePrompt/baseNegativePrompt: 结构化元数据中保留的基础文本
/// - effectivePrompt/effectiveNegativePrompt: 当前实际送给模型时的等效文本
class PromptSemanticsSnapshot {
  const PromptSemanticsSnapshot({
    required this.basePrompt,
    required this.baseNegativePrompt,
    required this.effectivePrompt,
    required this.effectiveNegativePrompt,
    this.autoTextBlock,
  });

  final String basePrompt;
  final String baseNegativePrompt;
  final String effectivePrompt;
  final String effectiveNegativePrompt;
  final String? autoTextBlock;
}

PromptSemanticsSnapshot buildPromptSemanticsSnapshot({
  required String prompt,
  required String negativePrompt,
  required String model,
  required bool qualityToggle,
  required int ucPreset,
  bool isEnhanceRequest = false,
  bool transparentBackground = false,
  String qualityTier = QualityTags.standardTier,
  List<NovelAiAutoTextCharacter> characters = const [],
  bool useCoords = false,
  ModelMode modelMode = ModelMode.anime,
}) {
  final basePrompt = prompt;
  final baseNegativePrompt = negativePrompt;
  prompt = PromptEditDocument.effectiveText(prompt);
  negativePrompt = PromptEditDocument.effectiveText(negativePrompt);
  characters = characters
      .map(
        (character) => NovelAiAutoTextCharacter(
          prompt: PromptEditDocument.effectiveText(character.prompt),
          centerX: character.centerX,
          centerY: character.centerY,
          enabled: character.enabled,
        ),
      )
      .toList(growable: false);
  final capabilities = ModelCapabilityRegistry.of(model);
  // 官网的 Model Mode 不进入请求参数：Furry 只由客户端把 `fur dataset, `
  // 数据集标签加到正向提示词最前面，Anime 不加任何内容。模型不支持该模式时
  // （网页端能力位 hasFurryMode 为 false）不注入。质量词是后缀，因此前缀
  // 一定落在最终提示词最前面。
  if (capabilities.supportsModelMode) {
    prompt = modelMode.applyDatasetTag(prompt);
  }
  // 自定义质量预设在到这一步之前就已经并进 prompt（qualityToggle=false），
  // 因此 `transparent background` 会落在自定义质量词之后；官网没有自定义
  // 预设这一路，NAI 默认质量词的顺序与官网一致。
  var effectivePrompt = QualityTags.applySuffix(
    prompt,
    QualityTags.composeSuffix(
      model,
      qualityToggle: qualityToggle,
      transparentBackground:
          transparentBackground && capabilities.supportsTransparentBackground,
      qualityTier: qualityTier,
    ),
    capabilities,
  );
  if (isEnhanceRequest && capabilities.supportsEnhancePromptAdd) {
    effectivePrompt = EnhanceLevels.applyPromptAddition(effectivePrompt);
  }

  String? autoTextBlock;
  if (capabilities.supportsAutoText) {
    autoTextBlock = NovelAiAutoText.buildBlock(
      effectivePrompt,
      characters: characters,
      useCoords: useCoords,
    );
    effectivePrompt = NovelAiAutoText.apply(
      effectivePrompt,
      characters: characters,
      useCoords: useCoords,
    );
  }

  // 节约模式不支持自定义 UC：官网固定发 V5 的 Heavy 预设，用户的负面
  // 提示词与预设选择都不进请求（界面提示改用负权重，如 `-3::hat::`）。
  final effectiveNegativePrompt = capabilities.locksUndesiredContent
      ? UcPresets.getPresetContent(model, UcPresetType.heavy)
      : UcPresets.applyPresetWithNsfwCheck(
          negativePrompt,
          prompt,
          model,
          ucPreset,
        );

  return PromptSemanticsSnapshot(
    basePrompt: basePrompt,
    baseNegativePrompt: baseNegativePrompt,
    effectivePrompt: effectivePrompt,
    effectiveNegativePrompt: effectiveNegativePrompt,
    autoTextBlock: autoTextBlock,
  );
}
