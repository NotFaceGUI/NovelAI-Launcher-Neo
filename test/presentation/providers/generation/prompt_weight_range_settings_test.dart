import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nai_launcher/core/storage/local_storage_service.dart';
import 'package:nai_launcher/data/models/prompt/prompt_weight_range.dart';
import 'package:nai_launcher/presentation/providers/generation/generation_settings_notifiers.dart';

class _MemoryStorage extends LocalStorageService {
  _MemoryStorage({this.min, this.max});

  double? min;
  double? max;

  @override
  double? getPromptWeightMin() => min;

  @override
  double? getPromptWeightMax() => max;

  @override
  Future<void> setPromptWeightRange(double min, double max) async {
    this.min = min;
    this.max = max;
  }
}

void main() {
  test('uses the default range when nothing is stored', () {
    final storage = _MemoryStorage();
    final container = ProviderContainer(
      overrides: [localStorageServiceProvider.overrideWithValue(storage)],
    );
    addTearDown(container.dispose);

    expect(
      container.read(promptWeightRangeSettingsProvider),
      PromptWeightRange.defaults,
    );
  });

  test('persists a narrowed range', () async {
    final storage = _MemoryStorage();
    final container = ProviderContainer(
      overrides: [localStorageServiceProvider.overrideWithValue(storage)],
    );
    addTearDown(container.dispose);

    await container
        .read(promptWeightRangeSettingsProvider.notifier)
        .setRange(0.53, 1.97);

    final range = container.read(promptWeightRangeSettingsProvider);
    expect(range.min, 0.55);
    expect(range.max, 1.95);
    expect(storage.min, 0.55);
    expect(storage.max, 1.95);
  });

  test('rejects an invalid range without changing state', () async {
    final container = ProviderContainer(
      overrides: [
        localStorageServiceProvider.overrideWithValue(_MemoryStorage()),
      ],
    );
    addTearDown(container.dispose);

    await expectLater(
      container
          .read(promptWeightRangeSettingsProvider.notifier)
          .setRange(2.0, 2.0),
      throwsFormatException,
    );
    expect(
      container.read(promptWeightRangeSettingsProvider),
      PromptWeightRange.defaults,
    );
  });

  test('normalizes an invalid stored range back to defaults', () {
    final container = ProviderContainer(
      overrides: [
        localStorageServiceProvider.overrideWithValue(
          _MemoryStorage(min: 5, max: 1),
        ),
      ],
    );
    addTearDown(container.dispose);

    expect(
      container.read(promptWeightRangeSettingsProvider),
      PromptWeightRange.defaults,
    );
  });
}
