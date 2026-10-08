/// 多提示词模式（agent `prompts` 参数）的共享解析与校验。
///
/// `prompts` 是每张图一条的完整正向提示词列表：准备阶段用它计算批次数量和
/// Anlas，执行阶段用它构造每批一张的提示词序列。两处必须得出同一份结果，
/// 因此校验只在这里维护。
class PromptVariationArguments {
  const PromptVariationArguments({required this.prompts, required this.error});

  /// 解析成功的提示词列表；调用方未提供 `prompts` 时为 null。
  final List<String>? prompts;

  /// 面向模型或开发者的失败原因；成功时为 null。
  final String? error;
}

PromptVariationArguments parsePromptVariations(
  Object? raw, {
  required int maximum,
}) {
  if (raw == null) {
    return const PromptVariationArguments(prompts: null, error: null);
  }
  if (raw is! List) {
    return const PromptVariationArguments(
      prompts: null,
      error: 'Parameter "prompts" must be an array of strings.',
    );
  }
  if (raw.isEmpty || raw.length > maximum) {
    return PromptVariationArguments(
      prompts: null,
      error:
          'Parameter "prompts" must hold between 1 and $maximum prompts; '
          'got ${raw.length}.',
    );
  }
  final prompts = <String>[];
  for (var index = 0; index < raw.length; index++) {
    final entry = raw[index];
    final text = entry is String ? entry.trim() : '';
    if (text.isEmpty) {
      return PromptVariationArguments(
        prompts: null,
        error: 'Parameter "prompts[$index]" must be a non-empty string.',
      );
    }
    prompts.add(text);
  }
  return PromptVariationArguments(prompts: prompts, error: null);
}
