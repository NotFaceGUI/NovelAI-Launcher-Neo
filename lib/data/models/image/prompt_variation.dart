import 'image_params.dart';

/// One entry of a multi-prompt generation run.
///
/// The positive prompt is always replaced for that batch. Optional fields
/// override the shared request for that single image so one run can mix
/// portrait, landscape, square or other canvases.
class PromptVariation {
  const PromptVariation({
    required this.prompt,
    this.width,
    this.height,
    this.steps,
    this.sampler,
    this.scale,
    this.seed,
    this.characters,
    this.useCoords,
  });

  final String prompt;
  final int? width;
  final int? height;
  final int? steps;
  final String? sampler;
  final double? scale;
  final int? seed;

  /// Per-image character prompts. Null inherits the shared request; an empty
  /// list explicitly clears characters for this image.
  final List<CharacterPrompt>? characters;
  final bool? useCoords;

  bool get hasExplicitSeed => seed != null;

  /// Applies every field except the prompts. Positive and negative prompt
  /// resolution runs through the generation preset chain before this is called.
  ImageParams applyOverrides(ImageParams params) {
    var next = params;
    final entryWidth = width;
    if (entryWidth != null) next = next.copyWith(width: entryWidth);
    final entryHeight = height;
    if (entryHeight != null) next = next.copyWith(height: entryHeight);
    final entrySteps = steps;
    if (entrySteps != null) next = next.copyWith(steps: entrySteps);
    final entrySampler = sampler;
    if (entrySampler != null) next = next.copyWith(sampler: entrySampler);
    final entryScale = scale;
    if (entryScale != null) next = next.copyWith(scale: entryScale);
    final entrySeed = seed;
    if (entrySeed != null) next = next.copyWith(seed: entrySeed);
    final entryCharacters = characters;
    if (entryCharacters != null) {
      next = next.copyWith(
        characters: entryCharacters,
        useCoords: useCoords ?? false,
      );
    }
    return next;
  }
}
