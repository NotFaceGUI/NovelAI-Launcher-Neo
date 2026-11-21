import '../../../core/constants/api_constants.dart';
import '../../../data/models/image/prompt_variation.dart';
import 'generation_character_orchestration.dart';

export '../../../data/models/image/prompt_variation.dart';

/// Parsed `prompts` list and the per-entry overrides it carries.
class PromptVariationArguments {
  const PromptVariationArguments({required this.prompts, required this.error});

  /// Parsed entries; null when the caller did not provide `prompts`.
  final List<PromptVariation>? prompts;

  /// Model/developer facing reason when parsing failed; null on success.
  final String? error;
}

PromptVariationArguments parsePromptVariations(
  Object? raw, {
  required int maximum,
  required String model,
}) {
  if (raw == null) {
    return const PromptVariationArguments(prompts: null, error: null);
  }
  if (raw is! List) {
    return const PromptVariationArguments(
      prompts: null,
      error:
          'Parameter "prompts" must be an array of strings or prompt objects.',
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
  final prompts = <PromptVariation>[];
  for (var index = 0; index < raw.length; index++) {
    final variation = _parseEntry(raw[index], index, model);
    if (variation.error != null) {
      return PromptVariationArguments(prompts: null, error: variation.error);
    }
    prompts.add(variation.value!);
  }
  return PromptVariationArguments(prompts: prompts, error: null);
}

({PromptVariation? value, String? error}) _parseEntry(
  Object? raw,
  int index,
  String model,
) {
  if (raw is String) {
    final text = raw.trim();
    if (text.isEmpty) {
      return (value: null, error: _entryError(index, 'must be non-empty'));
    }
    return (value: PromptVariation(prompt: text), error: null);
  }
  if (raw is! Map) {
    return (
      value: null,
      error: _entryError(index, 'must be a string or an object'),
    );
  }
  final prompt = raw['prompt'];
  if (prompt is! String || prompt.trim().isEmpty) {
    return (
      value: null,
      error: _entryError(index, 'needs a non-empty string "prompt"'),
    );
  }
  const allowed = {
    'prompt',
    'width',
    'height',
    'steps',
    'sampler',
    'scale',
    'seed',
    'characters',
    'character_layout_mode',
  };
  final unknown = raw.keys.where((key) => !allowed.contains(key)).toList();
  if (unknown.isNotEmpty) {
    return (
      value: null,
      error: _entryError(
        index,
        'contains unsupported field(s) ${unknown.join(', ')}',
      ),
    );
  }
  final width = _positiveInt(raw['width'], 'width', index);
  if (width.error != null) return (value: null, error: width.error);
  final height = _positiveInt(raw['height'], 'height', index);
  if (height.error != null) return (value: null, error: height.error);
  final steps = _intInRange(raw['steps'], 'steps', index, 1, 50);
  if (steps.error != null) return (value: null, error: steps.error);
  final seed = _intInRange(raw['seed'], 'seed', index, -1, null);
  if (seed.error != null) return (value: null, error: seed.error);
  final sampler = raw['sampler'];
  if (sampler != null &&
      (sampler is! String || !Samplers.allSamplers.contains(sampler))) {
    return (
      value: null,
      error: _entryError(index, 'has an unsupported "sampler"'),
    );
  }
  final scale = raw['scale'];
  if (scale != null && (scale is! num || scale < 0 || scale > 10)) {
    return (
      value: null,
      error: _entryError(index, '"scale" must be between 0 and 10'),
    );
  }
  final rawCharacters = raw['characters'];
  final rawLayoutMode = raw['character_layout_mode'];
  GenerationCharacterSnapshot? characterSnapshot;
  if (rawCharacters != null || rawLayoutMode != null) {
    if (rawCharacters == null) {
      return (
        value: null,
        error: _entryError(
          index,
          '"character_layout_mode" requires an explicit "characters" list',
        ),
      );
    }
    try {
      characterSnapshot = GenerationCharacterOrchestrator.normalizeExplicit(
        rawCharacters: rawCharacters,
        rawLayoutMode: rawLayoutMode,
        model: model,
      );
    } on GenerationCharacterValidationException catch (error) {
      return (
        value: null,
        error: _entryError(index, '"characters": ${error.message}'),
      );
    }
  }
  return (
    value: PromptVariation(
      prompt: prompt.trim(),
      width: width.value,
      height: height.value,
      steps: steps.value,
      sampler: sampler as String?,
      scale: scale == null ? null : (scale as num).toDouble(),
      seed: seed.value,
      characters: characterSnapshot?.characters,
      useCoords: characterSnapshot?.useCoords,
    ),
    error: null,
  );
}

({int? value, String? error}) _positiveInt(
  Object? raw,
  String field,
  int index,
) {
  if (raw == null) return (value: null, error: null);
  if (raw is! int || raw <= 0) {
    return (value: null, error: _entryError(index, '"$field" must be an int'));
  }
  return (value: raw, error: null);
}

({int? value, String? error}) _intInRange(
  Object? raw,
  String field,
  int index,
  int minimum,
  int? maximum,
) {
  if (raw == null) return (value: null, error: null);
  if (raw is! int || raw < minimum || (maximum != null && raw > maximum)) {
    final range = maximum == null ? '>= $minimum' : '$minimum..$maximum';
    return (
      value: null,
      error: _entryError(index, '"$field" must be an int in $range'),
    );
  }
  return (value: raw, error: null);
}

String _entryError(int index, String reason) =>
    'Parameter "prompts[$index]" $reason.';
