import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/services/anlas_calculator.dart';
import '../../../data/models/image/image_params.dart';
import '../../providers/image_generation_provider.dart';
import '../../providers/subscription_provider.dart';
import 'generation_prompt_variations.dart';

class GenerationAnlasEstimator {
  GenerationAnlasEstimator(this._ref);

  final Ref _ref;

  int get currentBatchSize => _ref.read(imagesPerRequestProvider);

  int estimate(
    ImageParams params, {
    required int requestCount,
    int? batchSize,
  }) {
    final subscription = _ref.read(subscriptionNotifierProvider).subscription;
    final tier = subscription?.isOpus == true ? AnlasCalculator.opusTier : 0;
    return AnlasCalculator.calculateRequestCost(
      width: params.width,
      height: params.height,
      steps: params.steps,
      batchCount: params.nSamples * requestCount,
      batchSize: batchSize ?? currentBatchSize,
      smea: params.effectiveSmea,
      smeaDyn: params.effectiveSmeaDyn,
      model: params.model,
      subscriptionTier: tier,
      opusQuotaExhausted: subscription?.usage?.isNegative ?? false,
      strength: switch (params.action) {
        ImageGenerationAction.img2img => params.strength,
        ImageGenerationAction.infill => params.inpaintStrength,
        ImageGenerationAction.generate => 1.0,
      },
      extraPerSampleCost: AnlasCalculator.resolvePreciseReferenceExtraCost(
        params,
      ),
      extraPerRequestCost: AnlasCalculator.resolveVibeReferenceExtraCost(
        params,
      ),
      oneTimeCost: AnlasCalculator.resolveVibeEncodingCost(params),
    );
  }

  /// Multi-prompt runs may mix canvas sizes, steps and samplers, so the cost
  /// of each entry is calculated independently and summed.
  int estimateVariations(
    ImageParams base,
    List<PromptVariation> variations,
  ) {
    var total = 0;
    for (final variation in variations) {
      final params = variation.applyOverrides(
        base.copyWith(prompt: variation.prompt, nSamples: 1),
      );
      final cost = estimate(params, requestCount: 1, batchSize: 1);
      if (cost == AnlasCalculator.invalidCost) return cost;
      total += cost;
    }
    return total;
  }
}
