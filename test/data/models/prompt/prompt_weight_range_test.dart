import 'package:flutter_test/flutter_test.dart';
import 'package:nai_launcher/data/models/prompt/prompt_weight_range.dart';

void main() {
  group('PromptWeightRange', () {
    test('defaults span the full numeric range from -10 to 10', () {
      const range = PromptWeightRange.defaults;
      expect(range.min, -10);
      expect(range.max, 10);
      expect(range.isDefault, isTrue);
      expect(range.isValid, isTrue);
      expect(range.clamp(-20), -10);
      expect(range.clamp(0), 0);
      expect(range.clamp(20), 10);
    });

    test('snaps configured values to the 0.05 step', () {
      final range = PromptWeightRange.tryCreate(0.53, 1.97);
      expect(range, isNotNull);
      expect(range!.min, 0.55);
      expect(range.max, 1.95);
      expect(range.isDefault, isFalse);
    });

    test('accepts negative bounds', () {
      final range = PromptWeightRange.tryCreate(-2, 2);
      expect(range, isNotNull);
      expect(range!.min, -2);
      expect(range.max, 2);
    });

    test('rejects ranges outside the numeric bounds', () {
      for (final values in const [
        (-10.1, 0.0),
        (0.0, 10.1),
        (2.0, 2.0),
        (2.0, 1.0),
      ]) {
        expect(
          PromptWeightRange.tryCreate(values.$1, values.$2),
          isNull,
          reason: '${values.$1}–${values.$2}',
        );
      }
    });

    test('formats bounds as compact numbers', () {
      expect(PromptWeightRange.format(-10), '-10');
      expect(PromptWeightRange.format(10), '10');
      expect(PromptWeightRange.format(0.5), '0.50');
      expect(PromptWeightRange.format(-1.25), '-1.25');
    });
  });
}
